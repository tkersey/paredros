const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const admission = @import("admission.zig");

pub const View = struct {
    recovery: ?t.InputReference = null,
    recovery_purpose: ?t.RestorePurpose = null,
    recovery_hold: bool = false,
    restore_cut: []const t.InputReference = &.{},
};

pub fn inspect(a: std.mem.Allocator, index: anytype) !View {
    var result: View = .{};
    var cut: std.ArrayList(t.InputReference) = .empty;
    errdefer cut.deinit(a);
    var count: usize = 0;
    for (index.records) |item| {
        if (item.input != .restore) continue;
        try validateRecord(a, index, item);
        if (item.input.restore.action == .begin) count += 1;
    }
    for (0..count) |_| {
        var next: ?t.InputReference = null;
        for (index.records) |item| {
            if (item.input != .restore or item.input.restore.action != .begin) continue;
            const begin_action = item.input.restore.action.begin;
            if (!std.meta.eql(begin_action.previous, result.recovery)) continue;
            if (next != null) return error.RestoreChainConflict;
            next = .{ .task = item.task, .digest = item.input_digest };
            result.recovery_purpose = begin_action.purpose;
            if (result.recovery) |previous| {
                if (!contains(begin_action.cut.items, previous))
                    return error.RestoreCutMissingPrevious;
                if (try released(index, previous)) |release_ref|
                    if (!contains(begin_action.cut.items, release_ref))
                        return error.RestoreReleaseOutsideCut;
            }
            for (begin_action.cut.items) |reference| {
                if (!contains(cut.items, reference)) try cut.append(a, reference);
            }
        }
        result.recovery = next orelse return error.RestoreChainGap;
    }
    if (result.recovery) |reference| result.recovery_hold =
        (try released(index, reference)) == null;
    result.restore_cut = try cut.toOwnedSlice(a);
    return result;
}

fn contains(cut: []const t.InputReference, reference: t.InputReference) bool {
    for (cut) |item| if (std.meta.eql(item, reference)) return true;
    return false;
}

fn beginRecord(index: anytype, reference: t.InputReference) !void {
    const item = index.record(reference.task) orelse return error.MissingRestoreBoundary;
    if (!std.meta.eql(item.input_digest, reference.digest) or item.input != .restore or
        item.input.restore.action != .begin or item.input.restore.envelope.origin != .local)
        return error.InvalidRestoreBoundary;
}

fn validateRecord(a: std.mem.Allocator, index: anytype, item: anytype) !void {
    const restore = item.input.restore;
    if (restore.envelope.origin != .local) return error.RestoreLocalOnly;
    if (item.result) |output| {
        if (output != .restore) return error.RestoreResultMismatch;
        const before = try c.encodeOwned(t.Restore, a, restore);
        defer a.free(before);
        const after = try c.encodeOwned(t.Restore, a, output.restore);
        defer a.free(after);
        if (!std.mem.eql(u8, before, after)) return error.RestoreResultMismatch;
    }
    switch (restore.action) {
        .begin => |value| {
            if (value.previous) |previous| {
                try beginRecord(index, previous);
                if (purpose(index, previous) == .transfer) return error.RestoreTransferPermanent;
            }
            for (value.cut.items, 0..) |reference, i| {
                if (std.meta.eql(reference.task, item.task)) return error.RestoreSelfCut;
                const source = index.record(reference.task) orelse return error.MissingRestoreCut;
                if (!std.meta.eql(reference.digest, source.input_digest))
                    return error.RestoreCutMismatch;
                if (contains(value.cut.items[0..i], reference)) return error.DuplicateRestoreCut;
            }
        },
        .release => |value| {
            if (!value.exclusive_owner) return error.RestoreExclusiveOwnerRequired;
            try beginRecord(index, value.recovery);
            if (purpose(index, value.recovery) == .transfer) return error.RestoreTransferPermanent;
        },
    }
}

fn purpose(index: anytype, reference: t.InputReference) t.RestorePurpose {
    return index.record(reference.task).?.input.restore.action.begin.purpose;
}

fn released(index: anytype, reference: t.InputReference) !?t.InputReference {
    var found: ?t.InputReference = null;
    for (index.records) |item| {
        if (item.input != .restore or item.input.restore.action != .release) continue;
        if (!std.meta.eql(item.input.restore.action.release.recovery, reference)) continue;
        if (found != null) return error.DuplicateRestoreRelease;
        found = .{ .task = item.task, .digest = item.input_digest };
    }
    return found;
}

pub fn validateRetainedDirective(
    index: anytype,
    target: t.Id,
    body: t.DirectiveBody,
    origin: t.Origin,
) !void {
    _ = target;
    const reference = switch (body) {
        .recovery_hold => |value| value.recovery,
        .recovery_release => |value| blk: {
            if (!value.exclusive_owner) return error.RestoreExclusiveOwnerRequired;
            break :blk value.recovery;
        },
        else => return,
    };
    if (origin != .local) return error.RestoreLocalOnly;
    try beginRecord(index, reference);
    if (body == .recovery_release and purpose(index, reference) == .transfer)
        return error.RestoreTransferPermanent;
}

pub fn validateDirective(
    index: anytype,
    target: t.Id,
    body: t.DirectiveBody,
    origin: t.Origin,
) !void {
    try validateRetainedDirective(index, target, body, origin);
    const reference = switch (body) {
        .recovery_hold => |value| value.recovery,
        .recovery_release => |value| value.recovery,
        else => return,
    };
    if (index.recovery == null or !std.meta.eql(index.recovery.?, reference))
        return error.RestoreBoundaryNotCurrent;
    if (body == .recovery_hold and !index.recovery_hold) return error.RestoreAlreadyReleased;
}

pub fn begin(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
) !t.Id {
    return admitBoundary(
        driver,
        a,
        operation,
        origin,
        .rollback,
        try admission.stableDigest(a, @as(t.RestorePurpose, .rollback)),
    );
}

pub fn beginTransfer(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    request_digest: t.Digest,
) !t.Id {
    const stable: struct { purpose: t.RestorePurpose, request: t.Digest } = .{
        .purpose = .transfer,
        .request = request_digest,
    };
    return admitBoundary(
        driver,
        a,
        operation,
        origin,
        .transfer,
        try admission.stableDigest(a, stable),
    );
}

fn admitBoundary(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    selected: t.RestorePurpose,
    request_digest: t.Digest,
) !t.Id {
    if (!driver.attached) return error.DriverDetached;
    if (origin != .local) return error.RestoreLocalOnly;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const request: admission.Request = .{
        .operation = operation,
        .kind = .restore,
        .target = null,
        .origin = origin,
        .digest = request_digest,
    };
    const result = try admission.admit(driver.service, scratch, request, Begin(@TypeOf(driver)){
        .driver = driver,
        .purpose = selected,
    });
    const task = result.receipt.task;
    var index = try driver.rebuild(a);
    defer index.deinit();
    const reference: t.InputReference = .{
        .task = task,
        .digest = index.record(task).?.input_digest,
    };
    if (index.recovery_hold and std.meta.eql(index.recovery, @as(?t.InputReference, reference)))
        try directives(driver, a, &index, reference, origin, false);
    return task;
}

fn Begin(comptime Driver: type) type {
    return struct {
        driver: Driver,
        purpose: t.RestorePurpose,

        pub fn materialize(
            self: @This(),
            a: std.mem.Allocator,
            request: admission.Request,
        ) !t.Input {
            var index = try self.driver.rebuild(a);
            defer index.deinit();
            if (index.recovery_purpose == .transfer) return error.RestoreTransferPermanent;
            const cut = try a.alloc(t.InputReference, index.records.len);
            for (index.records, cut) |record, *reference| reference.* = .{
                .task = record.task,
                .digest = record.input_digest,
            };
            return .{ .restore = .{
                .envelope = envelope(request),
                .action = .{ .begin = .{
                    .previous = index.recovery,
                    .cut = .{ .items = cut },
                    .purpose = self.purpose,
                } },
            } };
        }
    };
}

fn envelope(request: admission.Request) t.Envelope {
    return .{
        .operation = .{ .bytes = request.operation },
        .stable_request = request.digest,
        .origin = request.origin,
    };
}

fn directives(
    driver: anytype,
    a: std.mem.Allocator,
    index: anytype,
    reference: t.InputReference,
    origin: t.Origin,
    releasing: bool,
) !void {
    for (index.obligations) |*obligation| {
        const head = index.head(obligation);
        if (head.mode == .cancelled or head.mode == .transferred) continue;
        const kind: []const u8 = if (releasing) "release" else "hold";
        const operation = try std.fmt.allocPrint(a, "restore-{s}-{s}-{s}", .{
            kind,                                        std.fmt.bytesToHex(reference.task, .lower),
            std.fmt.bytesToHex(obligation.task, .lower),
        });
        defer a.free(operation);
        const body: t.DirectiveBody = if (releasing)
            .{ .recovery_release = .{ .recovery = reference, .exclusive_owner = true } }
        else
            .{ .recovery_hold = .{ .recovery = reference } };
        _ = try driver.directive(a, operation, origin, obligation.task, body);
    }
}

pub fn release(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    reference: t.InputReference,
    exclusive_owner: bool,
) !t.Id {
    if (!driver.attached) return error.DriverDetached;
    if (origin != .local) return error.RestoreLocalOnly;
    if (!exclusive_owner) return error.RestoreExclusiveOwnerRequired;
    const action: @FieldType(t.Restore, "action") = .{ .release = .{
        .recovery = reference,
        .exclusive_owner = exclusive_owner,
    } };
    const request: admission.Request = .{
        .operation = operation,
        .kind = .restore,
        .target = null,
        .origin = origin,
        .digest = try admission.stableDigest(a, action),
    };
    if (try driver.service.operationLookup(a, operation)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        const result = try admission.admit(driver.service, a, request, Release{ .action = action });
        return result.receipt.task;
    }
    var index = try driver.rebuild(a);
    defer index.deinit();
    if (index.recovery == null or !std.meta.eql(index.recovery.?, reference))
        return error.RestoreBoundaryNotCurrent;
    if (!index.recovery_hold) return error.RestoreAlreadyReleased;
    if (index.recovery_purpose == .transfer) return error.RestoreTransferPermanent;
    const admitted_origin = index.record(reference.task).?.input.restore.envelope.origin;
    try directives(driver, a, &index, reference, admitted_origin, false);
    try directives(driver, a, &index, reference, origin, true);
    const result = try admission.admit(driver.service, a, request, Release{ .action = action });
    return result.receipt.task;
}

const Release = struct {
    action: @FieldType(t.Restore, "action"),

    pub fn materialize(self: @This(), _: std.mem.Allocator, request: admission.Request) !t.Input {
        return .{ .restore = .{ .envelope = envelope(request), .action = self.action } };
    }
};
