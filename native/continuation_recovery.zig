const std = @import("std");
const recovery = @import("recovery_status.zig");

pub fn advance(driver: anytype, a: std.mem.Allocator, limit: u32) !u32 {
    if (!driver.attached) return error.DriverDetached;
    if (limit == 0) return error.InvalidRecoveryLimit;
    var index = try driver.rebuild(a);
    defer index.deinit();
    var resumed: u32 = 0;
    for (index.records) |record| {
        if (record.superseded or record.result != null or
            record.input == .step or record.input == .turn) continue;
        if (resumed == limit) break;
        var saved = try driver.service.task(a, record.task);
        defer saved.deinit();
        const action = recovery.classify(
            try driver.service.status(a, saved.value),
            saved.value.blocker,
            saved.value.current_occurrence,
            record.owner_snapshot orelse return error.MissingOwnerSnapshot,
        );
        if (try recovery.resumeSelected(
            driver.service,
            a,
            record.task,
            saved.value.revision,
            action,
            saved.value.current_occurrence,
        ) == .resumed) resumed += 1;
    }
    return resumed;
}
