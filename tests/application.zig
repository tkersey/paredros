const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const application = @import("../app/application.zig");
const github = @import("../app/github_contract.zig");
const history = @import("../app/audit_contract.zig");
const model = @import("../app/model_contract.zig");

const Expected = struct {
    identity: []const u8,
    role: protean.admission.Role,
    resource: []const u8,
    capture: bool = false,
};
const expected = [_]Expected{
    .{ .identity = github.identity, .role = .read, .resource = "read", .capture = true },
    .{ .identity = history.identity, .role = .read, .resource = "read", .capture = true },
    .{
        .identity = @import("../app/lineage_audit_contract.zig").identity,
        .role = .read,
        .resource = "read",
        .capture = true,
    },
    .{ .identity = model.P.identity, .role = .model, .resource = "inference", .capture = true },
    .{
        .identity = application.notification_identity,
        .role = .write,
        .resource = "write",
        .capture = true,
    },
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
        try std.testing.expectEqual(1, c.registry.entry_dispatches.items.len);
        const protected = c.registry.entry_dispatches.items[0];
        try std.testing.expectEqual(module.entry, protected.function);
        try std.testing.expectEqualStrings(application.notification_identity, protected.identity);
        try std.testing.expectEqual(
            std.meta.fieldIndex(t.Input, "delivery").?,
            protected.delivery_case,
        );
        try std.testing.expectEqual(
            std.meta.fieldIndex(t.Output, "delivery").?,
            protected.result_case,
        );
        const payload = c.builder.effects.items[@intCast(protected.effect)].payload;
        try std.testing.expectEqual(
            try horos.authoring.interop.schemaId(c.author, try c.schema(t.Delivery)),
            payload,
        );
        const ordinary = c.builder.functions.items[@intCast(protected.ordinary)];
        try std.testing.expectEqual(expected.len - 1, ordinary.effects.len);
        for (ordinary.effects) |effect|
            try std.testing.expect(effect != protected.effect);
        return module;
    }
};

test "application composition admits exact provider effects and protected notifications" {
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
        const cts = @import("protean_contracts");
        const slack = @import("../native/slack_external.zig");
        const prepare = @import("../native/delivery_prepare.zig");
        const fixtures = @import("contracts.zig");
        const allocator = std.testing.allocator;

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

        fn delivery() !cts.Decoded(t.Delivery) {
            return prepare.materialize(
                allocator,
                intent(),
                .{ .task = @splat(4), .digest = @splat(5) },
                @splat(6),
                "B1",
            );
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
            const declaration = bridge.Application.declarations[3];
            const payload = try declaration.payload_schema(allocator);
            defer allocator.free(payload);
            const expected_payload = try native.values.schemaBytes(t.Delivery, allocator);
            defer allocator.free(expected_payload);
            try std.testing.expectEqualSlices(u8, expected_payload, payload);
        }

        test "native application delivery projection preserves every sealed adapter input field" {
            var admitted = try delivery();
            defer admitted.deinit();
            const original = try cts.encodeOwned(t.Delivery, allocator, admitted.value);
            defer allocator.free(original);
            const projected = try bridge.projectDelivery(allocator, original);
            defer allocator.free(projected);
            var decoded = try cts.decodeOwned(
                @import("../app/slack_contract.zig").Request,
                allocator,
                projected,
            );
            defer decoded.deinit();
            try std.testing.expectEqualDeep(admitted.value.destination, decoded.value.destination);
            try std.testing.expectEqualDeep(admitted.value.key, decoded.value.key);
            try std.testing.expectEqualDeep(admitted.value.payload, decoded.value.payload);
            var prepared = try slack.preparedWire(allocator, decoded.value, "B1");
            defer prepared.deinit();
            try std.testing.expectEqualSlices(
                u8,
                admitted.value.payload.wire_json.bytes,
                prepared.body,
            );
        }

        test "native application rejects tampered delivery envelopes keys and wire" {
            var admitted = try delivery();
            defer admitted.deinit();
            for (0..6) |mutation| {
                var changed = admitted.value;
                switch (mutation) {
                    0 => changed.envelope.version = 2,
                    1 => changed.envelope.operation.bytes = "unbound operation",
                    2 => changed.envelope.stable_request[0] ^= 1,
                    3 => changed.destination.channel.bytes = "D-other",
                    4 => changed.key.generation += 1,
                    5 => changed.payload.logical.frozen_text.bytes = "changed notification",
                    else => unreachable,
                }
                const bytes = try cts.encodeOwned(t.Delivery, allocator, changed);
                defer allocator.free(bytes);
                try std.testing.expectError(
                    error.InvalidPayload,
                    bridge.projectDelivery(allocator, bytes),
                );
            }
        }
    };
}
