const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const configuration = @import("configuration.zig");
const commands = @import("commands.zig");
const idx = @import("index.zig");
const experiments = @import("experiments.zig");
const continuity_control = @import("continuity_control.zig");
const transfer = @import("transfer.zig");
const ingress_policy = @import("ingress_policy.zig");
const messages = @import("messages.zig");
const cli = @import("cli.zig");
const recovery_status = @import("recovery_status.zig");
const admission = @import("admission.zig");
const wire = @import("wire.zig");

pub const frame_bytes_max: u32 = 4 * 1024 * 1024;
pub const capacity_rejection =
    \\{"error":"Capacity","schema":"paredros.control.v1","status":"rejected"}
;
const frame_limits: native.json.Limits = .{ .bytes = frame_bytes_max };

pub const Request = struct {
    version: u32,
    operation: ?t.OperationId,
    command: union(enum) {
        status: struct { after: ?t.Id, limit: u32 },
        monitor_add: commands.MonitorRequest,
        monitor_show: t.Id,
        monitor_directives: struct { target: t.Id, after: ?u64, limit: u32 },
        messages: struct { target: t.Id, after: ?u64, limit: u32 },
        directive: struct { target: t.Id, body: commands.CallerDirective },
        ask: struct { text: t.Text, target: ?t.Id },
        proposal_confirm: commands.ProposalSelector,
        proposal_show: commands.ProposalSelector,
        experiment_run: experiments.Request,
        experiment_show: t.Digest,
        task_show: t.Id,
        method_show: t.Id,
        transfer_export: continuity_control.Export,
        transfer_import: continuity_control.Import,
    },
};

pub fn encode(a: std.mem.Allocator, request: Request) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return native.json.canonical(a, try wire.toJson(Request, arena.allocator(), request));
}

pub fn dispatch(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
) ![]const u8 {
    return dispatchWithEnvironment(a, driver, config, uid, bytes, null);
}

pub fn dispatchWithEnvironment(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
    environment: ?continuity_control.Environment,
) ![]const u8 {
    return dispatchWithIndex(a, driver, config, uid, bytes, environment, null, null);
}

pub fn dispatchWithIndex(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
    environment: ?continuity_control.Environment,
    index: ?*const idx.Index,
    config_path: ?[]const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const read: Read = .{ .index = index, .config_path = config_path };
    const response = execute(scratch, driver, config, uid, bytes, environment, read) catch |err|
        try rejected(scratch, err);
    return frame(a, response) catch |err| frame(a, try rejected(scratch, err));
}

const Read = struct { index: ?*const idx.Index, config_path: ?[]const u8 };

fn frame(a: std.mem.Allocator, value: native.json.Value) ![]u8 {
    if (!try native.json.fits(a, value, frame_limits)) return error.Capacity;
    return native.json.canonicalBounded(a, value, frame_bytes_max);
}

const Extent = struct {
    bytes: u64,
    tokens: u64,

    fn plus(self: Extent, other: Extent) Extent {
        return .{ .bytes = self.bytes + other.bytes, .tokens = self.tokens + other.tokens };
    }

    fn within(self: Extent, room: Extent) bool {
        return self.bytes <= room.bytes and self.tokens <= room.tokens;
    }

    fn less(self: Extent, other: Extent) ?Extent {
        if (!other.within(self)) return null;
        return .{ .bytes = self.bytes - other.bytes, .tokens = self.tokens - other.tokens };
    }
};

const content: Extent = .{ .bytes = frame_bytes_max, .tokens = frame_limits.tokens };
const separator: Extent = .{ .bytes = 1, .tokens = 0 };

fn extent(a: std.mem.Allocator, value: native.json.Value) !Extent {
    const encoded = try native.json.canonical(a, value);
    defer a.free(encoded);
    var pending: std.ArrayList(native.json.Value) = .empty;
    defer pending.deinit(a);
    try pending.append(a, value);
    var tokens: u64 = 0;
    while (pending.pop()) |item| switch (item) {
        .object => |map| {
            tokens += 2 + map.count();
            try pending.appendSlice(a, map.values());
        },
        .array => |items| {
            tokens += 2;
            try pending.appendSlice(a, items.items);
        },
        else => tokens += 1,
    };
    return .{ .bytes = encoded.len, .tokens = tokens };
}

fn dataRoom(a: std.mem.Allocator) !Extent {
    const wrapper = try extent(a, try reply(a, "observed", .null));
    const unwrapped = wrapper.less(try extent(a, .null)) orelse return error.Capacity;
    return content.less(unwrapped) orelse error.Capacity;
}

fn rejected(a: std.mem.Allocator, err: anyerror) !native.json.Value {
    var value = envelope();
    try native.json.put(a, &value, "schema", native.json.string("paredros.control.v1"));
    try native.json.put(a, &value, "status", native.json.string("rejected"));
    try native.json.put(a, &value, "error", native.json.string(@errorName(err)));
    return value;
}

fn envelope() native.json.Value {
    return native.json.object();
}

fn reply(
    a: std.mem.Allocator,
    disposition: []const u8,
    data: native.json.Value,
) !native.json.Value {
    var value = envelope();
    try native.json.put(a, &value, "schema", native.json.string("paredros.control.v1"));
    try native.json.put(a, &value, "status", native.json.string(disposition));
    try native.json.put(a, &value, "data", data);
    return value;
}

fn operation(request: Request) ![]const u8 {
    const value = (request.operation orelse return error.MissingOperationId).bytes;
    if (value.len == 0) return error.InvalidOperationId;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidOperationId;
    return value;
}

fn execute(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
    environment: ?continuity_control.Environment,
    read: Read,
) !native.json.Value {
    if (uid != config.current_uid) return error.PermissionDenied;
    var parsed = try native.json.parse(a, bytes, .{ .bytes = frame_bytes_max });
    defer parsed.deinit();
    const request = try decodeRequest(a, parsed.value);
    const origin: t.Origin = .{ .local = .{ .uid = uid } };
    if (readOnly(request)) {
        if (read.index) |index| return inspect(
            a,
            driver.service,
            index,
            request,
            try driver.clock.now(driver.clock.context),
            read.config_path,
        );
        var index = try driver.rebuild(a);
        defer index.deinit();
        return inspect(
            a,
            driver.service,
            &index,
            request,
            try driver.clock.now(driver.clock.context),
            read.config_path,
        );
    }
    const operation_id = try operation(request);
    if (!try admission.recorded(driver.service, a, operation_id))
        try validateFresh(a, driver, request.command, operation_id);
    var response = switch (request.command) {
        .transfer_export, .transfer_import => try continuityCommand(
            a,
            driver,
            config,
            origin,
            request.command,
            operation_id,
            environment,
        ),
        else => try admitted(a, try admitCommand(a, driver, config, origin, request, operation_id)),
    };
    try native.json.put(a, &response, "operation", native.json.string(operation_id));
    return response;
}

fn validateFresh(
    a: std.mem.Allocator,
    driver: anytype,
    command: @FieldType(Request, "command"),
    operation_id: []const u8,
) !void {
    if (std.mem.indexOfScalar(u8, operation_id, ':') != null) return error.ReservedOperationId;
    if (command == .transfer_export or command == .transfer_import) return;
    var index = try driver.rebuild(a);
    defer index.deinit();
    switch (command) {
        .directive => |value| {
            try ingress_policy.validate(&index);
            try ingress_policy.directive(a, &index, value.target);
        },
        .proposal_confirm => |selector| {
            try ingress_policy.validate(&index);
            const confirmation = try commands.resolveProposal(&index, selector);
            const selected = try commands.proposal(&index, confirmation);
            if (selected.body != .directive) return;
            _ = try commands.CallerDirective.narrow(selected.body.directive);
            const target = selected.target orelse return error.InvalidProposalTarget;
            try ingress_policy.directive(a, &index, target);
        },
        else => try ingress_policy.validate(&index),
    }
}

pub fn observingFrame(a: std.mem.Allocator, bytes: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var parsed = native.json.parse(
        arena.allocator(),
        bytes,
        .{ .bytes = frame_bytes_max },
    ) catch return false;
    defer parsed.deinit();
    const request = decodeRequest(arena.allocator(), parsed.value) catch return false;
    return readOnly(request);
}

fn decodeRequest(a: std.mem.Allocator, value: native.json.Value) !Request {
    const request = try wire.fromJson(Request, a, value);
    if (request.version != 1) return error.UnsupportedProtocol;
    return request;
}

fn readOnly(request: Request) bool {
    return switch (request.command) {
        .status,
        .monitor_show,
        .monitor_directives,
        .messages,
        .task_show,
        .method_show,
        .proposal_show,
        .experiment_show,
        => true,
        else => false,
    };
}

fn admitCommand(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    origin: t.Origin,
    request: Request,
    operation_id: []const u8,
) !t.Id {
    switch (request.command) {
        .monitor_add => |value| return commands.monitor(
            driver,
            a,
            operation_id,
            origin,
            value,
            configuration.template(config),
        ),
        .directive => |value| {
            if (value.body == .cancel and try commands.unrunGenesis(driver, a, value.target))
                return commands.abandon(driver, a, operation_id, origin, value.target);
            return driver.directive(a, operation_id, origin, value.target, value.body.widen());
        },
        .ask => |value| return driver.turn(
            a,
            operation_id,
            origin,
            .{
                .text = value.text,
                .target = value.target,
                .genesis_template = configuration.template(config),
            },
        ),
        .experiment_run => |value| return experiments.admit(
            driver,
            a,
            operation_id,
            origin,
            value,
        ),
        .proposal_confirm => |value| return confirmProposal(
            a,
            driver,
            operation_id,
            origin,
            value,
        ),
        else => return error.InvalidMutation,
    }
}

fn continuityCommand(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    origin: t.Origin,
    command: @FieldType(Request, "command"),
    operation_id: []const u8,
    environment: ?continuity_control.Environment,
) !native.json.Value {
    const context = environment orelse return error.ContinuityEnvironmentUnavailable;
    switch (command) {
        .transfer_export => |value| {
            const outcome = try continuity_control.exportBundle(
                driver,
                a,
                config,
                context,
                operation_id,
                origin,
                value,
            );
            const result = switch (outcome) {
                .progress => |progress| progress,
                .stranded => |tasks| {
                    var refused = try rejected(a, error.StrandedGenesis);
                    var data = native.json.object();
                    try native.json.put(a, &data, "stranded", try wire.toJson(
                        c.Vector(t.Id, null),
                        a,
                        .{ .items = tasks },
                    ));
                    try native.json.put(a, &refused, "data", data);
                    return refused;
                },
            };
            return reply(
                a,
                if (result.phase == .written) "observed" else "admitted",
                try wire.toJson(continuity_control.ExportProgress, a, result),
            );
        },
        .transfer_import => |value| {
            var result = try continuity_control.importBundle(
                driver,
                a,
                config,
                context,
                operation_id,
                origin,
                value,
            );
            defer result.deinit(a);
            const value_type = struct {
                phase: @FieldType(transfer.ImportProgress, "phase"),
                manifest: t.Id,
                members: u64,
                obligations: c.Vector(t.Id, null),
            };
            const data = try wire.toJson(value_type, a, .{
                .phase = result.phase,
                .manifest = result.manifest,
                .members = result.members,
                .obligations = .{ .items = result.obligations },
            });
            return reply(a, if (result.phase == .materialized) "observed" else "admitted", data);
        },
        else => return error.InvalidContinuityCommand,
    }
}

fn confirmProposal(
    a: std.mem.Allocator,
    driver: anytype,
    operation_id: []const u8,
    origin: t.Origin,
    selector: commands.ProposalSelector,
) !t.Id {
    try commands.authenticate(driver, origin);
    var index = try driver.rebuild(a);
    defer index.deinit();
    const confirmation = try commands.resolveProposal(&index, selector);
    const prior = try commands.confirmed(driver, a, &index, operation_id, origin, confirmation);
    if (prior) |task_id| return task_id;
    return commands.admitConfirmation(driver, a, &index, operation_id, origin, confirmation);
}

fn proposal(
    a: std.mem.Allocator,
    index: *const idx.Index,
    selector: commands.ProposalSelector,
) !native.json.Value {
    const confirmation = try commands.resolveProposal(index, selector);
    return wire.toJson(t.Proposal, a, try commands.proposal(index, confirmation));
}

fn admitted(a: std.mem.Allocator, task_id: t.Id) !native.json.Value {
    var data = native.json.object();
    try native.json.put(a, &data, "task", try wire.toJson(t.Id, a, task_id));
    return reply(a, "admitted", data);
}

fn inspect(
    a: std.mem.Allocator,
    service: anytype,
    index: *const idx.Index,
    request: Request,
    clock_ms: i64,
    config_path: ?[]const u8,
) !native.json.Value {
    const data = switch (request.command) {
        .status => |value| try status(a, service, index, clock_ms, value.after, value.limit),
        .monitor_show => |id| try shownMonitor(a, index, id, clock_ms),
        .monitor_directives => |page| try pendingDirectives(
            a,
            index,
            page.target,
            page.after,
            page.limit,
        ),
        .messages => |page| try messagePage(a, index, page, config_path),
        .task_show => |id| try task(a, service, index, id, config_path),
        .method_show => |id| try wire.toJson(
            t.Method,
            a,
            index.head(index.obligation(id) orelse return error.UnknownObligation).method,
        ),
        .proposal_show => |value| try proposal(a, index, value),
        .experiment_show => |value| try campaign(a, index, value),
        else => return error.InvalidReadCommand,
    };
    return reply(a, "observed", data);
}

fn campaign(a: std.mem.Allocator, index: *const idx.Index, id: t.Digest) !native.json.Value {
    var observed = try experiments.campaign(a, index, id);
    defer observed.deinit();
    return wire.toJson(experiments.Campaign, a, observed.value);
}

fn namespaceBytes(io: std.Io, directory: std.Io.Dir) !u64 {
    const File = struct { name: []const u8, transient: bool = false };
    var total: u64 = 0;
    for ([_]File{
        .{ .name = "identity" },
        .{ .name = "owner.lock" },
        .{ .name = "state.sqlite" },
        .{ .name = "seal" },
        .{ .name = "state.sqlite-journal", .transient = true },
        .{ .name = "seal.next", .transient = true },
    }) |file| {
        const stat = directory.statFile(io, file.name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound and file.transient) continue;
            return err;
        };
        if (stat.kind != .file) return error.UnsafeStatePath;
        total = try std.math.add(u64, total, stat.size);
    }
    return total;
}

fn status(
    a: std.mem.Allocator,
    service: anytype,
    index: *const idx.Index,
    clock_ms: i64,
    after: ?t.Id,
    limit: u32,
) !native.json.Value {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    const ordered = try a.dupe(idx.Obligation, index.obligations);
    std.mem.sort(idx.Obligation, ordered, {}, struct {
        fn less(_: void, left: idx.Obligation, right: idx.Obligation) bool {
            return std.mem.order(u8, &left.task, &right.task) == .lt;
        }
    }.less);
    var result = try statusSummary(a, service, index, clock_ms);
    var items: std.array_list.Managed(native.json.Value) = .init(a);
    try native.json.put(a, &result, "obligations", .{ .array = items });
    const widest: ?t.Id = @splat(std.math.maxInt(u8));
    try native.json.put(a, &result, "next", try wire.toJson(?t.Id, a, widest));
    const room = try dataRoom(a);
    var used = try extent(a, result);
    var next: ?t.Id = null;
    var stopped = false;
    for (ordered) |obligation| {
        if (after) |previous| if (std.mem.order(u8, &obligation.task, &previous) != .gt) continue;
        if (items.items.len == limit) {
            stopped = true;
            break;
        }
        const gap: Extent = if (items.items.len == 0) .{ .bytes = 0, .tokens = 0 } else separator;
        const entry = if (room.less(used.plus(gap))) |available|
            try monitor(a, index, obligation.task, clock_ms, available)
        else
            null;
        if (entry == null or (entry.?.clipped and items.items.len != 0)) {
            if (items.items.len == 0) return error.Capacity;
            stopped = true;
            break;
        }
        try items.append(entry.?.value);
        used = used.plus(gap).plus(entry.?.extent);
        next = obligation.task;
    }
    try native.json.put(a, &result, "obligations", .{ .array = items });
    try native.json.put(a, &result, "next", if (stopped)
        try wire.toJson(?t.Id, a, next)
    else
        .null);
    return result;
}

fn statusSummary(
    a: std.mem.Allocator,
    service: anytype,
    index: *const idx.Index,
    clock_ms: i64,
) !native.json.Value {
    var result = native.json.object();
    const bytes = try namespaceBytes(service.io, .{ .handle = service.namespace.directory });
    try native.json.put(a, &result, "namespace_bytes", try wire.toJson(u64, a, bytes));
    var daemon = native.json.object();
    try native.json.put(
        a,
        &daemon,
        "application_version",
        service.application.metadata.object.get("application_version").?,
    );
    try native.json.put(
        a,
        &daemon,
        "artifact_sha256",
        try wire.toJson(t.Digest, a, service.profile.runtime_identity),
    );
    try native.json.put(a, &result, "daemon", daemon);
    try native.json.put(
        a,
        &result,
        "task_count",
        try wire.toJson(u64, a, index.records.len),
    );
    try native.json.put(a, &result, "clock_ms", try wire.toJson(i64, a, clock_ms));
    return result;
}

const Entry = struct { value: native.json.Value, extent: Extent, clipped: bool, shown: usize };

fn monitor(
    a: std.mem.Allocator,
    index: *const idx.Index,
    id: t.Id,
    clock_ms: i64,
    room: Extent,
) !?Entry {
    const obligation = index.obligation(id) orelse return error.UnknownObligation;
    var result = try monitorHead(a, index, obligation, clock_ms);
    return appendPending(a, index, obligation, null, 16, &result, room);
}

fn shownMonitor(
    a: std.mem.Allocator,
    index: *const idx.Index,
    id: t.Id,
    clock_ms: i64,
) !native.json.Value {
    const entry = try monitor(a, index, id, clock_ms, try dataRoom(a)) orelse
        return error.Capacity;
    return entry.value;
}

fn monitorHead(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    clock_ms: i64,
) !native.json.Value {
    const head = index.head(obligation);
    var result = native.json.object();
    try native.json.put(a, &result, "id", try wire.toJson(t.Id, a, obligation.task));
    try native.json.put(a, &result, "head", try wire.toJson(t.Head, a, head));
    try native.json.put(a, &result, "fault", try faultJson(a, obligation.fault));
    try native.json.put(
        a,
        &result,
        "effective_mode",
        native.json.string(@tagName(obligation.effective_mode)),
    );
    try native.json.put(
        a,
        &result,
        "ordinary_dispatch",
        .{ .bool = obligation.ordinaryDispatch() },
    );
    const age: ?u64 = if (head.last_observation) |check| if (clock_ms >= check.acquired_ms)
        @intCast(@as(i128, clock_ms) - check.acquired_ms)
    else
        null else null;
    try native.json.put(a, &result, "source_age_ms", try wire.toJson(?u64, a, age));
    const materialize = @import("materialize.zig");
    try native.json.put(a, &result, "backlog", try wire.toJson(
        materialize.Backlog,
        a,
        try materialize.backlog(a, index, obligation),
    ));
    return result;
}

fn faultJson(a: std.mem.Allocator, fault: ?idx.Fault) !native.json.Value {
    const value = fault orelse return .null;
    var result = native.json.object();
    try native.json.put(a, &result, "reason", native.json.string(value.reason));
    try native.json.put(a, &result, "at_ms", try wire.toJson(i64, a, value.at_ms));
    try native.json.put(a, &result, "failures", try wire.toJson(u32, a, value.failures));
    try native.json.put(a, &result, "retry_ms", try wire.toJson(i64, a, value.retry_ms));
    return result;
}

fn pendingDirectives(
    a: std.mem.Allocator,
    index: *const idx.Index,
    id: t.Id,
    after: ?u64,
    limit: u32,
) !native.json.Value {
    const obligation = index.obligation(id) orelse return error.UnknownObligation;
    var result = native.json.object();
    const page = try appendPending(a, index, obligation, after, limit, &result, try dataRoom(a));
    if (page == null or (page.?.clipped and page.?.shown == 0)) return error.Capacity;
    return result;
}

fn messagePage(
    a: std.mem.Allocator,
    index: *const idx.Index,
    selected: @FieldType(@FieldType(Request, "command"), "messages"),
    config_path: ?[]const u8,
) !native.json.Value {
    if (selected.limit == 0 or selected.limit > 64) return error.InvalidPageLimit;
    const room = try dataRoom(a);
    var bounded = selected.limit;
    for (0..7) |_| {
        const page = try messages.page(
            a,
            index,
            selected.target,
            selected.after,
            bounded,
            config_path,
        );
        const value = try wire.toJson(messages.Page, a, page);
        if ((try extent(a, value)).within(room)) return value;
        if (bounded == 1) break;
        bounded /= 2;
    }
    return error.Capacity;
}

fn appendPending(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    after: ?u64,
    limit: u32,
    result: *native.json.Value,
    room: Extent,
) !?Entry {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    const folded = index.head(obligation).folded_directive_ordinal;
    var total: u64 = 0;
    for (obligation.directives) |position| {
        if (index.records[position].input.directive.ordinal > folded) total += 1;
    }
    try native.json.put(
        a,
        result,
        "pending_directives_total",
        try wire.toJson(u64, a, total),
    );
    try native.json.put(
        a,
        result,
        "folded_directive_ordinal",
        try wire.toJson(u64, a, folded),
    );
    var pending: std.array_list.Managed(native.json.Value) = .init(a);
    try native.json.put(a, result, "pending_directives", .{ .array = pending });
    const widest: ?u64 = std.math.maxInt(u64);
    try native.json.put(a, result, "pending_directives_next", try wire.toJson(
        ?u64,
        a,
        widest,
    ));
    var used = try extent(a, result.*);
    if (!used.within(room)) return null;
    var cursor = @max(after orelse folded, folded);
    var more = false;
    var clipped = false;
    for (obligation.directives) |position| {
        const directive = index.records[position].input.directive;
        if (directive.ordinal <= cursor) continue;
        if (pending.items.len == limit) {
            more = true;
            break;
        }
        const item = try wire.toJson(t.Directive, a, directive);
        var size = try extent(a, item);
        if (pending.items.len != 0) size = size.plus(separator);
        if (!used.plus(size).within(room)) {
            more = true;
            clipped = true;
            break;
        }
        try pending.append(item);
        used = used.plus(size);
        cursor = directive.ordinal;
    }
    try native.json.put(a, result, "pending_directives", .{ .array = pending });
    try native.json.put(
        a,
        result,
        "pending_directives_next",
        try wire.toJson(?u64, a, if (more) cursor else null),
    );
    return .{ .value = result.*, .extent = used, .clipped = clipped, .shown = pending.items.len };
}

fn task(
    a: std.mem.Allocator,
    service: anytype,
    index: *const idx.Index,
    id: t.Id,
    config_path: ?[]const u8,
) !native.json.Value {
    const record = try currentTask(index, id);
    var result = native.json.object();
    try native.json.put(a, &result, "requested_id", try wire.toJson(t.Id, a, id));
    try native.json.put(a, &result, "id", try wire.toJson(t.Id, a, record.task));
    try native.json.put(a, &result, "input", try wire.toJson(t.Input, a, record.input));
    try native.json.put(
        a,
        &result,
        "result",
        try wire.toJson(?t.Output, a, record.result),
    );
    try native.json.put(
        a,
        &result,
        "result_digest",
        try wire.toJson(?t.Digest, a, record.result_digest),
    );
    try native.json.put(a, &result, "superseded", .{ .bool = record.superseded });
    const confirming = try confirmations(a, index, record, config_path);
    try native.json.put(a, &result, "confirmations", confirming);
    try native.json.put(a, &result, "task_status", if (try taskStatus(a, service, record)) |value|
        native.json.string(@tagName(value))
    else
        .null);
    if (record.owner_snapshot) |snapshot| {
        try native.json.put(a, &result, "outcome", native.json.string(@tagName(snapshot.outcome)));
        try native.json.put(
            a,
            &result,
            "accounting",
            try wire.toJson(t.Accounting, a, snapshot.accounting),
        );
    }
    return result;
}

fn taskStatus(
    a: std.mem.Allocator,
    service: anytype,
    record: *const idx.Record,
) !?native.tasks.Status {
    const recorded = if (record.owner_evidence) |evidence| evidence.status else null;
    if (!recovery_status.recoverableTurn(record.*)) return recorded;
    const state = recovery_status.turn(service, a, record.*) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return recorded,
    };
    return state.status;
}

fn confirmations(
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: *const idx.Record,
    config_path: ?[]const u8,
) !native.json.Value {
    var items: std.array_list.Managed(native.json.Value) = .init(a);
    if (record.input != .turn or record.result == null or record.result.? != .turn)
        return .{ .array = items };
    const turn = record.input.turn;
    for (0..record.result.?.turn.proposals.items.len) |ordinal| {
        const identity: commands.ProposalIdentity = .{
            .request = turn.envelope.stable_request,
            .attempt = turn.attempt,
            .ordinal = @intCast(ordinal),
        };
        const resolved = commands.resolveProposal(index, .{ .identity = identity }) catch null;
        if (resolved) |value| if (!std.meta.eql(value.turn.task, record.task)) continue;
        const token = try wire.format(commands.ProposalIdentity, a, identity);
        var item = native.json.object();
        try native.json.put(a, &item, "identity", native.json.string(token));
        try native.json.put(a, &item, "confirmable", .{ .bool = resolved != null });
        try native.json.put(a, &item, "command", if (resolved != null and config_path != null)
            native.json.string(
                try cli.commandLine(a, config_path.?, &.{ "proposal", "confirm", token }),
            )
        else
            .null);
        try items.append(item);
    }
    return .{ .array = items };
}

fn currentTask(index: *const idx.Index, id: t.Id) !*const idx.Record {
    var record = index.record(id) orelse return error.UnknownTask;
    for (0..index.records.len) |_| {
        if (record.input != .turn or !record.superseded) return record;
        var child: ?*const idx.Record = null;
        for (index.records) |*candidate| {
            if (candidate.input != .turn) continue;
            const replacement = candidate.input.turn.replacement orelse continue;
            if (!std.meta.eql(replacement.input.task, record.task)) continue;
            if (child != null) return error.ConflictingTurnSuccessor;
            child = candidate;
        }
        record = child orelse return error.MissingTurnSuccessor;
    }
    return error.InvalidTurnAttempt;
}
