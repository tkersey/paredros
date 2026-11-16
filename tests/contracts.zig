const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");

pub fn specification() t.Specification {
    return .{
        .revision = 0,
        .repository = .{
            .account = .{ .bytes = "github-test" },
            .id = 123,
            .owner = .{ .bytes = "owner" },
            .name = .{ .bytes = "test" },
            .ref = .{ .bytes = "refs/heads/main" },
        },
        .destination = .{
            .account = .{ .bytes = "slack-test" },
            .app = .{ .bytes = "A123" },
            .workspace = .{ .bytes = "T123" },
            .operator = .{ .bytes = "U123" },
            .channel = .{ .bytes = "D123" },
        },
        .interval_ms = 900_000,
        .anchor_ms = 100,
        .wording = .{ .bytes = "Summarize newly observed commits." },
        .policies = .{},
    };
}

pub fn genesis() t.Genesis {
    return .{
        .envelope = .{
            .operation = .{ .bytes = "local-genesis-test" },
            .stable_request = @splat(7),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .lineage = @splat(8),
        .specification = specification(),
        .clock_ms = 100,
        .imported = null,
    };
}

test "application contracts retain frozen materialization and exact large counters" {
    const a = std.testing.allocator;
    var value = genesis();
    value.specification.revision = std.math.maxInt(u64);
    value.clock_ms = -500;
    const input: t.Input = .{ .genesis = value };
    const bytes = try c.encodeOwned(t.Input, a, input);
    defer a.free(bytes);
    var decoded = try c.decodeOwned(t.Input, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(input, decoded.value);
    value.clock_ms = 101;
    const changed = try c.encodeOwned(t.Input, a, .{ .genesis = value });
    defer a.free(changed);
    try std.testing.expect(!std.mem.eql(u8, bytes, changed));
}

test "application source has finite schemas for every task boundary" {
    inline for (.{ t.Input, t.Output, t.Failure, t.Message }) |T| {
        _ = c.native.info(T);
    }
    try std.testing.expectEqual(11, @typeInfo(t.Input).@"union".field_names.len);
}

test "appended lineage audit preserves every legacy input and output tag" {
    const LegacyInput = union(enum) {
        genesis: t.Genesis,
        step: t.Step,
        directive: t.Directive,
        delivery: t.Delivery,
        audit: t.Audit,
        turn: t.Turn,
        experiment: t.Experiment,
        continuity_member: t.ContinuityMember,
        continuity_cut: t.ContinuityCut,
        restore: t.Restore,
    };
    const LegacyOutput = union(enum) {
        genesis: t.Head,
        step: t.StepResult,
        directive: t.Directive,
        delivery: t.DeliveryOutcome,
        audit: t.AuditResult,
        turn: t.TurnResult,
        experiment: t.ExperimentResult,
        continuity_member: t.ContinuityMember,
        continuity_cut: t.ContinuityCut,
        restore: t.Restore,
    };
    inline for (@typeInfo(LegacyInput).@"union".field_names, 0..) |name, ordinal| {
        try std.testing.expectEqual(ordinal, std.meta.fieldIndex(t.Input, name).?);
        try std.testing.expectEqual(ordinal, std.meta.fieldIndex(t.Output, name).?);
    }
    const allocator = std.testing.allocator;
    const old_input = try c.encodeOwned(LegacyInput, allocator, .{ .genesis = genesis() });
    defer allocator.free(old_input);
    var decoded = try c.decodeOwned(t.Input, allocator, old_input);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(genesis(), decoded.value.genesis);
    const old_output = try c.encodeOwned(LegacyOutput, allocator, .{ .audit = .{
        .inconclusive = .{ .bytes = "metadata" },
    } });
    defer allocator.free(old_output);
    var result = try c.decodeOwned(t.Output, allocator, old_output);
    defer result.deinit();
    try std.testing.expectEqualStrings("metadata", result.value.audit.inconclusive.bytes);
    const current = try c.encodeOwned(t.Output, allocator, result.value);
    defer allocator.free(current);
    try std.testing.expectEqualSlices(u8, old_output, current);
}
