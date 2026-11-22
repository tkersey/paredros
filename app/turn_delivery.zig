const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const m = @import("model_contract.zig");
const description = @import("proposal_text.zig");

pub const action_id = "paredros.proposal.confirm.v1";
pub const Conversation = @FieldType(m.Candidate, "conversation");
pub const Input = struct { turn: t.Turn, conversation: Conversation };
pub const Function = a.Function(struct { input: Input }, t.TurnResult);
const Proposals = @FieldType(t.TurnResult, "proposals");
const Buttons = @FieldType(t.LogicalPayload, "buttons");
const CountArgs = struct { text: cts.Utf8, index: u64, total: u64 };
const Count = a.Function(CountArgs, u64);
const State = struct {
    input: Input,
    index: u64,
    message: description.Complete,
    buttons: Buttons,
    proposals: Proposals,
};
const Loop = a.Function(struct { state: State }, t.TurnResult);

pub fn emit(c: protean.Context) !Function {
    const count = try counter(c);
    const loop = try proposals(c, try description.emit(c));
    const function = try c.author.function("seal turn delivery and exact confirmation buttons", .{
        .input = try c.schema(Input),
    }, try c.schema(t.TurnResult), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const result = try b.call(loop, .{ .state = try b.product(try c.schema(State), .{
        .input = input,
        .index = try b.constant(u64, 0),
        .message = try initial(c, b, count, input),
        .proposals = try c.literal(Proposals, .{ .items = &.{} }),
        .buttons = try c.literal(Buttons, .{ .items = &.{} }),
    }) });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn literal(c: protean.Context, text: []const u8) !a.Value(t.Text) {
    return c.literal(t.Text, .{ .bytes = text });
}

fn join(c: protean.Context, b: anytype, parts: anytype) !a.Value(t.Text) {
    var result = try literal(c, "");
    inline for (parts) |part| result = try b.blobConcat(
        try c.schema(t.Text),
        result,
        part,
        try a.failure(c, "turn_delivery_capacity"),
    );
    return result;
}

fn add(c: protean.Context, b: anytype, left: a.Value(u64), right: a.Value(u64)) !a.Value(u64) {
    return b.checked(.add, left, right, .{ .overflow = try a.failure(c, "turn_size_overflow") });
}

fn cost(c: protean.Context, b: anytype, count: Count, text: anytype) !a.Value(u64) {
    const bounded_text = try b.branch();
    const oversized = try b.branch();
    const raw = try bounded_text.blobSlice(
        try c.schema(cts.Utf8),
        text,
        try bounded_text.constant(u64, 0),
        try bounded_text.blobLength(text),
        .{
            .capacity = try a.failure(c, "turn_text_capacity"),
            .invalid_utf8 = try a.failure(c, "turn_text_utf8"),
        },
    );
    const measured = try bounded_text.call(count, .{
        .text = raw,
        .index = try bounded_text.constant(u64, 0),
        .total = try bounded_text.constant(u64, 0),
    });
    return b.conditional(
        try b.less(try b.constant(u64, 16000), try b.blobLength(text)),
        try oversized.ret(try oversized.constant(u64, 4001)),
        try bounded_text.ret(measured),
    );
}

fn counter(c: protean.Context) !Count {
    const function = try c.author.function("measure escaped Slack scalar budget", .{
        .text = try c.schema(cts.Utf8),
        .index = try c.schema(u64),
        .total = try c.schema(u64),
    }, try c.schema(u64), &.{});
    const b = try c.author.body(function);
    const text = try b.parameter("text");
    const index = try b.parameter("index");
    const total = try b.parameter("total");
    const more = try b.branch();
    const done = try b.branch();
    const byte = try more.variantPayload(
        try more.blobByte(text, index),
        "some",
        try a.failure(c, "turn_text_bounds"),
    );
    const next = try more.call(function, .{
        .text = text,
        .index = try add(c, more, index, try description.scalarWidth(more, byte)),
        .total = try add(c, more, total, try description.scalarCost(more, byte)),
    });
    const within = try b.booleanNot(try b.less(try b.constant(u64, 4000), total));
    const active = try b.select(
        within,
        try b.less(index, try b.blobLength(text)),
        try b.constant(bool, false),
    );
    try c.author.define(function, try b.ret(try b.conditional(
        active,
        try more.ret(next),
        try done.ret(total),
    )));
    return function;
}

fn allowance(c: protean.Context, b: anytype, remaining: a.Value(u64)) !a.Value(u64) {
    const failure = try a.failure(c, "turn_proposal_budget");
    const reserved = try b.checked(.multiply, remaining, try b.constant(u64, 256), .{
        .overflow = failure,
    });
    return b.checked(.subtract, try b.constant(u64, 4000), reserved, .{ .overflow = failure });
}

fn initial(
    c: protean.Context,
    b: anytype,
    count: Count,
    input: a.Value(Input),
) !a.Value(description.Complete) {
    const conversation = try b.field(input, "conversation");
    const reply = try b.field(conversation, "reply");
    const prefix = "Assistant reply; no action has been admitted:\n";
    const fallback = "The full assistant reply is retained locally. " ++
        "Inspect it through the CLI. No action has been admitted.";
    const size = try add(
        c,
        b,
        try b.constant(u64, try description.literalCost(prefix)),
        try cost(c, b, count, reply),
    );
    const limit = try allowance(c, b, try b.sequenceLength(try b.field(conversation, "proposals")));
    const fits = try b.branch();
    const large = try b.branch();
    return b.conditional(
        try b.less(limit, size),
        try large.ret(try c.literal(
            description.Complete,
            .{ .text = .{ .bytes = fallback }, .cost = try description.literalCost(fallback) },
        )),
        try fits.ret(try fits.product(try c.schema(description.Complete), .{
            .text = try join(c, fits, .{ try literal(c, prefix), reply }),
            .cost = size,
        })),
    );
}

fn proposals(c: protean.Context, describe: description.Function) !Loop {
    const function = try c.author.function("render full proposals or CLI references", .{
        .state = try c.schema(State),
    }, try c.schema(t.TurnResult), &.{});
    const b = try c.author.body(function);
    const state = try b.parameter("state");
    const input = try b.field(state, "input");
    const list = try b.field(try b.field(input, "conversation"), "proposals");
    const index = try b.field(state, "index");
    const more = try b.branch();
    const done = try b.branch();
    const candidate = try more.variantPayload(
        try more.sequenceGet(list, index),
        "some",
        try a.failure(c, "turn_proposal_bounds"),
    );
    const next = try renderProposal(c, more, describe, state, candidate);
    const continued = try more.call(function, .{ .state = try more.update(next, .{
        .index = try add(c, more, index, try more.constant(u64, 1)),
    }) });
    const final = try done.product(try c.schema(t.TurnResult), .{
        .reply = try done.field(try done.field(input, "conversation"), "reply"),
        .proposals = try done.field(state, "proposals"),
        .delivery = try done.variant(
            try c.schema(?t.DeliveryIntent),
            "some",
            try intent(c, done, try done.field(input, "turn"), state),
        ),
    });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(list)),
        try more.ret(continued),
        try done.ret(final),
    )));
    return function;
}

fn proposalId(
    c: protean.Context,
    b: anytype,
    turn: a.Value(t.Turn),
    proposal: a.Value(t.Proposal),
) !a.Value(t.Text) {
    const identity = try b.field(proposal, "identity");
    return join(c, b, .{
        try description.identity(
            c,
            b,
            try b.field(try b.field(turn, "envelope"), "stable_request"),
        ),
        try literal(c, ":"),
        try b.textInteger(try b.field(identity, "attempt")),
        try literal(c, ":"),
        try b.textInteger(try b.field(identity, "ordinal")),
    });
}

fn renderProposal(
    c: protean.Context,
    b: anytype,
    describe: description.Function,
    state: a.Value(State),
    candidate: a.Value(m.BoundProposal),
) !a.Value(State) {
    const turn = try b.field(try b.field(state, "input"), "turn");
    const identity = try b.product(try c.schema(@FieldType(t.Proposal, "identity")), .{
        .operation = try b.field(try b.field(turn, "envelope"), "operation"),
        .attempt = try b.field(turn, "attempt"),
        .ordinal = try b.convertInteger(try c.schema(u32), try b.field(state, "index"), .{
            .overflow = try a.failure(c, "proposal_ordinal"),
        }),
    });
    const target = try b.field(turn, "target");
    const body = try b.field(candidate, "body");
    const proposal = try b.product(try c.schema(t.Proposal), .{
        .identity = identity,
        .target = target,
        .body = body,
        .description = try c.literal(?t.Text, null),
    });
    const id = try proposalId(c, b, turn, proposal);
    const rendered = try b.call(describe, .{
        .input = try b.product(try c.schema(description.Input), .{
            .target = target,
            .body = body,
        }),
    });
    const cli = try b.caseOf(rendered, "cli");
    const complete = try b.caseOf(rendered, "complete");
    const cb = complete.body();
    const full = try cb.update(proposal, .{
        .description = try cb.variant(
            try c.schema(?t.Text),
            "some",
            try cb.field(complete.payload(), "text"),
        ),
    });
    const local = try omitted(c, cli.body(), state, id);
    const delivered = try renderComplete(c, cb, state, full, complete.payload(), id);
    return b.match(rendered, .{
        .cli = try cli.ret(try retain(c, cli.body(), local, proposal)),
        .complete = try complete.ret(try retain(c, cb, delivered, full)),
    });
}

fn retain(
    c: protean.Context,
    b: anytype,
    state: a.Value(State),
    proposal: a.Value(t.Proposal),
) !a.Value(State) {
    return b.update(state, .{
        .proposals = try b.append(
            try b.field(state, "proposals"),
            proposal,
            .{ .capacity = try a.failure(c, "proposal_limit") },
        ),
    });
}

fn renderComplete(
    c: protean.Context,
    b: anytype,
    state: a.Value(State),
    proposal: a.Value(t.Proposal),
    measured: a.Value(description.Complete),
    id: a.Value(t.Text),
) !a.Value(State) {
    const input = try b.field(state, "input");
    const index = try b.field(state, "index");
    const prefix = try join(c, b, .{
        try literal(c, "\n\nProposal "), id, try literal(c, ":\n"),
    });
    // The generated prefix contains only ASCII literals, hexadecimal and decimal digits.
    const size = try add(c, b, try b.field(try b.field(state, "message"), "cost"), try add(
        c,
        b,
        try b.blobLength(prefix),
        try b.field(measured, "cost"),
    ));
    const length = try b.sequenceLength(
        try b.field(try b.field(input, "conversation"), "proposals"),
    );
    const next_index = try add(c, b, index, try b.constant(u64, 1));
    const remaining = try b.checked(.subtract, length, next_index, .{
        .overflow = try a.failure(c, "turn_proposal_bounds"),
    });
    const fits = try b.branch();
    const large = try b.branch();
    const included = try include(
        c,
        fits,
        state,
        proposal,
        try fits.field(measured, "text"),
        prefix,
        id,
        size,
    );
    return b.conditional(
        try b.less(try allowance(c, b, remaining), size),
        try large.ret(try omitted(c, large, state, id)),
        try fits.ret(included),
    );
}

fn omitted(
    c: protean.Context,
    b: anytype,
    state: a.Value(State),
    id: a.Value(t.Text),
) !a.Value(State) {
    const message = try b.field(state, "message");
    const reference = try join(c, b, .{
        try literal(c, "\n\nComplete proposal is retained locally. " ++
            "Inspect before confirming via CLI:\n"),
        try literal(c, "paredros proposal confirm "),
        id,
    });
    return b.update(state, .{ .message = try b.product(try c.schema(description.Complete), .{
        .text = try join(c, b, .{ try b.field(message, "text"), reference }),
        .cost = try add(c, b, try b.field(message, "cost"), try b.blobLength(reference)),
    }) });
}

fn bounded(c: protean.Context, b: anytype, comptime T: type, text: anytype) !a.Value(T) {
    return b.blobSlice(try c.schema(T), text, try b.constant(u64, 0), try b.blobLength(text), .{
        .capacity = try a.failure(c, "turn_button_capacity"),
        .invalid_utf8 = try a.failure(c, "turn_button_utf8"),
    });
}

fn include(
    c: protean.Context,
    b: anytype,
    state: a.Value(State),
    proposal: a.Value(t.Proposal),
    description_text: a.Value(t.Text),
    prefix: a.Value(t.Text),
    id: a.Value(t.Text),
    size: a.Value(u64),
) !a.Value(State) {
    const ordinal = try b.field(try b.field(proposal, "identity"), "ordinal");
    const number = try b.textInteger(ordinal);
    const button = try b.product(try c.schema(t.Button), .{
        .block_id = try bounded(c, b, @FieldType(t.Button, "block_id"), try join(c, b, .{
            try literal(c, "paredros_proposal_"), number,
        })),
        .action_id = try c.literal(@FieldType(t.Button, "action_id"), .{ .bytes = action_id }),
        .value = try bounded(c, b, @FieldType(t.Button, "value"), id),
        .label = try bounded(c, b, @FieldType(t.Button, "label"), try join(c, b, .{
            try literal(c, "Confirm proposal "), number,
        })),
    });
    return b.update(state, .{
        .message = try b.product(try c.schema(description.Complete), .{
            .text = try join(
                c,
                b,
                .{ try b.field(try b.field(state, "message"), "text"), prefix, description_text },
            ),
            .cost = size,
        }),
        .buttons = try b.append(try b.field(state, "buttons"), button, .{
            .capacity = try a.failure(c, "turn_button_count"),
        }),
    });
}

fn intent(
    c: protean.Context,
    b: anytype,
    turn: a.Value(t.Turn),
    state: a.Value(State),
) !a.Value(t.DeliveryIntent) {
    const identity = try b.field(try b.field(turn, "envelope"), "stable_request");
    const revision = try b.field(turn, "expected_revision");
    const none = try b.caseOf(revision, "none");
    const some = try b.caseOf(revision, "some");
    const expected = try b.match(revision, .{
        .none = try none.ret(try none.body().constant(u64, 0)),
        .some = try some.ret(some.payload()),
    });
    return b.product(try c.schema(t.DeliveryIntent), .{
        .destination = try b.field(turn, "destination"),
        .key = try b.product(try c.schema(t.DeliveryKey), .{
            .lineage = identity,
            .purpose = try c.literal(@FieldType(t.DeliveryKey, "purpose"), .turn),
            .identity = identity,
            .generation = try b.field(turn, "attempt"),
        }),
        .payload = try b.update(try c.literal(t.LogicalPayload, .{
            .obligation = null,
            .specification_revision = 0,
            .prior_sequence = 0,
            .through_sequence = 0,
            .frozen_text = .{ .bytes = "" },
            .prompt = null,
            .supersedes = null,
        }), .{
            .obligation = try b.field(turn, "target"),
            .specification_revision = expected,
            .frozen_text = try b.field(try b.field(state, "message"), "text"),
            .buttons = try b.field(state, "buttons"),
        }),
    });
}
