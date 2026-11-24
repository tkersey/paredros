const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const m = @import("model_contract.zig");
const model = @import("model.zig");
const description = @import("proposal_text.zig");
const frame = @import("render_frame.zig");

pub const Function = a.Function(struct { input: t.Turn }, t.TurnResult);
const Conversation = @FieldType(m.Candidate, "conversation");
const Proposals = @FieldType(t.TurnResult, "proposals");
const State = struct { turn: t.Turn, conversation: Conversation, index: u64, proposals: Proposals };
const Loop = a.Function(struct { state: State }, t.TurnResult);
const Tools = struct { describe: description.Function, neutral: frame.Neutral };

pub fn emit(c: protean.Context, completion: model.Function, effects: anytype) !Function {
    const loop = try proposals(c, .{
        .describe = try description.emit(c),
        .neutral = try frame.neutral(c),
    });
    const function = try c.author.function("one frozen conversation turn", .{
        .input = try c.schema(t.Turn),
    }, try c.schema(t.TurnResult), effects);
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const refusal = try b.field(input, "refusal");
    const ordinary = try b.caseOf(refusal, "none");
    const refused = try b.caseOf(refusal, "some");
    const conversation = try b.match(refusal, .{
        .none = try ordinary.ret(try respond(c, ordinary.body(), input, completion)),
        .some = try refused.ret(try failure(
            c,
            "This confirmation could not be admitted. No action was taken.",
        )),
    });
    const output = try b.call(loop, .{ .state = try b.product(try c.schema(State), .{
        .turn = input,
        .conversation = conversation,
        .index = try b.constant(u64, 0),
        .proposals = try c.literal(Proposals, .{ .items = &.{} }),
    }) });
    try c.author.define(function, try b.ret(output));
    return function;
}

fn respond(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Turn),
    completion: model.Function,
) !a.Value(Conversation) {
    const attempt = try b.field(input, "attempt");
    const final = try b.branch();
    const eligible = try b.branch();
    const binding = try eligible.field(input, "model");
    const absent = try eligible.caseOf(binding, "none");
    const present = try eligible.caseOf(binding, "some");
    const acquired = try acquire(c, present.body(), input, present.payload(), completion);
    const configured = try eligible.match(binding, .{
        .none = try absent.ret(try failure(c, "No model is configured. No action was admitted.")),
        .some = try present.ret(acquired),
    });
    return b.conditional(
        try b.less(try b.constant(u32, 1), attempt),
        try final.ret(try failure(c, "I could not complete this turn. No action was admitted.")),
        try eligible.ret(configured),
    );
}

fn failure(c: protean.Context, text: []const u8) !a.Value(Conversation) {
    return c.literal(Conversation, .{
        .reply = .{ .bytes = text },
        .proposals = .{ .items = &.{} },
    });
}

fn context(c: protean.Context, b: anytype, input: a.Value(t.Turn)) !a.Value(cts.Text(256 * 1024)) {
    const Text = cts.Text(256 * 1024);
    const invalid = try a.failure(c, "turn_context_bounds");
    var text = try b.blobConcat(
        try c.schema(Text),
        try c.literal(Text, .{ .bytes = "Frozen state and evidence:\n" }),
        try b.field(input, "context"),
        invalid,
    );
    text = try b.blobConcat(
        try c.schema(Text),
        text,
        try c.literal(Text, .{ .bytes = "\nAuthenticated operator input:\n" }),
        invalid,
    );
    return b.blobConcat(try c.schema(Text), text, try b.field(input, "text"), invalid);
}

fn acquire(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Turn),
    binding: a.Value(t.ModelBinding),
    completion: model.Function,
) !a.Value(Conversation) {
    const request = try b.product(try c.schema(m.Input), .{
        .binding = binding,
        .phase = try c.literal(@FieldType(m.Input, "phase"), .conversation),
        .context = try context(c, b, input),
        .initiating_input = try b.field(try b.field(input, "envelope"), "stable_request"),
        .target = try b.field(input, "target"),
        .expected_revision = try b.field(input, "expected_revision"),
        .proposal_offers = try b.field(input, "proposal_offers"),
        .genesis_template = try b.field(input, "genesis_template"),
    });
    const observed = try b.call(completion, .{ .input = request });
    const candidate = try b.field(observed, "candidate");
    const conversation = try b.caseOf(candidate, "conversation");
    const summary = try b.caseOf(candidate, "summary");
    const rejected = try b.caseOf(candidate, "rejected");
    return b.match(candidate, .{
        .conversation = try conversation.ret(conversation.payload()),
        .summary = try summary.fail(
            try c.schema(Conversation),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "wrong_turn_candidate" } }),
        ),
        .rejected = try rejected.fail(
            try c.schema(Conversation),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "rejected_turn_candidate" } }),
        ),
    });
}

fn proposals(c: protean.Context, tools: Tools) !Loop {
    const function = try c.author.function("describe frozen proposals", .{
        .state = try c.schema(State),
    }, try c.schema(t.TurnResult), &.{});
    const b = try c.author.body(function);
    const state = try b.parameter("state");
    const conversation = try b.field(state, "conversation");
    const list = try b.field(conversation, "proposals");
    const index = try b.field(state, "index");
    const more = try b.branch();
    const done = try b.branch();
    const candidate = try more.variantPayload(
        try more.sequenceGet(list, index),
        "some",
        try a.failure(c, "turn_proposal_bounds"),
    );
    const next = try more.update(state, .{
        .index = try more.checked(.add, index, try more.constant(u64, 1), .{
            .overflow = try a.failure(c, "turn_size_overflow"),
        }),
        .proposals = try more.append(
            try more.field(state, "proposals"),
            try proposal(c, more, tools.describe, state, candidate),
            .{ .capacity = try a.failure(c, "proposal_limit") },
        ),
    });
    const final = try done.product(try c.schema(t.TurnResult), .{
        .reply = try done.call(tools.neutral, .{ .text = try done.field(conversation, "reply") }),
        .proposals = try done.field(state, "proposals"),
    });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(list)),
        try more.ret(try more.call(function, .{ .state = next })),
        try done.ret(final),
    )));
    return function;
}

fn proposal(
    c: protean.Context,
    b: anytype,
    describe: description.Function,
    state: a.Value(State),
    candidate: a.Value(m.BoundProposal),
) !a.Value(t.Proposal) {
    const turn = try b.field(state, "turn");
    const target = try b.field(turn, "target");
    const body = try b.field(candidate, "body");
    const rendered = try b.call(describe, .{
        .input = try b.product(try c.schema(description.Input), .{
            .target = target,
            .body = body,
        }),
    });
    const cli = try b.caseOf(rendered, "cli");
    const complete = try b.caseOf(rendered, "complete");
    const cb = complete.body();
    const text = try b.match(rendered, .{
        .cli = try cli.ret(try c.literal(?t.Text, null)),
        .complete = try complete.ret(try cb.variant(
            try c.schema(?t.Text),
            "some",
            try cb.field(complete.payload(), "text"),
        )),
    });
    return b.product(try c.schema(t.Proposal), .{
        .identity = try b.product(try c.schema(@FieldType(t.Proposal, "identity")), .{
            .operation = try b.field(try b.field(turn, "envelope"), "operation"),
            .attempt = try b.field(turn, "attempt"),
            .ordinal = try b.convertInteger(try c.schema(u32), try b.field(state, "index"), .{
                .overflow = try a.failure(c, "proposal_ordinal"),
            }),
        }),
        .target = target,
        .body = body,
        .description = text,
    });
}
