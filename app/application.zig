const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const a = @import("author.zig");
const t = @import("application_types");
const genesis = @import("genesis.zig");
const step = @import("step.zig");
const check = @import("check.zig");
const policy = @import("directive_policy.zig");
const render = @import("render.zig");
const model = @import("model.zig");
const method = @import("method.zig");
const turn = @import("turn.zig");
const experiment = @import("experiment.zig");
const audit = @import("audit.zig");
const github = @import("github_contract.zig");
const history = @import("audit_contract.zig");
const m = @import("model_contract.zig");
const slack = @import("slack_contract.zig");

pub const notification_identity = slack.notification_identity;
const Function = a.Function(struct { input: t.Input }, t.Output);
const Functions = struct {
    genesis: genesis.Function,
    step: step.Function,
    turn: turn.Function,
    audit: audit.Function,
    experiment: experiment.Function,
};

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const completion = try model.emit(c);
        const inference = try m.P.declare(c);
        const reader = try check.emit(c);
        const github_read = try operation(c, reader, github.Request, github.Reply, github.identity);
        const history_reader = try audit.emit(c);
        const history_read = try operation(
            c,
            history_reader,
            history.Request,
            history.Reply,
            history.identity,
        );
        const method_ops = try method.declare(c);
        const render_effects = .{ inference, method_ops.workspace, method_ops.codec };
        const retained = try method.emit(c, method_ops, completion, render_effects);
        const experiment_ops = try experiment.declare(c);
        const experiment_effects = .{
            inference,            method_ops.workspace, method_ops.codec, experiment_ops.codec,
            experiment_ops.clock,
        };
        const functions: Functions = .{
            .genesis = try genesis.emit(c),
            .step = try step.emit(
                c,
                try policy.emit(c),
                reader,
                try render.emit(c, completion, retained, render_effects),
                .{ github_read, inference, method_ops.workspace, method_ops.codec },
            ),
            .turn = try turn.emit(c, completion, .{inference}),
            .audit = history_reader,
            .experiment = try experiment.emit(c, experiment_ops, method_ops, completion, experiment_effects),
        };
        const ordinary = try dispatch(c, functions, .{
            github_read,          inference,            history_read, method_ops.workspace, method_ops.codec,
            experiment_ops.codec, experiment_ops.clock,
        });
        const published = try c.author.module(ordinary, try c.schema(t.Failure));
        const prefix = protean.notification.identity_prefix;
        if (!std.mem.startsWith(u8, notification_identity, prefix))
            return error.InvalidNotificationIdentity;
        const entry = try protean.notification.Dispatcher(t.Input, t.Output).emit(
            c,
            notification_identity[prefix.len..],
            try horos.authoring.interop.functionId(c.author, ordinary),
        );
        return c.builder.module(entry, published.failure);
    }
};

fn operation(
    c: protean.Context,
    function: anytype,
    comptime Payload: type,
    comptime Reply: type,
    identity: []const u8,
) !a.Operation(Payload, Reply) {
    const id = try horos.authoring.interop.functionId(c.author, function);
    const effects = c.builder.functions.items[@intCast(id)].effects;
    if (effects.len != 1 or
        !std.mem.eql(u8, c.builder.effects.items[@intCast(effects[0])].identity, identity))
        return error.UnexpectedProviderEffects;
    return horos.authoring.interop.externalOperation(
        c.author,
        effects[0],
        try c.schema(Payload),
        try c.schema(Reply),
    );
}

fn dispatch(c: protean.Context, functions: Functions, effects: anytype) !Function {
    const function = try c.author.function("dispatch admitted PAREDROS input", .{
        .input = try c.schema(t.Input),
    }, try c.schema(t.Output), effects);
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const initial = try b.caseOf(input, "genesis");
    const advance = try b.caseOf(input, "step");
    const directive = try b.caseOf(input, "directive");
    const delivery = try b.caseOf(input, "delivery");
    const inspect = try b.caseOf(input, "audit");
    const converse = try b.caseOf(input, "turn");
    const compare = try b.caseOf(input, "experiment");
    const member = try b.caseOf(input, "continuity_member");
    const cut = try b.caseOf(input, "continuity_cut");
    const restore = try b.caseOf(input, "restore");
    try envelope(c, directive.body(), directive.payload());
    const result = try b.match(input, .{
        .genesis = try initial.ret(try invoke(
            c,
            initial.body(),
            functions.genesis,
            initial.payload(),
            "genesis",
        )),
        .step = try advance.ret(try invoke(
            c,
            advance.body(),
            functions.step,
            advance.payload(),
            "step",
        )),
        .directive = try directive.ret(try directive.body().variant(
            try c.schema(t.Output),
            "directive",
            directive.payload(),
        )),
        .delivery = try delivery.fail(
            try c.schema(t.Output),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "notification_dispatch_bypass" } }),
        ),
        .audit = try inspect.ret(try invoke(
            c,
            inspect.body(),
            functions.audit,
            inspect.payload(),
            "audit",
        )),
        .turn = try converse.ret(try invoke(
            c,
            converse.body(),
            functions.turn,
            converse.payload(),
            "turn",
        )),
        .experiment = try compare.ret(try invoke(
            c,
            compare.body(),
            functions.experiment,
            compare.payload(),
            "experiment",
        )),
        .continuity_member = try member.ret(try preserve(
            c,
            member.body(),
            member.payload(),
            "continuity_member",
        )),
        .continuity_cut = try cut.ret(try preserve(
            c,
            cut.body(),
            cut.payload(),
            "continuity_cut",
        )),
        .restore = try restore.ret(try preserve(c, restore.body(), restore.payload(), "restore")),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn preserve(c: protean.Context, b: anytype, input: anytype, comptime tag: []const u8) !a.Value(t.Output) {
    try envelope(c, b, input);
    return b.variant(try c.schema(t.Output), tag, input);
}

fn invoke(
    c: protean.Context,
    b: anytype,
    function: anytype,
    input: anytype,
    comptime tag: []const u8,
) !a.Value(t.Output) {
    try envelope(c, b, input);
    return b.variant(try c.schema(t.Output), tag, try b.call(function, .{ .input = input }));
}

fn envelope(c: protean.Context, b: anytype, input: anytype) !void {
    try a.require(
        c,
        b,
        try b.equal(try b.field(try b.field(input, "envelope"), "version"), try b.constant(u32, 1)),
        "unsupported_input_version",
    );
}
