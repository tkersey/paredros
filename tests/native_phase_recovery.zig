const std = @import("std");
const t = @import("application_types");
const recovery = @import("../app/phase_recovery.zig");
const witness = @import("phase_recovery.zig");
const check = @import("../app/check.zig");
const examples = @import("contracts.zig");
const Types = struct {
    pub const application_id = "paredros.phase-recovery.witness";
    pub const application_version = "1.0.0";
    pub const Input = witness.Input;
    pub const Output = t.Head;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.phase-recovery.input.v1";
    pub const output_schema_id = "paredros.phase-recovery.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.phase-recovery.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Fixture = @import("native_fixture.zig").Fixture(Types, witness.Application);

fn head() t.Head {
    var value = @import("native_genesis.zig").expectedFresh(examples.genesis());
    value.obligation = .{ .task = @splat(1) };
    value.observed = .{ .sequence = 3, .epoch = 0, .tip = @splat('a') };
    value.told = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') };
    return value;
}

fn failed(value: t.Head, phase: t.Phase) witness.Input {
    return .{ .failure = .{
        .head = value,
        .phase = phase,
        .defer_to_slot = false,
        .provider_not_before_ms = std.math.minInt(i64),
    } };
}

fn supersession(phase: t.Phase, cause: @FieldType(t.Supersession, "cause")) t.Supersession {
    return .{
        .input = .{ .task = @splat(8), .digest = @splat(9) },
        .attempt = 0,
        .phase = phase,
        .cause = cause,
        .cancellation = .{
            .operation = .{ .bytes = "cancel-failed-attempt" },
            .task = @splat(8),
            .bytes = .{ .bytes = "owner cancellation receipt" },
        },
    };
}

fn step(value: t.Head) t.Step {
    return .{
        .envelope = examples.genesis().envelope,
        .obligation = @splat(1),
        .predecessor = .{ .task = @splat(1), .digest = @splat(2) },
        .previous = value,
        .sequence = value.sequence + 1,
        .attempt = 0,
        .supersession = null,
        .directives = .{ .items = &.{} },
        .facts = .{ .items = &.{} },
        .batches = .{ .items = &.{} },
        .clock_ms = value.clock_ms,
        .fold_only = false,
    };
}

fn readEvidence() t.ReadEvidence {
    return .{
        .request_digest = @splat(1),
        .target = .{ .bytes = "https://api.github.com/repos/o/r" },
        .status = 429,
        .body = .{ .bytes = "{}" },
        .body_digest = @splat(2),
        .captured_ms = 200,
        .provider_date = null,
        .request_id = null,
        .link = null,
        .etag = null,
        .retry_after = .{ .bytes = "300" },
        .rate_remaining = .{ .bytes = "0" },
        .rate_reset = .{ .bytes = "2000" },
    };
}

test "native phase recovery bounds check attempts then opens a fresh cycle at the next slot" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var value = head();
    value.accounting.possible_charged_calls = 7;
    const expected = [_]i64{ 60_100, 180_100, 900_100, 960_100 };
    for (expected, 0..) |deadline, ordinal| {
        const operation = try std.fmt.allocPrint(
            fixture.arena.allocator(),
            "check-{d}",
            .{ordinal},
        );
        const previous = value;
        value = try fixture.output(try fixture.execute(operation, failed(value, .check)));
        try std.testing.expectEqual(deadline, value.schedule.source_not_before_ms);
        try std.testing.expectEqual(deadline, value.schedule.next_due_ms);
        try std.testing.expectEqual(
            @as(u32, if (ordinal == 3) 1 else @intCast(ordinal + 1)),
            value.check_failure_streak,
        );
        try std.testing.expectEqualDeep(previous.observed, value.observed);
        try std.testing.expectEqualDeep(previous.told, value.told);
        try std.testing.expectEqualDeep(previous.accounting, value.accounting);
        try std.testing.expectEqual(
            previous.schedule.render_not_before_ms,
            value.schedule.render_not_before_ms,
        );
        value.clock_ms = deadline;
    }
}

test "native phase recovery render backoff preserves due checks and stronger provider constraints" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var value = head();
    value.schedule.source_not_before_ms = 55;
    value.schedule.render_not_before_ms = 100_000;
    var request = failed(value, .render);
    request.failure.provider_not_before_ms = 200_000;
    const result = try fixture.output(try fixture.execute("render-provider", request));
    try std.testing.expectEqual(1, result.render_failure_streak);
    try std.testing.expectEqual(200_000, result.schedule.render_not_before_ms);
    try std.testing.expectEqual(value.schedule.next_due_ms, result.schedule.next_due_ms);
    try std.testing.expectEqual(
        value.schedule.source_not_before_ms,
        result.schedule.source_not_before_ms,
    );
    try std.testing.expectEqual(value.check_failure_streak, result.check_failure_streak);
    try std.testing.expectEqualDeep(value.told, result.told);
}

test "native phase recovery excludes control cancellations and defers unattributed fold faults" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var value = head();
    value.check_failure_streak = 2;
    value.render_failure_streak = 1;
    value.schedule.source_not_before_ms = 1_500_000;
    const controlled = try fixture.output(try fixture.execute("control", .{ .recovery = .{
        .head = value,
        .supersession = supersession(.check, .control),
    } }));
    try std.testing.expectEqualDeep(value, controlled);
    const ordinary = try fixture.output(try fixture.execute("ordinary", .{ .recovery = .{
        .head = value,
        .supersession = null,
    } }));
    try std.testing.expectEqualDeep(value, ordinary);
    const fault = try fixture.output(try fixture.execute("fold-fault", .{ .recovery = .{
        .head = value,
        .supersession = supersession(.fold, .failed),
    } }));
    try std.testing.expectEqual(900_100, fault.schedule.next_due_ms);
    try std.testing.expectEqual(900_100, fault.schedule.render_not_before_ms);
    try std.testing.expectEqual(1_500_000, fault.schedule.source_not_before_ms);
    try std.testing.expectEqual(value.check_failure_streak, fault.check_failure_streak);
    try std.testing.expectEqual(value.render_failure_streak, fault.render_failure_streak);
}

test "native phase recovery honors Retry After rate reset and retained provider deadline" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var evidence = readEvidence();
    var request: recovery.RejectionInput = .{
        .head = head(),
        .reason = .rate_limit,
        .evidence = .{ .items = &.{evidence} },
    };
    const limited = try fixture.output(try fixture.execute("limited", .{ .rejection = request }));
    try std.testing.expectEqual(2_000_000, limited.provider_not_before_ms);
    try std.testing.expectEqual(60_100, limited.schedule.source_not_before_ms);
    request.head.schedule.source_not_before_ms = 3_000_000;
    const previous = try fixture.output(try fixture.execute("retained", .{ .rejection = request }));
    try std.testing.expectEqual(3_000_000, previous.schedule.source_not_before_ms);
    try std.testing.expectEqual(2_000_000, previous.provider_not_before_ms);
    request.head = head();
    request.reason = .unavailable;
    evidence.rate_remaining = .{ .bytes = "5" };
    request.evidence.items = &.{evidence};
    const available = try fixture.output(try fixture.execute(
        "retry-after",
        .{ .rejection = request },
    ));
    try std.testing.expectEqual(300_200, available.provider_not_before_ms);
}

test "native phase recovery delays conservatively for an HTTP-date or unparseable Retry After" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var evidence = readEvidence();
    evidence.rate_remaining = .{ .bytes = "5" };
    var request: recovery.RejectionInput = .{
        .head = head(),
        .reason = .unavailable,
        .evidence = .{ .items = &.{evidence} },
    };
    for ([_][]const u8{ "Sun, 15 Nov 2026 00:00:00 GMT", "bad", "", "-1", "1.5" }, 0..) |text, i| {
        evidence.retry_after = .{ .bytes = text };
        request.evidence.items = &.{evidence};
        const operation = try std.fmt.allocPrint(fixture.arena.allocator(), "date-{d}", .{i});
        const task = try fixture.execute(operation, .{ .rejection = request });
        const delayed = try fixture.output(task);
        try std.testing.expectEqual(3_600_200, delayed.provider_not_before_ms);
    }
    evidence.retry_after = .{ .bytes = "99999999999999999999999999" };
    request.evidence.items = &.{evidence};
    const huge = try fixture.output(try fixture.execute("huge", .{ .rejection = request }));
    try std.testing.expectEqual(1_000_000_000_000_200, huge.provider_not_before_ms);
    evidence.retry_after = null;
    evidence.rate_reset = .{ .bytes = "Sun, 15 Nov 2026 00:00:00 GMT" };
    request.evidence.items = &.{evidence};
    request.reason = .rate_limit;
    const reset = try fixture.output(try fixture.execute("reset-date", .{ .rejection = request }));
    try std.testing.expectEqual(3_600_200, reset.provider_not_before_ms);
}

fn rejectedComparison() check.Result {
    return .{
        .kind = .rejected,
        .base = @splat('a'),
        .tip = @splat('c'),
        .reason = .diverged,
        .commits = .{ .items = &.{} },
        .evidence = .{ .items = &.{} },
    };
}

test "native phase recovery publication preserves source questions and resets success streak" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var request = @import("../app/check_publish.zig").Input{
        .head = head(),
        .obligation = @splat(1),
        .identity = @splat(3),
        .acquired = rejectedComparison(),
    };
    const first = try fixture.output(try fixture.execute("diverged", .{ .publication = request }));
    try std.testing.expectEqual(900_100, first.schedule.source_not_before_ms);
    try std.testing.expectEqual(1, first.check_failure_streak);
    try std.testing.expectEqual(.diverged, first.question.?.source_condition.?.coverage);
    request.head = first;
    request.identity = @splat(4);
    const same = try fixture.output(try fixture.execute("same-gap", .{ .publication = request }));
    try std.testing.expectEqualDeep(first.question, same.question);
    request.head = same;
    request.acquired = .{
        .kind = .unchanged,
        .base = @splat('a'),
        .tip = @splat('a'),
        .reason = null,
        .commits = .{ .items = &.{} },
        .evidence = .{ .items = &.{} },
    };
    const success = try fixture.output(try fixture.execute(
        "source-success",
        .{ .publication = request },
    ));
    try std.testing.expectEqual(0, success.check_failure_streak);
    try std.testing.expect(success.question == null);
}

fn pause() t.DirectiveFact {
    return .{
        .reference = .{ .task = @splat(3), .digest = @splat(4) },
        .value = .{
            .envelope = examples.genesis().envelope,
            .obligation = @splat(1),
            .ordinal = 1,
            .predecessor = null,
            .body = .{ .pause = {} },
        },
    };
}

test "native phase recovery replacement folds pending controls and unknown accounting once" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var request = step(head());
    request.attempt = 1;
    request.supersession = supersession(.render, .unknown);
    request.fold_only = true;
    request.directives.items = &.{pause()};
    const fact: t.Settlement = .{
        .reference = .{ .task = @splat(8), .revision = 2, .digest = @splat(9) },
        .kind = .superseded,
        .accounting = .{ .possible_charged_calls = 1 },
    };
    request.facts.items = &.{fact};
    const result = try fixture.output(try fixture.execute("fold-unknown", .{ .step = request }));
    try std.testing.expectEqual(.paused, result.mode);
    try std.testing.expectEqual(1, result.sequence);
    try std.testing.expectEqual(1, result.attempt);
    try std.testing.expectEqualDeep(request.supersession.?.input, result.superseded.?);
    try std.testing.expectEqual(1, result.folded_directive_ordinal);
    try std.testing.expectEqual(1, result.accounting.possible_charged_calls);
    try std.testing.expectEqualSlices(
        t.RevisionReference,
        &.{fact.reference},
        result.consumed.items,
    );
    try std.testing.expectEqual(1, result.render_failure_streak);
    try std.testing.expectEqual(60_100, result.schedule.render_not_before_ms);
    try std.testing.expectEqualDeep(request.previous.observed, result.observed);
    request.fold_only = false;
    try fixture.rejected("replacement-effect", .{ .step = request }, "replacement_requires_fold");
}

test "native phase recovery failed render allows next source check and successful render resets" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var request = step(head());
    request.attempt = 1;
    request.supersession = supersession(.render, .failed);
    request.fold_only = true;
    const recovered = try fixture.output(try fixture.execute(
        "render-failed",
        .{ .step = request },
    ));
    const checked = try fixture.output(try fixture.execute(
        "check-remains-due",
        .{ .step = step(recovered) },
    ));
    try std.testing.expectEqual(.check, checked.phase);
    try std.testing.expectEqual(1, checked.render_failure_streak);
    request = step(head());
    request.previous.render_failure_streak = 2;
    request.previous.schedule.source_not_before_ms = 1_000;
    const batch = pendingBatch();
    request.batches.items = &.{batch};
    const rendered = try fixture.output(try fixture.execute(
        "render-success",
        .{ .step = request },
    ));
    try std.testing.expectEqual(.render, rendered.phase);
    try std.testing.expectEqual(0, rendered.render_failure_streak);
}

fn pendingBatch() @FieldType(t.Step, "batches").Child {
    return .{
        .reference = .{ .task = @splat(4), .digest = @splat(5) },
        .value = .{
            .repository = examples.specification().repository,
            .sequence = 2,
            .epoch = 0,
            .base = @splat('b'),
            .tip = @splat('c'),
            .coverage = .complete,
            .commits = .{ .items = &.{} },
            .raw_evidence = .{ .items = &.{} },
            .acquired_ms = 100,
            .provider_date = null,
        },
    };
}

test "native phase recovery rejects unrepresentable backoff and does not overflow counters" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var value = head();
    value.specification.policies.phase_attempts = 100;
    value.render_failure_streak = 48;
    try fixture.rejected("delay-overflow", failed(value, .render), "phase_backoff_overflow");
    value.specification.policies.phase_attempts = std.math.maxInt(u32);
    value.render_failure_streak = std.math.maxInt(u32);
    value.schedule.render_not_before_ms = 1000;
    try fixture.rejected("counter-overflow", failed(value, .render), "phase_failure_overflow");
}
