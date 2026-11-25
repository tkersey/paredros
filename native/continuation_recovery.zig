const std = @import("std");
const idx = @import("index.zig");
const recovery = @import("recovery_status.zig");

pub fn advance(driver: anytype, a: std.mem.Allocator, limit: u32) !u32 {
    if (!driver.attached) return error.DriverDetached;
    if (limit == 0) return error.InvalidRecoveryLimit;
    var indexed = try driver.view(a);
    defer indexed.deinit();
    var resumed: u32 = 0;
    for (indexed.index.records) |record| {
        if (record.superseded or record.result != null or
            record.input == .step or record.input == .turn) continue;
        if (resumed == limit) break;
        const outcome = try driver.guarded(
            .{ .item = record.task, .work = .retained },
            recovery.Resume,
            resumeOne,
            .{ driver, a, record },
        );
        if (outcome == recovery.Resume.resumed) resumed += 1;
    }
    return resumed;
}

fn resumeOne(driver: anytype, a: std.mem.Allocator, record: idx.Record) !recovery.Resume {
    const service = driver.service;
    var saved = try service.task(a, record.task);
    defer saved.deinit();
    const action = recovery.classify(
        try service.status(a, saved.value),
        saved.value.blocker,
        saved.value.current_occurrence,
        record.owner_snapshot orelse return error.MissingOwnerSnapshot,
    );
    return recovery.resumeSelected(
        driver,
        a,
        record.task,
        saved.value.revision,
        action,
        saved.value.current_occurrence,
    );
}
