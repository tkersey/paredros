const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const e = @import("experiment_contract.zig");
const method = @import("method.zig");
const mc = @import("method_contract.zig");
const model = @import("model.zig");
const m = @import("model_contract.zig");
const render = @import("render.zig");
const step = @import("step.zig");

pub const Function = a.Function(struct { input: t.Experiment }, t.ExperimentResult);
pub const Ops = struct {
    codec: a.Operation(e.CodecRequest, e.CodecReply),
    clock: a.Operation(e.Stamp, i64),
};
const State = struct {
    identity: e.Identity,
    envelope: t.Envelope,
    plan: e.ComparisonPlan,
    model: t.ModelBinding,
    case_index: u64,
    arm: u64,
    states: e.States,
    runs: e.Runs,
};
const Loop = a.Function(struct { state: State }, t.ExperimentResult);
const Emit = struct {
    context: protean.Context,
    ops: Ops,
    ordinary_scripted: step.Render,
    ordinary_live: step.Render,
    loop: Loop,
};

pub fn declare(c: protean.Context) !Ops {
    return .{
        .codec = try c.external(
            e.codec_identity,
            try c.schema(e.CodecRequest),
            try c.schema(e.CodecReply),
            .read,
        ),
        .clock = try c.external(e.clock_identity, try c.schema(e.Stamp), try c.schema(i64), .read),
    };
}

pub fn emit(
    c: protean.Context,
    ops: Ops,
    method_ops: method.Ops,
    completion: model.Function,
    effects: anytype,
) !Function {
    const scripted = try scriptedCompletion(c, ops.codec);
    const scripted_method = try method.emitBounded(
        c,
        method_ops,
        scripted,
        effects,
        e.advances_per_render,
    );
    const live_method = try method.emitBounded(
        c,
        method_ops,
        completion,
        effects,
        e.advances_per_render,
    );
    const loop = try c.author.function("compare every declared case and candidate", .{
        .state = try c.schema(State),
    }, try c.schema(t.ExperimentResult), effects);
    const construction: Emit = .{
        .context = c,
        .ops = ops,
        .ordinary_scripted = try render.emit(c, scripted, scripted_method, effects),
        .ordinary_live = try render.emit(c, completion, live_method, effects),
        .loop = loop,
    };
    try loopBody(construction);
    const function = try c.author.function("execute a finite declared comparison", .{
        .input = try c.schema(t.Experiment),
    }, try c.schema(t.ExperimentResult), effects);
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const reply = try codec(construction, b, "prepare", input);
    const rejected = try b.branch();
    const admitted = try b.branch();
    const prepared = try payload(c, admitted, reply, "prepared");
    const initial_state = try initial(c, admitted, input, prepared);
    const started = try admitted.call(loop, .{ .state = initial_state });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.equal(
            try b.variantTag(reply),
            try b.variantTag(try c.literal(e.CodecReply, .{ .terminal = .{
                .campaign = @splat(0),
                .attempt = 0,
                .report = .{ .bytes = "" },
                .accounting = .{},
            } })),
        ),
        try rejected.ret(try payload(c, rejected, reply, "terminal")),
        try admitted.ret(started),
    )));
    return function;
}

fn initial(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Experiment),
    prepared: a.Value(e.Prepared),
) !a.Value(State) {
    return b.product(try c.schema(State), .{
        .identity = try b.field(prepared, "identity"),
        .envelope = try b.field(input, "envelope"),
        .plan = try b.field(prepared, "plan"),
        .model = try b.field(prepared, "model"),
        .case_index = try b.constant(u64, 0),
        .arm = try b.constant(u64, 0),
        .states = try b.field(prepared, "states"),
        .runs = try c.literal(e.Runs, .{ .items = &.{} }),
    });
}

fn payload(
    c: protean.Context,
    b: anytype,
    reply: a.Value(e.CodecReply),
    comptime name: []const u8,
) !a.Value(@FieldType(e.CodecReply, name)) {
    return b.variantPayload(reply, name, try a.failure(c, "experiment_codec_contract"));
}

fn codec(
    construction: Emit,
    b: anytype,
    comptime name: []const u8,
    input: a.Value(@FieldType(e.CodecRequest, name)),
) !a.Value(e.CodecReply) {
    return b.perform(construction.ops.codec, try b.variant(
        try construction.context.schema(e.CodecRequest),
        name,
        input,
    ));
}

fn scriptedCompletion(
    c: protean.Context,
    op: a.Operation(e.CodecRequest, e.CodecReply),
) !model.Function {
    const function = try c.author.function("labelled scripted comparison completion", .{
        .input = try c.schema(m.Input),
    }, try c.schema(m.Result), .{op});
    const b = try c.author.body(function);
    const reply = try b.perform(op, try b.variant(
        try c.schema(e.CodecRequest),
        "scripted_completion",
        try b.parameter("input"),
    ));
    try c.author.define(function, try b.ret(try payload(c, b, reply, "scripted_completion")));
    return function;
}

fn narrow(c: protean.Context, b: anytype, value: a.Value(u64)) !a.Value(u32) {
    return b.convertInteger(try c.schema(u32), value, .{
        .overflow = try a.failure(c, "experiment_index_overflow"),
    });
}

fn increment(c: protean.Context, b: anytype, value: a.Value(u64)) !a.Value(u64) {
    return b.checked(.add, value, try b.constant(u64, 1), .{
        .overflow = try a.failure(c, "experiment_index_overflow"),
    });
}

fn candidateIndex(c: protean.Context, b: anytype, state: a.Value(State)) !a.Value(u64) {
    return b.checked(.subtract, try b.field(state, "arm"), try b.constant(u64, 1), .{
        .overflow = try a.failure(c, "experiment_candidate_index"),
    });
}

fn loopBody(construction: Emit) !void {
    const c = construction.context;
    const b = try c.author.body(construction.loop);
    const state = try b.parameter("state");
    const cases = try b.field(try b.field(state, "plan"), "cases");
    const running = try b.branch();
    const finished = try b.branch();
    const reply = try codec(construction, finished, "finish", try finished.product(
        try c.schema(@FieldType(e.CodecRequest, "finish")),
        .{
            .identity = try finished.field(state, "identity"),
            .plan = try finished.field(state, "plan"),
            .runs = try finished.field(state, "runs"),
        },
    ));
    try c.author.define(construction.loop, try b.ret(try b.conditional(
        try b.less(try b.field(state, "case_index"), try b.sequenceLength(cases)),
        try running.ret(try run(construction, running, state)),
        try finished.ret(try payload(c, finished, reply, "finished")),
    )));
}

fn selectedCase(c: protean.Context, b: anytype, state: a.Value(State)) !a.Value(e.Case) {
    return b.variantPayload(try b.sequenceGet(
        try b.field(try b.field(state, "plan"), "cases"),
        try b.field(state, "case_index"),
    ), "some", try a.failure(c, "experiment_case_index"));
}

fn inputForRun(
    construction: Emit,
    b: anytype,
    state: a.Value(State),
    selected: a.Value(e.Case),
) !a.Value(step.RenderInput) {
    const c = construction.context;
    const ordinary = try b.branch();
    const candidate = try b.branch();
    const index = try candidateIndex(c, candidate, state);
    const chosen = try candidate.variantPayload(try candidate.sequenceGet(
        try candidate.field(try candidate.field(state, "plan"), "candidates"),
        index,
    ), "some", try a.failure(c, "experiment_candidate_index"));
    const prior = try candidate.variantPayload(try candidate.sequenceGet(
        try candidate.field(state, "states"),
        index,
    ), "some", try a.failure(c, "experiment_state_index"));
    const baseline = try prepareRun(
        construction,
        ordinary,
        state,
        selected,
        try c.literal(?e.Candidate, null),
        try c.literal(mc.State, .{ .bytes = "" }),
    );
    const treatment = try prepareRun(
        construction,
        candidate,
        state,
        selected,
        try candidate.variant(try c.schema(?e.Candidate), "some", chosen),
        prior,
    );
    return b.conditional(
        try b.equal(try b.field(state, "arm"), try b.constant(u64, 0)),
        try ordinary.ret(baseline),
        try candidate.ret(treatment),
    );
}

fn prepareRun(
    construction: Emit,
    b: anytype,
    state: a.Value(State),
    selected: a.Value(e.Case),
    candidate: a.Value(?e.Candidate),
    prior: a.Value(mc.State),
) !a.Value(step.RenderInput) {
    const c = construction.context;
    const reply = try codec(construction, b, "run_input", try b.product(
        try c.schema(e.RunInput),
        .{
            .envelope = try b.field(state, "envelope"),
            .selected = selected,
            .candidate = candidate,
            .state = prior,
            .model = try b.field(state, "model"),
        },
    ));
    return payload(c, b, reply, "run_input");
}

fn timestamp(
    construction: Emit,
    b: anytype,
    state: a.Value(State),
    comptime edge: anytype,
) !a.Value(i64) {
    const c = construction.context;
    return b.perform(construction.ops.clock, try b.product(try c.schema(e.Stamp), .{
        .case_index = try narrow(c, b, try b.field(state, "case_index")),
        .arm = try narrow(c, b, try b.field(state, "arm")),
        .edge = try c.literal(@FieldType(e.Stamp, "edge"), edge),
    }));
}

fn checkpoint(
    construction: Emit,
    b: anytype,
    state: a.Value(State),
    selected: a.Value(e.Case),
) !void {
    const c = construction.context;
    const interrupted = try b.branch();
    const continuous = try b.branch();
    _ = try codec(construction, interrupted, "checkpoint", try interrupted.product(
        try c.schema(e.Checkpoint),
        .{
            .case_index = try narrow(c, interrupted, try interrupted.field(state, "case_index")),
            .arm = try narrow(c, interrupted, try interrupted.field(state, "arm")),
        },
    ));
    _ = try b.conditional(
        try b.equal(
            try b.enumTag(try b.field(selected, "condition")),
            try b.enumTag(try c.literal(e.Condition, .interruption)),
        ),
        try interrupted.ret(try interrupted.constant(void, {})),
        try continuous.ret(try continuous.constant(void, {})),
    );
}

fn run(construction: Emit, b: anytype, state: a.Value(State)) !a.Value(t.ExperimentResult) {
    const c = construction.context;
    const selected = try selectedCase(c, b, state);
    const input = try inputForRun(construction, b, state, selected);
    const began = try timestamp(construction, b, state, .begin);
    try checkpoint(construction, b, state, selected);
    const live = try b.branch();
    const scripted = try b.branch();
    const output = try b.conditional(
        try b.equal(
            try b.enumTag(try b.field(try b.field(state, "identity"), "mode")),
            try b.enumTag(try c.literal(e.Mode, .live)),
        ),
        try live.ret(try live.call(construction.ordinary_live, .{ .input = input })),
        try scripted.ret(try scripted.call(construction.ordinary_scripted, .{ .input = input })),
    );
    const ended = try timestamp(construction, b, state, .end);
    const reply = try codec(construction, b, "observe", try b.product(
        try c.schema(e.Observation),
        .{
            .case_index = try narrow(c, b, try b.field(state, "case_index")),
            .arm = try narrow(c, b, try b.field(state, "arm")),
            .selected = selected,
            .input = input,
            .output = output,
            .started_ms = began,
            .ended_ms = ended,
        },
    ));
    const observed = try payload(c, b, reply, "observed");
    return b.call(construction.loop, .{ .state = try next(c, b, state, observed) });
}

fn next(
    c: protean.Context,
    b: anytype,
    state: a.Value(State),
    observed: a.Value(e.Observed),
) !a.Value(State) {
    const states = try nextStates(c, b, state, observed);
    const runs = try b.append(try b.field(state, "runs"), try b.field(observed, "run"), .{
        .capacity = try a.failure(c, "experiment_run_bound"),
    });
    const more = try b.branch();
    const following = try b.branch();
    const updated = try b.update(state, .{ .states = states, .runs = runs });
    const same_case = try more.update(updated, .{
        .arm = try increment(c, more, try more.field(state, "arm")),
    });
    const next_case = try following.update(updated, .{
        .arm = try following.constant(u64, 0),
        .case_index = try increment(c, following, try following.field(state, "case_index")),
    });
    return b.conditional(
        try b.less(try b.field(state, "arm"), try b.sequenceLength(
            try b.field(try b.field(state, "plan"), "candidates"),
        )),
        try more.ret(same_case),
        try following.ret(next_case),
    );
}

fn nextStates(
    c: protean.Context,
    b: anytype,
    state: a.Value(State),
    observed: a.Value(e.Observed),
) !a.Value(e.States) {
    const ordinary = try b.branch();
    const candidate = try b.branch();
    const prior = try b.field(state, "states");
    const changed = try candidate.sequenceSet(
        prior,
        try candidateIndex(c, candidate, state),
        try candidate.field(observed, "state"),
        try a.failure(c, "experiment_state_index"),
    );
    return b.conditional(
        try b.equal(try b.field(state, "arm"), try b.constant(u64, 0)),
        try ordinary.ret(prior),
        try candidate.ret(changed),
    );
}
