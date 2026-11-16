const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const m = @import("method_contract.zig");
const model_contract = @import("model_contract.zig");
const model = @import("model.zig");
const a = @import("author.zig");
const w = cts.workspace;

pub const Function = a.Function(struct { input: m.MethodInput }, m.Result);
pub const Ops = struct {
    workspace: a.Operation(m.WorkspaceRequest, w.Reply),
    codec: a.Operation(m.CodecRequest, m.CodecReply),
};
const State = struct {
    input: m.MethodInput,
    port_identity: ?cts.Text(128),
    consumed: bool,
    advances: u32,
};
const Loop = a.Function(struct { state: State, reply: w.Reply }, m.Result);
const PageState = struct {
    state: State,
    expected: w.Expected,
    reference: w.Ref,
    port: ?m.Port,
    text: m.JsonText,
    offset: u64,
    total: ?u64,
};
const Pages = a.Function(struct { page: PageState }, m.Result);
const Emit = struct {
    context: protean.Context,
    ops: Ops,
    completion: model.Function,
    loop: Loop,
    pages: Pages,
    max_advances: ?u32,
};

pub fn declare(c: protean.Context) !Ops {
    return .{
        .workspace = try c.external(
            m.workspace_identity,
            try c.schema(m.WorkspaceRequest),
            try c.schema(w.Reply),
            .read,
        ),
        .codec = try c.external(
            m.codec_identity,
            try c.schema(m.CodecRequest),
            try c.schema(m.CodecReply),
            .read,
        ),
    };
}

pub fn emit(
    c: protean.Context,
    ops: Ops,
    completion: model.Function,
    effects: anytype,
) !Function {
    return emitLimit(c, ops, completion, effects, null);
}

pub fn emitBounded(
    c: protean.Context,
    ops: Ops,
    completion: model.Function,
    effects: anytype,
    comptime max_advances: u32,
) !Function {
    if (max_advances == 0) @compileError("method advance bound must be positive");
    return emitLimit(c, ops, completion, effects, max_advances);
}

fn emitLimit(
    c: protean.Context,
    ops: Ops,
    completion: model.Function,
    effects: anytype,
    max_advances: ?u32,
) !Function {
    const loop = try c.author.function(
        "advance admitted retained method",
        .{
            .state = try c.schema(State),
            .reply = try c.schema(w.Reply),
        },
        try c.schema(m.Result),
        effects,
    );
    const pages = try c.author.function(
        "read complete retained method value",
        .{
            .page = try c.schema(PageState),
        },
        try c.schema(m.Result),
        effects,
    );
    const e: Emit = .{
        .context = c,
        .ops = ops,
        .completion = completion,
        .loop = loop,
        .pages = pages,
        .max_advances = max_advances,
    };
    try loopBody(e);
    try pagesBody(e);
    const function = try c.author.function(
        "run retained source in child custody",
        .{
            .input = try c.schema(m.MethodInput),
        },
        try c.schema(m.Result),
        effects,
    );
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const reply = try codec(e, b, "prepare", input);
    const good = try b.branch();
    const prepared = try payload(c, good, reply, "prepared");
    const result = try begin(e, good, input, prepared);
    try c.author.define(
        function,
        try b.ret(try guarded(
            e,
            b,
            reply,
            try b.constant(bool, false),
            try good.ret(result),
        )),
    );
    return function;
}

fn payload(
    c: protean.Context,
    b: anytype,
    reply: a.Value(m.CodecReply),
    comptime name: []const u8,
) !a.Value(@FieldType(m.CodecReply, name)) {
    return b.variantPayload(
        reply,
        name,
        try a.failure(c, "method_codec_contract"),
    );
}

fn codec(
    e: Emit,
    b: anytype,
    comptime name: []const u8,
    value: a.Value(@FieldType(m.CodecRequest, name)),
) !a.Value(m.CodecReply) {
    return b.perform(
        e.ops.codec,
        try b.variant(try e.context.schema(m.CodecRequest), name, value),
    );
}

fn command(
    e: Emit,
    b: anytype,
    input: a.Value(m.MethodInput),
    value: a.Value(w.Command),
) !a.Value(w.Reply) {
    const retained = try b.field(input, "retained");
    return b.perform(
        e.ops.workspace,
        try b.product(
            try e.context.schema(m.WorkspaceRequest),
            .{
                .source_digest = try b.field(retained, "source_digest"),
                .contract_digest = try b.field(retained, "contract_digest"),
                .command = value,
            },
        ),
    );
}

fn work(
    e: Emit,
    b: anytype,
    input: a.Value(m.MethodInput),
    comptime name: []const u8,
    value: a.Value(@FieldType(w.Work, name)),
) !a.Value(w.Reply) {
    return command(
        e,
        b,
        input,
        try b.variant(
            try e.context.schema(w.Command),
            "work",
            try b.variant(try e.context.schema(w.Work), name, value),
        ),
    );
}

fn fault(
    c: protean.Context,
    b: anytype,
    reason: a.Value(t.Name),
    consumed: a.Value(bool),
) !a.Value(m.Result) {
    return b.product(
        try c.schema(m.Result),
        .{
            .outcome = try b.variant(
                try c.schema(@FieldType(m.Result, "outcome")),
                "fault",
                reason,
            ),
            .model_consumed = consumed,
        },
    );
}

fn guarded(
    e: Emit,
    b: anytype,
    reply: a.Value(m.CodecReply),
    consumed: a.Value(bool),
    success: anytype,
) !a.Value(m.Result) {
    const bad = try b.branch();
    return b.conditional(
        try b.equal(
            try b.variantTag(reply),
            try b.variantTag(try e.context.literal(m.CodecReply, .{ .fault = .{ .bytes = "" } })),
        ),
        try bad.ret(try fault(
            e.context,
            bad,
            try payload(e.context, bad, reply, "fault"),
            consumed,
        )),
        success,
    );
}

fn begin(
    e: Emit,
    b: anytype,
    input: a.Value(m.MethodInput),
    prepared: a.Value(m.Prepared),
) !a.Value(m.Result) {
    const c = e.context;
    const built_reply = try command(e, b, input, try b.field(prepared, "build"));
    const normalized = try codec(
        e,
        b,
        "built",
        try b.product(
            try c.schema(@FieldType(m.CodecRequest, "built")),
            .{
                .reply = built_reply,
                .prepared = prepared,
            },
        ),
    );
    const good = try b.branch();
    const built = try payload(c, good, normalized, "built");
    const started = try work(
        e,
        good,
        input,
        "start",
        try good.product(
            try c.schema(@FieldType(w.Work, "start")),
            .{
                .program = try good.field(built, "program"),
                .input = try good.field(built, "input"),
                .policy = try c.literal(
                    w.Policy,
                    .{
                        .stop = .next_exposed_event,
                        .continuation = .explicit_only,
                    },
                ),
                .runtime = try c.literal(w.RuntimeChoice, .{ .packaged = .{} }),
                .trial = try c.literal(w.Trial, .{ .none = .{} }),
            },
        ),
    );
    const state = try good.product(
        try c.schema(State),
        .{
            .input = input,
            .port_identity = try good.field(prepared, "port_identity"),
            .consumed = try good.constant(bool, false),
            .advances = try good.constant(u32, 0),
        },
    );
    const result = try good.call(e.loop, .{ .state = state, .reply = started });
    return guarded(
        e,
        b,
        normalized,
        try b.constant(bool, false),
        try good.ret(result),
    );
}

fn loopBody(e: Emit) !void {
    const c = e.context;
    const b = try c.author.body(e.loop);
    const state = try b.parameter("state");
    const reply = try codec(
        e,
        b,
        "observe",
        try b.product(
            try c.schema(@FieldType(m.CodecRequest, "observe")),
            .{
                .reply = try b.parameter("reply"),
                .port_identity = try b.field(state, "port_identity"),
            },
        ),
    );
    const good = try b.branch();
    const observed = try payload(c, good, reply, "observed");
    const result = try observation(e, good, state, observed);
    try c.author.define(
        e.loop,
        try b.ret(try guarded(
            e,
            b,
            reply,
            try b.field(state, "consumed"),
            try good.ret(result),
        )),
    );
}

fn observation(
    e: Emit,
    b: anytype,
    state: a.Value(State),
    observed: a.Value(m.Observation),
) !a.Value(m.Result) {
    const c = e.context;
    const value = try b.field(observed, "state");
    const expected = try b.field(observed, "expected");
    const running = try b.caseOf(value, "running");
    const waiting = try b.caseOf(value, "waiting");
    const port = try b.caseOf(value, "port");
    const done = try b.caseOf(value, "done");
    const failed = try b.caseOf(value, "fault");
    const wb = waiting.body();
    const inspected = try work(
        e,
        wb,
        try wb.field(state, "input"),
        "inspect",
        try wb.product(try c.schema(@FieldType(w.Work, "inspect")), .{
            .work = try wb.field(expected, "work"),
        }),
    );
    return b.match(
        value,
        .{
            .waiting = try waiting.ret(try wb.call(
                e.loop,
                .{ .state = state, .reply = inspected },
            )),
            .running = try running.ret(try advance(e, running.body(), state, expected)),
            .port = try port.ret(try atPort(e, port.body(), state, expected, port.payload())),
            .done = try done.ret(try readValue(
                e,
                done.body(),
                state,
                expected,
                done.payload(),
                try c.literal(?m.Port, null),
            )),
            .fault = try failed.ret(try fault(
                c,
                failed.body(),
                failed.payload(),
                try failed.body().field(state, "consumed"),
            )),
        },
    );
}

fn advance(
    e: Emit,
    b: anytype,
    state: a.Value(State),
    expected: a.Value(w.Expected),
) !a.Value(m.Result) {
    if (e.max_advances == null) {
        const reply = try work(e, b, try b.field(state, "input"), "advance", expected);
        return b.call(e.loop, .{ .state = state, .reply = reply });
    }
    const allowed = try b.branch();
    const next = try allowed.update(state, .{
        .advances = try allowed.checked(
            .add,
            try allowed.field(state, "advances"),
            try allowed.constant(u32, 1),
            .{ .overflow = try a.failure(e.context, "method_advance_overflow") },
        ),
    });
    const reply = try work(e, allowed, try allowed.field(state, "input"), "advance", expected);
    const output = try allowed.call(e.loop, .{ .state = next, .reply = reply });
    const exhausted = try b.branch();
    return b.conditional(
        try b.less(try b.field(state, "advances"), try b.constant(u32, e.max_advances.?)),
        try allowed.ret(output),
        try exhausted.ret(try cancel(e, exhausted, state, expected, "MethodAdvanceLimit")),
    );
}

fn cancel(
    e: Emit,
    b: anytype,
    state: a.Value(State),
    expected: a.Value(w.Expected),
    reason: []const u8,
) !a.Value(m.Result) {
    _ = try work(
        e,
        b,
        try b.field(state, "input"),
        "cancel",
        try b.product(
            try e.context.schema(@FieldType(w.Work, "cancel")),
            .{
                .expected = expected,
                .reason = try e.context.literal(cts.Text(256), .{ .bytes = reason }),
            },
        ),
    );
    return fault(
        e.context,
        b,
        try e.context.literal(t.Name, .{ .bytes = reason }),
        try b.field(state, "consumed"),
    );
}

fn atPort(
    e: Emit,
    b: anytype,
    state: a.Value(State),
    expected: a.Value(w.Expected),
    port: a.Value(m.Port),
) !a.Value(m.Result) {
    const c = e.context;
    const second = try b.branch();
    const first = try b.branch();
    const input = try first.field(state, "input");
    const configured = try first.field(input, "model");
    const absent = try first.caseOf(configured, "none");
    const present = try first.caseOf(configured, "some");
    const pb = present.body();
    const result = try first.match(
        configured,
        .{
            .none = try absent.ret(try cancel(
                e,
                absent.body(),
                state,
                expected,
                "MethodModelMissing",
            )),
            .some = try present.ret(try readValue(
                e,
                pb,
                state,
                expected,
                try pb.field(port, "reference"),
                try pb.variant(try c.schema(?m.Port), "some", port),
            )),
        },
    );
    return b.conditional(
        try b.field(state, "consumed"),
        try second.ret(try cancel(
            e,
            second,
            state,
            expected,
            "MethodCompletionLimit",
        )),
        try first.ret(result),
    );
}

fn readValue(
    e: Emit,
    b: anytype,
    state: a.Value(State),
    expected: a.Value(w.Expected),
    reference: a.Value(w.Ref),
    port: a.Value(?m.Port),
) !a.Value(m.Result) {
    return b.call(
        e.pages,
        .{ .page = try b.product(
            try e.context.schema(PageState),
            .{
                .state = state,
                .expected = expected,
                .reference = reference,
                .port = port,
                .text = try e.context.literal(m.JsonText, .{ .bytes = "" }),
                .offset = try b.constant(u64, 0),
                .total = try e.context.literal(?u64, null),
            },
        ) },
    );
}

fn pagesBody(e: Emit) !void {
    const c = e.context;
    const b = try c.author.body(e.pages);
    const selected = try b.parameter("page");
    const state = try b.field(selected, "state");
    const offset = try b.field(selected, "offset");
    const expanded = try command(
        e,
        b,
        try b.field(state, "input"),
        try b.variant(
            try c.schema(w.Command),
            "context",
            try b.variant(
                try c.schema(w.Context),
                "expand",
                try b.product(
                    try c.schema(@FieldType(w.Context, "expand")),
                    .{
                        .reference = try b.field(selected, "reference"),
                        .page = try b.product(
                            try c.schema(w.Page),
                            .{
                                .offset = offset,
                                .maximum = try b.constant(u32, 48 * 1024),
                            },
                        ),
                    },
                ),
            ),
        ),
    );
    const reply = try codec(
        e,
        b,
        "page",
        try b.product(
            try c.schema(@FieldType(m.CodecRequest, "page")),
            .{
                .reply = expanded,
                .offset = offset,
            },
        ),
    );
    const good = try b.branch();
    const page = try payload(c, good, reply, "page");
    const result = try appendPage(e, good, selected, page);
    try c.author.define(
        e.pages,
        try b.ret(try guarded(
            e,
            b,
            reply,
            try b.field(state, "consumed"),
            try good.ret(result),
        )),
    );
}

fn appendPage(
    e: Emit,
    b: anytype,
    selected: a.Value(PageState),
    page: a.Value(m.Page),
) !a.Value(m.Result) {
    const c = e.context;
    const text = try b.blobConcat(
        try c.schema(m.JsonText),
        try b.field(selected, "text"),
        try b.field(page, "text"),
        try a.failure(c, "method_page_bound"),
    );
    const total = try b.field(selected, "total");
    const missing = try b.caseOf(total, "none");
    const found = try b.caseOf(total, "some");
    const coherent = try b.match(
        total,
        .{
            .none = try missing.ret(try missing.body().constant(bool, true)),
            .some = try found.ret(try found.body().equal(
                found.payload(),
                try b.field(page, "total"),
            )),
        },
    );
    try a.require(c, b, coherent, "method_page_identity");
    const done = try b.branch();
    const more = try b.branch();
    const next = try more.update(
        selected,
        .{
            .text = text,
            .offset = try more.field(page, "next"),
            .total = try more.variant(
                try c.schema(?u64),
                "some",
                try more.field(page, "total"),
            ),
        },
    );
    return b.conditional(
        try b.field(page, "eof"),
        try done.ret(try decodedValue(e, done, selected, text)),
        try more.ret(try more.call(e.pages, .{ .page = next })),
    );
}

fn decodedValue(
    e: Emit,
    b: anytype,
    selected: a.Value(PageState),
    text: a.Value(m.JsonText),
) !a.Value(m.Result) {
    const port = try b.field(selected, "port");
    const output = try b.caseOf(port, "none");
    const request = try b.caseOf(port, "some");
    return b.match(
        port,
        .{
            .none = try output.ret(try outputValue(e, output.body(), selected, text)),
            .some = try request.ret(try completionRequest(
                e,
                request.body(),
                selected,
                request.payload(),
                text,
            )),
        },
    );
}

fn outputValue(
    e: Emit,
    b: anytype,
    selected: a.Value(PageState),
    text: a.Value(m.JsonText),
) !a.Value(m.Result) {
    const c = e.context;
    const reply = try codec(e, b, "output", text);
    const good = try b.branch();
    const consumed = try b.field(try b.field(selected, "state"), "consumed");
    const result = try good.product(
        try c.schema(m.Result),
        .{
            .outcome = try good.variant(
                try c.schema(@FieldType(m.Result, "outcome")),
                "success",
                try payload(c, good, reply, "output"),
            ),
            .model_consumed = consumed,
        },
    );
    return guarded(e, b, reply, consumed, try good.ret(result));
}

fn completionRequest(
    e: Emit,
    b: anytype,
    selected: a.Value(PageState),
    port: a.Value(m.Port),
    text: a.Value(m.JsonText),
) !a.Value(m.Result) {
    const c = e.context;
    const reply = try codec(e, b, "payload", text);
    const good = try b.branch();
    const request = try payload(c, good, reply, "payload");
    const state = try good.field(selected, "state");
    const input = try good.field(state, "input");
    const binding = try good.variantPayload(
        try good.field(input, "model"),
        "some",
        try a.failure(c, "method_model_binding"),
    );
    const response = try good.call(
        e.completion,
        .{ .input = try good.product(
            try c.schema(model_contract.Input),
            .{
                .binding = binding,
                .phase = try c.literal(
                    @FieldType(model_contract.Input, "phase"),
                    .summary,
                ),
                .context = try good.field(request, "context"),
                .initiating_input = try good.field(input, "initiating_input"),
                .target = try c.literal(?t.Id, null),
                .expected_revision = try c.literal(?u64, null),
                .proposal_offers = try c.literal(
                    @FieldType(model_contract.Input, "proposal_offers"),
                    .{ .items = &.{} },
                ),
                .genesis_template = try c.literal(?t.Specification, null),
            },
        ) },
    );
    const consumed = try good.update(
        state,
        .{ .consumed = try good.constant(bool, true) },
    );
    const answer = try candidate(e, good, try good.field(response, "candidate"));
    const result = try resumePort(
        e,
        good,
        consumed,
        try good.field(selected, "expected"),
        port,
        answer,
    );
    return guarded(
        e,
        b,
        reply,
        try b.constant(bool, false),
        try good.ret(result),
    );
}

fn candidate(
    e: Emit,
    b: anytype,
    value: a.Value(model_contract.Candidate),
) !a.Value(m.CompletionReply) {
    const c = e.context;
    const summary = try b.caseOf(value, "summary");
    const rejected = try b.caseOf(value, "rejected");
    const conversation = try b.caseOf(value, "conversation");
    return b.match(
        value,
        .{
            .summary = try summary.ret(try summary.body().variant(
                try c.schema(m.CompletionReply),
                "summary",
                summary.payload(),
            )),
            .rejected = try rejected.ret(try c.literal(m.CompletionReply, .{ .rejected = {} })),
            .conversation = try conversation.ret(try c.literal(
                m.CompletionReply,
                .{ .rejected = {} },
            )),
        },
    );
}

fn resumePort(
    e: Emit,
    b: anytype,
    state: a.Value(State),
    expected: a.Value(w.Expected),
    port: a.Value(m.Port),
    value: a.Value(m.CompletionReply),
) !a.Value(m.Result) {
    const c = e.context;
    const reply = try codec(e, b, "encode_reply", value);
    const good = try b.branch();
    const argument = try good.variant(
        try c.schema(w.ValueInput),
        "inline_json",
        try good.product(
            try c.schema(@FieldType(w.ValueInput, "inline_json")),
            .{
                .schema = try good.field(port, "argument_schema"),
                .json_text = try payload(c, good, reply, "encoded"),
            },
        ),
    );
    const command_value = try good.product(
        try c.schema(@FieldType(w.Work, "interact")),
        .{
            .expected = expected,
            .port = try good.field(port, "reference"),
            .generation = try good.field(port, "generation"),
            .command = try good.variant(
                try c.schema(@FieldType(@FieldType(w.Work, "interact"), "command")),
                "resume_value",
                argument,
            ),
        },
    );
    const interacted = try work(
        e,
        good,
        try good.field(state, "input"),
        "interact",
        command_value,
    );
    const result = try good.call(e.loop, .{ .state = state, .reply = interacted });
    return guarded(
        e,
        b,
        reply,
        try b.constant(bool, true),
        try good.ret(result),
    );
}
