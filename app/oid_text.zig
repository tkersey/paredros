const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");

pub const Function = a.Function(struct { oid: t.Oid, index: u64, text: cts.Utf8 }, cts.Utf8);

// Both columns are ASCII for a hexadecimal byte. Every other entry is one
// two-byte UTF-8 scalar. A checked slice of its first byte therefore rejects it.
const alphabet = blk: {
    var table: [2 * 256]u8 = undefined;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        table[2 * i ..][0..2].* = switch (byte) {
            '0'...'9', 'a'...'f', 'A'...'F' => .{ byte, byte },
            else => .{ 0xc2, 0x80 },
        };
    }
    break :blk table;
};

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
    const group = try active.branch();
    const tail = try active.branch();
    const next = try active.conditional(
        try active.less(index, try active.constant(u64, 37)),
        try group.ret(try append(c, group, function, oid, index, text, 4)),
        try tail.ret(try append(c, tail, function, oid, index, text, 1)),
    );
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.constant(u64, 40)),
        try active.ret(next),
        try ended.ret(text),
    )));
    return function;
}

fn append(
    c: protean.Context,
    b: anytype,
    function: Function,
    oid: a.Value(t.Oid),
    index: a.Value(u64),
    text: a.Value(cts.Utf8),
    comptime count: usize,
) !a.Value(cts.Utf8) {
    const bounds = try a.failure(c, "render_bounds");
    const invalid = try a.failure(c, "render_invalid_oid");
    const one = try b.constant(u64, 1);
    const table = try c.literal(cts.Utf8, .{ .bytes = &alphabet });
    var position = index;
    var output = text;
    inline for (0..count) |_| {
        const byte = try b.variantPayload(try b.sequenceGet(oid, position), "some", bounds);
        const value = try b.convertInteger(try c.schema(u64), byte, .{});
        const start = try b.checked(.add, value, value, .{ .overflow = bounds });
        const digit = try b.blobSlice(
            try c.schema(cts.Utf8),
            table,
            start,
            try b.checked(.add, start, one, .{ .overflow = bounds }),
            .{ .capacity = bounds, .invalid_utf8 = invalid },
        );
        output = try b.blobConcat(try c.schema(cts.Utf8), output, digit, bounds);
        position = try b.checked(.add, position, one, .{ .overflow = bounds });
    }
    return b.call(function, .{ .oid = oid, .index = position, .text = output });
}

pub fn format(
    c: protean.Context,
    b: anytype,
    function: Function,
    oid: a.Value(t.Oid),
) !a.Value(cts.Utf8) {
    return b.call(
        function,
        .{ .oid = oid, .index = try b.constant(u64, 0), .text = try c.literal(cts.Utf8, .{ .bytes = "" }) },
    );
}
