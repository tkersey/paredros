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
        const prepare = @import("../native/delivery_prepare.zig");
        const fixtures = @import("contracts.zig");
        const allocator = std.testing.allocator;
        const Fixture = @import("native_fixture.zig").Fixture(bridge.Types, struct {
            pub const use_product_assets = true;
            pub const declarations = bridge.Application.declarations;
        });

        fn intent() t.DeliveryIntent {
            return .{
                .destination = fixtures.specification().destination,
                .key = .{
                    .lineage = @splat(1),
                    .purpose = .control,
                    .identity = @splat(2),
                    .generation = 0,
                },
                .payload = .{
                    .obligation = @splat(3),
                    .specification_revision = 4,
                    .prior_sequence = 5,
                    .through_sequence = 5,
                    .frozen_text = .{ .bytes = "pause applied." },
                    .prompt = null,
                    .supersedes = null,
                },
            };
        }

        fn delivery() !@import("protean_contracts").Decoded(t.Delivery) {
            return prepare.materialize(
                allocator,
                intent(),
                .{ .task = @splat(4), .digest = @splat(5) },
                @splat(6),
            );
        }

        fn audit(admitted: t.Delivery) t.Input {
            return .{ .audit = .{
                .envelope = admitted.envelope,
                .delivery = admitted,
                .ordinal = 0,
                .oldest = .{ .bytes = "0" },
                .latest = null,
                .page_limit = 1,
                .canary = null,
            } };
        }

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

        test "native application completes local deliveries and refuses legacy and audit work" {
            var f: Fixture = .{};
            defer f.deinit();
            try f.init();
            var admitted = try delivery();
            defer admitted.deinit();
            const version = admitted.value.payload.renderer_version;
            try std.testing.expectEqual(prepare.renderer_version, version);
            const task = try f.execute("local-delivery", .{ .delivery = admitted.value });
            try std.testing.expectEqualDeep(t.Output{ .delivery = .{ .confirmed = .{
                .timestamp = .{ .bytes = "local" },
                .metadata_observed = true,
            } } }, try f.output(task));
            var legacy = admitted.value;
            legacy.payload.renderer_version = prepare.legacy_renderer_version;
            const refusal = "legacy_delivery_unsupported";
            try f.rejected("legacy-delivery", .{ .delivery = legacy }, refusal);
            var future = admitted.value;
            future.envelope.version = 2;
            try f.rejected("future-delivery", .{ .delivery = future }, "unsupported_input_version");
            try f.rejected("audit", audit(admitted.value), "audit_unavailable");
        }
    };
}
