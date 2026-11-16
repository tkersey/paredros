const std = @import("std");
const t = @import("application_types");
const restore = @import("../native/restore.zig");

const Record = struct {
    task: t.Id,
    input_digest: t.Digest,
    input: t.Input,
    result: ?t.Output = null,
};
const Index = struct {
    records: []const Record,
    recovery: ?t.InputReference = null,
    recovery_hold: bool = false,

    pub fn record(self: *const Index, task: t.Id) ?*const Record {
        for (self.records) |*item| if (std.meta.eql(task, item.task)) return item;
        return null;
    }
};

fn reference(id: u8) t.InputReference {
    return .{ .task = @splat(id), .digest = @splat(id + 20) };
}

fn marker(id: u8, action: @FieldType(t.Restore, "action")) Record {
    return .{
        .task = reference(id).task,
        .input_digest = reference(id).digest,
        .input = .{ .restore = .{
            .envelope = .{
                .operation = .{ .bytes = "restore" },
                .stable_request = @splat(id),
                .origin = .{ .local = .{ .uid = 501 } },
            },
            .action = action,
        } },
    };
}

fn begin(id: u8, previous: ?t.InputReference, cut: []const t.InputReference) Record {
    return marker(id, .{ .begin = .{ .previous = previous, .cut = .{ .items = cut } } });
}

fn release(id: u8, recovery: t.InputReference, exclusive_owner: bool) Record {
    return marker(id, .{ .release = .{
        .recovery = recovery,
        .exclusive_owner = exclusive_owner,
    } });
}

test "restore marker alone holds startup and release retains every earlier cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = begin(1, null, &.{});
    var index: Index = .{ .records = &.{first} };
    const held = try restore.inspect(a, &index);
    try std.testing.expect(held.recovery_hold);
    try std.testing.expectEqualDeep(reference(1), held.recovery.?);
    const released = release(2, reference(1), true);
    const second = begin(3, reference(1), &.{ reference(1), reference(2) });
    index.records = &.{ second, released, first };
    const again = try restore.inspect(a, &index);
    try std.testing.expect(again.recovery_hold);
    try std.testing.expectEqualDeep(reference(3), again.recovery.?);
    try std.testing.expectEqual(2, again.restore_cut.len);
    index.records = &.{ release(4, reference(3), true), second, released, first };
    const done = try restore.inspect(a, &index);
    try std.testing.expect(!done.recovery_hold);
    try std.testing.expectEqualDeep(again.restore_cut, done.restore_cut);
}

test "restore rejects branched markers missing cuts and nonexclusive release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = begin(1, null, &.{});
    var index: Index = .{ .records = &.{ first, begin(2, null, &.{reference(1)}) } };
    try std.testing.expectError(error.RestoreChainConflict, restore.inspect(a, &index));
    index.records = &.{ first, begin(2, reference(1), &.{}) };
    try std.testing.expectError(error.RestoreCutMissingPrevious, restore.inspect(a, &index));
    index.records = &.{ first, release(2, reference(1), false) };
    try std.testing.expectError(error.RestoreExclusiveOwnerRequired, restore.inspect(a, &index));
    index.records = &.{
        first,                                    release(2, reference(1), true),
        begin(3, reference(1), &.{reference(1)}),
    };
    try std.testing.expectError(error.RestoreReleaseOutsideCut, restore.inspect(a, &index));
    index.records = &.{ first, begin(2, reference(1), &.{ reference(1), reference(99) }) };
    try std.testing.expectError(error.MissingRestoreCut, restore.inspect(a, &index));
    index.records = &.{ first, release(2, reference(1), true), release(3, reference(1), true) };
    try std.testing.expectError(error.DuplicateRestoreRelease, restore.inspect(a, &index));
}

test "restore directive admission binds current local marker while history remains readable" {
    const first = begin(1, null, &.{});
    const second = begin(2, reference(1), &.{reference(1)});
    var index: Index = .{
        .records = &.{ first, second },
        .recovery = reference(2),
        .recovery_hold = true,
    };
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    const old: t.DirectiveBody = .{ .recovery_hold = .{ .recovery = reference(1) } };
    try restore.validateRetainedDirective(&index, @splat(9), old, origin);
    try std.testing.expectError(
        error.RestoreBoundaryNotCurrent,
        restore.validateDirective(&index, @splat(9), old, origin),
    );
    const current: t.DirectiveBody = .{ .recovery_hold = .{ .recovery = reference(2) } };
    try restore.validateDirective(&index, @splat(9), current, origin);
    const derived: t.Origin = .{ .derived = .{
        .predecessor = .{ .task = @splat(9), .digest = @splat(8) },
    } };
    try std.testing.expectError(
        error.RestoreLocalOnly,
        restore.validateDirective(&index, @splat(9), current, derived),
    );
    index.recovery_hold = false;
    try std.testing.expectError(
        error.RestoreAlreadyReleased,
        restore.validateDirective(&index, @splat(9), current, origin),
    );
}

test "restore transfer purpose is a terminal namespace fence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var transfer = begin(1, null, &.{});
    transfer.input.restore.action.begin.purpose = .transfer;
    var index: Index = .{ .records = &.{transfer} };
    const view = try restore.inspect(a, &index);
    try std.testing.expectEqual(t.RestorePurpose.transfer, view.recovery_purpose.?);
    try std.testing.expect(view.recovery_hold);
    index.records = &.{ transfer, begin(2, reference(1), &.{reference(1)}) };
    try std.testing.expectError(error.RestoreTransferPermanent, restore.inspect(a, &index));
    index.records = &.{ transfer, release(2, reference(1), true) };
    try std.testing.expectError(error.RestoreTransferPermanent, restore.inspect(a, &index));
    index.records = &.{transfer};
    const body: t.DirectiveBody = .{ .recovery_release = .{
        .recovery = reference(1),
        .exclusive_owner = true,
    } };
    try std.testing.expectError(
        error.RestoreTransferPermanent,
        restore.validateRetainedDirective(&index, @splat(9), body, .{ .local = .{ .uid = 501 } }),
    );
}
