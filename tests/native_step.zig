const std = @import("std");
const t = @import("application_types");
const genesis = @import("native_genesis.zig");
const fixtures = @import("contracts.zig");
const Types = struct {
    pub const application_id = "paredros.step.witness";
    pub const application_version = "1.0.0";
    pub const Input = t.Step;
    pub const Output = t.StepResult;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.step.input.v1";
    pub const output_schema_id = "paredros.step.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.step.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Fixture = @import("native_fixture.zig").Fixture(Types, @import("step.zig").Application);

fn input(head: t.Head) t.Step {
    return .{
        .envelope = .{
            .operation = .{ .bytes = "step" },
            .stable_request = @splat(3),
            .origin = .{ .derived = .{ .predecessor = .{
                .task = @splat(1),
                .digest = @splat(2),
            } } },
        },
        .obligation = @splat(1),
        .predecessor = .{ .task = @splat(1), .digest = @splat(2) },
        .previous = head,
        .sequence = head.sequence + 1,
        .attempt = 0,
        .supersession = null,
        .directives = .{ .items = &.{} },
        .facts = .{ .items = &.{} },
        .batches = .{ .items = &.{} },
        .clock_ms = 100,
        .fold_only = false,
    };
}

fn control(body: t.DirectiveBody, ordinal: u64, previous: ?t.InputReference) t.DirectiveFact {
    return .{
        .reference = .{
            .task = @splat(@intCast(ordinal + 2)),
            .digest = @splat(@intCast(ordinal)),
        },
        .value = .{
            .envelope = .{
                .operation = .{ .bytes = "control" },
                .stable_request = @splat(4),
                .origin = .{ .local = .{ .uid = 501 } },
            },
            .obligation = @splat(1),
            .ordinal = ordinal,
            .predecessor = previous,
            .body = body,
        },
    };
}

fn backlog(head: t.Head) @FieldType(t.Step, "batches").Child {
    return .{
        .reference = .{ .task = @splat(8), .digest = @splat(9) },
        .value = .{
            .repository = head.specification.repository,
            .sequence = 1,
            .epoch = 0,
            .base = @splat('a'),
            .tip = @splat('b'),
            .coverage = .complete,
            .commits = .{ .items = &.{} },
            .raw_evidence = .{ .items = &.{} },
            .acquired_ms = 100,
            .provider_date = null,
        },
    };
}

test "native bounded step folds controls before one phase and preserves exact lineage" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const head = genesis.expectedFresh(fixtures.genesis());
    var next = input(head);
    const pause = control(.{ .pause = {} }, 1, null);
    next.directives = .{ .items = &.{pause} };
    const paused = try fixture.output(try fixture.execute("pause-due", next));
    try std.testing.expectEqual(.paused, paused.head.mode);
    try std.testing.expectEqual(@as(?t.Oid, null), paused.head.observed.tip);
    try std.testing.expectEqual(1, paused.head.sequence);
    try std.testing.expectEqual(1, paused.head.folded_directive_ordinal);
    try std.testing.expectEqualDeep(next.predecessor, paused.head.predecessor.?);
    try std.testing.expectEqual(1, paused.dispositions.items.len);
    const resume_fact = control(.{ .@"resume" = {} }, 2, pause.reference);
    next = input(paused.head);
    next.predecessor = .{ .task = @splat(5), .digest = @splat(6) };
    next.directives = .{ .items = &.{resume_fact} };
    const resumed = try fixture.output(try fixture.execute("resume-due", next));
    try std.testing.expectEqual(.active, resumed.head.mode);
    try std.testing.expectEqual(.check, resumed.head.phase);
    try std.testing.expectEqual(@as(?t.Oid, @splat('a')), resumed.head.observed.tip);
    try std.testing.expectEqual(0, resumed.head.render_failure_streak);
    next = input(resumed.head);
    const cancel = control(.{ .cancel = {} }, 3, resume_fact.reference);
    next.directives = .{ .items = &.{cancel} };
    next.clock_ms = 9_000_100;
    const cancelled = try fixture.output(try fixture.execute("cancel-due", next));
    try std.testing.expectEqual(.cancelled, cancelled.head.mode);
    try std.testing.expectEqualDeep(resumed.head.observed, cancelled.head.observed);
    try std.testing.expectEqual(resumed.head.skipped_slots, cancelled.head.skipped_slots);
}

test "native bounded step prioritizes source except for backlog fairness and provider deferral" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var head = genesis.expectedFresh(fixtures.genesis());
    head.observed = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') };
    const batch = backlog(head);
    var next = input(head);
    next.batches = .{ .items = &.{batch} };
    const source = try fixture.output(try fixture.execute("source-first", next));
    try std.testing.expectEqual(.check, source.head.phase);
    try std.testing.expectEqual(0, source.head.render_failure_streak);
    next.previous.phase = .check;
    next.previous.previous_check_overran = true;
    const alternate = try fixture.output(try fixture.execute("fair-render", next));
    try std.testing.expectEqual(.render, alternate.head.phase);
    try std.testing.expectEqual(0, alternate.head.render_failure_streak);
    try std.testing.expectEqual(head.next_due_ms, alternate.head.next_due_ms);
    next = input(head);
    next.batches = .{ .items = &.{batch} };
    next.previous.source_not_before_ms = 1000;
    const deferred = try fixture.output(try fixture.execute("backoff-render", next));
    try std.testing.expectEqual(.render, deferred.head.phase);
    next.fold_only = true;
    const folded = try fixture.output(try fixture.execute("fold-only", next));
    try std.testing.expectEqual(0, folded.head.render_failure_streak);
    try std.testing.expectEqualDeep(head.observed, folded.head.observed);
}

test "native bounded step drops the published message and renders a due untold prefix" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var head = genesis.expectedFresh(fixtures.genesis());
    head.observed = .{ .sequence = 2, .epoch = 0, .tip = @splat('c') };
    head.told = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') };
    head.next_due_ms = 1_000_000;
    head.render_not_before_ms = 200;
    var second = backlog(head);
    second.value.sequence = 2;
    second.value.base = @splat('b');
    second.value.tip = @splat('c');
    var next = input(head);
    next.batches = .{ .items = &.{second} };
    const paced = try fixture.output(try fixture.execute("paced-prefix", next));
    try std.testing.expectEqual(head.phase, paced.head.phase);
    try std.testing.expect(paced.head.message == null);
    try std.testing.expectEqualDeep(head.told, paced.head.told);
    next = input(paced.head);
    next.clock_ms = 200;
    next.batches = .{ .items = &.{second} };
    const drained = try fixture.output(try fixture.execute("next-prefix", next));
    try std.testing.expectEqual(.render, drained.head.phase);
    try std.testing.expect(drained.head.message == null);
}

test "native bounded step corrects skipped slots and regression while preserving backoff" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var head = genesis.expectedFresh(fixtures.genesis());
    head.observed.tip = @splat('a');
    var next = input(head);
    next.clock_ms = 2_700_100;
    const catchup = try fixture.output(try fixture.execute("catch-up", next));
    try std.testing.expectEqual(3, catchup.head.skipped_slots);
    try std.testing.expectEqual(3_600_100, catchup.head.next_due_ms);
    head = catchup.head;
    head.source_not_before_ms = 4_000_000;
    next = input(head);
    next.clock_ms = 100;
    const regressed = try fixture.output(try fixture.execute("regressed", next));
    try std.testing.expectEqual(900_100, regressed.head.next_due_ms);
    try std.testing.expectEqual(head.source_not_before_ms, regressed.head.source_not_before_ms);
    try std.testing.expectEqual(head.skipped_slots, regressed.head.skipped_slots);
    try std.testing.expectEqual(100, regressed.head.clock_ms);
}

test "native bounded step refuses skipped sequence and unexplained replacement attempts" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const head = genesis.expectedFresh(fixtures.genesis());
    for (0..3) |index| {
        var next = input(head);
        if (index == 0) next.sequence = 3;
        if (index == 1) next.attempt = 1;
        if (index == 2) next.obligation = @splat(9);
        const operation = try std.fmt.allocPrint(
            fixture.arena.allocator(),
            "invalid-{d}",
            .{index},
        );
        const task = try fixture.execute(operation, next);
        var state = try fixture.service.?.task(fixture.arena.allocator(), task);
        defer state.deinit();
        try std.testing.expectEqual(.failed, state.value.outcome_kind);
    }
}
