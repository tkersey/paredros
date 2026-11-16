const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const catalog = @import("catalog.zig");
const recovery_status = @import("recovery_status.zig");

pub fn advance(driver: anytype, a: std.mem.Allocator, limit: u32) ![]t.Id {
    if (!driver.attached) return error.DriverDetached;
    if (limit == 0) return error.InvalidTurnLimit;
    var index = try driver.rebuild(a);
    defer index.deinit();
    var admitted: std.ArrayList(t.Id) = .empty;
    errdefer admitted.deinit(a);
    for (index.records) |record| {
        if (record.input != .turn or record.superseded or record.result != null) continue;
        if (admitted.items.len == limit) break;
        if (try advanceOne(driver, a, record)) |task| try admitted.append(a, task);
    }
    return admitted.toOwnedSlice(a);
}

fn advanceOne(driver: anytype, a: std.mem.Allocator, record: idx.Record) !?t.Id {
    var saved = try driver.service.task(a, record.task);
    defer saved.deinit();
    const status = try driver.service.status(a, saved.value);
    const action = recovery_status.classify(status, saved.value.blocker, saved.value.current_occurrence, record.owner_snapshot orelse return error.MissingOwnerSnapshot);
    if (action == .replace) {
        if (record.input.turn.attempt >= 2) return null;
        return try replace(driver, a, record);
    }
    const resumed = try recovery_status.resumeSelected(driver.service, a, record.task, saved.value.revision, action, saved.value.current_occurrence);
    if (resumed == .incompatible and record.input.turn.attempt < 2)
        return try replace(driver, a, record);
    return null;
}

fn replace(driver: anytype, a: std.mem.Allocator, record: idx.Record) !t.Id {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const operation = try std.fmt.allocPrint(scratch, "turn-replace:{s}", .{
        std.fmt.bytesToHex(record.task, .lower),
    });
    const cancelled = try driver.service.requestCancel(
        scratch,
        operation,
        record.task,
        "superseded conversation attempt",
    );
    var current = try catalog.rebuild(driver.service, scratch, driver.page_limit);
    defer current.deinit();
    const old = current.record(record.task) orelse return error.MissingTurn;
    if (old.input != .turn or old.superseded or old.result != null)
        return error.StaleTurnReplacement;
    var owner = try retained.load(driver.service, scratch, old.task, driver.page_limit);
    defer owner.deinit();
    var next = old.input.turn;
    next.attempt = try std.math.add(u32, next.attempt, 1);
    next.envelope.operation = .{ .bytes = try std.fmt.allocPrint(scratch, "turn-retry:{s}:{d}", .{
        std.fmt.bytesToHex(old.task, .lower), next.attempt,
    }) };
    next.replacement = .{
        .input = .{ .task = old.task, .digest = old.input_digest },
        .attempt = old.input.turn.attempt,
        .cancellation = .{
            .task = old.task,
            .operation = .{ .bytes = operation },
            .bytes = .{ .bytes = try c.encodeOwned(@TypeOf(cancelled.receipt), scratch, cancelled.receipt) },
        },
        .reference = owner.snapshot.reference,
        .owner_snapshot = .{ .bytes = owner.snapshot.bytes },
    };
    return (try driver.service.submit(scratch, next.envelope.operation.bytes, .{ .turn = next })).receipt.task;
}
