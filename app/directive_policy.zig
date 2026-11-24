const std = @import("std");
const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const bytes = @import("bytes.zig");
const mode = @import("mode.zig");
const revision = @import("revision.zig");
const chain = @import("directive_chain.zig");

const ChoiceArgs = struct { choices: cts.Vector(t.Choice, 8), choice: t.Name, index: u64 };
const Choices = a.Function(ChoiceArgs, bool);
const Helpers = struct {
    digests: a.Function(bytes.Parameters(32), bool),
    oids: a.Function(bytes.Parameters(40), bool),
    choices: Choices,
    mode: mode.Function,
    revision: revision.Function,
};
const SourceCondition = @typeInfo(@FieldType(t.Question, "source_condition")).optional.child;

pub fn emit(c: protean.Context) !chain.Apply {
    const helpers: Helpers = .{
        .digests = try bytes.emit(c, 32),
        .oids = try bytes.emit(c, 40),
        .choices = try choicesFunction(c),
        .mode = try mode.emit(c),
        .revision = try revision.emit(c),
    };
    const function = try c.author.function("fold operator directive policy", .{
        .input = try c.schema(chain.ApplyInput),
    }, try c.schema(chain.Applied), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const directive = try b.field(input, "directive");
    const body = try b.field(directive, "body");
    const old_mode = try b.field(head, "mode");
    const final = try b.select(
        try mode.enumIs(c, b, t.Mode, old_mode, .cancelled),
        try b.constant(bool, true),
        try mode.enumIs(c, b, t.Mode, old_mode, .transferred),
    );
    const allowed = try b.booleanNot(final);
    const active = try b.branch();
    const ended = try b.branch();
    const next = try applyBody(c, active, helpers, head, body);
    const applied = try b.conditional(
        allowed,
        try active.ret(next),
        try ended.ret(try refuse(c, ended, head, "final_head")),
    );
    try c.author.define(function, try b.ret(applied));
    return function;
}

fn applyBody(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    body: a.Value(t.DirectiveBody),
) !a.Value(chain.Applied) {
    const pause = try b.caseOf(body, "pause");
    const run = try b.caseOf(body, "resume");
    const cancel = try b.caseOf(body, "cancel");
    const transfer = try b.caseOf(body, "transfer");
    const check = try b.caseOf(body, "check");
    const amend = try b.caseOf(body, "amend");
    const adopt = try b.caseOf(body, "adopt");
    const revert = try b.caseOf(body, "revert");
    const answer = try b.caseOf(body, "answer");
    const cb = check.body();
    const due = try cb.update(head, .{ .schedule = try cb.update(
        try cb.field(head, "schedule"),
        .{ .next_due_ms = try cb.field(head, "clock_ms") },
    ) });
    const amended = try revise(c, amend.body(), h.revision, head, "amend", amend.payload());
    const adopted = try revise(c, adopt.body(), h.revision, head, "adopt", adopt.payload());
    const reverted = try revise(c, revert.body(), h.revision, head, "revert", revert.payload());
    return b.match(body, .{
        .pause = try pause.ret(try control(c, pause.body(), h.mode, head, .pause)),
        .@"resume" = try run.ret(try control(c, run.body(), h.mode, head, .@"resume")),
        .cancel = try cancel.ret(try control(c, cancel.body(), h.mode, head, .cancel)),
        .transfer = try transfer.ret(try control(c, transfer.body(), h.mode, head, .transfer)),
        .check = try check.ret(try accept(c, check.body(), due)),
        .amend = try amend.ret(amended),
        .adopt = try adopt.ret(adopted),
        .revert = try revert.ret(reverted),
        .answer = try answer.ret(try answerQuestion(c, answer.body(), h, head, answer.payload())),
    });
}

fn outcomeResult(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    outcome: anytype,
) !a.Value(chain.Applied) {
    return b.product(try c.schema(chain.Applied), .{
        .head = head,
        .outcome = outcome,
        .gap = try c.literal(?t.Batch, null),
    });
}

fn accept(c: protean.Context, b: anytype, head: a.Value(t.Head)) !a.Value(chain.Applied) {
    return outcomeResult(c, b, head, try c.literal(chain.Outcome, .{ .applied = {} }));
}

fn refuse(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    code: []const u8,
) !a.Value(chain.Applied) {
    return outcomeResult(
        c,
        b,
        head,
        try c.literal(chain.Outcome, .{ .rejected = .{ .bytes = code } }),
    );
}

fn control(
    c: protean.Context,
    b: anytype,
    function: mode.Function,
    head: a.Value(t.Head),
    value: mode.Control,
) !a.Value(chain.Applied) {
    const next = try b.call(function, .{ .input = try b.product(try c.schema(mode.Input), .{
        .head = head,
        .control = try c.literal(mode.Control, value),
    }) });
    return accept(c, b, next);
}

fn revise(
    c: protean.Context,
    b: anytype,
    function: revision.Function,
    head: a.Value(t.Head),
    comptime tag: []const u8,
    change: anytype,
) !a.Value(chain.Applied) {
    const next = try b.call(function, .{ .input = try b.product(try c.schema(revision.Input), .{
        .head = head,
        .change = try b.variant(try c.schema(revision.Change), tag, change),
    }) });
    return outcomeResult(c, b, try b.field(next, "head"), try b.field(next, "disposition"));
}

fn answerQuestion(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    answer: a.Value(@FieldType(t.DirectiveBody, "answer")),
) !a.Value(chain.Applied) {
    const question = try b.field(head, "question");
    const none = try b.caseOf(question, "none");
    const some = try b.caseOf(question, "some");
    const sb = some.body();
    const same_id = try digestEqual(
        sb,
        h,
        try sb.field(some.payload(), "identity"),
        try sb.field(answer, "question"),
    );
    const chosen = try sb.call(h.choices, .{
        .choices = try sb.field(some.payload(), "choices"),
        .choice = try sb.field(answer, "choice"),
        .index = try sb.constant(u64, 0),
    });
    const current = try sb.equal(
        try sb.field(some.payload(), "specification_revision"),
        try sb.field(try sb.field(head, "specification"), "revision"),
    );
    const valid = try all(sb, &.{ same_id, chosen, current });
    const accepted = try sb.branch();
    const rejected = try sb.branch();
    const next = try answerCondition(
        c,
        accepted,
        h,
        head,
        some.payload(),
        try accepted.field(answer, "choice"),
    );
    const applied = try sb.conditional(
        valid,
        try accepted.ret(next),
        try rejected.ret(try refuse(c, rejected, head, "question_binding_mismatch")),
    );
    return b.match(question, .{
        .none = try none.ret(try refuse(c, none.body(), head, "question_missing")),
        .some = try some.ret(applied),
    });
}

fn answerCondition(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    question: a.Value(t.Question),
    choice: a.Value(t.Name),
) !a.Value(chain.Applied) {
    const condition = try b.field(question, "source_condition");
    const none = try b.caseOf(condition, "none");
    const some = try b.caseOf(condition, "some");
    const closed = try none.body().update(head, .{ .question = try c.literal(?t.Question, null) });
    const valid = try sourceConditionValid(c, some.body(), h, head, some.payload(), choice);
    const accepted = try some.body().branch();
    const rejected = try some.body().branch();
    const next = try publishGap(c, accepted, head, some.payload());
    const applied = try some.body().conditional(
        valid,
        try accepted.ret(next),
        try rejected.ret(try refuse(c, rejected, head, "source_condition_changed")),
    );
    return b.match(condition, .{
        .none = try none.ret(try accept(c, none.body(), closed)),
        .some = try some.ret(applied),
    });
}

fn sourceConditionValid(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    condition: a.Value(SourceCondition),
    choice: a.Value(t.Name),
) !a.Value(bool) {
    const observed = try b.field(head, "observed");
    const tip = try b.field(observed, "tip");
    const none = try b.caseOf(tip, "none");
    const some = try b.caseOf(tip, "some");
    const same_base = try some.body().call(h.oids, .{
        .left = some.payload(),
        .right = try some.body().field(condition, "base"),
        .index = try some.body().constant(u64, 0),
    });
    const base = try b.match(tip, .{
        .none = try none.ret(try none.body().constant(bool, false)),
        .some = try some.ret(same_base),
    });
    const epoch = try b.equal(try b.field(observed, "epoch"), try b.field(condition, "epoch"));
    const action = try textEqual(b, choice, try c.literal(t.Name, .{ .bytes = "accept_gap" }));
    const sequence_room = try b.less(
        try b.field(observed, "sequence"),
        try b.constant(u64, std.math.maxInt(u64)),
    );
    const epoch_room = try b.less(
        try b.field(observed, "epoch"),
        try b.constant(u64, std.math.maxInt(u64)),
    );
    return all(b, &.{ base, epoch, action, sequence_room, epoch_room });
}

fn publishGap(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    condition: a.Value(SourceCondition),
) !a.Value(chain.Applied) {
    const observed = try b.field(head, "observed");
    const failure = try a.failure(c, "gap_counter_overflow");
    const sequence = try b.checked(
        .add,
        try b.field(observed, "sequence"),
        try b.constant(u64, 1),
        .{ .overflow = failure },
    );
    const epoch = try b.checked(
        .add,
        try b.field(observed, "epoch"),
        try b.constant(u64, 1),
        .{ .overflow = failure },
    );
    const tip = try b.field(condition, "tip");
    const clock = try b.field(head, "clock_ms");
    const gap = try b.product(try c.schema(t.Batch), .{
        .repository = try b.field(try b.field(head, "specification"), "repository"),
        .sequence = sequence,
        .epoch = epoch,
        .base = try b.field(condition, "base"),
        .tip = tip,
        .coverage = try c.literal(t.Coverage, .accepted_gap),
        .commits = try c.literal(@FieldType(t.Batch, "commits"), .{ .items = &.{} }),
        .raw_evidence = try c.literal(@FieldType(t.Batch, "raw_evidence"), .{ .items = &.{} }),
        .acquired_ms = clock,
        .provider_date = try c.literal(?t.Timestamp, null),
    });
    const frontier = try b.product(try c.schema(t.Frontier), .{
        .sequence = sequence,
        .epoch = epoch,
        .tip = try b.variant(try c.schema(?t.Oid), "some", tip),
    });
    const observation = try b.product(try c.schema(t.Observation), .{
        .sequence = sequence,
        .epoch = epoch,
        .tip = tip,
        .batch = try c.literal(?t.PublicationReference, .{ .current = {} }),
        .coverage = try c.literal(t.Coverage, .accepted_gap),
        .acquired_ms = clock,
        .provider_date = try c.literal(?t.Timestamp, null),
        .commit_count = try b.constant(u64, 0),
    });
    const next = try b.update(head, .{
        .observed = frontier,
        .question = try c.literal(?t.Question, null),
        .last_observation = try b.variant(try c.schema(?t.Observation), "some", observation),
        .schedule = try b.update(try b.field(head, "schedule"), .{ .next_due_ms = clock }),
    });
    return b.update(try accept(c, b, next), .{
        .gap = try b.variant(try c.schema(?t.Batch), "some", gap),
    });
}

fn choicesFunction(c: protean.Context) !Choices {
    const function = try c.author.function("match offered question answer", .{
        .choices = try c.schema(cts.Vector(t.Choice, 8)),
        .choice = try c.schema(t.Name),
        .index = try c.schema(u64),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const choices = try b.parameter("choices");
    const choice = try b.parameter("choice");
    const index = try b.parameter("index");
    const more = try b.branch();
    const done = try b.branch();
    const option = try more.variantPayload(
        try more.sequenceGet(choices, index),
        "some",
        try a.failure(c, "question_choice_bounds"),
    );
    const found = try more.branch();
    const next = try more.branch();
    const continued = try next.call(function, .{
        .choices = choices,
        .choice = choice,
        .index = try next.checked(.add, index, try next.constant(u64, 1), .{
            .overflow = try a.failure(c, "question_choice_overflow"),
        }),
    });
    const selected = try more.conditional(
        try textEqual(more, try more.field(option, "value"), choice),
        try found.ret(try found.constant(bool, true)),
        try next.ret(continued),
    );
    const result_value = try b.conditional(
        try b.less(index, try b.sequenceLength(choices)),
        try more.ret(selected),
        try done.ret(try done.constant(bool, false)),
    );
    try c.author.define(function, try b.ret(result_value));
    return function;
}

fn digestEqual(
    b: anytype,
    h: Helpers,
    left: a.Value(t.Digest),
    right: a.Value(t.Digest),
) !a.Value(bool) {
    return b.call(h.digests, .{ .left = left, .right = right, .index = try b.constant(u64, 0) });
}

fn textEqual(b: anytype, left: anytype, right: anytype) !a.Value(bool) {
    return b.equal(try b.blobCompare(left, right), try b.constant(i8, 0));
}

fn all(b: anytype, values: []const a.Value(bool)) !a.Value(bool) {
    var conjunction = try b.constant(bool, true);
    for (values) |value| conjunction = try b.select(
        conjunction,
        value,
        try b.constant(bool, false),
    );
    return conjunction;
}
