const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const chain = @import("../app/directive_chain.zig");
const witness = @import("directive_policy.zig");
const contracts = @import("contracts.zig");
const fresh = @import("native_genesis.zig").expectedFresh;
const Fixture = @import("native_fixture.zig").Fixture(witness.Types, witness.Application);

fn head() t.Head {
    var value = fresh(contracts.genesis());
    value.obligation = .{ .task = @splat(1) };
    value.lineage = @splat(2);
    value.sequence = 7;
    value.predecessor = .{ .task = @splat(5), .digest = @splat(6) };
    value.attempt = 2;
    value.specification.revision = 6;
    value.clock_ms = 1000;
    value.schedule.next_due_ms = 5000;
    value.observed = .{ .sequence = 18, .epoch = 2, .tip = @splat('a') };
    value.told = .{ .sequence = 9, .epoch = 1, .tip = @splat('b') };
    value.schedule.source_not_before_ms = 1700;
    value.schedule.render_not_before_ms = 1800;
    value.accounting = .{
        .known_calls = 11,
        .known_input_tokens = 90,
        .possible_charged_calls = 2,
    };
    return value;
}

fn question() t.Question {
    return .{
        .identity = @splat(20),
        .condition = @splat(21),
        .specification_revision = 6,
        .source_condition = .{
            .epoch = 2,
            .base = @splat('a'),
            .tip = @splat('c'),
            .coverage = .diverged,
        },
        .choices = .{ .items = &.{.{
            .value = .{ .bytes = "accept_gap" },
            .label = .{ .bytes = "Accept explicit gap" },
        }} },
        .prompt = .{ .bytes = "Accept the explicit gap?" },
    };
}

fn directive(
    id: u8,
    ordinal: u64,
    previous: ?t.InputReference,
    body: t.DirectiveBody,
) t.DirectiveFact {
    var envelope = contracts.genesis().envelope;
    envelope.stable_request = @splat(id + 40);
    envelope.origin = .{ .local = .{ .uid = 1000 } };
    return .{
        .reference = .{ .task = @splat(id), .digest = @splat(id + 1) },
        .value = .{
            .envelope = envelope,
            .obligation = @splat(1),
            .ordinal = ordinal,
            .predecessor = previous,
            .body = body,
        },
    };
}

fn selected(previous: t.Head, fact: t.DirectiveFact) t.Head {
    var value = previous;
    value.folded_directive_ordinal = fact.value.ordinal;
    value.last_directive = fact.reference;
    return value;
}

fn execute(
    fixture: *Fixture,
    operation: []const u8,
    previous: t.Head,
    facts: []const t.DirectiveFact,
) !chain.Result {
    return fixture.output(try fixture.execute(operation, .{
        .obligation = @splat(1),
        .head = previous,
        .directives = .{ .items = facts },
    }));
}

fn expectApplied(value: chain.Result, index: usize) !void {
    try std.testing.expectEqualDeep(
        chain.Outcome{ .applied = {} },
        value.dispositions.items[index].outcome,
    );
}

fn expectRejected(value: chain.Result, index: usize, reason: []const u8) !void {
    try std.testing.expectEqualStrings(
        reason,
        value.dispositions.items[index].outcome.rejected.bytes,
    );
}

test "native directive policy composes modes coalesced checks and refuses final heads" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const pause = directive(2, 1, null, .{ .pause = {} });
    const check = directive(3, 2, pause.reference, .{ .check = {} });
    const again = directive(4, 3, check.reference, .{ .check = {} });
    const paused = try execute(&f, "pause-checks", head(), &.{ pause, check, again });
    var expected = selected(head(), again);
    expected.mode = .paused;
    expected.desired_mode = .paused;
    expected.schedule.next_due_ms = expected.clock_ms;
    try std.testing.expectEqualDeep(expected, paused.head);
    for (0..3) |i| try expectApplied(paused, i);
    var stopped = head();
    stopped.mode = .paused;
    stopped.desired_mode = .paused;
    const resume_case = directive(5, 1, null, .{ .@"resume" = {} });
    const resumed = try execute(&f, "resume", stopped, &.{resume_case});
    expected = selected(stopped, resume_case);
    expected.mode = .active;
    expected.desired_mode = .active;
    try std.testing.expectEqualDeep(expected, resumed.head);
    const cancel = directive(6, 1, null, .{ .cancel = {} });
    const revive = directive(7, 2, cancel.reference, .{ .@"resume" = {} });
    const late = directive(8, 3, revive.reference, .{ .check = {} });
    const final = try execute(&f, "final-controls", head(), &.{ cancel, revive, late });
    expected = selected(head(), late);
    expected.mode = .cancelled;
    expected.desired_mode = .cancelled;
    try std.testing.expectEqualDeep(expected, final.head);
    for (1..3) |i| try expectRejected(final, i, "final_head");
    const transfer = directive(10, 1, null, .{ .transfer = {} });
    const transferred = try execute(&f, "transfer", head(), &.{transfer});
    expected = selected(head(), transfer);
    expected.mode = .transferred;
    try std.testing.expectEqualDeep(expected, transferred.head);
}

fn retainedMethod() t.Method {
    return .{ .retained = .{
        .source = .{ .task = @splat(11), .digest = @splat(12) },
        .source_digest = @splat(13),
        .contract_digest = @splat(14),
        .report = .{ .task = @splat(15), .digest = @splat(16) },
        .applicability = @splat(17),
        .state = .{ .bytes = "method state" },
        .consecutive_faults = 0,
    } };
}

fn amendment() t.Amendment {
    return .{
        .expected_revision = 6,
        .interval_ms = 2000,
        .wording = .{ .bytes = "Summarize the verified changes." },
        .policies = null,
        .repository_route = null,
    };
}

test "native directive policy delegates amendments adoption and reversion with stale rejection" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const amend = directive(2, 1, null, .{ .amend = amendment() });
    const adopt = directive(3, 2, amend.reference, .{ .adopt = .{
        .expected_revision = 7,
        .method = retainedMethod(),
    } });
    const revert = directive(4, 3, adopt.reference, .{ .revert = .{ .expected_revision = 8 } });
    const stale = directive(5, 4, revert.reference, .{ .amend = amendment() });
    const value = try execute(&f, "revisions", head(), &.{ amend, adopt, revert, stale });
    var expected = selected(head(), stale);
    expected.specification.revision = 9;
    expected.specification.interval_ms = 2000;
    expected.specification.wording = amendment().wording.?;
    expected.schedule.next_due_ms = 2100;
    try std.testing.expectEqualDeep(expected, value.head);
    for (0..3) |i| try expectApplied(value, i);
    try expectRejected(value, 3, "stale_revision");
}

fn expectedGap(previous: t.Head) t.Batch {
    const condition = previous.question.?.source_condition.?;
    return .{
        .repository = previous.specification.repository,
        .sequence = previous.observed.sequence + 1,
        .epoch = previous.observed.epoch + 1,
        .base = condition.base,
        .tip = condition.tip,
        .coverage = .accepted_gap,
        .commits = .{ .items = &.{} },
        .raw_evidence = .{ .items = &.{} },
        .acquired_ms = previous.clock_ms,
        .provider_date = null,
    };
}

test "native directive policy records source gaps preserving earlier owed records" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    var previous = head();
    previous.question = question();
    const answer = directive(2, 1, null, .{ .answer = .{
        .question = question().identity,
        .choice = .{ .bytes = "accept_gap" },
    } });
    const repeated = directive(3, 2, answer.reference, answer.value.body);
    const value = try execute(&f, "accept-gap", previous, &.{ answer, repeated });
    const gap = expectedGap(previous);
    var expected = selected(previous, repeated);
    expected.question = null;
    expected.observed = .{ .sequence = gap.sequence, .epoch = gap.epoch, .tip = gap.tip };
    expected.last_observation = .{
        .sequence = gap.sequence,
        .epoch = gap.epoch,
        .tip = gap.tip,
        .batch = .{ .current = {} },
        .coverage = .accepted_gap,
        .acquired_ms = previous.clock_ms,
        .provider_date = null,
        .commit_count = 0,
    };
    expected.schedule.next_due_ms = previous.clock_ms;
    try std.testing.expectEqualDeep(expected, value.head);
    try std.testing.expectEqualDeep(gap, value.gap.?);
    try expectApplied(value, 0);
    try expectRejected(value, 1, "question_missing");
}

const AnswerCase = enum {
    identity,
    choice,
    revision,
    epoch,
    base,
    no_tip,
    sequence,
    epoch_max,
};

fn changedQuestion(
    case: AnswerCase,
    previous: *t.Head,
    answer: *@FieldType(t.DirectiveBody, "answer"),
) void {
    switch (case) {
        .identity => answer.question = @splat(99),
        .choice => answer.choice = .{ .bytes = "not offered" },
        .revision => previous.question.?.specification_revision = 5,
        .epoch => previous.question.?.source_condition.?.epoch = 1,
        .base => previous.question.?.source_condition.?.base = @splat('z'),
        .no_tip => previous.observed.tip = null,
        .sequence => previous.observed.sequence = std.math.maxInt(u64),
        .epoch_max => {
            previous.observed.epoch = std.math.maxInt(u64);
            previous.question.?.source_condition.?.epoch = std.math.maxInt(u64);
        },
    }
}

test "native directive policy refuses stale or unbound answers and exhausted source counters" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    for (std.enums.values(AnswerCase)) |case| {
        var previous = head();
        previous.question = question();
        var answer: @FieldType(t.DirectiveBody, "answer") = .{
            .question = question().identity,
            .choice = .{ .bytes = "accept_gap" },
        };
        changedQuestion(case, &previous, &answer);
        const fact = directive(2, 1, null, .{ .answer = answer });
        const value = try execute(&f, @tagName(case), previous, &.{fact});
        try std.testing.expectEqualDeep(selected(previous, fact), value.head);
        const code = switch (case) {
            .identity, .choice, .revision => "question_binding_mismatch",
            else => "source_condition_changed",
        };
        try expectRejected(value, 0, code);
        try std.testing.expect(value.gap == null);
    }
    var previous = head();
    previous.question = question();
    previous.question.?.source_condition = null;
    const fact = directive(3, 1, null, .{ .answer = .{
        .question = question().identity,
        .choice = .{ .bytes = "accept_gap" },
    } });
    const closed = try execute(&f, "ordinary-question", previous, &.{fact});
    var expected = selected(previous, fact);
    expected.question = null;
    try std.testing.expectEqualDeep(expected, closed.head);
    try std.testing.expect(closed.gap == null);
}

const ExcessGaps = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const apply = try c.author.function("invalid duplicate gap witness", .{
            .input = try c.schema(chain.ApplyInput),
        }, try c.schema(chain.Applied), &.{});
        const b = try c.author.body(apply);
        const input = try b.parameter("input");
        var previous = head();
        previous.question = question();
        const result = try b.product(try c.schema(chain.Applied), .{
            .head = try b.field(input, "head"),
            .outcome = try c.literal(chain.Outcome, .{ .applied = {} }),
            .gap = try c.literal(?t.Batch, expectedGap(previous)),
        });
        try c.author.define(apply, try b.ret(result));
        return c.author.module(try chain.emit(c, apply), try c.schema(t.Failure));
    }
};

test "native directive policy chain rejects multiple gap publications" {
    const GapFixture = @import("native_fixture.zig").Fixture(witness.Types, ExcessGaps);
    var f: GapFixture = .{};
    defer f.deinit();
    try f.init();
    const first = directive(2, 1, null, .{ .check = {} });
    const second = directive(3, 2, first.reference, .{ .check = {} });
    try f.rejected("multiple-gaps", .{
        .obligation = @splat(1),
        .head = head(),
        .directives = .{ .items = &.{ first, second } },
    }, "multiple_directive_gaps");
}
