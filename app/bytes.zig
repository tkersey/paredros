const protean = @import("protean");
const a = @import("author.zig");

pub fn Parameters(comptime length: usize) type {
    return struct { left: [length]u8, right: [length]u8 };
}

pub fn emit(c: protean.Context, comptime length: usize) !a.Function(Parameters(length), bool) {
    const function = try c.author.function("compare fixed bytes", .{
        .left = try c.schema([length]u8),
        .right = try c.schema([length]u8),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const left = try b.parameter("left");
    const right = try b.parameter("right");
    const result = try compare(c, b, length, left, right, 0);
    try c.author.define(function, try b.ret(result));
    return function;
}

fn compare(
    c: protean.Context,
    b: anytype,
    comptime length: usize,
    left: a.Value([length]u8),
    right: a.Value([length]u8),
    comptime start: usize,
) anyerror!a.Value(bool) {
    const end = @min(start + 8, length);
    const failure = try a.failure(c, "fixed_byte_bounds");
    const different = try b.constant(bool, false);
    var equal = try b.constant(bool, true);
    for (start..end) |i| {
        const at = try b.constant(u64, i);
        const x = try b.variantPayload(try b.sequenceGet(left, at), "some", failure);
        const y = try b.variantPayload(try b.sequenceGet(right, at), "some", failure);
        equal = try b.select(equal, try b.equal(x, y), different);
    }
    if (end == length) return equal;
    const more = try b.branch();
    const done = try b.branch();
    return b.conditional(equal, try more.ret(try compare(c, more, length, left, right, end)), try done.ret(different));
}
