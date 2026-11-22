const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");

pub const Function = a.Function(struct { oid: t.Oid, index: u64, text: cts.Utf8 }, cts.Utf8);

pub fn emit(c: protean.Context) !Function {
    const function = try c.author.function("verified hexadecimal commit identity", .{
        .oid = try c.schema(t.Oid),
        .index = try c.schema(u64),
        .text = try c.schema(cts.Utf8),
    }, try c.schema(cts.Utf8), &.{});
    const b = try c.author.body(function);
    const oid = try b.parameter("oid");
    const index = try b.parameter("index");
    const text = try b.parameter("text");
    const active = try b.branch();
    const ended = try b.branch();
    const bounds = try a.failure(c, "render_bounds");
    const byte = try active.variantPayload(
        try active.sequenceGet(oid, index),
        "some",
        bounds,
    );
    const table = comptime blk: {
        var values: [256]u8 = @splat(0);
        for ("0123456789abcdefABCDEF") |digit| values[digit] = digit;
        break :blk values;
    };
    const position = try active.convertInteger(try c.schema(u64), byte, .{});
    const digit = try active.variantPayload(
        try active.blobByte(try c.literal(cts.Utf8, .{ .bytes = &table }), position),
        "some",
        bounds,
    );
    try a.require(
        c,
        active,
        try active.less(try active.constant(u8, 0), digit),
        "render_invalid_oid",
    );
    const scalar = try active.convertInteger(try c.schema(u32), digit, .{});
    const character = try active.textScalar(scalar, bounds);
    const next = try active.call(function, .{
        .oid = oid,
        .index = try active.checked(
            .add,
            index,
            try active.constant(u64, 1),
            .{ .overflow = bounds },
        ),
        .text = try active.blobConcat(try c.schema(cts.Utf8), text, character, bounds),
    });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.constant(u64, 40)),
        try active.ret(next),
        try ended.ret(text),
    )));
    return function;
}

pub fn format(
    c: protean.Context,
    b: anytype,
    function: Function,
    oid: a.Value(t.Oid),
) !a.Value(cts.Utf8) {
    return b.call(
        function,
        .{
            .oid = oid,
            .index = try b.constant(u64, 0),
            .text = try c.literal(cts.Utf8, .{ .bytes = "" }),
        },
    );
}
