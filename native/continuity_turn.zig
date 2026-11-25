const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");

pub fn memberTurns(item: continuity.Member) []const continuity.Turn {
    return switch (item) {
        .obligation => |value| value.turns.items,
        .conversation => |value| value.pending.items,
        .report => &.{},
    };
}

pub fn operation(a: std.mem.Allocator, view: continuity.ImportView, at: continuity.Position) ![]u8 {
    return continuity.mappedOperation(a, .turn, view.digest, at);
}

pub fn carried(index: anytype, turn: t.Turn) ?continuity.Turn {
    const ancestry = turn.continuity orelse return null;
    const view = index.continuity_import orelse return null;
    const bundle = view.bundle orelse return null;
    if (ancestry.member >= bundle.members.items.len) return null;
    const turns = memberTurns(bundle.members.items[ancestry.member]);
    if (ancestry.turn >= turns.len) return null;
    return turns[ancestry.turn];
}

fn nextOrdinal(index: *const idx.Index) !u64 {
    var last: u64 = 0;
    for (index.records) |record| {
        if (record.input == .turn) last = @max(last, record.input.turn.ordinal);
    }
    return std.math.add(u64, last, 1);
}

fn manifestReference(a: std.mem.Allocator, record: idx.Record) !t.RevisionReference {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    return .{
        .task = record.task,
        .revision = record.revision,
        .digest = try continuity.digest(a, retained.Snapshot, snapshot),
    };
}

fn importedTarget(index: *const idx.Index, view: continuity.ImportView, lineage: t.Digest) !t.Id {
    const position = try continuity.importedLineage(index, lineage, view.digest) orelse
        return error.MissingContinuityTarget;
    if (index.records[position].result == null) return error.MissingContinuityTarget;
    return index.records[position].task;
}

fn mappedInput(
    a: std.mem.Allocator,
    index: *const idx.Index,
    view: continuity.ImportView,
    at: continuity.Position,
    model: ?t.ModelBinding,
    ordinal: u64,
) !t.Turn {
    const item = view.bundle.?.members.items[at.member];
    var result = memberTurns(item)[at.position].input;
    result.envelope.operation = .{ .bytes = try operation(a, view, at) };
    result.continuity = .{
        .manifest = view.manifest.?,
        .member = at.member,
        .turn = at.position,
        .continuation = .portable_import,
    };
    result.attempt = @min(try std.math.add(u32, result.attempt, 1), 2);
    result.ordinal = ordinal;
    result.model = model;
    result.target = if (item == .obligation)
        try importedTarget(index, view, item.obligation.lineage)
    else
        null;
    result.context_references.items = try a.dupe(
        t.RevisionReference,
        &.{try manifestReference(a, index.records[view.position])},
    );
    return result;
}

pub fn validateMapped(a: std.mem.Allocator, index: *const idx.Index, turn: t.Turn) !void {
    const ancestry = turn.continuity orelse return error.MissingContinuityAncestry;
    _ = carried(index, turn) orelse return error.MissingContinuityAncestry;
    const view = index.continuity_import.?;
    if (!std.meta.eql(ancestry.manifest, view.manifest.?)) return error.ContinuityTurnMismatch;
    const expected = try mappedInput(a, index, view, .{
        .member = ancestry.member,
        .position = ancestry.turn,
    }, turn.model, turn.ordinal);
    if (!try continuity.equal(a, t.Turn, turn, expected)) return error.ContinuityTurnMismatch;
}

pub const Progress = struct { admitted: ?t.Id = null, remaining: u64 = 0 };
const Pending = struct { at: continuity.Position, ordinal: u64 };

fn pending(a: std.mem.Allocator, index: *const idx.Index, view: continuity.ImportView) ![]Pending {
    var result: std.ArrayList(Pending) = .empty;
    for (view.bundle.?.members.items, 0..) |item, member| {
        for (memberTurns(item), 0..) |turn, position| {
            const at: continuity.Position = .{
                .member = @intCast(member),
                .position = @intCast(position),
            };
            if (index.operations.contains(try operation(a, view, at))) continue;
            try result.append(a, .{ .at = at, .ordinal = turn.input.ordinal });
        }
    }
    std.mem.sort(Pending, result.items, {}, struct {
        fn less(_: void, left: Pending, right: Pending) bool {
            if (left.ordinal != right.ordinal) return left.ordinal < right.ordinal;
            if (left.at.member != right.at.member) return left.at.member < right.at.member;
            return left.at.position < right.at.position;
        }
    }.less);
    return result.toOwnedSlice(a);
}

pub fn admit(driver: anytype, a: std.mem.Allocator, origin: t.Origin) !Progress {
    if (!driver.attached or origin != .local) return error.TransferLocalOnly;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var indexed = try driver.view(scratch);
    defer indexed.deinit();
    const index = &indexed.index;
    if (index.transferred()) return error.TransferredNamespace;
    const view = index.continuity_import orelse return .{};
    if (view.bundle == null) return .{};
    const selected = try pending(scratch, index, view);
    if (selected.len == 0) return .{};
    const input = try mappedInput(
        scratch,
        index,
        view,
        selected[0].at,
        driver.model,
        try nextOrdinal(index),
    );
    const admitted = try driver.submit(
        scratch,
        input.envelope.operation.bytes,
        .{ .turn = input },
    );
    return .{ .admitted = admitted.receipt.task, .remaining = selected.len - 1 };
}
