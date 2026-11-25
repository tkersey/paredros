const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const application = @import("../app/application.zig");
const github = @import("../app/github_contract.zig");
const model = @import("../app/model_contract.zig");

const Expected = struct {
    identity: []const u8,
    role: protean.admission.Role,
    resource: []const u8,
    capture: bool = false,
};
const expected = [_]Expected{
    .{ .identity = github.identity, .role = .read, .resource = "read", .capture = true },
    .{ .identity = model.P.identity, .role = .model, .resource = "inference", .capture = true },
    .{
        .identity = @import("../app/method_contract.zig").workspace_identity,
        .role = .read,
        .resource = "workspace",
    },
    .{
        .identity = @import("../app/method_contract.zig").codec_identity,
        .role = .read,
        .resource = "frozen",
    },
    .{
        .identity = @import("../app/experiment_contract.zig").codec_identity,
        .role = .read,
        .resource = "frozen",
    },
    .{
        .identity = @import("../app/experiment_contract.zig").clock_identity,
        .role = .read,
        .resource = "measurement",
    },
};

const ObservedApplication = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const module = try application.Application.emit(c);
        try std.testing.expectEqual(expected.len, c.builder.effects.items.len);
        for (expected) |wanted| {
            var count: usize = 0;
            for (c.builder.effects.items, 0..) |effect, index| {
                if (!std.mem.eql(u8, wanted.identity, effect.identity)) continue;
                count += 1;
                try std.testing.expect(effect.external);
                try std.testing.expectEqual(wanted.role, c.registry.roleOf(index));
            }
            try std.testing.expectEqual(1, count);
        }
        try std.testing.expectEqual(0, c.registry.entry_dispatches.items.len);
        const entry = c.builder.functions.items[@intCast(module.entry)];
        try std.testing.expectEqual(expected.len, entry.effects.len);
        return module;
    }
};

test "application composition admits exact provider effects without protected dispatch" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("application diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = t.Input,
        .Result = t.Output,
        .Failure = t.Failure,
        .application = ObservedApplication,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(expected.len, compiled.program.effects.len);
    for (expected) |wanted| {
        var count: usize = 0;
        for (compiled.program.effects) |effect| {
            if (std.mem.eql(u8, wanted.identity, effect.identity)) count += 1;
        }
        try std.testing.expectEqual(1, count);
    }
}

pub fn NativeTests(comptime native: type) type {
    return struct {
        const bridge = @import("../native/application.zig");
        const fixtures = @import("contracts.zig");
        const allocator = std.testing.allocator;
        const Fixture = @import("native_fixture.zig").Fixture(bridge.Types, struct {
            pub const use_product_assets = true;
            pub const declarations = bridge.Application.declarations;
        });

        test "native application declarations match production capability schemas" {
            try std.testing.expectEqual(expected.len, bridge.Application.declarations.len);
            var registry = try native.Registry.init(allocator, bridge.Application.declarations);
            defer registry.deinit();
            for (expected) |wanted| {
                var count: usize = 0;
                for (registry.entries) |entry| {
                    if (!std.mem.eql(u8, wanted.identity, entry.declaration.identity)) continue;
                    count += 1;
                    if (wanted.capture) try std.testing.expect(entry.declaration.capture != null);
                    try std.testing.expectEqualStrings(
                        wanted.resource,
                        entry.declaration.resource_role,
                    );
                }
                try std.testing.expectEqual(1, count);
            }
        }

        test "native application preserves transfer markers and refuses future envelopes" {
            var f: Fixture = .{};
            defer f.deinit();
            try f.init();
            const marker: t.TransferMarker = .{ .envelope = .{
                .operation = .{ .bytes = "local-transfer" },
                .stable_request = @splat(6),
                .origin = .{ .local = .{ .uid = 501 } },
            } };
            const task = try f.execute("local-transfer", .{ .transfer = marker });
            try std.testing.expectEqualDeep(t.Output{ .transfer = marker }, try f.output(task));
            var future = marker;
            future.envelope.version = 2;
            try f.rejected("future-transfer", .{ .transfer = future }, "unsupported_input_version");
        }
    };
}
