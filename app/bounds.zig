const std = @import("std");
const t = @import("application_types");

pub const Bound = struct { min: u64, max: u64 };
pub const day_ms: u64 = 24 * 60 * 60 * 1000;
pub const interval_ms_max: u64 = 366 * day_ms;
pub const instant_ms_max: i64 = 253_402_300_799_999;
pub const phase_retry_ms: i64 = 60_000;
pub const phase_attempts_max: u32 = 20;
pub const interval: Bound = .{ .min = 1, .max = interval_ms_max };
pub const anchor: Bound = .{ .min = 0, .max = instant_ms_max };
pub const policies = .{
    .notification_interval_ms = Bound{ .min = 0, .max = interval_ms_max },
    .clock_regression_tolerance_ms = Bound{ .min = 0, .max = interval_ms_max },
    .phase_attempts = Bound{ .min = 1, .max = phase_attempts_max },
    .method_faults = Bound{ .min = 1, .max = 1000 },
    .render_input_bytes = Bound{ .min = 256, .max = 1024 * 1024 },
    .context_bytes = Bound{ .min = 256, .max = 248 * 1024 },
};

comptime {
    const names = @typeInfo(t.Policies).@"struct".field_names;
    if (names.len != @typeInfo(@TypeOf(policies)).@"struct".field_names.len)
        @compileError("every policy needs exactly one bound");
    for (names) |name| _ = @field(policies, name);
    std.debug.assert(phase_retry_ms << (phase_attempts_max - 1) <= interval_ms_max);
    std.debug.assert(instant_ms_max + 2 * @as(i64, interval_ms_max) < std.math.maxInt(i64));
}

pub const Violation = enum { interval, anchor, policy };

pub fn within(bound: Bound, value: anytype) bool {
    return value >= bound.min and value <= bound.max;
}

pub fn instant(value: i64) bool {
    return value >= 0 and value <= instant_ms_max;
}

pub fn violation(specification: t.Specification) ?Violation {
    if (!within(interval, specification.interval_ms)) return .interval;
    if (!instant(specification.anchor_ms)) return .anchor;
    if (!policiesWithin(specification.policies)) return .policy;
    return null;
}

pub fn policiesWithin(value: t.Policies) bool {
    inline for (@typeInfo(t.Policies).@"struct".field_names) |name|
        if (!within(@field(policies, name), @field(value, name))) return false;
    return true;
}
