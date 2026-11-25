const protean = @import("protean");
const a = @import("author.zig");

pub fn Parameters(comptime length: usize) type {
    return struct { left: [length]u8, right: [length]u8, index: u64 };
}

pub fn emit(c: protean.Context, comptime length: usize) !a.Function(Parameters(length), bool) {
    const function = try c.author.function("compare fixed bytes", .{
        .left = try c.schema([length]u8),
        .right = try c.schema([length]u8),
        .index = try c.schema(u64),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const left = try b.parameter("left");
    const right = try b.parameter("right");
    const index = try b.parameter("index");
    const ended = try b.branch();
    const active = try b.branch();
    const failure = try a.failure(c, "fixed_byte_bounds");
    const x = try active.variantPayload(try active.sequenceGet(left, index), "some", failure);
    const y = try active.variantPayload(try active.sequenceGet(right, index), "some", failure);
    const equal = try active.branch();
    const different = try active.branch();
    const next = try equal.call(function, .{
        .left = left,
        .right = right,
        .index = try equal.checked(
            .add,
            index,
            try equal.constant(u64, 1),
            .{ .overflow = failure },
        ),
    });
    const compared = try active.conditional(
        try active.equal(x, y),
        try equal.ret(next),
        try different.ret(try different.constant(bool, false)),
    );
    const result = try b.conditional(
        try b.less(index, try b.constant(u64, length)),
        try active.ret(compared),
        try ended.ret(try ended.constant(bool, true)),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}
