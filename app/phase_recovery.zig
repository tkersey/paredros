const std = @import("std");
const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const temporal = @import("temporal.zig");
const check = @import("check.zig");
const github = @import("github_contract.zig");

pub const Input = struct { head: t.Head, supersession: ?t.Supersession };
pub const Function = a.Function(struct { input: Input }, t.Head);
pub const FailureInput = struct {
    head: t.Head,
    phase: t.Phase,
    defer_to_slot: bool,
    provider_not_before_ms: i64,
};
pub const Failure = a.Function(struct { input: FailureInput }, t.Head);
pub const RejectionInput = struct {
    head: t.Head,
    reason: ?github.Failure,
    evidence: check.Evidence,
};
pub const Rejection = a.Function(struct { input: RejectionInput }, t.Head);
const Delay = a.Function(struct { remaining: u32, delay_ms: i64 }, i64);
const Seconds = a.Function(struct { text: t.Name, index: u64, value: i64 }, ?i64);
const conservative_retry_ms: i64 = 60 * 60 * 1000;
const retry_seconds_ceiling: i64 = 1_000_000_000_000;
const ProviderInput = struct {
    evidence: check.Evidence,
    clock_ms: i64,
    deadline_ms: i64,
    index: u64,
    rate_limited: bool,
};
const Provider = a.Function(struct { input: ProviderInput }, i64);

pub fn emit(c: protean.Context) !Function {
    const failed = try failure(c);
    const function = try c.author.function("fold unusable phase recovery", .{
        .input = try c.schema(Input),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const replacement = try b.field(input, "supersession");
    const none = try b.caseOf(replacement, "none");
    const some = try b.caseOf(replacement, "some");
    const sb = some.body();
    const control = try sb.branch();
    const fault = try sb.branch();
    const cause = try sb.enumTag(try sb.field(some.payload(), "cause"));
    const recovered = try fault.call(failed, .{ .input = try fault.product(
        try c.schema(FailureInput),
        .{
            .head = head,
            .phase = try fault.field(some.payload(), "phase"),
            .defer_to_slot = try fault.constant(bool, false),
            .provider_not_before_ms = try fault.constant(i64, std.math.minInt(i64)),
        },
    ) });
    const selected = try sb.conditional(
        try sb.equal(
            cause,
            try sb.enumTag(try c.literal(@FieldType(t.Supersession, "cause"), .control)),
        ),
        try control.ret(head),
        try fault.ret(recovered),
    );
    try c.author.define(function, try b.ret(try b.match(replacement, .{
        .none = try none.ret(head),
        .some = try some.ret(selected),
    })));
    return function;
}

pub fn failure(c: protean.Context) !Failure {
    const next_slot = try temporal.emit(c);
    const delay = try delayFunction(c);
    const function = try c.author.function("bounded attributed phase retry", .{
        .input = try c.schema(FailureInput),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const phase = try b.enumTag(try b.field(input, "phase"));
    const checking = try b.branch();
    const remaining = try b.branch();
    const rendering = try remaining.branch();
    const unattributed = try remaining.branch();
    const other = try remaining.conditional(
        try remaining.equal(phase, try remaining.enumTag(try c.literal(t.Phase, .render))),
        try rendering.ret(try attributed(c, rendering, input, next_slot, delay, .render)),
        try unattributed.ret(try deferFold(c, unattributed, head, next_slot)),
    );
    try c.author.define(function, try b.ret(try b.conditional(
        try b.equal(phase, try b.enumTag(try c.literal(t.Phase, .check))),
        try checking.ret(try attributed(c, checking, input, next_slot, delay, .check)),
        try remaining.ret(other),
    )));
    return function;
}

fn slot(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    next: temporal.Function,
) !a.Value(i64) {
    const specification = try b.field(head, "specification");
    return b.call(next, .{ .input = try b.product(try c.schema(temporal.Input), .{
        .anchor_ms = try b.field(specification, "anchor_ms"),
        .interval_ms = try b.field(specification, "interval_ms"),
        .clock_ms = try b.field(head, "clock_ms"),
    }) });
}

fn maximum(b: anytype, left: a.Value(i64), right: a.Value(i64)) !a.Value(i64) {
    return b.select(try b.less(left, right), right, left);
}

fn deferFold(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    next: temporal.Function,
) !a.Value(t.Head) {
    const deadline = try slot(c, b, head, next);
    return b.update(head, .{
        .next_due_ms = try maximum(b, try b.field(head, "next_due_ms"), deadline),
        .source_not_before_ms = try maximum(b, try b.field(head, "source_not_before_ms"), deadline),
        .render_not_before_ms = try maximum(b, try b.field(head, "render_not_before_ms"), deadline),
    });
}

fn attributed(
    c: protean.Context,
    b: anytype,
    input: a.Value(FailureInput),
    next: temporal.Function,
    delay: Delay,
    comptime phase: t.Phase,
) !a.Value(t.Head) {
    const count_field = if (phase == .check) "check_failure_streak" else "render_failure_streak";
    const deadline_field = if (phase == .check) "source_not_before_ms" else "render_not_before_ms";
    const head = try b.field(input, "head");
    const now = try b.field(head, "clock_ms");
    const old = try b.field(head, count_field);
    const previous = try b.field(head, deadline_field);
    const policies = try b.field(try b.field(head, "specification"), "policies");
    const bound = try b.field(policies, "phase_attempts");
    const count = try nextCount(c, b, old, bound, now, previous);
    const scheduled = try b.branch();
    const retrying = try b.branch();
    const exceeded = try b.booleanNot(try b.less(count, bound));
    const defer_slot = try b.select(
        try b.field(input, "defer_to_slot"),
        try b.constant(bool, true),
        exceeded,
    );
    const immediate = try retryInstant(c, retrying, now, count, delay);
    const instant = try b.conditional(
        defer_slot,
        try scheduled.ret(try slot(c, scheduled, head, next)),
        try retrying.ret(immediate),
    );
    const constrained = try maximum(b, previous, try b.field(input, "provider_not_before_ms"));
    const deadline = try maximum(b, instant, constrained);
    const changed = if (phase == .check)
        try b.update(
            head,
            .{
                .check_failure_streak = count,
                .source_not_before_ms = deadline,
                .next_due_ms = deadline,
            },
        )
    else
        try b.update(head, .{ .render_failure_streak = count, .render_not_before_ms = deadline });
    return changed;
}

fn nextCount(
    c: protean.Context,
    b: anytype,
    old: a.Value(u32),
    bound: a.Value(u32),
    now: a.Value(i64),
    previous: a.Value(i64),
) !a.Value(u32) {
    const exhausted = try b.booleanNot(try b.less(old, bound));
    const elapsed = try b.booleanNot(try b.less(now, previous));
    const fresh = try b.branch();
    const continued = try b.branch();
    return b.conditional(
        try b.select(exhausted, elapsed, try b.constant(bool, false)),
        try fresh.ret(try fresh.constant(u32, 1)),
        try continued.ret(try continued.checked(
            .add,
            old,
            try continued.constant(u32, 1),
            .{ .overflow = try a.failure(c, "phase_failure_overflow") },
        )),
    );
}

fn retryInstant(
    c: protean.Context,
    b: anytype,
    now: a.Value(i64),
    count: a.Value(u32),
    delay: Delay,
) !a.Value(i64) {
    try a.require(c, b, try b.less(count, try b.constant(u32, 49)), "phase_backoff_overflow");
    const overflow = try a.failure(c, "phase_backoff_overflow");
    const duration = try b.call(delay, .{
        .remaining = try b.checked(
            .subtract,
            count,
            try b.constant(u32, 1),
            .{ .overflow = overflow },
        ),
        .delay_ms = try b.constant(i64, 60_000),
    });
    return b.checked(.add, now, duration, .{ .overflow = overflow });
}

fn delayFunction(c: protean.Context) !Delay {
    const function = try c.author.function("checked exponential phase delay", .{
        .remaining = try c.schema(u32),
        .delay_ms = try c.schema(i64),
    }, try c.schema(i64), &.{});
    const b = try c.author.body(function);
    const remaining = try b.parameter("remaining");
    const duration = try b.parameter("delay_ms");
    const more = try b.branch();
    const done = try b.branch();
    const overflow = try a.failure(c, "phase_backoff_overflow");
    const result = try more.call(function, .{
        .remaining = try more.checked(
            .subtract,
            remaining,
            try more.constant(u32, 1),
            .{ .overflow = overflow },
        ),
        .delay_ms = try more.checked(
            .multiply,
            duration,
            try more.constant(i64, 2),
            .{ .overflow = overflow },
        ),
    });
    try c.author.define(function, try b.ret(try b.conditional(try b.less(
        try b.constant(u32, 0),
        remaining,
    ), try more.ret(result), try done.ret(duration))));
    return function;
}

pub fn rejection(c: protean.Context) !Rejection {
    const failed = try failure(c);
    const provider = try providerFunction(c, try secondsFunction(c));
    const function = try c.author.function("pace rejected source check", .{
        .input = try c.schema(RejectionInput),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const reason = try b.variantPayload(
        try b.field(input, "reason"),
        "some",
        try a.failure(c, "missing_source_failure"),
    );
    var defer_slot = try b.constant(bool, false);
    inline for (.{
        github.Failure.permission,
        .binding,
        .unsupported_object,
        .incomplete,
        .behind,
        .diverged,
        .unretained,
    }) |kind|
        defer_slot = try b.select(
            try b.equal(try b.enumTag(reason), try b.enumTag(try c.literal(github.Failure, kind))),
            try b.constant(bool, true),
            defer_slot,
        );
    const deadline = try b.call(provider, .{ .input = try b.product(try c.schema(ProviderInput), .{
        .evidence = try b.field(input, "evidence"),
        .clock_ms = try b.field(head, "clock_ms"),
        .deadline_ms = try b.field(head, "source_not_before_ms"),
        .index = try b.constant(u64, 0),
        .rate_limited = try b.equal(
            try b.enumTag(reason),
            try b.enumTag(try c.literal(github.Failure, .rate_limit)),
        ),
    }) });
    const result = try b.call(failed, .{ .input = try b.product(try c.schema(FailureInput), .{
        .head = head,
        .phase = try c.literal(t.Phase, .check),
        .defer_to_slot = defer_slot,
        .provider_not_before_ms = deadline,
    }) });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn providerFunction(c: protean.Context, seconds: Seconds) !Provider {
    const function = try c.author.function("fold provider retry deadlines", .{
        .input = try c.schema(ProviderInput),
    }, try c.schema(i64), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const index = try b.field(input, "index");
    const evidence = try b.field(input, "evidence");
    const active = try b.branch();
    const done = try b.branch();
    const entry = try active.variantPayload(
        try active.sequenceGet(evidence, index),
        "some",
        try a.failure(c, "provider_evidence_bounds"),
    );
    const deadline = try providerEntry(c, active, seconds, input, entry);
    const continued = try active.call(function, .{ .input = try active.update(input, .{
        .index = try active.checked(
            .add,
            index,
            try active.constant(u64, 1),
            .{ .overflow = try a.failure(c, "provider_evidence_overflow") },
        ),
        .deadline_ms = deadline,
    }) });
    try c.author.define(
        function,
        try b.ret(try b.conditional(
            try b.less(index, try b.sequenceLength(evidence)),
            try active.ret(continued),
            try done.ret(try done.field(input, "deadline_ms")),
        )),
    );
    return function;
}

fn providerEntry(
    c: protean.Context,
    b: anytype,
    seconds: Seconds,
    input: a.Value(ProviderInput),
    entry: a.Value(t.ReadEvidence),
) !a.Value(i64) {
    const base = try maximum(
        b,
        try b.field(input, "clock_ms"),
        try b.field(entry, "captured_ms"),
    );
    const after = try headerInstant(
        c,
        b,
        seconds,
        try b.field(entry, "retry_after"),
        .{ .base = base, .fallback = base },
    );
    const remaining = try b.field(entry, "rate_remaining");
    const absent = try b.caseOf(remaining, "none");
    const present = try b.caseOf(remaining, "some");
    const exhausted = try b.match(remaining, .{
        .none = try absent.ret(try absent.body().constant(bool, false)),
        .some = try present.ret(try present.body().equal(try present.body().blobCompare(
            present.payload(),
            try c.literal(t.Name, .{ .bytes = "0" }),
        ), try present.body().constant(i8, 0))),
    });
    const limited = try b.branch();
    const ordinary = try b.branch();
    const reset = try b.conditional(try b.select(
        try b.field(input, "rate_limited"),
        try b.constant(bool, true),
        exhausted,
    ), try limited.ret(try headerInstant(c, limited, seconds, try limited.field(
        entry,
        "rate_reset",
    ), .{ .base = try limited.constant(i64, 0), .fallback = base })), try ordinary.ret(
        try ordinary.constant(i64, std.math.minInt(i64)),
    ));
    return maximum(
        b,
        try b.field(input, "deadline_ms"),
        try maximum(b, after, reset),
    );
}

fn headerInstant(
    c: protean.Context,
    b: anytype,
    seconds: Seconds,
    header: a.Value(?t.Name),
    origin: struct { base: a.Value(i64), fallback: a.Value(i64) },
) !a.Value(i64) {
    const none = try b.caseOf(header, "none");
    const some = try b.caseOf(header, "some");
    const sb = some.body();
    const parsed = try sb.call(seconds, .{
        .text = some.payload(),
        .index = try sb.constant(u64, 0),
        .value = try sb.constant(i64, 0),
    });
    const unparsed = try sb.caseOf(parsed, "none");
    const numeric = try sb.caseOf(parsed, "some");
    const nb = numeric.body();
    const milliseconds = try nb.checked(
        .multiply,
        numeric.payload(),
        try nb.constant(i64, 1000),
        .{ .overflow = try a.failure(c, "provider_retry_overflow") },
    );
    const instant = try sb.match(parsed, .{
        .none = try unparsed.ret(try saturated(
            c,
            unparsed.body(),
            origin.fallback,
            try unparsed.body().constant(i64, conservative_retry_ms),
        )),
        .some = try numeric.ret(try saturated(c, nb, origin.base, milliseconds)),
    });
    return b.match(header, .{
        .none = try none.ret(try none.body().constant(i64, std.math.minInt(i64))),
        .some = try some.ret(instant),
    });
}

fn saturated(
    c: protean.Context,
    b: anytype,
    base: a.Value(i64),
    duration: a.Value(i64),
) !a.Value(i64) {
    const overflow = try a.failure(c, "provider_retry_overflow");
    const ceiling = try b.checked(
        .subtract,
        try b.constant(i64, std.math.maxInt(i64)),
        duration,
        .{ .overflow = overflow },
    );
    const sum = try b.branch();
    const saturate = try b.branch();
    return b.conditional(
        try b.less(base, ceiling),
        try sum.ret(try sum.checked(.add, base, duration, .{ .overflow = overflow })),
        try saturate.ret(try saturate.constant(i64, std.math.maxInt(i64))),
    );
}

fn secondsFunction(c: protean.Context) !Seconds {
    const function = try c.author.function("parse provider integer seconds", .{
        .text = try c.schema(t.Name),
        .index = try c.schema(u64),
        .value = try c.schema(i64),
    }, try c.schema(?i64), &.{});
    const b = try c.author.body(function);
    const text = try b.parameter("text");
    const index = try b.parameter("index");
    const value = try b.parameter("value");
    const active = try b.branch();
    const done = try b.branch();
    const overflow = try a.failure(c, "provider_retry_overflow");
    const byte = try active.variantPayload(try active.blobByte(text, index), "some", overflow);
    const zero = try active.constant(u8, '0');
    const digit = try active.select(
        try active.less(byte, zero),
        try active.constant(bool, false),
        try active.less(byte, try active.constant(u8, '9' + 1)),
    );
    const accepted = try active.branch();
    const rejected = try active.branch();
    const scaled = try accepted.checked(.add, try accepted.checked(
        .multiply,
        value,
        try accepted.constant(i64, 10),
        .{ .overflow = overflow },
    ), try accepted.convertInteger(
        try c.schema(i64),
        try accepted.checked(.subtract, byte, zero, .{ .overflow = overflow }),
        .{},
    ), .{ .overflow = overflow });
    const ceiling = try accepted.constant(i64, retry_seconds_ceiling);
    const continued = try accepted.call(function, .{
        .text = text,
        .index = try accepted.checked(
            .add,
            index,
            try accepted.constant(u64, 1),
            .{ .overflow = overflow },
        ),
        .value = try accepted.select(try accepted.less(scaled, ceiling), scaled, ceiling),
    });
    const scanned = try active.conditional(
        digit,
        try accepted.ret(continued),
        try rejected.ret(try c.literal(?i64, null)),
    );
    const complete = try done.select(
        try done.less(try done.constant(u64, 0), index),
        try done.variant(try c.schema(?i64), "some", value),
        try c.literal(?i64, null),
    );
    try c.author.define(function, try b.ret(try b.conditional(try b.less(
        index,
        try b.blobLength(text),
    ), try active.ret(scanned), try done.ret(complete))));
    return function;
}
