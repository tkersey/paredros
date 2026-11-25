const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");

pub const Control = enum { pause, @"resume", cancel, transfer };
pub const Input = struct { head: t.Head, control: Control };
pub const Function = a.Function(struct { input: Input }, t.Head);

pub fn emit(c: protean.Context) !Function {
    const function = try c.author.function("fold responsibility mode", .{
        .input = try c.schema(Input),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const control = try b.field(input, "control");
    const old_mode = try b.field(head, "mode");
    const final = try b.select(
        try enumIs(c, b, t.Mode, old_mode, .cancelled),
        try b.constant(bool, true),
        try enumIs(c, b, t.Mode, old_mode, .transferred),
    );
    const desired = try b.select(
        try enumIs(c, b, Control, control, .cancel),
        try c.literal(@FieldType(t.Head, "desired_mode"), .cancelled),
        try b.select(
            try enumIs(c, b, Control, control, .@"resume"),
            try c.literal(@FieldType(t.Head, "desired_mode"), .active),
            try b.select(
                try enumIs(c, b, Control, control, .pause),
                try c.literal(@FieldType(t.Head, "desired_mode"), .paused),
                try b.field(head, "desired_mode"),
            ),
        ),
    );
    const next = try b.update(head, .{
        .mode = try nextMode(c, b, control),
        .desired_mode = desired,
    });
    try c.author.define(function, try b.ret(try b.select(final, head, next)));
    return function;
}

fn nextMode(c: protean.Context, b: anytype, control: a.Value(Control)) !a.Value(t.Mode) {
    const continued = try b.select(
        try enumIs(c, b, Control, control, .pause),
        try c.literal(t.Mode, .paused),
        try c.literal(t.Mode, .active),
    );
    const transferred = try b.select(
        try enumIs(c, b, Control, control, .transfer),
        try c.literal(t.Mode, .transferred),
        continued,
    );
    return b.select(
        try enumIs(c, b, Control, control, .cancel),
        try c.literal(t.Mode, .cancelled),
        transferred,
    );
}

pub fn enumIs(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    value: a.Value(T),
    expected: T,
) !a.Value(bool) {
    return b.equal(try b.enumTag(value), try b.enumTag(try c.literal(T, expected)));
}
