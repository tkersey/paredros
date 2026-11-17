const std = @import("std");
const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const bytes = @import("bytes.zig");
const mode = @import("mode.zig");
const revision = @import("revision.zig");
const chain = @import("directive_chain.zig");

const ChoiceArgs = struct { choices: cts.Vector(t.Name, 8), choice: t.Name, index: u64 };
const Choices = a.Function(ChoiceArgs, bool);
const FitsArgs = struct { text: t.Text, index: u64, used: u64 };
const Fits = a.Function(FitsArgs, bool);
const Helpers = struct {
    ids: a.Function(bytes.Parameters(16), bool),
    digests: a.Function(bytes.Parameters(32), bool),
    oids: a.Function(bytes.Parameters(40), bool),
    choices: Choices,
    fits: Fits,
    mode: mode.Function,
    revision: revision.Function,
};
const SourceCondition = @typeInfo(@FieldType(t.Question, "source_condition")).optional.child;

pub fn emit(c: protean.Context) !chain.Apply {
    const helpers: Helpers = .{
        .ids = try bytes.emit(c, 16),
        .digests = try bytes.emit(c, 32),
        .oids = try bytes.emit(c, 40),
        .choices = try choicesFunction(c),
        .fits = try fitsFunction(c),
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
    const readonly = try b.select(
        try bodyIs(b, body, "audit"),
        try b.constant(bool, true),
        try bodyIs(b, body, "frontier_audit"),
    );
    const allowed = try b.select(final, readonly, try b.constant(bool, true));
    const active = try b.branch();
    const ended = try b.branch();
    const next = try applyBody(c, active, helpers, head, directive, body);
    const applied = try b.conditional(
        allowed,
        try active.ret(next),
        try ended.ret(try refuse(c, ended, head, "final_head")),
    );
    const result = try withNotice(c, b, directive, applied);
    try c.author.define(function, try b.ret(result));
    return function;
}

fn applyBody(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    directive: a.Value(t.Directive),
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
    const release = try b.caseOf(body, "release");
    const audit = try b.caseOf(body, "audit");
    const frontier = try b.caseOf(body, "frontier_audit");
    const recovery_hold = try b.caseOf(body, "recovery_hold");
    const recovery_release = try b.caseOf(body, "recovery_release");
    const due = try check.body().update(
        head,
        .{ .next_due_ms = try check.body().field(head, "clock_ms") },
    );
    const frontier_result = try frontier.body().update(try accept(c, frontier.body(), head), .{
        .audit_request = try c.literal(?t.AuditRequest, .{ .frontier = {} }),
    });
    const amended = try revise(c, amend.body(), h.revision, head, "amend", amend.payload());
    const adopted = try revise(c, adopt.body(), h.revision, head, "adopt", adopt.payload());
    const reverted = try revise(c, revert.body(), h.revision, head, "revert", revert.payload());
    const hb = recovery_hold.body();
    const rb = recovery_release.body();
    const held = try holdRecovery(c, hb, head, directive, recovery_hold.payload());
    const released = try releaseRecovery(c, rb, h, head, directive, recovery_release.payload());
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
        .release = try release.ret(try releaseDigest(
            c,
            release.body(),
            h,
            head,
            directive,
            try release.body().field(release.payload(), "key"),
        )),
        .audit = try audit.ret(try requestAudit(
            c,
            audit.body(),
            h,
            head,
            try audit.body().field(audit.payload(), "key"),
        )),
        .frontier_audit = try frontier.ret(frontier_result),
        .recovery_hold = try recovery_hold.ret(held),
        .recovery_release = try recovery_release.ret(released),
    });
}

fn localOrigin(b: anytype, directive: a.Value(t.Directive)) !a.Value(bool) {
    const origin = try b.field(try b.field(directive, "envelope"), "origin");
    return b.equal(
        try b.variantTag(origin),
        try b.constant(u64, std.meta.fieldIndex(t.Origin, "local").?),
    );
}

fn holdRecovery(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    directive: a.Value(t.Directive),
    request: a.Value(@FieldType(t.DirectiveBody, "recovery_hold")),
) !a.Value(chain.Applied) {
    const next = try mode.recoveryHold(c, b, head, try b.field(request, "recovery"));
    return b.select(
        try localOrigin(b, directive),
        try accept(c, b, next),
        try refuse(c, b, head, "recovery_local_only"),
    );
}

fn releaseRecovery(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    directive: a.Value(t.Directive),
    request: a.Value(@FieldType(t.DirectiveBody, "recovery_release")),
) !a.Value(chain.Applied) {
    const boundary = try b.field(head, "recovery_boundary");
    const none = try b.caseOf(boundary, "none");
    const some = try b.caseOf(boundary, "some");
    const sb = some.body();
    const reference = try sb.field(request, "recovery");
    const same = try all(sb, &.{
        try sb.call(h.ids, .{
            .left = try sb.field(some.payload(), "task"),
            .right = try sb.field(reference, "task"),
        }),
        try digestEqual(
            sb,
            h,
            try sb.field(some.payload(), "digest"),
            try sb.field(reference, "digest"),
        ),
        try sb.field(request, "exclusive_owner"),
        try localOrigin(sb, directive),
    });
    const result = try sb.select(
        same,
        try accept(c, sb, try mode.recoveryRelease(c, sb, head)),
        try refuse(c, sb, head, "recovery_release_not_authorized"),
    );
    return b.match(boundary, .{
        .none = try none.ret(try refuse(c, none.body(), head, "recovery_boundary_missing")),
        .some = try some.ret(result),
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
        .notice = try c.literal(?t.DeliveryIntent, null),
        .audit_request = try c.literal(?t.AuditRequest, null),
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
    const anchored = try sb.booleanNot(try isNone(
        c,
        sb,
        t.PublicationReference,
        try sb.field(some.payload(), "evidence"),
    ));
    const valid = try all(sb, &.{ same_id, chosen, current, anchored });
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
        .next_due_ms = clock,
    });
    return b.update(try accept(c, b, next), .{
        .gap = try b.variant(try c.schema(?t.Batch), "some", gap),
    });
}

fn releaseDigest(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    directive: a.Value(t.Directive),
    requested: a.Value(t.DeliveryKey),
) !a.Value(chain.Applied) {
    const digest = try b.field(head, "digest");
    const none = try b.caseOf(digest, "none");
    const some = try b.caseOf(digest, "some");
    const sb = some.body();
    const delivery = try sb.field(some.payload(), "delivery");
    const key = try sb.field(delivery, "key");
    const payload = try sb.field(delivery, "payload");
    const new_identity = try sb.field(try sb.field(directive, "envelope"), "stable_request");
    const same_key = try keyEqual(sb, h, key, requested);
    const held = try mode.enumIs(
        c,
        sb,
        t.DeliveryHold,
        try sb.field(some.payload(), "hold"),
        .uncertain_transmission,
    );
    const purpose = try mode.enumIs(
        c,
        sb,
        @FieldType(t.DeliveryKey, "purpose"),
        try sb.field(key, "purpose"),
        .digest,
    );
    const fresh = try sb.equal(try sb.field(payload, "issue"), try sb.constant(u32, 0));
    const original = try isNone(c, sb, ?t.DeliveryKey, try sb.field(payload, "supersedes"));
    const distinct = try sb.booleanNot(try digestEqual(
        sb,
        h,
        new_identity,
        try sb.field(key, "identity"),
    ));
    const lineage = try digestEqual(
        sb,
        h,
        try sb.field(key, "lineage"),
        try sb.field(head, "lineage"),
    );
    const coverage = try releasableCoverage(c, sb, head, payload);
    const valid = try all(
        sb,
        &.{ same_key, held, purpose, fresh, original, distinct, lineage, coverage },
    );
    const accepted = try sb.branch();
    const rejected = try sb.branch();
    const next = try replacement(c, accepted, h, head, some.payload(), new_identity);
    const applied = try sb.conditional(
        valid,
        try accepted.ret(next),
        try rejected.ret(try refuse(c, rejected, head, "release_not_authorized")),
    );
    return b.match(digest, .{
        .none = try none.ret(try refuse(c, none.body(), head, "digest_missing")),
        .some = try some.ret(applied),
    });
}

fn releasableCoverage(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    payload: a.Value(t.LogicalPayload),
) !a.Value(bool) {
    _ = c;
    const prior = try b.field(payload, "prior_sequence");
    const through = try b.field(payload, "through_sequence");
    const observed = try b.field(head, "observed");
    const current = try b.equal(prior, try b.field(try b.field(head, "told"), "sequence"));
    const growing = try b.less(prior, through);
    const acquired = try b.booleanNot(try b.less(try b.field(observed, "sequence"), through));
    const coverage = try b.field(payload, "coverage");
    const none = try b.caseOf(coverage, "none");
    const some = try b.caseOf(coverage, "some");
    const exact = try some.body().equal(through, try some.body().field(some.payload(), "sequence"));
    const available = try b.match(coverage, .{
        .none = try none.ret(try none.body().constant(bool, false)),
        .some = try some.ret(exact),
    });
    return all(b, &.{ current, growing, acquired, available });
}

fn replacement(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    intent: a.Value(t.DigestIntent),
    identity: a.Value(t.Digest),
) !a.Value(chain.Applied) {
    const delivery = try b.field(intent, "delivery");
    const old_key = try b.field(delivery, "key");
    const old_payload = try b.field(delivery, "payload");
    const key = try b.update(
        old_key,
        .{ .identity = identity, .generation = try b.constant(u32, 0) },
    );
    const payload = try b.update(old_payload, .{
        .issue = try b.constant(u32, 1),
        .supersedes = try b.variant(try c.schema(?t.DeliveryKey), "some", old_key),
        .frozen_text = try replacementText(c, b, h.fits, old_payload),
    });
    const issued = try b.update(intent, .{
        .delivery = try b.update(delivery, .{ .key = key, .payload = payload }),
        .hold = try c.literal(t.DeliveryHold, .none),
    });
    return accept(c, b, try b.update(head, .{
        .digest = try b.variant(try c.schema(?t.DigestIntent), "some", issued),
    }));
}

fn replacementText(
    c: protean.Context,
    b: anytype,
    fits: Fits,
    payload: a.Value(t.LogicalPayload),
) !a.Value(t.Text) {
    const old = try b.field(payload, "frozen_text");
    const retained = try b.branch();
    const abbreviated = try b.branch();
    const warning = try c.literal(t.Text, .{
        .bytes = "The earlier digest may also have arrived. " ++
            "This is the authorized replacement issue.\n\n",
    });
    const complete = try join(c, retained, warning, old);
    const lower = try abbreviated.textInteger(try abbreviated.field(payload, "prior_sequence"));
    const upper = try abbreviated.textInteger(try abbreviated.field(payload, "through_sequence"));
    var summary = try join(c, abbreviated, warning, try c.literal(t.Text, .{
        .bytes = "Abbreviated digest: observation records after ",
    }));
    summary = try join(c, abbreviated, summary, lower);
    summary = try join(c, abbreviated, summary, try c.literal(t.Text, .{ .bytes = " through " }));
    summary = try join(c, abbreviated, summary, upper);
    summary = try join(c, abbreviated, summary, try c.literal(t.Text, .{
        .bytes = ". Full entries and evidence remain in local history.",
    }));
    const keep = try b.call(fits, .{
        .text = old,
        .index = try b.constant(u64, 0),
        .used = try b.constant(u64, 0),
    });
    return b.conditional(keep, try retained.ret(complete), try abbreviated.ret(summary));
}

fn requestAudit(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    head: a.Value(t.Head),
    key: a.Value(t.DeliveryKey),
) !a.Value(chain.Applied) {
    const valid = try digestEqual(b, h, try b.field(key, "lineage"), try b.field(head, "lineage"));
    const request = try b.variant(try c.schema(t.AuditRequest), "delivery", key);
    const accepted = try b.update(try accept(c, b, head), .{
        .audit_request = try b.variant(try c.schema(?t.AuditRequest), "some", request),
    });
    return b.select(valid, accepted, try refuse(c, b, head, "audit_lineage_mismatch"));
}

fn withNotice(
    c: protean.Context,
    b: anytype,
    directive: a.Value(t.Directive),
    applied: a.Value(chain.Applied),
) !a.Value(chain.Applied) {
    const origin = try b.field(try b.field(directive, "envelope"), "origin");
    const local = try b.caseOf(origin, "local");
    const slack = try b.caseOf(origin, "slack");
    const derived = try b.caseOf(origin, "derived");
    const notice = try controlNotice(c, slack.body(), directive, applied);
    const added = try slack.body().update(applied, .{
        .notice = try slack.body().variant(try c.schema(?t.DeliveryIntent), "some", notice),
    });
    return b.match(origin, .{
        .local = try local.ret(applied),
        .slack = try slack.ret(added),
        .derived = try derived.ret(applied),
    });
}

fn controlNotice(
    c: protean.Context,
    b: anytype,
    directive: a.Value(t.Directive),
    applied: a.Value(chain.Applied),
) !a.Value(t.DeliveryIntent) {
    const head = try b.field(applied, "head");
    const specification = try b.field(head, "specification");
    const key = try b.product(try c.schema(t.DeliveryKey), .{
        .lineage = try b.field(head, "lineage"),
        .purpose = try c.literal(@FieldType(t.DeliveryKey, "purpose"), .control),
        .identity = try b.field(try b.field(directive, "envelope"), "stable_request"),
        .generation = try b.constant(u32, 0),
    });
    const payload = try b.product(try c.schema(t.LogicalPayload), .{
        .schema_version = try b.constant(u32, 1),
        .obligation = try b.variant(
            try c.schema(?t.Id),
            "some",
            try b.field(directive, "obligation"),
        ),
        .specification_revision = try b.field(specification, "revision"),
        .prior_sequence = try b.field(try b.field(head, "told"), "sequence"),
        .through_sequence = try b.field(try b.field(head, "told"), "sequence"),
        .frozen_text = try noticeText(c, b, directive, try b.field(applied, "outcome")),
        .prompt = try c.literal(?t.Digest, null),
        .supersedes = try c.literal(?t.DeliveryKey, null),
        .coverage = try c.literal(?t.Frontier, null),
        .issue = try b.constant(u32, 0),
        .buttons = try c.literal(@FieldType(t.LogicalPayload, "buttons"), .{ .items = &.{} }),
        .comparison = try c.literal(@FieldType(t.LogicalPayload, "comparison"), null),
    });
    return b.product(try c.schema(t.DeliveryIntent), .{
        .destination = try b.field(specification, "destination"),
        .key = key,
        .payload = payload,
    });
}

fn noticeText(
    c: protean.Context,
    b: anytype,
    directive: a.Value(t.Directive),
    outcome: a.Value(chain.Outcome),
) !a.Value(t.Text) {
    const body = try b.field(directive, "body");
    var name = try c.literal(t.Text, .{ .bytes = "directive" });
    inline for (comptime std.meta.fieldNames(t.DirectiveBody)) |field| {
        name = try b.select(
            try bodyIs(b, body, field),
            try c.literal(t.Text, .{ .bytes = field }),
            name,
        );
    }
    const applied = try b.caseOf(outcome, "applied");
    const rejected = try b.caseOf(outcome, "rejected");
    const success = try join(
        c,
        applied.body(),
        name,
        try c.literal(t.Text, .{ .bytes = " applied." }),
    );
    const prefix = try join(
        c,
        rejected.body(),
        name,
        try c.literal(t.Text, .{ .bytes = " rejected: " }),
    );
    const failure = try join(c, rejected.body(), prefix, rejected.payload());
    return b.match(
        outcome,
        .{ .applied = try applied.ret(success), .rejected = try rejected.ret(failure) },
    );
}

fn choicesFunction(c: protean.Context) !Choices {
    const function = try c.author.function("match offered question answer", .{
        .choices = try c.schema(cts.Vector(t.Name, 8)),
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
        try textEqual(more, option, choice),
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

fn fitsFunction(c: protean.Context) !Fits {
    const function = try c.author.function("bound escaped replacement text", .{
        .text = try c.schema(t.Text),
        .index = try c.schema(u64),
        .used = try c.schema(u64),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const text = try b.parameter("text");
    const index = try b.parameter("index");
    const used = try b.parameter("used");
    const more = try b.branch();
    const done = try b.branch();
    const byte = try more.variantPayload(
        try more.blobByte(text, index),
        "some",
        try a.failure(c, "replacement_text_bounds"),
    );
    const ampersand = try more.equal(byte, try more.constant(u8, '&'));
    const angle = try more.select(
        try more.equal(byte, try more.constant(u8, '<')),
        try more.constant(bool, true),
        try more.equal(byte, try more.constant(u8, '>')),
    );
    const width = try more.select(
        ampersand,
        try more.constant(u64, 5),
        try more.select(angle, try more.constant(u64, 4), try more.constant(u64, 1)),
    );
    const continued = try more.call(function, .{
        .text = text,
        .index = try more.checked(.add, index, try more.constant(u64, 1), .{
            .overflow = try a.failure(c, "replacement_text_overflow"),
        }),
        .used = try more.checked(.add, used, width, .{
            .overflow = try a.failure(c, "replacement_text_overflow"),
        }),
    });
    const ended = try b.select(
        try b.less(try b.constant(u64, 3800), used),
        try b.constant(bool, false),
        try b.constant(bool, true),
    );
    const active = try all(b, &.{ try b.less(index, try b.blobLength(text)), ended });
    const value = try b.conditional(active, try more.ret(continued), try done.ret(ended));
    try c.author.define(function, try b.ret(value));
    return function;
}

fn bodyIs(b: anytype, body: a.Value(t.DirectiveBody), comptime tag: []const u8) !a.Value(bool) {
    return b.equal(
        try b.variantTag(body),
        try b.constant(u64, std.meta.fieldIndex(t.DirectiveBody, tag).?),
    );
}

fn digestEqual(
    b: anytype,
    h: Helpers,
    left: a.Value(t.Digest),
    right: a.Value(t.Digest),
) !a.Value(bool) {
    return b.call(h.digests, .{ .left = left, .right = right });
}

fn keyEqual(
    b: anytype,
    h: Helpers,
    left: a.Value(t.DeliveryKey),
    right: a.Value(t.DeliveryKey),
) !a.Value(bool) {
    return all(b, &.{
        try digestEqual(b, h, try b.field(left, "lineage"), try b.field(right, "lineage")),
        try digestEqual(b, h, try b.field(left, "identity"), try b.field(right, "identity")),
        try b.equal(
            try b.enumTag(try b.field(left, "purpose")),
            try b.enumTag(try b.field(right, "purpose")),
        ),
        try b.equal(try b.field(left, "generation"), try b.field(right, "generation")),
    });
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

fn isNone(c: protean.Context, b: anytype, comptime T: type, value: a.Value(T)) !a.Value(bool) {
    const expected = if (T == t.PublicationReference)
        try c.literal(T, .{ .current = {} })
    else
        try c.literal(T, null);
    return b.equal(try b.variantTag(value), try b.variantTag(expected));
}

fn join(c: protean.Context, b: anytype, left: anytype, right: anytype) !a.Value(t.Text) {
    return b.blobConcat(
        try c.schema(t.Text),
        left,
        right,
        try a.failure(c, "directive_text_capacity"),
    );
}
