const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");

fn hash(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

const Schema = struct {
    schema_id: []const u8,
    wire_sha256: []const u8,
    wire_base64url: []const u8,
    json: native.json.Value,
};

fn schema(comptime T: type, a: std.mem.Allocator, id: []const u8) !Schema {
    const wire = try native.values.schemaBytes(T, a);
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(wire.len));
    return .{
        .schema_id = id,
        .wire_sha256 = try hash(a, wire),
        .wire_base64url = std.base64.url_safe_no_pad.Encoder.encode(encoded, wire),
        .json = (try native.json.parse(a, &native.values.schemas.ClientSchema(T).value, .{})).value,
    };
}

const Capability = struct {
    identity: []const u8,
    resource_role: []const u8,
    payload_sha256: []const u8,
    resume_sha256: []const u8,
};

fn capabilities(a: std.mem.Allocator, handlers: native.Registry) ![]const Capability {
    var result: std.ArrayList(Capability) = .empty;
    for (handlers.entries) |entry| {
        if (entry.declaration.workspace_only) continue;
        try result.append(a, .{
            .identity = entry.declaration.identity,
            .resource_role = entry.declaration.resource_role,
            .payload_sha256 = try hash(a, entry.payload_schema),
            .resume_sha256 = try hash(a, entry.resume_schema),
        });
    }
    return result.toOwnedSlice(a);
}

fn metadata(
    comptime Types: type,
    a: std.mem.Allocator,
    image: []const u8,
    identity: [32]u8,
    handlers: native.Registry,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .format = "agent-native-application/v1",
        .application_id = Types.application_id,
        .application_version = Types.application_version,
        .program_sha256 = try hash(a, image),
        .program_identity = @as([]const u8, &std.fmt.bytesToHex(identity, .lower)),
        .client_mapping = native.values.schemas.client_mapping,
        .input = try schema(Types.Input, a, Types.input_schema_id),
        .output = try schema(Types.Output, a, Types.output_schema_id),
        .failure = try schema(Types.Failure, a, Types.failure_schema_id),
        .answer = try schema(Types.Answer, a, Types.answer_schema_id),
        .message = try schema(Types.Message, a, Types.message_schema_id),
        .capabilities = try capabilities(a, handlers),
        .resources = [_]u32{},
        .controller = @as(?u8, null),
    }, .{});
}

fn manifest(a: std.mem.Allocator, image: []const u8, application: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .format = "agent-native-build/v2",
        .native_host_contract = "paredros-native-witness",
        .protocol = "agent-host/2.2",
        .client_mapping = native.values.schemas.client_mapping,
        .state_format = "agent-native-state/22",
        .program_sha256 = try hash(a, image),
        .application_assets_sha256 = try hash(a, application),
    }, .{});
}

pub fn scratch(root: ?[]const u8) !std.testing.TmpDir {
    const base = root orelse return std.testing.tmpDir(.{});
    const io = std.testing.io;
    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var value: std.testing.TmpDir = undefined;
    _ = std.base64.url_safe.Encoder.encode(&value.sub_path, &random_bytes);
    value.parent_dir = try std.Io.Dir.cwd().createDirPathOpen(io, base, .{});
    errdefer value.parent_dir.close(io);
    value.dir = try value.parent_dir.createDirPathOpen(io, &value.sub_path, .{});
    return value;
}

pub fn Fixture(comptime Types: type, comptime Application: type) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
        temporary: ?std.testing.TmpDir = null,
        root: ?[]const u8 = null,
        path: []const u8 = undefined,
        assets: native.discovery.Assets = undefined,
        application: ?native.discovery.Application = null,
        handlers: ?native.Registry = null,
        namespace: ?native.Namespace = null,
        service: ?native.tasks.Service(Types) = null,
        io: std.Io = std.testing.io,
        profile: native.tasks.Profile = .{
            .id = "native-test",
            .runtime_identity = @splat(42),
            .bytes = "native-test-profile",
            .authority = .{ .grants = &.{}, .principal = "native-test", .tenant = "local" },
        },

        pub fn init(self: *Self) !void {
            return self.initWithGrants(&.{});
        }

        pub fn initWithGrants(self: *Self, identities: []const []const u8) !void {
            const a = self.arena.allocator();
            const declarations = if (@hasDecl(Application, "declarations"))
                Application.declarations
            else
                &.{};
            self.handlers = try native.Registry.init(std.testing.allocator, declarations);
            self.assets = if (@hasDecl(Application, "use_product_assets")) .{
                .image = @embedFile("test_application_image"),
                .application = @embedFile("test_application_metadata"),
                .manifest = @embedFile("test_application_manifest"),
            } else try self.compileAssets(declarations.len);
            self.application = try native.discovery.Application.init(
                Types,
                std.testing.allocator,
                self.assets,
                self.handlers.?,
            );
            try self.grant(identities);
            self.temporary = try scratch(self.root);
            var path_buffer: [4096]u8 = undefined;
            const length = try self.temporary.?.dir.realPath(std.testing.io, &path_buffer);
            self.path = try std.fmt.allocPrint(a, "{s}/native", .{path_buffer[0..length]});
            try self.open();
        }

        fn compileAssets(self: *Self, declaration_count: usize) !native.discovery.Assets {
            const a = self.arena.allocator();
            var compiled = try protean.compile(a, protean.system(.{
                .InitialArgs = Types.Input,
                .Result = Types.Output,
                .Failure = Types.Failure,
                .application = Application,
            }));
            defer compiled.deinit();
            if (declaration_count == 0) try std.testing.expectEqual(
                0,
                compiled.program.effects.len,
            );
            const image = try a.alloc(
                u8,
                try horos.data.program_image.encodedLength(compiled.program),
            );
            _ = try compiled.encode(a, image);
            const admitted = try horos.data.program_image.Admitted.decode(a, image);
            defer admitted.deinit();
            const application = try metadata(Types, a, image, admitted.identity(), self.handlers.?);
            return .{
                .image = image,
                .application = application,
                .manifest = try manifest(a, image, application),
            };
        }

        fn grant(self: *Self, identities: []const []const u8) !void {
            if (identities.len == 0) return;
            const a = self.arena.allocator();
            const grants = try a.alloc(native.registry.Grant, identities.len);
            const resource = try self.profile.resourceIdentity(
                a,
                self.application.?.image_identity,
            );
            for (identities, grants) |identity, *selected| {
                for (self.handlers.?.entries) |entry| {
                    if (!std.mem.eql(u8, entry.declaration.identity, identity)) continue;
                    selected.* = .{
                        .identity = identity,
                        .resource_role = entry.declaration.resource_role,
                        .resource_identity = resource,
                    };
                    break;
                } else return error.UnknownGrant;
            }
            self.profile.authority.grants = grants;
        }

        pub fn open(self: *Self) !void {
            self.namespace = try native.Namespace.open(
                std.testing.allocator,
                self.io,
                self.path,
            );
            self.service = try native.tasks.Service(Types).init(
                std.testing.allocator,
                self.io,
                &self.namespace.?,
                self.assets,
                &self.application.?,
                self.handlers.?,
                self.profile,
            );
        }

        pub fn close(self: *Self) !void {
            if (self.service) |*service| {
                try service.close(self.arena.allocator());
                self.service = null;
            }
            if (self.namespace) |*namespace| {
                try namespace.close();
                self.namespace = null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close() catch |err| std.debug.panic(
                "native fixture cleanup: {s}",
                .{@errorName(err)},
            );
            if (self.application) |*application| application.deinit();
            if (self.handlers) |*handlers| handlers.deinit();
            if (self.temporary) |*temporary| temporary.cleanup();
            self.arena.deinit();
        }

        pub fn execute(self: *Self, operation: []const u8, input: Types.Input) ![16]u8 {
            const a = self.arena.allocator();
            const service = &self.service.?;
            const admitted = try service.submit(a, operation, input);
            for (0..4096) |_| {
                var task = try service.task(a, admitted.receipt.task);
                defer task.deinit();
                if (task.value.terminal()) return admitted.receipt.task;
                switch (try service.pump(a)) {
                    .work => |work| {
                        try service.notSent(a, work);
                        return error.UnexpectedExternalWork;
                    },
                    .idle, .waiting, .progressed => {},
                }
            }
            return error.PureTaskDidNotComplete;
        }

        pub fn outcome(self: *Self, task: [16]u8) !native.json.Value {
            const a = self.arena.allocator();
            var client: native.client.Client(Types) = .{ .service = &self.service.? };
            var params = native.json.object();
            try native.json.put(a, &params, "task_id", native.json.string(
                try a.dupe(u8, &std.fmt.bytesToHex(task, .lower)),
            ));
            const response = try client.call(a, .@"task.result", params);
            try std.testing.expect(native.json.get(response, "ready").?.bool);
            return native.json.get(response, "outcome") orelse error.MissingOutcome;
        }

        pub fn output(self: *Self, task: [16]u8) !Types.Output {
            const result = try self.outcome(task);
            try std.testing.expectEqualStrings(
                "completed",
                try native.json.text(native.json.get(result, "type").?),
            );
            try std.testing.expectEqualStrings(
                Types.output_schema_id,
                try native.json.text(native.json.get(result, "schema_id").?),
            );
            return native.values.fromJson(
                Types.Output,
                self.arena.allocator(),
                native.json.get(result, "value").?,
            );
        }

        pub fn rejected(
            self: *Self,
            operation: []const u8,
            input: Types.Input,
            expected: []const u8,
        ) !void {
            const result = try self.outcome(try self.execute(operation, input));
            try std.testing.expectEqualStrings(
                "failed",
                try native.json.text(native.json.get(result, "type").?),
            );
            try std.testing.expectEqualStrings(
                Types.failure_schema_id,
                try native.json.text(native.json.get(result, "schema_id").?),
            );
            const failure = try native.values.fromJson(
                Types.Failure,
                self.arena.allocator(),
                native.json.get(result, "value").?,
            );
            try std.testing.expectEqualStrings(expected, failure.code.bytes);
            try std.testing.expect(native.json.get(result, "cleanup_complete").?.bool);
        }
    };
}
