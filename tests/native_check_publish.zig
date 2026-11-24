const std = @import("std");
const t = @import("application_types");
const publish = @import("../app/check_publish.zig");
const check = @import("../app/check.zig");
const genesis = @import("native_genesis.zig");
const fixtures = @import("contracts.zig");
const preparation = @import("../native/delivery_prepare.zig");

const Types = struct {
    pub const application_id = "paredros.source-publication.witness";
    pub const application_version = "1.0.0";
    pub const Input = publish.Input;
    pub const Output = publish.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.source-publication.input.v1";
    pub const output_schema_id = "paredros.source-publication.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.source-publication.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Fixture = @import("native_fixture.zig").Fixture(
    Types,
    @import("check_publish.zig").Application,
);

fn input(head: t.Head, acquired: check.Result, identity: u8) publish.Input {
    return .{
        .head = head,
        .obligation = @splat(1),
        .identity = @splat(identity),
        .acquired = acquired,
    };
}

fn result(kind: @FieldType(check.Result, "kind"), base: ?t.Oid, tip: ?t.Oid) check.Result {
    return .{
        .kind = kind,
        .base = base,
        .tip = tip,
        .reason = null,
        .commits = .{ .items = &.{} },
        .evidence = .{ .items = &.{} },
    };
}

test "native source publication retains baseline complete batches and unchanged observations" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const initial = genesis.expectedFresh(fixtures.genesis());
    const baseline = try fixture.output(
        try fixture.execute("baseline", input(initial, result(.baseline, null, @splat('a')), 2)),
    );
    try std.testing.expectEqual(0, baseline.head.observed.sequence);
    try std.testing.expectEqual(@as(?t.Oid, @splat('a')), baseline.head.observed.tip);
    try std.testing.expectEqualDeep(baseline.head.observed, baseline.head.told);
    try std.testing.expectEqual(@as(?t.Batch, null), baseline.batch);
    try std.testing.expectEqual(900_100, baseline.head.next_due_ms);
    try fixture.close();
    try fixture.open();
    var acquired = result(.complete, @splat('a'), @splat('b'));
    acquired.commits = .{ .items = &.{.{ .oid = @splat('b'), .message = .{ .bytes = "new" } }} };
    const complete = try fixture.output(
        try fixture.execute("complete", input(baseline.head, acquired, 3)),
    );
    try std.testing.expectEqual(1, complete.head.observed.sequence);
    try std.testing.expectEqual(0, complete.head.told.sequence);
    try std.testing.expectEqual(.current, complete.head.last_observation.?.batch.?);
    try std.testing.expectEqualDeep(acquired.commits, complete.batch.?.commits);
    try std.testing.expectEqual(.complete, complete.batch.?.coverage);
    const unchanged = try fixture.output(try fixture.execute(
        "unchanged",
        input(complete.head, result(.unchanged, @splat('b'), @splat('b')), 4),
    ));
    try std.testing.expectEqualDeep(complete.head.observed, unchanged.head.observed);
    try std.testing.expectEqualDeep(complete.head.told, unchanged.head.told);
    try std.testing.expectEqual(@as(?t.Batch, null), unchanged.batch);
    try std.testing.expectEqual(0, unchanged.head.last_observation.?.commit_count);
}

test "native source publication binds and preserves questions until condition changes or clears" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var head = genesis.expectedFresh(fixtures.genesis());
    head.observed = .{ .sequence = 5, .epoch = 2, .tip = @splat('a') };
    head.told = .{ .sequence = 2, .epoch = 2, .tip = @splat('c') };
    var rejected = result(.rejected, @splat('a'), @splat('b'));
    rejected.reason = .diverged;
    const first = try fixture.output(try fixture.execute("question", input(head, rejected, 6)));
    try std.testing.expectEqualDeep(head.observed, first.head.observed);
    try std.testing.expectEqualDeep(head.told, first.head.told);
    try std.testing.expectEqual(@as(t.Digest, @splat(6)), first.head.question.?.identity);
    try std.testing.expectEqual(.diverged, first.head.question.?.source_condition.?.coverage);
    var sealed = try preparation.materialize(
        std.testing.allocator,
        first.head.question.?.prompt,
        .{ .task = @splat(7), .digest = @splat(8) },
        @splat(9),
    );
    defer sealed.deinit();
    try preparation.verifyStored(std.testing.allocator, sealed.value);
    const repeat = try fixture.output(
        try fixture.execute("same-condition", input(first.head, rejected, 7)),
    );
    try std.testing.expectEqualDeep(first.head.question, repeat.head.question);
    rejected.tip = @splat('d');
    const changed = try fixture.output(
        try fixture.execute("new-condition", input(repeat.head, rejected, 8)),
    );
    try std.testing.expectEqual(@as(t.Digest, @splat(8)), changed.head.question.?.identity);
    try std.testing.expectEqual(
        @as(t.Oid, @splat('d')),
        changed.head.question.?.source_condition.?.tip,
    );
    const cleared = try fixture.output(try fixture.execute(
        "cleared",
        input(changed.head, result(.unchanged, @splat('a'), @splat('a')), 9),
    ));
    try std.testing.expectEqual(@as(?t.Question, null), cleared.head.question);
    try std.testing.expectEqual(0, cleared.head.check_failure_streak);
}

test "native source publication rejects false unchanged complete baseline and overflow claims" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var head = genesis.expectedFresh(fixtures.genesis());
    head.observed = .{ .sequence = std.math.maxInt(u64), .epoch = 2, .tip = @splat('a') };
    var complete = result(.complete, @splat('a'), @splat('b'));
    complete.commits = .{ .items = &.{.{ .oid = @splat('b'), .message = .{ .bytes = "new" } }} };
    const cases = [_]check.Result{
        result(.baseline, null, @splat('b')),
        result(.unchanged, @splat('a'), @splat('b')),
        result(.complete, @splat('b'), @splat('c')),
        complete,
    };
    for (cases, 0..) |acquired, index| {
        const operation = try std.fmt.allocPrint(
            fixture.arena.allocator(),
            "invalid-{d}",
            .{index},
        );
        const task = try fixture.execute(operation, input(head, acquired, 10));
        var state = try fixture.service.?.task(fixture.arena.allocator(), task);
        defer state.deinit();
        try std.testing.expectEqual(.failed, state.value.outcome_kind);
    }
}
