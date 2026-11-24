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
    try std.testing.expectEqual(8, @typeInfo(t.Input).@"union".field_names.len);
}
