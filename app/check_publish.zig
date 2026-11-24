const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const check = @import("check.zig");
const clock = @import("temporal.zig");
const equal_bytes = @import("bytes.zig");
const recovery = @import("phase_recovery.zig");
const notification = @import("notification.zig");

pub const Input = struct {
    head: t.Head,
    obligation: t.Id,
    identity: t.Digest,
    acquired: check.Result,
};
pub const Result = struct { head: t.Head, batch: ?t.Batch };
pub const Function = a.Function(struct { input: Input }, Result);
const Evidence = @FieldType(check.Result, "evidence");
const ObservationTime = struct { acquired_ms: i64, provider_date: ?t.Timestamp };
const Time = a.Function(struct { evidence: Evidence, clock_ms: i64 }, ObservationTime);

pub fn emit(c: protean.Context) !Function {
    const next = try clock.emit(c);
    const time = try observationTime(c);
    const equal = try equal_bytes.emit(c, 40);
    const function = try c.author.function("publish complete source observation", .{
        .input = try c.schema(Input),
    }, try c.schema(Result), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const previous = try b.field(input, "head");
    const acquired = try b.field(input, "acquired");
    const specification = try b.field(previous, "specification");
    const due = try b.call(next, .{ .input = try b.product(try c.schema(clock.Input), .{
        .anchor_ms = try b.field(specification, "anchor_ms"),
        .interval_ms = try b.field(specification, "interval_ms"),
        .clock_ms = try b.field(previous, "clock_ms"),
    }) });
    const observed_time = try b.call(time, .{
        .evidence = try b.field(acquired, "evidence"),
        .clock_ms = try b.field(previous, "clock_ms"),
    });
    const head = try b.update(previous, .{
        .next_due_ms = due,
        .phase = try c.literal(t.Phase, .check),
        .previous_check_overran = try b.less(due, try b.field(observed_time, "acquired_ms")),
    });
    const accepted = try b.branch();
    const rejected = try b.branch();
    const failed = try b.equal(
        try b.enumTag(try b.field(acquired, "kind")),
        try b.enumTag(try c.literal(@FieldType(check.Result, "kind"), .rejected)),
    );
    const result = try b.conditional(
        failed,
        try rejected.ret(try rejectedCheck(c, rejected, input, head, observed_time)),
        try accepted.ret(try acceptedCheck(c, accepted, input, head, observed_time, equal)),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}

fn observationTime(c: protean.Context) !Time {
    const function = try c.author.function("source observation time with provenance", .{
        .evidence = try c.schema(Evidence),
        .clock_ms = try c.schema(i64),
    }, try c.schema(ObservationTime), &.{});
    const b = try c.author.body(function);
    const evidence = try b.parameter("evidence");
    const count = try b.sequenceLength(evidence);
    const some = try b.branch();
    const none = try b.branch();
    const position = try some.checked(.subtract, count, try some.constant(u64, 1), .{
        .overflow = try a.failure(c, "source_time_bounds"),
    });
    const last = try some.variantPayload(
        try some.sequenceGet(evidence, position),
        "some",
        try a.failure(c, "source_time_bounds"),
    );
    const retained = try some.product(try c.schema(ObservationTime), .{
        .acquired_ms = try some.field(last, "captured_ms"),
        .provider_date = try some.field(last, "provider_date"),
    });
    const local = try none.product(try c.schema(ObservationTime), .{
        .acquired_ms = try b.parameter("clock_ms"),
        .provider_date = try c.literal(?t.Timestamp, null),
    });
    try c.author.define(
        function,
        try b.ret(try b.conditional(
            try b.less(try b.constant(u64, 0), count),
            try some.ret(retained),
            try none.ret(local),
        )),
    );
    return function;
}

fn acceptedCheck(
    c: protean.Context,
    b: anytype,
    input: a.Value(Input),
    head: a.Value(t.Head),
    time: a.Value(ObservationTime),
    equal: anytype,
) !a.Value(Result) {
    const acquired = try b.field(input, "acquired");
    const tip = try b.variantPayload(
        try b.field(acquired, "tip"),
        "some",
        try a.failure(c, "missing_observed_tip"),
    );
    const observed = try b.field(head, "observed");
    const initial = try b.equal(
        try b.enumTag(try b.field(acquired, "kind")),
        try b.enumTag(try c.literal(@FieldType(check.Result, "kind"), .baseline)),
    );
    const baseline = try b.branch();
    const subsequent = try b.branch();
    try a.require(c, baseline, try baseline.equal(
        try baseline.variantTag(try baseline.field(observed, "tip")),
        try baseline.variantTag(try c.literal(?t.Oid, null)),
    ), "baseline_already_established");
    const first = try baseline.update(
        observed,
        .{ .tip = try baseline.variant(try c.schema(?t.Oid), "some", tip) },
    );
    const first_head = try baseline.update(head, .{
        .observed = first,
        .told = try baseline.select(
            try baseline.equal(
                try baseline.field(try baseline.field(head, "told"), "sequence"),
                try baseline.constant(u64, 0),
            ),
            first,
            try baseline.field(head, "told"),
        ),
        .question = try c.literal(?t.Question, null),
        .check_failure_streak = try baseline.constant(u32, 0),
        .last_observation = try baseline.variant(
            try c.schema(?t.Observation),
            "some",
            try observation(
                c,
                baseline,
                first,
                tip,
                .baseline,
                time,
                try baseline.constant(u64, 0),
                false,
            ),
        ),
    });
    const later = try continued(c, subsequent, input, head, tip, time, equal);
    return b.conditional(initial, try baseline.ret(try baseline.product(try c.schema(Result), .{
        .head = first_head,
        .batch = try c.literal(?t.Batch, null),
    })), try subsequent.ret(later));
}

fn continued(
    c: protean.Context,
    b: anytype,
    input: a.Value(Input),
    head: a.Value(t.Head),
    tip: a.Value(t.Oid),
    time: a.Value(ObservationTime),
    equal: anytype,
) !a.Value(Result) {
    const acquired = try b.field(input, "acquired");
    const observed = try b.field(head, "observed");
    const base = try b.variantPayload(
        try b.field(observed, "tip"),
        "some",
        try a.failure(c, "missing_source_baseline"),
    );
    const declared_base = try b.variantPayload(
        try b.field(acquired, "base"),
        "some",
        try a.failure(c, "missing_comparison_base"),
    );
    try a.require(
        c,
        b,
        try b.call(
            equal,
            .{ .left = base, .right = declared_base, .index = try b.constant(u64, 0) },
        ),
        "comparison_base_mismatch",
    );
    const complete = try b.equal(
        try b.enumTag(try b.field(acquired, "kind")),
        try b.enumTag(try c.literal(@FieldType(check.Result, "kind"), .complete)),
    );
    const count = try b.sequenceLength(try b.field(acquired, "commits"));
    const changed = try b.branch();
    const same = try b.branch();
    return b.conditional(
        complete,
        try changed.ret(try completeCheck(c, changed, head, acquired, base, tip, time, count)),
        try same.ret(try unchangedCheck(c, same, head, base, tip, time, count, equal)),
    );
}

fn completeCheck(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    acquired: a.Value(check.Result),
    base: a.Value(t.Oid),
    tip: a.Value(t.Oid),
    time: a.Value(ObservationTime),
    count: a.Value(u64),
) !a.Value(Result) {
    const observed = try b.field(head, "observed");
    const sequence = try b.checked(
        .add,
        try b.field(observed, "sequence"),
        try b.constant(u64, 1),
        .{ .overflow = try a.failure(c, "observation_overflow") },
    );
    const frontier = try b.update(observed, .{
        .sequence = sequence,
        .tip = try b.variant(try c.schema(?t.Oid), "some", tip),
    });
    try a.require(
        c,
        b,
        try b.less(try b.constant(u64, 0), count),
        "empty_changed_comparison",
    );
    const batch = try b.product(try c.schema(t.Batch), .{
        .repository = try b.field(try b.field(head, "specification"), "repository"),
        .sequence = sequence,
        .epoch = try b.field(frontier, "epoch"),
        .base = base,
        .tip = tip,
        .coverage = try c.literal(t.Coverage, .complete),
        .commits = try b.field(acquired, "commits"),
        .raw_evidence = try b.field(acquired, "evidence"),
        .acquired_ms = try b.field(time, "acquired_ms"),
        .provider_date = try b.field(time, "provider_date"),
    });
    const next = try b.update(head, .{
        .observed = frontier,
        .question = try c.literal(?t.Question, null),
        .check_failure_streak = try b.constant(u32, 0),
        .last_observation = try b.variant(
            try c.schema(?t.Observation),
            "some",
            try observation(c, b, frontier, tip, .complete, time, count, true),
        ),
    });
    return b.product(try c.schema(Result), .{
        .head = next,
        .batch = try b.variant(try c.schema(?t.Batch), "some", batch),
    });
}

fn unchangedCheck(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    base: a.Value(t.Oid),
    tip: a.Value(t.Oid),
    time: a.Value(ObservationTime),
    count: a.Value(u64),
    equal: anytype,
) !a.Value(Result) {
    const observed = try b.field(head, "observed");
    try a.require(
        c,
        b,
        try b.call(equal, .{ .left = base, .right = tip, .index = try b.constant(u64, 0) }),
        "unchanged_tip_mismatch",
    );
    try a.require(
        c,
        b,
        try b.equal(count, try b.constant(u64, 0)),
        "unchanged_commits_present",
    );
    const unchanged = try b.update(head, .{
        .question = try c.literal(
            ?t.Question,
            null,
        ),
        .check_failure_streak = try b.constant(u32, 0),
        .last_observation = try b.variant(
            try c.schema(?t.Observation),
            "some",
            try observation(c, b, observed, tip, .complete, time, count, false),
        ),
    });
    return b.product(try c.schema(Result), .{
        .head = unchanged,
        .batch = try c.literal(?t.Batch, null),
    });
}

fn observation(
    c: protean.Context,
    b: anytype,
    frontier: a.Value(t.Frontier),
    tip: a.Value(t.Oid),
    coverage: t.Coverage,
    time: a.Value(ObservationTime),
    count: a.Value(u64),
    batch: bool,
) !a.Value(t.Observation) {
    return b.product(try c.schema(t.Observation), .{
        .sequence = try b.field(frontier, "sequence"),
        .epoch = try b.field(frontier, "epoch"),
        .tip = tip,
        .batch = try c.literal(?t.PublicationReference, if (batch) .{ .current = {} } else null),
        .coverage = try c.literal(t.Coverage, coverage),
        .acquired_ms = try b.field(time, "acquired_ms"),
        .provider_date = try b.field(time, "provider_date"),
        .commit_count = count,
    });
}

fn rejectedCheck(
    c: protean.Context,
    b: anytype,
    input: a.Value(Input),
    head: a.Value(t.Head),
    time: a.Value(ObservationTime),
) !a.Value(Result) {
    _ = time;
    const acquired = try b.field(input, "acquired");
    const questioned = try notification.raised(
        c,
        b,
        try b.field(head, "question"),
        try b.update(head, .{ .question = try sourceQuestion(c, b, input, head) }),
    );
    const next = try b.call(try recovery.rejection(c), .{
        .input = try b.product(try c.schema(recovery.RejectionInput), .{
            .head = questioned,
            .reason = try b.field(acquired, "reason"),
            .evidence = try b.field(acquired, "evidence"),
        }),
    });
    return b.product(
        try c.schema(Result),
        .{ .head = next, .batch = try c.literal(?t.Batch, null) },
    );
}

fn sourceQuestion(
    c: protean.Context,
    b: anytype,
    input: a.Value(Input),
    head: a.Value(t.Head),
) !a.Value(?t.Question) {
    const acquired = try b.field(input, "acquired");
    const reason = try b.field(acquired, "reason");
    const none = try b.caseOf(reason, "none");
    const some = try b.caseOf(reason, "some");
    const sb = some.body();
    const tag = try sb.enumTag(some.payload());
    const Failure = @import("github_contract.zig").Failure;
    const behind = try sb.equal(tag, try sb.enumTag(try c.literal(Failure, .behind)));
    const diverged = try sb.equal(tag, try sb.enumTag(try c.literal(Failure, .diverged)));
    const incomplete = try sb.equal(tag, try sb.enumTag(try c.literal(Failure, .incomplete)));
    const special = try sb.select(
        behind,
        try sb.constant(bool, true),
        try sb.select(diverged, try sb.constant(bool, true), incomplete),
    );
    const yes = try sb.branch();
    const no = try sb.branch();
    const result = try sb.conditional(
        special,
        try yes.ret(try newQuestion(c, yes, input, head, behind, diverged)),
        try no.ret(try no.field(head, "question")),
    );
    return b.match(
        reason,
        .{ .none = try none.ret(try b.field(head, "question")), .some = try some.ret(result) },
    );
}

fn newQuestion(
    c: protean.Context,
    b: anytype,
    input: a.Value(Input),
    head: a.Value(t.Head),
    behind: a.Value(bool),
    diverged: a.Value(bool),
) !a.Value(?t.Question) {
    const acquired = try b.field(input, "acquired");
    const tip = try b.field(acquired, "tip");
    const absent = try b.caseOf(tip, "none");
    const present = try b.caseOf(tip, "some");
    const pb = present.body();
    const base = try pb.variantPayload(
        try pb.field(acquired, "base"),
        "some",
        try a.failure(c, "condition_baseline_missing"),
    );
    const specification = try pb.field(head, "specification");
    const condition_type = @typeInfo(@FieldType(t.Question, "source_condition")).optional.child;
    const condition = try pb.product(try c.schema(condition_type), .{
        .epoch = try pb.field(try pb.field(head, "observed"), "epoch"),
        .base = base,
        .tip = present.payload(),
        .coverage = try pb.select(behind, try c.literal(
            @FieldType(condition_type, "coverage"),
            .behind,
        ), try pb.select(diverged, try c.literal(
            @FieldType(condition_type, "coverage"),
            .diverged,
        ), try c.literal(@FieldType(condition_type, "coverage"), .incomplete))),
    });
    const identity = try pb.field(input, "identity");
    const question = try pb.product(try c.schema(t.Question), .{
        .identity = identity,
        .condition = identity,
        .specification_revision = try pb.field(specification, "revision"),
        .source_condition = try pb.variant(try c.schema(?condition_type), "some", condition),
        .choices = try c.literal(@FieldType(t.Question, "choices"), .{ .items = &.{.{
            .value = .{ .bytes = "accept_gap" },
            .label = .{ .bytes = "Accept explicit gap" },
        }} }),
        .prompt = try c.literal(t.Text, .{ .bytes = "The branch comparison is " ++
            "incomplete or rewritten. Accepting this gap establishes " ++
            "a new baseline at the comparison tip without claiming that all commits were read. " ++
            "Older outstanding observations remain owed." }),
    });
    return b.match(
        tip,
        .{
            .none = try absent.ret(try absent.body().field(head, "question")),
            .some = try present.ret(try preserveQuestion(c, pb, head, question)),
        },
    );
}

fn preserveQuestion(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    replacement: a.Value(t.Question),
) !a.Value(?t.Question) {
    const old = try b.field(head, "question");
    const none = try b.caseOf(old, "none");
    const some = try b.caseOf(old, "some");
    const sb = some.body();
    const condition = try sb.field(some.payload(), "source_condition");
    const absent = try sb.caseOf(condition, "none");
    const present = try sb.caseOf(condition, "some");
    const pb = present.body();
    const next_condition = try pb.variantPayload(
        try pb.field(replacement, "source_condition"),
        "some",
        try a.failure(c, "source_condition_missing"),
    );
    const equal = try equal_bytes.emit(c, 40);
    var matched = try pb.equal(
        try pb.field(some.payload(), "specification_revision"),
        try pb.field(replacement, "specification_revision"),
    );
    matched = try pb.select(
        matched,
        try pb.equal(
            try pb.field(present.payload(), "epoch"),
            try pb.field(next_condition, "epoch"),
        ),
        try pb.constant(bool, false),
    );
    matched = try pb.select(
        matched,
        try pb.equal(
            try pb.enumTag(try pb.field(present.payload(), "coverage")),
            try pb.enumTag(try pb.field(next_condition, "coverage")),
        ),
        try pb.constant(bool, false),
    );
    inline for (.{ "base", "tip" }) |field| matched = try pb.select(
        matched,
        try pb.call(
            equal,
            .{
                .left = try pb.field(present.payload(), field),
                .right = try pb.field(next_condition, field),
                .index = try pb.constant(u64, 0),
            },
        ),
        try pb.constant(bool, false),
    );
    const new_optional = try b.variant(try c.schema(?t.Question), "some", replacement);
    const selected = try sb.match(condition, .{
        .none = try absent.ret(new_optional),
        .some = try present.ret(try pb.select(matched, old, new_optional)),
    });
    return b.match(old, .{ .none = try none.ret(new_optional), .some = try some.ret(selected) });
}
