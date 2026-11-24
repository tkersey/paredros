const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const bytes = @import("bytes.zig");
const clock = @import("temporal.zig");
const chain = @import("directive_chain.zig");
const settlements = @import("settlement.zig");
const check = @import("check.zig");
const publication = @import("check_publish.zig");
const recovery = @import("phase_recovery.zig");

pub const RenderInput = struct { step: t.Step, head: t.Head };
pub const Render = a.Function(struct { input: RenderInput }, t.Head);
pub const Function = a.Function(struct { input: t.Step }, t.StepResult);
const Folded = struct { controls: chain.Result, head: t.Head };
const Timing = struct { schedule: clock.Schedule, rebase: clock.Rebase };

pub fn emit(
    c: protean.Context,
    apply: chain.Apply,
    read: check.Function,
    render: Render,
    effects: anytype,
) !Function {
    const directives = try chain.emit(c, apply);
    const settlement = try settlements.emit(c);
    const timing: Timing = .{ .schedule = try clock.schedule(c), .rebase = try clock.rebase(c) };
    const publish = try publication.emit(c);
    const recover = try recovery.emit(c);
    const function = try c.author.function("advance one bounded responsibility step", .{
        .input = try c.schema(t.Step),
    }, try c.schema(t.StepResult), effects);
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    try validate(c, b, input);
    const folded = try fold(c, b, directives, settlement, timing, recover, input);
    const head = try b.field(folded, "head");
    const controls = try b.field(folded, "controls");
    const phase = try selectPhase(c, b, input, head, try b.field(controls, "gap"));
    const checking = try b.branch();
    const remaining = try b.branch();
    const check_result = try checkPhase(c, checking, read, publish, input, folded);
    const rendering = try remaining.branch();
    const idle = try remaining.branch();
    const rendered = try rendering.call(
        render,
        .{ .input = try rendering.product(
            try c.schema(RenderInput),
            .{ .step = input, .head = head },
        ) },
    );
    const render_result = try output(c, rendering, try rendering.update(rendered, .{
        .phase = try c.literal(
            t.Phase,
            .render,
        ),
        .previous_check_overran = try rendering.constant(bool, false),
        .render_failure_streak = try rendering.constant(u32, 0),
    }), try c.literal(?t.Batch, null), controls);
    const idle_result = try output(c, idle, head, try idle.field(controls, "gap"), controls);
    const no_check = try remaining.conditional(
        try isPhase(c, remaining, phase, .render),
        try rendering.ret(render_result),
        try idle.ret(idle_result),
    );
    const result = try b.conditional(
        try isPhase(c, b, phase, .check),
        try checking.ret(check_result),
        try remaining.ret(no_check),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}

fn validate(c: protean.Context, b: anytype, input: a.Value(t.Step)) !void {
    const previous = try b.field(input, "previous");
    const sequence = try b.checked(
        .add,
        try b.field(previous, "sequence"),
        try b.constant(u64, 1),
        .{ .overflow = try a.failure(c, "step_sequence_overflow") },
    );
    try a.require(c, b, try b.equal(sequence, try b.field(input, "sequence")), "step_sequence_gap");
    const identity = try b.field(previous, "obligation");
    const self = try b.caseOf(identity, "self");
    const retained = try b.caseOf(identity, "task");
    const ids = try bytes.emit(c, 16);
    const original = try self.body().call(ids, .{
        .left = try self.body().field(try self.body().field(input, "predecessor"), "task"),
        .right = try self.body().field(
            input,
            "obligation",
        ),
        .index = try self.body().constant(u64, 0),
    });
    const bound = try retained.body().call(ids, .{
        .left = retained.payload(),
        .right = try retained.body().field(input, "obligation"),
        .index = try retained.body().constant(u64, 0),
    });
    try a.require(c, b, try b.match(identity, .{
        .self = try self.ret(try self.body().select(original, try self.body().equal(
            try self.body().field(previous, "sequence"),
            try self.body().constant(u64, 0),
        ), try self.body().constant(bool, false))),
        .task = try retained.ret(bound),
    }), "step_obligation_mismatch");
    const replacement = try b.field(input, "supersession");
    const ordinary = try b.equal(
        try b.variantTag(replacement),
        try b.variantTag(try c.literal(?t.Supersession, null)),
    );
    try a.require(
        c,
        b,
        try b.select(ordinary, try b.constant(bool, true), try b.field(input, "fold_only")),
        "replacement_requires_fold",
    );
    const first = try b.caseOf(replacement, "none");
    const next = try b.caseOf(replacement, "some");
    const next_attempt = try next.body().checked(.add, try next.body().field(
        next.payload(),
        "attempt",
    ), try next.body().constant(u32, 1), .{ .overflow = try a.failure(c, "attempt_overflow") });
    const expected = try b.match(replacement, .{
        .none = try first.ret(try first.body().constant(
            u32,
            0,
        )),
        .some = try next.ret(next_attempt),
    });
    try a.require(
        c,
        b,
        try b.equal(expected, try b.field(input, "attempt")),
        "attempt_sequence_gap",
    );
}

fn fold(
    c: protean.Context,
    b: anytype,
    directives: chain.Function,
    settlement: settlements.Function,
    timing: Timing,
    recover: recovery.Function,
    input: a.Value(t.Step),
) !a.Value(Folded) {
    const scheduled = try observeClock(c, b, timing.schedule, input);
    const prepared = try clocked(c, b, timing.rebase, input, scheduled);
    const recovered = try b.call(recover, .{ .input = try b.product(try c.schema(recovery.Input), .{
        .head = prepared,
        .supersession = try b.field(input, "supersession"),
    }) });
    const controls = try b.call(directives, .{ .input = try b.product(try c.schema(chain.Input), .{
        .obligation = try b.field(input, "obligation"),
        .head = recovered,
        .directives = try b.field(input, "directives"),
    }) });
    const settled = try b.call(settlement, .{ .input = try b.product(
        try c.schema(settlements.Input),
        .{ .head = try b.field(controls, "head"), .facts = try b.field(input, "facts") },
    ) });
    return b.product(try c.schema(Folded), .{
        .controls = controls,
        .head = try lineage(c, b, input, settled),
    });
}

fn clocked(
    c: protean.Context,
    b: anytype,
    rebase: clock.Rebase,
    input: a.Value(t.Step),
    scheduled: a.Value(clock.ScheduleResult),
) !a.Value(t.Head) {
    const previous = try b.field(input, "previous");
    const instant = try b.field(input, "clock_ms");
    const regressed = try b.field(scheduled, "regressed");
    const corrected = try b.branch();
    const ordinary = try b.branch();
    const rebased = try corrected.call(rebase, .{ .input = try corrected.product(
        try c.schema(clock.RebaseInput),
        .{
            .schedule = try corrected.field(previous, "schedule"),
            .previous_clock_ms = try corrected.field(previous, "clock_ms"),
            .clock_ms = instant,
        },
    ) });
    const regression = try b.variant(
        try c.schema(?t.ClockRegression),
        "some",
        try b.product(try c.schema(t.ClockRegression), .{
            .previous_clock_ms = try b.field(previous, "clock_ms"),
            .clock_ms = instant,
        }),
    );
    return b.update(previous, .{
        .clock_ms = instant,
        .schedule = try b.conditional(
            regressed,
            try corrected.ret(rebased),
            try ordinary.ret(try ordinary.field(previous, "schedule")),
        ),
        .clock_regressions = try b.checked(
            .add,
            try b.field(previous, "clock_regressions"),
            try b.select(regressed, try b.constant(u64, 1), try b.constant(u64, 0)),
            .{ .overflow = try a.failure(c, "clock_regression_overflow") },
        ),
        .last_clock_regression = try b.select(
            regressed,
            regression,
            try b.field(previous, "last_clock_regression"),
        ),
        .message = try c.literal(?t.Notification, null),
    });
}

fn lineage(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Step),
    settled: a.Value(t.Head),
) !a.Value(t.Head) {
    const supersession = try b.field(input, "supersession");
    const none = try b.caseOf(supersession, "none");
    const some = try b.caseOf(supersession, "some");
    const replaced = try b.match(supersession, .{
        .none = try none.ret(try c.literal(?t.InputReference, null)),
        .some = try some.ret(try some.body().variant(
            try c.schema(?t.InputReference),
            "some",
            try some.body().field(some.payload(), "input"),
        )),
    });
    return b.update(settled, .{
        .obligation = try b.variant(
            try c.schema(t.GenesisIdentity),
            "task",
            try b.field(input, "obligation"),
        ),
        .sequence = try b.field(input, "sequence"),
        .predecessor = try b.variant(
            try c.schema(?t.Reference),
            "some",
            try b.field(input, "predecessor"),
        ),
        .attempt = try b.field(input, "attempt"),
        .superseded = replaced,
    });
}

fn observeClock(
    c: protean.Context,
    b: anytype,
    timing: clock.Schedule,
    input: a.Value(t.Step),
) !a.Value(clock.ScheduleResult) {
    const previous = try b.field(input, "previous");
    const specification = try b.field(previous, "specification");
    const instant = try b.field(input, "clock_ms");
    return b.call(timing, .{ .input = try b.product(try c.schema(clock.ScheduleInput), .{
        .previous_clock_ms = try b.field(previous, "clock_ms"),
        .clock_ms = instant,
        .tolerance_ms = try b.field(
            try b.field(specification, "policies"),
            "clock_regression_tolerance_ms",
        ),
    }) });
}

fn isPhase(
    c: protean.Context,
    b: anytype,
    phase: a.Value(t.Phase),
    expected: t.Phase,
) !a.Value(bool) {
    return b.equal(try b.enumTag(phase), try b.enumTag(try c.literal(t.Phase, expected)));
}

fn selectPhase(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Step),
    head: a.Value(t.Head),
    gap: a.Value(?t.Batch),
) !a.Value(t.Phase) {
    const no = try b.constant(bool, false);
    const now = try b.field(head, "clock_ms");
    const active = try b.equal(
        try b.enumTag(try b.field(head, "mode")),
        try b.enumTag(try c.literal(t.Mode, .active)),
    );
    var enabled = try b.select(active, try b.booleanNot(try b.field(input, "fold_only")), no);
    enabled = try b.select(
        enabled,
        try b.equal(try b.variantTag(gap), try b.variantTag(try c.literal(?t.Batch, null))),
        no,
    );
    const schedule = try b.field(head, "schedule");
    const check_due = try b.booleanNot(try b.less(now, try b.field(schedule, "next_due_ms")));
    const source_ready = try b.booleanNot(try b.less(
        now,
        try b.field(schedule, "source_not_before_ms"),
    ));
    const provider_ready = try b.booleanNot(try b.less(
        now,
        try b.field(schedule, "provider_not_before_ms"),
    ));
    const scheduled = try b.select(check_due, source_ready, no);
    const wanted = try b.select(try b.field(head, "check_requested"), try b.constant(bool, true), scheduled);
    const checking = try b.select(wanted, provider_ready, no);
    const rendering = try b.select(
        try b.less(try b.constant(u64, 0), try b.sequenceLength(try b.field(input, "batches"))),
        try b.booleanNot(try b.less(now, try b.field(schedule, "render_not_before_ms"))),
        no,
    );
    const last_check = try isPhase(c, b, try b.field(head, "phase"), .check);
    const alternate = try b.select(last_check, try b.field(head, "previous_check_overran"), no);
    const check_phase = try b.select(
        try b.select(alternate, rendering, no),
        try c.literal(t.Phase, .render),
        try c.literal(t.Phase, .check),
    );
    const idle_phase = try b.select(
        rendering,
        try c.literal(t.Phase, .render),
        try c.literal(t.Phase, .fold),
    );
    return b.select(
        enabled,
        try b.select(checking, check_phase, idle_phase),
        try c.literal(t.Phase, .fold),
    );
}

fn checkPhase(
    c: protean.Context,
    b: anytype,
    read: check.Function,
    publish: publication.Function,
    input: a.Value(t.Step),
    folded: a.Value(Folded),
) !a.Value(t.StepResult) {
    const head = try b.update(try b.field(folded, "head"), .{
        .check_requested = try b.constant(bool, false),
    });
    const acquired = try b.call(read, .{ .input = try b.product(try c.schema(check.Input), .{
        .repository = try b.field(try b.field(head, "specification"), "repository"),
        .previous = try b.field(try b.field(head, "observed"), "tip"),
    }) });
    const publication_input = try b.product(try c.schema(publication.Input), .{
        .head = head,
        .obligation = try b.field(input, "obligation"),
        .identity = try b.field(
            try b.field(input, "envelope"),
            "stable_request",
        ),
        .acquired = acquired,
    });
    const published = try b.call(publish, .{ .input = publication_input });
    return output(
        c,
        b,
        try b.field(published, "head"),
        try b.field(published, "batch"),
        try b.field(folded, "controls"),
    );
}

fn output(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    batch: a.Value(?t.Batch),
    controls: a.Value(chain.Result),
) !a.Value(t.StepResult) {
    return b.product(try c.schema(t.StepResult), .{
        .head = head,
        .batch = batch,
        .dispositions = try b.field(controls, "dispositions"),
    });
}
