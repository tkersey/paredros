const std = @import("std");
const idx = @import("index.zig");
const recovery = @import("recovery_status.zig");
const outbound = @import("outbound.zig");
const materialize = @import("materialize.zig");

pub fn advance(driver: anytype, a: std.mem.Allocator, limit: u32) !u32 {
    if (!driver.attached) return error.DriverDetached;
    if (limit == 0) return error.InvalidRecoveryLimit;
    var index = try driver.rebuild(a);
    defer index.deinit();
    const clock_ms = try driver.clock.now(driver.clock.context);
    var resumed: u32 = 0;
    for (index.records) |record| {
        if (record.superseded or record.result != null or
            record.input == .step or record.input == .turn) continue;
        if (resumed == limit) break;
        if (record.input == .delivery) {
            if (try retire(driver.service, a, &index, record)) resumed += 1;
            if (!try outbound.resumable(a, &index, record.input.delivery, clock_ms)) continue;
        }
        if (try resumeOne(driver.service, a, record) == .resumed) resumed += 1;
    }
    return resumed;
}

fn resumeOne(service: anytype, a: std.mem.Allocator, record: idx.Record) !recovery.Resume {
    var saved = try service.task(a, record.task);
    defer saved.deinit();
    const action = recovery.classify(
        try service.status(a, saved.value),
        saved.value.blocker,
        saved.value.current_occurrence,
        record.owner_snapshot orelse return error.MissingOwnerSnapshot,
    );
    return recovery.resumeSelected(
        service,
        a,
        record.task,
        saved.value.revision,
        action,
        saved.value.current_occurrence,
    );
}

fn retire(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: idx.Record,
) !bool {
    if (!materialize.retirable(index, record)) return false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const operation = try std.fmt.allocPrint(scratch, "legacy-retire:{s}:{d}", .{
        std.fmt.bytesToHex(record.task, .lower), record.revision,
    });
    _ = try service.requestCancel(scratch, operation, record.task, "retired Slack-era digest");
    return true;
}
