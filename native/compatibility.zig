const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const wire = @import("wire.zig");
pub const Object = @FieldType(native.Namespace.AuditTaskView, "image");

pub const ImageDigest = struct {
    sha256: t.Digest,

    pub fn of(image: []const u8) ImageDigest {
        return .{ .sha256 = digest(image) };
    }

    pub fn names(self: ImageDigest, object: Object) bool {
        return std.meta.eql(object.digest, self.sha256);
    }
};

pub const ProfileBinding = struct {
    digest: t.Digest,
    resources: []const Object,
};

pub const Candidate = struct {
    image: ImageDigest,
    runtime: t.Digest,
    has_controller: bool,
    principal: []const u8,
    tenant: []const u8,
    profile: ?ProfileBinding,
};

pub const Disposition = union(enum) {
    terminal_reusable: void,
    exact_continuation: void,
    requires_supersession: enum { image, runtime, controller, profile, resources },
    profile_unresolved: void,
};

pub const Task = struct {
    id: t.Id,
    revision: u64,
    disposition: Disposition,

    pub fn jsonStringify(self: Task, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(&wire.hex(self.id));
        try writer.objectField("revision");
        try writer.write(self.revision);
        try writer.objectField("disposition");
        try writer.write(self.disposition);
        try writer.endObject();
    }
};

pub const Report = struct {
    native_closure: native.NamespaceAuditReport,
    tasks: []const Task,

    pub fn complete(self: Report) bool {
        for (self.tasks) |item| if (item.disposition == .profile_unresolved) return false;
        return true;
    }
};

pub const OwnedReport = struct {
    arena: std.heap.ArenaAllocator,
    value: Report,

    pub fn deinit(self: *OwnedReport) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn digest(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn fromProfile(
    a: std.mem.Allocator,
    image: ImageDigest,
    has_controller: bool,
    profile: native.tasks.Profile,
) !Candidate {
    const resources = try a.alloc(Object, profile.resources.len);
    for (profile.resources, resources) |bytes, *reference| reference.* = .{
        .digest = digest(bytes),
        .bytes = bytes.len,
    };
    return .{
        .image = image,
        .runtime = profile.runtime_identity,
        .has_controller = has_controller,
        .principal = profile.authority.principal,
        .tenant = profile.authority.tenant,
        .profile = .{ .digest = digest(profile.bytes), .resources = resources },
    };
}

pub fn classify(candidate: Candidate, task: native.Namespace.AuditTaskView) !Disposition {
    if (!same(task.application_id, t.application_id)) return error.WrongApplication;
    if (!same(task.principal, candidate.principal) or !same(task.tenant, candidate.tenant))
        return error.IncompatibleOwner;
    if (task.terminal) return .{ .terminal_reusable = {} };
    if (!candidate.image.names(task.image)) return .{ .requires_supersession = .image };
    if (!std.meta.eql(task.runtime_identity, candidate.runtime))
        return .{ .requires_supersession = .runtime };
    if (task.has_controller != candidate.has_controller)
        return .{ .requires_supersession = .controller };
    const profile = candidate.profile orelse return .{ .profile_unresolved = {} };
    if (!std.meta.eql(task.profile.digest, profile.digest))
        return .{ .requires_supersession = .profile };
    if (task.resources.len != profile.resources.len)
        return .{ .requires_supersession = .resources };
    for (task.resources, profile.resources) |retained, selected| {
        if (!std.meta.eql(retained, selected)) return .{ .requires_supersession = .resources };
    }
    return .{ .exact_continuation = {} };
}

const Decoder = struct {
    allocator: std.mem.Allocator,
    results: std.mem.Allocator,
    candidate: Candidate,
    tasks: std.ArrayList(Task) = .empty,

    fn value(context: ?*anyopaque, retained: native.NamespaceApplicationValue) !void {
        const self: *Decoder = @ptrCast(@alignCast(context.?));
        if (!same(retained.application_id, t.application_id)) return error.WrongApplication;
        switch (retained.kind) {
            .input => try validate(t.Input, self.allocator, retained, t.input_schema_id),
            .output => try validate(t.Output, self.allocator, retained, t.output_schema_id),
            .failure => try validate(t.Failure, self.allocator, retained, t.failure_schema_id),
        }
    }

    fn task(context: ?*anyopaque, retained: native.Namespace.AuditTaskView) !void {
        const self: *Decoder = @ptrCast(@alignCast(context.?));
        try self.tasks.append(self.results, .{
            .id = retained.task,
            .revision = retained.revision,
            .disposition = try classify(self.candidate, retained),
        });
    }
};

fn validate(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: native.NamespaceApplicationValue,
    schema: []const u8,
) !void {
    if (!same(value.schema_id, schema)) return error.WrongApplicationSchema;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (value.encoding == .contract) {
        _ = try c.decodeOwned(T, a, value.bytes);
    } else {
        const parsed = try native.json.parseAsset(a, value.bytes, value.bytes.len);
        _ = try native.values.fromJson(T, a, parsed.value);
    }
}

pub fn audit(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    handlers: native.Registry,
    candidate: Candidate,
) !OwnedReport {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var decoder: Decoder = .{
        .allocator = a,
        .results = arena.allocator(),
        .candidate = candidate,
    };
    const report = try native.Namespace.audit(a, io, path, handlers, .{
        .context = &decoder,
        .validate = Decoder.value,
        .task = Decoder.task,
    });
    return .{ .arena = arena, .value = .{
        .native_closure = report,
        .tasks = try decoder.tasks.toOwnedSlice(arena.allocator()),
    } };
}
