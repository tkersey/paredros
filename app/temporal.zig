const std = @import("std");
const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");

pub const Input = struct { anchor_ms: i64, interval_ms: u64, clock_ms: i64 };
pub const Function = a.Function(struct { input: Input }, i64);
const Shift = a.Function(struct { value: i64 }, u64);
const Restore = a.Function(struct { value: u64 }, i64);

pub fn emit(c: protean.Context) !Function {
    const shift = try shiftFunction(c);
    const restore = try restoreFunction(c);
    const function = try c.author.function("next anchored instant", .{
        .input = try c.schema(Input),
    }, try c.schema(i64), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const anchor = try b.field(input, "anchor_ms");
    const now = try b.field(input, "clock_ms");
    const interval = try b.field(input, "interval_ms");
    try a.require(c, b, try b.less(try b.constant(u64, 0), interval), "invalid_interval");
    const before = try b.branch();
    const after = try b.branch();
    const shifted_anchor = try after.call(shift, .{ .value = anchor });
    const shifted_now = try after.call(shift, .{ .value = now });
    const overflow = try a.failure(c, "schedule_overflow");
    const delta = try after.checked(
        .subtract,
        shifted_now,
        shifted_anchor,
        .{ .overflow = overflow },
    );
    const remainder = try after.checked(.remainder, delta, interval, .{
        .overflow = overflow,
        .division_by_zero = overflow,
    });
    const distance = try after.checked(.subtract, interval, remainder, .{ .overflow = overflow });
    const next = try after.checked(.add, shifted_now, distance, .{ .overflow = overflow });
    const result = try b.conditional(
        try b.less(now, anchor),
        try before.ret(anchor),
        try after.ret(try after.call(restore, .{ .value = next })),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}

fn shiftFunction(c: protean.Context) !Shift {
    const function = try c.author.function("ordered clock code", .{
        .value = try c.schema(i64),
    }, try c.schema(u64), &.{});
    const b = try c.author.body(function);
    const value = try b.parameter("value");
    const negative = try b.branch();
    const positive = try b.branch();
    const overflow = try a.failure(c, "clock_code");
    const shifted = try negative.checked(.subtract, value, try negative.constant(
        i64,
        std.math.minInt(i64),
    ), .{
        .overflow = overflow,
    });
    const low = try negative.convertInteger(try c.schema(u64), shifted, .{ .overflow = overflow });
    const high = try positive.checked(.add, try positive.convertInteger(
        try c.schema(u64),
        value,
        .{ .overflow = overflow },
    ), try positive.constant(u64, 1 << 63), .{ .overflow = overflow });
    const result = try b.conditional(
        try b.less(value, try b.constant(i64, 0)),
        try negative.ret(low),
        try positive.ret(high),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}

fn restoreFunction(c: protean.Context) !Restore {
    const function = try c.author.function("clock from ordered code", .{
        .value = try c.schema(u64),
    }, try c.schema(i64), &.{});
    const b = try c.author.body(function);
    const value = try b.parameter("value");
    const negative = try b.branch();
    const positive = try b.branch();
    const midpoint = try b.constant(u64, 1 << 63);
    const overflow = try a.failure(c, "clock_code");
    const low = try negative.checked(.add, try negative.convertInteger(
        try c.schema(i64),
        value,
        .{ .overflow = overflow },
    ), try negative.constant(i64, std.math.minInt(i64)), .{ .overflow = overflow });
    const shifted = try positive.checked(.subtract, value, midpoint, .{ .overflow = overflow });
    const high = try positive.convertInteger(try c.schema(i64), shifted, .{ .overflow = overflow });
    const result = try b.conditional(
        try b.less(value, midpoint),
        try negative.ret(low),
        try positive.ret(high),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}

pub const ScheduleInput = struct {
    previous_clock_ms: i64,
    clock_ms: i64,
    next_due_ms: i64,
    anchor_ms: i64,
    interval_ms: u64,
    tolerance_ms: u64,
};
pub const ScheduleResult = struct { next_due_ms: i64, skipped_slots: u64, regressed: bool };
pub const Schedule = a.Function(struct { input: ScheduleInput }, ScheduleResult);

pub fn schedule(c: protean.Context) !Schedule {
    const shift = try shiftFunction(c);
    const next = try emit(c);
    const function = try c.author.function("observe anchored schedule without an ambient clock", .{
        .input = try c.schema(ScheduleInput),
    }, try c.schema(ScheduleResult), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const interval = try b.field(input, "interval_ms");
    try a.require(c, b, try b.less(try b.constant(u64, 0), interval), "invalid_interval");
    const now = try b.call(shift, .{ .value = try b.field(input, "clock_ms") });
    const previous = try b.call(shift, .{ .value = try b.field(input, "previous_clock_ms") });
    const due = try b.call(shift, .{ .value = try b.field(input, "next_due_ms") });
    const earlier = try b.branch();
    const later = try b.branch();
    const delta = try earlier.checked(.subtract, previous, now, .{
        .overflow = try a.failure(c, "clock_difference_overflow"),
    });
    const regressed = try b.conditional(
        try b.less(now, previous),
        try earlier.ret(try earlier.less(try earlier.field(input, "tolerance_ms"), delta)),
        try later.ret(try later.constant(bool, false)),
    );
    const corrected = try b.branch();
    const ordinary = try b.branch();
    const corrected_due = try corrected.call(
        next,
        .{ .input = try corrected.product(
            try c.schema(Input),
            .{
                .clock_ms = try corrected.field(input, "clock_ms"),
                .anchor_ms = try corrected.field(input, "anchor_ms"),
                .interval_ms = interval,
            },
        ) },
    );
    const new_due = try b.conditional(
        regressed,
        try corrected.ret(corrected_due),
        try ordinary.ret(try ordinary.field(input, "next_due_ms")),
    );
    const missed = try b.branch();
    const waiting = try b.branch();
    const passed = try missed.checked(.subtract, now, due, .{
        .overflow = try a.failure(c, "schedule_difference_overflow"),
    });
    const skipped = try missed.checked(.divide, passed, interval, .{
        .overflow = try a.failure(c, "schedule_difference_overflow"),
        .division_by_zero = try a.failure(c, "invalid_interval"),
    });
    const due_now = try b.select(
        regressed,
        try b.constant(bool, false),
        try b.booleanNot(try b.less(now, due)),
    );
    const count = try b.conditional(
        due_now,
        try missed.ret(skipped),
        try waiting.ret(try waiting.constant(u64, 0)),
    );
    try c.author.define(function, try b.ret(try b.product(try c.schema(ScheduleResult), .{
        .next_due_ms = new_due,
        .skipped_slots = count,
        .regressed = regressed,
    })));
    return function;
}
