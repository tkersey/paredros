const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const m = @import("model_contract.zig");
const model = @import("model.zig");
const proposal_text = @import("proposal_text.zig");
const delivery = @import("turn_delivery.zig");

pub const Function = a.Function(struct { input: t.Turn }, t.TurnResult);
const Proposals = @FieldType(t.TurnResult, "proposals");
const Seal = a.Function(struct {
    input: t.Turn,
    candidates: m.Proposals,
    index: u64,
    proposals: Proposals,
}, Proposals);

pub fn emit(c: protean.Context, completion: model.Function, effects: anytype) !Function {
    const seal = try sealProposals(c, try proposal_text.emit(c));
    const notify = try delivery.emit(c);
    const function = try c.author.function("one frozen conversation turn", .{
        .input = try c.schema(t.Turn),
    }, try c.schema(t.TurnResult), effects);
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const attempt = try b.field(input, "attempt");
    try a.require(c, b, try b.less(attempt, try b.constant(u32, 3)), "turn_attempt_limit");
    const refusal = try b.field(input, "refusal");
    const ordinary = try b.caseOf(refusal, "none");
    const refused = try b.caseOf(refusal, "some");
    const result = try b.match(refusal, .{
        .none = try ordinary.ret(try respond(c, ordinary.body(), input, completion, seal)),
        .some = try refused.ret(try failure(
            c,
            "This confirmation could not be admitted. No action was taken.",
        )),
    });
    const output = try b.call(notify, .{ .input = try b.product(try c.schema(delivery.Input), .{
        .turn = input,
        .result = result,
    }) });
    try c.author.define(function, try b.ret(output));
    return function;
}

fn respond(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Turn),
    completion: model.Function,
    seal: Seal,
) !a.Value(t.TurnResult) {
    const attempt = try b.field(input, "attempt");
    const final = try b.branch();
    const eligible = try b.branch();
    const binding = try eligible.field(input, "model");
    const absent = try eligible.caseOf(binding, "none");
    const present = try eligible.caseOf(binding, "some");
    const acquired = try acquire(c, present.body(), input, present.payload(), completion, seal);
    const configured = try eligible.match(binding, .{
        .none = try absent.ret(try failure(c, "No model is configured. No action was admitted.")),
        .some = try present.ret(acquired),
    });
    return b.conditional(
        try b.equal(attempt, try b.constant(u32, 2)),
        try final.ret(try failure(c, "I could not complete this turn. No action was admitted.")),
        try eligible.ret(configured),
    );
}

fn failure(c: protean.Context, text: []const u8) !a.Value(t.TurnResult) {
    return c.literal(t.TurnResult, .{
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
    seal: Seal,
) !a.Value(t.TurnResult) {
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
    const cb = conversation.body();
    const proposals = try cb.call(seal, .{
        .input = input,
        .candidates = try cb.field(conversation.payload(), "proposals"),
        .index = try cb.constant(u64, 0),
        .proposals = try c.literal(Proposals, .{ .items = &.{} }),
    });
    const result = try cb.product(try c.schema(t.TurnResult), .{
        .reply = try cb.field(conversation.payload(), "reply"),
        .proposals = proposals,
        .delivery = try c.literal(?t.DeliveryIntent, null),
    });
    return b.match(candidate, .{
        .conversation = try conversation.ret(result),
        .summary = try summary.fail(
            try c.schema(t.TurnResult),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "wrong_turn_candidate" } }),
        ),
        .rejected = try rejected.fail(
            try c.schema(t.TurnResult),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "rejected_turn_candidate" } }),
        ),
    });
}

fn sealProposals(c: protean.Context, describe: proposal_text.Function) !Seal {
    const function = try c.author.function("bind proposal identity to the admitted turn", .{
        .input = try c.schema(t.Turn),
        .candidates = try c.schema(m.Proposals),
        .index = try c.schema(u64),
        .proposals = try c.schema(Proposals),
    }, try c.schema(Proposals), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const candidates = try b.parameter("candidates");
    const index = try b.parameter("index");
    const proposals = try b.parameter("proposals");
    const active = try b.branch();
    const done = try b.branch();
    const candidate = try active.variantPayload(
        try active.sequenceGet(candidates, index),
        "some",
        try a.failure(c, "proposal_ordinal"),
    );
    const identity = try active.product(try c.schema(@FieldType(t.Proposal, "identity")), .{
        .operation = try active.field(try active.field(input, "envelope"), "operation"),
        .attempt = try active.field(input, "attempt"),
        .ordinal = try active.convertInteger(try c.schema(u32), index, .{
            .overflow = try a.failure(c, "proposal_ordinal"),
        }),
    });
    const proposal = try active.product(try c.schema(t.Proposal), .{
        .identity = identity,
        .target = try active.field(input, "target"),
        .body = try active.field(candidate, "body"),
        .description = try active.call(describe, .{ .input = try active.product(
            try c.schema(proposal_text.Input),
            .{
                .target = try active.field(input, "target"),
                .body = try active.field(candidate, "body"),
            },
        ) }),
    });
    const next = try active.call(function, .{
        .input = input,
        .candidates = candidates,
        .index = try active.checked(.add, index, try active.constant(u64, 1), .{
            .overflow = try a.failure(c, "proposal_ordinal"),
        }),
        .proposals = try active.append(
            proposals,
            proposal,
            .{ .capacity = try a.failure(c, "proposal_limit") },
        ),
    });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(candidates)),
        try active.ret(next),
        try done.ret(proposals),
    )));
    return function;
}
