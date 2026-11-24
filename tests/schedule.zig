const std = @import("std");
const schedule = @import("../app/schedule.zig");

test "schedule coalesces missed slots without shifting the anchor" {
    const state: schedule.State = .{
        .anchor_ms = 100,
        .interval_ms = 900_000,
        .next_due_ms = 900_100,
        .last_clock_ms = 100,
    };
    const delayed = try schedule.observe(state, 3_600_101, 300_000, false);
    try std.testing.expect(delayed.due);
    try std.testing.expectEqual(3, delayed.skipped_slots);
    try std.testing.expectEqual(4_500_100, delayed.next_due_ms);
    var successor = state;
    successor.last_clock_ms = delayed.now_ms;
    successor.next_due_ms = delayed.next_due_ms;
    const repeat = try schedule.observe(successor, delayed.now_ms, 300_000, false);
    try std.testing.expect(!repeat.due);
    try std.testing.expectEqual(0, repeat.skipped_slots);
    const manual = try schedule.observe(successor, delayed.now_ms, 300_000, true);
    try std.testing.expect(manual.due);
    try std.testing.expectEqual(successor.next_due_ms, manual.next_due_ms);
}

test "clock regression recomputes schedule while provider backoff preserves duration" {
    const state: schedule.State = .{
        .anchor_ms = 100,
        .interval_ms = 900_000,
        .next_due_ms = 4_500_100,
        .last_clock_ms = 3_600_100,
    };
    const regressed = try schedule.observe(state, 1_800_100, 300_000, false);
    try std.testing.expect(regressed.clock_regressed);
    try std.testing.expect(!regressed.due);
    try std.testing.expectEqual(2_700_100, regressed.next_due_ms);
    const retry: schedule.ProviderBackoff = .{
        .admitted_wait_ms = 60_000,
        .started_monotonic_ms = 50_000,
    };
    try std.testing.expectEqual(59_000, retry.remaining(51_000));
    try std.testing.expectEqual(60_000, retry.remaining(40_000));
    const restarted = schedule.ProviderBackoff.afterRestart(60_000, 2_000);
    try std.testing.expectEqual(60_000, restarted.remaining(2_000));
    try std.testing.expectEqual(0, restarted.remaining(62_000));
}

test "anchor arithmetic is strict and checked across signed timestamp boundaries" {
    try std.testing.expectEqual(-900, try schedule.firstAfter(-1_900, 1_000, -1_000));
    try std.testing.expectEqual(100, try schedule.firstAfter(-1_900, 1_000, -900));
    try std.testing.expectEqual(100, try schedule.firstAfter(100, 1_000, -1_000));
    try std.testing.expectEqual(1_100, try schedule.firstAfter(100, 1_000, 100));
    try std.testing.expectError(error.InvalidInterval, schedule.firstAfter(0, 0, 0));
    try std.testing.expectError(
        error.ScheduleOverflow,
        schedule.firstAfter(0, 1, std.math.maxInt(i64)),
    );
    try std.testing.expectEqual(0, try schedule.firstAfter(0, std.math.maxInt(u64), -1));
}

test "phase policy observes before rendering and prevents sustained check starvation" {
    var inputs: schedule.PhaseInputs = .{
        .active = true,
        .check_due = true,
        .check_backoff = false,
        .renderable_prefix = false,
        .send_backoff = false,
        .previous_phase = .check,
        .previous_check_overran = true,
    };
    try std.testing.expectEqual(.check, schedule.phase(inputs));
    inputs.renderable_prefix = true;
    try std.testing.expectEqual(.render, schedule.phase(inputs));
    inputs.previous_phase = .render;
    try std.testing.expectEqual(.check, schedule.phase(inputs));
    inputs.check_backoff = true;
    try std.testing.expectEqual(.render, schedule.phase(inputs));
    inputs.send_backoff = true;
    try std.testing.expectEqual(.fold, schedule.phase(inputs));
    inputs.active = false;
    inputs.send_backoff = false;
    inputs.check_backoff = false;
    try std.testing.expectEqual(.fold, schedule.phase(inputs));
}
