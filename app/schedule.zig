const std = @import("std");

pub const State = struct {
    anchor_ms: i64,
    interval_ms: u64,
    next_due_ms: i64,
    last_clock_ms: i64,
};

pub const Observation = struct {
    now_ms: i64,
    due: bool,
    skipped_slots: u64,
    clock_regressed: bool,
    next_due_ms: i64,
};

pub fn firstAfter(anchor_ms: i64, interval_ms: u64, now_ms: i64) !i64 {
    if (interval_ms == 0) return error.InvalidInterval;
    const delta = @as(i128, now_ms) - anchor_ms;
    const ordinal = @max(0, @divFloor(delta, interval_ms) + 1);
    const next = @as(i128, anchor_ms) + ordinal * interval_ms;
    return std.math.cast(i64, next) orelse error.ScheduleOverflow;
}

pub fn observe(
    state: State,
    now_ms: i64,
    regression_tolerance_ms: u64,
    manual_check: bool,
) !Observation {
    if (state.interval_ms == 0) return error.InvalidInterval;
    const regressed = @as(i128, state.last_clock_ms) - now_ms > regression_tolerance_ms;
    const elapsed = @as(i128, now_ms) - state.next_due_ms;
    const scheduled = !regressed and elapsed >= 0;
    const skipped: u64 = if (scheduled) @intCast(@divFloor(elapsed, state.interval_ms)) else 0;
    return .{
        .now_ms = now_ms,
        .due = manual_check or scheduled,
        .skipped_slots = skipped,
        .clock_regressed = regressed,
        .next_due_ms = if (regressed or scheduled)
            try firstAfter(state.anchor_ms, state.interval_ms, now_ms)
        else
            state.next_due_ms,
    };
}

pub const ProviderBackoff = struct {
    admitted_wait_ms: u64,
    started_monotonic_ms: i64,

    pub fn remaining(self: ProviderBackoff, now_monotonic_ms: i64) u64 {
        const elapsed = @as(i128, now_monotonic_ms) - self.started_monotonic_ms;
        if (elapsed <= 0) return self.admitted_wait_ms;
        if (elapsed >= self.admitted_wait_ms) return 0;
        return self.admitted_wait_ms - @as(u64, @intCast(elapsed));
    }

    pub fn afterRestart(admitted_wait_ms: u64, now_monotonic_ms: i64) ProviderBackoff {
        return .{ .admitted_wait_ms = admitted_wait_ms, .started_monotonic_ms = now_monotonic_ms };
    }
};

pub const Phase = enum { fold, check, render };
pub const PhaseInputs = struct {
    active: bool,
    check_due: bool,
    check_backoff: bool,
    renderable_prefix: bool,
    unresolved_digest: bool,
    send_backoff: bool,
    previous_phase: Phase,
    previous_check_overran: bool,
};

pub fn phase(input: PhaseInputs) Phase {
    if (!input.active) return .fold;
    const render = input.renderable_prefix and !input.unresolved_digest and !input.send_backoff;
    if (input.check_due and !input.check_backoff) {
        if (render and input.previous_phase == .check and input.previous_check_overran)
            return .render;
        return .check;
    }
    return if (render) .render else .fold;
}
