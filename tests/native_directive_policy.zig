const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const chain = @import("../app/directive_chain.zig");
const witness = @import("directive_policy.zig");
const contracts = @import("contracts.zig");
const fresh = @import("native_genesis.zig").expectedFresh;
const Fixture = @import("native_fixture.zig").Fixture(witness.Types, witness.Application);

fn intent() t.DeliveryIntent {
    return .{
        .key = .{
            .lineage = @splat(2),
            .purpose = .digest,
            .identity = @splat(3),
            .generation = 4,
        },
        .payload = .{
            .obligation = @splat(1),
            .specification_revision = 6,
            .prior_sequence = 9,
            .through_sequence = 15,
            .frozen_text = .{ .bytes = "Seven verified changes." },
            .prompt = null,
            .supersedes = null,
            .coverage = .{ .sequence = 15, .epoch = 2, .tip = @splat('c') },
        },
    };
}

fn head() t.Head {
    var value = fresh(contracts.genesis());
    value.obligation = .{ .task = @splat(1) };
    value.lineage = @splat(2);
    value.sequence = 7;
    value.predecessor = .{ .task = @splat(5), .digest = @splat(6) };
    value.attempt = 2;
    value.specification.revision = 6;
    value.clock_ms = 1000;
    value.next_due_ms = 5000;
    value.observed = .{ .sequence = 18, .epoch = 2, .tip = @splat('a') };
    value.told = .{ .sequence = 9, .epoch = 1, .tip = @splat('b') };
    value.digest = .{ .delivery = intent(), .hold = .uncertain_transmission, .not_before_ms = 950 };
    value.source_not_before_ms = 1700;
    value.render_not_before_ms = 1800;
    value.accounting = .{
        .known_calls = 11,
        .known_input_tokens = 90,
        .possible_charged_calls = 2,
    };
    return value;
}

fn question() t.Question {
    var prompt = intent();
    prompt.key.purpose = .question;
    prompt.key.identity = @splat(20);
    prompt.payload.prompt = @splat(20);
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
        .choices = .{ .items = &.{.{ .bytes = "accept_gap" }} },
        .prompt = prompt,
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
    expected.next_due_ms = expected.clock_ms;
    try std.testing.expectEqualDeep(expected, paused.head);
    for (0..3) |i| try expectApplied(paused, i);
    var held = head();
    held.mode = .paused;
    held.recovery_hold = true;
    const resume_case = directive(5, 1, null, .{ .@"resume" = {} });
    const resumed = try execute(&f, "recovery-resume", held, &.{resume_case});
    expected = selected(held, resume_case);
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
    expected.next_due_ms = previous.clock_ms;
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

const warning = "The earlier digest may also have arrived. " ++
    "This is the authorized replacement issue.\n\n";

test "native directive policy authorizes one new digest issue preserving unknown generations" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const release = directive(2, 1, null, .{ .release = .{ .key = intent().key } });
    const value = try execute(&f, "release", head(), &.{release});
    var expected = selected(head(), release);
    expected.digest.?.delivery.key.identity = release.value.envelope.stable_request;
    expected.digest.?.delivery.key.generation = 0;
    expected.digest.?.delivery.payload.issue = 1;
    expected.digest.?.delivery.payload.supersedes = intent().key;
    expected.digest.?.delivery.payload.frozen_text = .{
        .bytes = warning ++ "Seven verified changes.",
    };
    expected.digest.?.hold = .none;
    try std.testing.expectEqualDeep(expected, value.head);
    try expectApplied(value, 0);
    var again = value.head;
    again.digest.?.hold = .uncertain_transmission;
    const exhausted = directive(3, 2, release.reference, .{ .release = .{
        .key = again.digest.?.delivery.key,
    } });
    const refused = try execute(&f, "second-release", again, &.{exhausted});
    try std.testing.expectEqualDeep(selected(again, exhausted), refused.head);
    try expectRejected(refused, 0, "release_not_authorized");
}

const question_warning = "The earlier question prompt may also have arrived. " ++
    "This is the authorized replacement issue.\n\n";

test "native directive policy holds a question at a boundary and reissues it once released" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    var previous = head();
    previous.question = question();
    const boundary: t.InputReference = .{ .task = @splat(30), .digest = @splat(31) };
    const hold = directive(2, 1, null, .{ .recovery_hold = .{ .recovery = boundary } });
    const old_key = question().prompt.key;
    const release = directive(3, 2, hold.reference, .{ .release = .{ .key = old_key } });
    const value = try execute(&f, "question-release", previous, &.{ hold, release });
    try expectApplied(value, 0);
    try expectApplied(value, 1);
    var expected = question();
    expected.prompt.key.identity = release.value.envelope.stable_request;
    expected.prompt.key.generation = 0;
    expected.prompt.payload.issue = 1;
    expected.prompt.payload.supersedes = old_key;
    expected.prompt.payload.frozen_text = .{
        .bytes = question_warning ++ "Seven verified changes.",
    };
    try std.testing.expectEqualDeep(expected, value.head.question.?);
    try std.testing.expect(value.head.recovery_hold);
    const again = directive(4, 3, release.reference, .{ .release = .{
        .key = expected.prompt.key,
    } });
    const repeated = try execute(&f, "question-release-again", value.head, &.{again});
    try std.testing.expectEqualDeep(selected(value.head, again), repeated.head);
    try expectRejected(repeated, 0, "release_not_authorized");
    const unheld = directive(5, 1, null, .{ .release = .{ .key = old_key } });
    const refused = try execute(&f, "question-release-unheld", previous, &.{unheld});
    try std.testing.expectEqualDeep(selected(previous, unheld), refused.head);
    try expectRejected(refused, 0, "release_not_authorized");
    var absent = head();
    absent.question = null;
    const missing = try execute(&f, "question-release-missing", absent, &.{unheld});
    try expectRejected(missing, 0, "question_missing");
}

const ReleaseCase = enum {
    key,
    fault,
    paused,
    none,
    identity,
    issue,
    predecessor,
    lineage,
    prior,
    beyond,
    coverage,
};

fn changedRelease(case: ReleaseCase, previous: *t.Head, fact: *t.DirectiveFact) void {
    switch (case) {
        .key => fact.value.body.release.key.generation += 1,
        .fault => previous.digest.?.hold = .rendering_fault,
        .paused => previous.digest.?.hold = .paused,
        .none => previous.digest.?.hold = .none,
        .identity => fact.value.envelope.stable_request = intent().key.identity,
        .issue => previous.digest.?.delivery.payload.issue = 1,
        .predecessor => previous.digest.?.delivery.payload.supersedes = intent().key,
        .lineage => {
            previous.digest.?.delivery.key.lineage = @splat(99);
            fact.value.body.release.key = previous.digest.?.delivery.key;
        },
        .prior => previous.digest.?.delivery.payload.prior_sequence = 8,
        .beyond => previous.digest.?.delivery.payload.through_sequence = 19,
        .coverage => previous.digest.?.delivery.payload.coverage = null,
    }
}

test "native directive policy rejects wrong keys permanent faults and missing coverage" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    for (std.enums.values(ReleaseCase)) |case| {
        var previous = head();
        var fact = directive(2, 1, null, .{ .release = .{ .key = intent().key } });
        changedRelease(case, &previous, &fact);
        const value = try execute(&f, @tagName(case), previous, &.{fact});
        try std.testing.expectEqualDeep(selected(previous, fact), value.head);
        try expectRejected(value, 0, "release_not_authorized");
    }
    var absent = head();
    absent.digest = null;
    const fact = directive(2, 1, null, .{ .release = .{ .key = intent().key } });
    const missing = try execute(&f, "missing", absent, &.{fact});
    try expectRejected(missing, 0, "digest_missing");
}

test "native directive policy abbreviates full escaped digests with a duplicate warning" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    var previous = head();
    const expanded: [800]u8 = @splat('&');
    previous.digest.?.delivery.payload.frozen_text = .{ .bytes = &expanded };
    const release = directive(2, 1, null, .{ .release = .{ .key = intent().key } });
    const value = try execute(&f, "abbreviated", previous, &.{release});
    try expectApplied(value, 0);
    const output = value.head.digest.?.delivery;
    try std.testing.expectEqualStrings(warning ++
        "Abbreviated digest: observation records after 9 through 15. " ++
        "Full entries and evidence remain in local history.", output.payload.frozen_text.bytes);
    try std.testing.expectEqualDeep(
        previous.digest.?.delivery.payload.coverage,
        output.payload.coverage,
    );
    var prepared = try @import("../native/delivery_prepare.zig").materialize(
        f.arena.allocator(),
        output,
        .{ .task = @splat(7), .digest = @splat(8) },
        @splat(9),
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.value.payload.wire_json.bytes.len != 0);
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
