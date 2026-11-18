const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const m = @import("model_contract.zig");
const model = @import("model.zig");
const delivery = @import("turn_delivery.zig");

pub const Function = a.Function(struct { input: t.Turn }, t.TurnResult);

pub fn emit(c: protean.Context, completion: model.Function, effects: anytype) !Function {
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
    const conversation = try b.match(refusal, .{
        .none = try ordinary.ret(try respond(c, ordinary.body(), input, completion)),
        .some = try refused.ret(try failure(
            c,
            "This confirmation could not be admitted. No action was taken.",
        )),
    });
    const output = try b.call(notify, .{ .input = try b.product(try c.schema(delivery.Input), .{
        .turn = input,
        .conversation = conversation,
    }) });
    try c.author.define(function, try b.ret(output));
    return function;
}

fn respond(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Turn),
    completion: model.Function,
) !a.Value(delivery.Conversation) {
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
        try b.equal(attempt, try b.constant(u32, 2)),
        try final.ret(try failure(c, "I could not complete this turn. No action was admitted.")),
        try eligible.ret(configured),
    );
}

fn failure(c: protean.Context, text: []const u8) !a.Value(delivery.Conversation) {
    return c.literal(delivery.Conversation, .{
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
) !a.Value(delivery.Conversation) {
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
            try c.schema(delivery.Conversation),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "wrong_turn_candidate" } }),
        ),
        .rejected = try rejected.fail(
            try c.schema(delivery.Conversation),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "rejected_turn_candidate" } }),
        ),
    });
}
