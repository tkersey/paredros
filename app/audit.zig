const protean = @import("protean");
const t = @import("application_types");
const contract = @import("audit_contract.zig");
const a = @import("author.zig");

pub const Function = a.Function(struct { input: t.Audit }, t.AuditResult);
const Loop = a.Function(struct { request: contract.Request }, t.AuditResult);

pub fn emit(c: protean.Context) !Function {
    const reader = try c.external(
        contract.identity,
        try c.schema(contract.Request),
        try c.schema(contract.Reply),
        .read,
    );
    const loop = try c.author.function("read frozen Slack history window", .{
        .request = try c.schema(contract.Request),
    }, try c.schema(t.AuditResult), .{reader});
    const body = try c.author.body(loop);
    const request = try body.parameter("request");
    const reply = try body.perform(reader, request);
    const next = try body.caseOf(reply, "next");
    const done = try body.caseOf(reply, "done");
    const pages = try body.field(request, "pages");
    const nb = next.body();
    try a.require(c, nb, try nb.less(
        try nb.sequenceLength(pages),
        try nb.convertInteger(
            try c.schema(u64),
            try nb.field(try nb.field(request, "audit"), "page_limit"),
            .{},
        ),
    ), "slack_audit_page_limit");
    const successor = try nb.update(request, .{
        .pages = try nb.append(pages, next.payload(), .{}),
    });
    try c.author.define(loop, try body.ret(try body.match(reply, .{
        .next = try next.ret(try nb.call(loop, .{ .request = successor })),
        .done = try done.ret(done.payload()),
    })));
    return entry(c, loop, reader);
}

fn entry(
    c: protean.Context,
    loop: Loop,
    reader: a.Operation(contract.Request, contract.Reply),
) !Function {
    const function = try c.author.function("audit admitted Slack delivery", .{
        .input = try c.schema(t.Audit),
    }, try c.schema(t.AuditResult), .{reader});
    const b = try c.author.body(function);
    const request = try b.product(try c.schema(contract.Request), .{
        .audit = try b.parameter("input"),
        .pages = try c.literal(contract.Pages, .{ .items = &.{} }),
    });
    try c.author.define(function, try b.ret(try b.call(loop, .{ .request = request })));
    return function;
}
