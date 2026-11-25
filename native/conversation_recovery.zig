const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const recovery_status = @import("recovery_status.zig");

pub fn advance(driver: anytype, a: std.mem.Allocator, limit: u32) ![]t.Id {
    if (!driver.attached) return error.DriverDetached;
    if (limit == 0) return error.InvalidTurnLimit;
    var indexed = try driver.view(a);
    defer indexed.deinit();
    var admitted: std.ArrayList(t.Id) = .empty;
    errdefer admitted.deinit(a);
    for (indexed.index.records) |record| {
        if (!recovery_status.recoverableTurn(record)) continue;
        if (admitted.items.len == limit) break;
        const outcome = try driver.guarded(
            .{ .item = record.task, .work = .turn },
            ?t.Id,
            advanceOne,
            .{ driver, a, record },
        );
        if (outcome) |replaced| if (replaced) |task| try admitted.append(a, task);
    }
    return admitted.toOwnedSlice(a);
}

fn advanceOne(driver: anytype, a: std.mem.Allocator, record: idx.Record) !?t.Id {
    const state = try recovery_status.turn(driver.service, a, record);
    if (state.action == .stay) return null;
    if (state.action == .replace) return try replace(driver, a, record);
    const resumed = try recovery_status.resumeSelected(
        driver,
        a,
        record.task,
        state.revision,
        state.action,
        state.occurrence,
    );
    if (resumed == .incompatible) return try replace(driver, a, record);
    return null;
}

fn replace(driver: anytype, a: std.mem.Allocator, record: idx.Record) !t.Id {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const operation = try std.fmt.allocPrint(scratch, "turn-replace:{s}", .{
        std.fmt.bytesToHex(record.task, .lower),
    });
    const cancelled = try driver.requestCancel(
        scratch,
        operation,
        record.task,
        "superseded conversation attempt",
    );
    var indexed = try driver.view(scratch);
    defer indexed.deinit();
    const old = indexed.index.record(record.task) orelse return error.MissingTurn;
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
            .bytes = .{
                .bytes = try c.encodeOwned(@TypeOf(cancelled.receipt), scratch, cancelled.receipt),
            },
        },
        .reference = owner.snapshot.reference,
        .owner_snapshot = .{ .bytes = owner.snapshot.bytes },
    };
    return (try driver.submit(
        scratch,
        next.envelope.operation.bytes,
        .{ .turn = next },
    )).receipt.task;
}
