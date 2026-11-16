const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const chain = @import("../app/directive_chain.zig");
const witness = @import("directive_chain.zig");
const Fixture = @import("native_fixture.zig").Fixture(witness.Types, witness.Application);
const genesis = @import("contracts.zig").genesis;
const fresh = @import("native_genesis.zig").expectedFresh;

fn directive(id: u8, ordinal: u64, predecessor: ?t.InputReference, body: t.DirectiveBody) t.DirectiveFact {
    return .{
        .reference = .{ .task = @splat(id), .digest = @splat(id + 1) },
        .value = .{
            .envelope = genesis().envelope,
            .obligation = @splat(1),
            .ordinal = ordinal,
            .predecessor = predecessor,
            .body = body,
        },
    };
}

fn expectHead(a: std.mem.Allocator, expected: t.Head, actual: t.Head) !void {
    const left = try c.encodeOwned(t.Head, a, expected);
    defer a.free(left);
    const right = try c.encodeOwned(t.Head, a, actual);
    defer a.free(right);
    try std.testing.expectEqualSlices(u8, left, right);
}

test "native directive chain respects order and retains rejected disposition consumption" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const first = directive(2, 1, null, .{ .pause = {} });
    const refused = directive(3, 2, first.reference, .{ .check = {} });
    const last = directive(4, 3, refused.reference, .{ .@"resume" = {} });
    const input: chain.Input = .{ .obligation = @splat(1), .head = fresh(genesis()), .directives = .{ .items = &.{ first, refused, last } } };
    const task = try f.execute("three-controls", input);
    const output = try f.output(task);
    var expected = input.head;
    expected.folded_directive_ordinal = 3;
    expected.last_directive = last.reference;
    try expectHead(f.arena.allocator(), expected, output.head);
    try std.testing.expectEqual(3, output.dispositions.items.len);
    try std.testing.expect(output.dispositions.items[0].outcome == .applied);
    try std.testing.expect(output.dispositions.items[2].outcome == .applied);
    try std.testing.expectEqualStrings("test_policy_refusal", output.dispositions.items[1].outcome.rejected.bytes);
    for (output.dispositions.items, input.directives.items) |disposition, fact| {
        try std.testing.expectEqualDeep(fact.reference, disposition.directive);
        try std.testing.expectEqual(fact.value.ordinal, disposition.ordinal);
    }
    try f.close();
    try f.open();
    try expectHead(f.arena.allocator(), expected, (try f.output(task)).head);
    const replay = try f.execute("empty-chain", .{
        .obligation = @splat(1),
        .head = output.head,
        .directives = .{ .items = &.{} },
    });
    try expectHead(f.arena.allocator(), expected, (try f.output(replay)).head);
}

test "native directive chain cannot skip reorder or borrow another predecessor or obligation" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const valid = directive(2, 1, null, .{ .pause = {} });
    const input: chain.Input = .{ .obligation = @splat(1), .head = fresh(genesis()), .directives = .{ .items = &.{} } };
    var bad = valid;
    bad.value.ordinal = 2;
    var value = input;
    value.directives.items = &.{bad};
    try f.rejected("skipped-ordinal", value, "directive_ordinal_gap");
    bad = valid;
    bad.value.predecessor = .{ .task = @splat(9), .digest = @splat(10) };
    value.directives.items = &.{bad};
    try f.rejected("foreign-predecessor", value, "directive_predecessor_mismatch");
    bad = valid;
    bad.value.obligation = @splat(10);
    value.directives.items = &.{bad};
    try f.rejected("foreign-obligation", value, "directive_obligation_mismatch");
    value = input;
    value.head.folded_directive_ordinal = std.math.maxInt(u64);
    value.directives.items = &.{valid};
    try f.rejected("ordinal-overflow", value, "directive_ordinal_overflow");
}

test "native directive chain final mode cannot be revived by a later resume" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const first = directive(2, 1, null, .{ .cancel = {} });
    const last = directive(3, 2, first.reference, .{ .@"resume" = {} });
    const task = try f.execute("cancel-resume", .{
        .obligation = @splat(1),
        .head = fresh(genesis()),
        .directives = .{ .items = &.{ first, last } },
    });
    const output = try f.output(task);
    try std.testing.expectEqual(t.Mode.cancelled, output.head.mode);
    try std.testing.expectEqual(.cancelled, output.head.desired_mode);
    try std.testing.expectEqual(2, output.head.folded_directive_ordinal);
}
