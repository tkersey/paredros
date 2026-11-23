const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");

pub fn sourceFact(
    a: std.mem.Allocator,
    bundle: continuity.Bundle,
    item: continuity.Member,
) !continuity.SourceFact {
    for (bundle.members.items) |source| {
        if (source.data.kind != .settlement or
            !std.meta.eql(source.data.source.namespace, item.data.source.namespace) or
            !std.meta.eql(source.data.source.task, item.data.source.task) or
            source.data.source.revision != item.data.source.revision) continue;
        return (try continuity.decode(.settlement, a, source.data)).value;
    }
    return error.MissingContinuityFact;
}

fn historicalMember(
    a: std.mem.Allocator,
    bundle: continuity.Bundle,
    imported: t.TurnContinuity,
) !continuity.Member {
    for (bundle.members.items) |source| {
        if (source.data.kind != .turn or
            !std.meta.eql(source.data.source.namespace, imported.source_namespace) or
            !std.meta.eql(source.data.source.task, imported.original.task) or
            source.data.source.revision != imported.original.revision) continue;
        const fact = try sourceFact(a, bundle, source);
        if (!std.meta.eql(
            try continuity.digest(a, retained.Snapshot, fact.snapshot),
            imported.original.digest,
        )) return error.InvalidContinuityAncestry;
        return source;
    }
    return error.MissingContinuityAncestry;
}

fn previousTurn(
    a: std.mem.Allocator,
    bundle: continuity.Bundle,
    item: continuity.Member,
) !?continuity.Member {
    const value = try continuity.decode(.turn, a, item.data);
    if (value.value.input.replacement) |replacement| {
        for (bundle.members.items) |candidate| {
            if (candidate.data.kind == .turn and
                std.meta.eql(candidate.data.source.namespace, item.data.source.namespace) and
                std.meta.eql(candidate.data.source.task, replacement.input.task) and
                std.meta.eql(
                    candidate.data.source.digest,
                    replacement.input.digest,
                )) return candidate;
        }
        return error.MissingContinuityAncestry;
    }
    const imported = value.value.input.continuity orelse return null;
    return try historicalMember(a, bundle, imported);
}

fn originalEnvelope(
    a: std.mem.Allocator,
    bundle: continuity.Bundle,
    item: continuity.Member,
) !t.Envelope {
    var current = item;
    for (0..bundle.members.items.len) |_| {
        const previous = try previousTurn(a, bundle, current) orelse {
            const value = try continuity.decode(.turn, a, current.data);
            return value.value.input.envelope;
        };
        current = previous;
    }
    return error.CyclicContinuityAncestry;
}

fn superseded(a: std.mem.Allocator, bundle: continuity.Bundle, item: continuity.Member) !bool {
    for (bundle.members.items) |candidate| {
        if (candidate.data.kind != .turn) continue;
        if (try previousTurn(a, bundle, candidate)) |previous|
            if (std.meta.eql(previous.identity, item.identity)) return true;
    }
    return false;
}

pub fn validateBundle(a: std.mem.Allocator, bundle: continuity.Bundle) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (bundle.members.items) |item| {
        if (item.data.kind != .turn) continue;
        _ = try originalEnvelope(arena.allocator(), bundle, item);
    }
}

fn operation(a: std.mem.Allocator, bundle: t.Digest, identity: t.Digest) ![]u8 {
    const key = try continuity.digest(a, struct { bundle: t.Digest, identity: t.Digest }, .{
        .bundle = bundle,
        .identity = identity,
    });
    return std.fmt.allocPrint(a, "continuity-turn:{s}", .{std.fmt.bytesToHex(key, .lower)});
}

fn byOperation(index: *const idx.Index, name: []const u8) ?*const idx.Record {
    return &index.records[index.operations.get(name) orelse return null];
}

fn nextOrdinal(index: *const idx.Index) !u64 {
    var last: u64 = 0;
    for (index.records) |record| {
        if (record.input == .turn) last = @max(last, record.input.turn.ordinal);
    }
    return std.math.add(u64, last, 1);
}

fn memberReference(a: std.mem.Allocator, record: idx.Record) !t.RevisionReference {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    return .{
        .task = record.task,
        .revision = record.revision,
        .digest = try continuity.digest(a, retained.Snapshot, snapshot),
    };
}

fn mappedInput(
    a: std.mem.Allocator,
    index: *const idx.Index,
    portable: continuity.Portable,
    item: continuity.Member,
    model: ?t.ModelBinding,
    ordinal: u64,
) !t.Turn {
    const decoded = try continuity.decode(.turn, a, item.data);
    if (decoded.value.result != null) return error.CompletedContinuityTurn;
    const local = try continuity.binding(portable.metadata.members.items, item.identity);
    const current = index.record(local.task) orelse return error.MissingContinuityMember;
    const fact = try sourceFact(a, portable.bundle, item);
    var result = decoded.value.input;
    result.envelope.operation = .{ .bytes = try operation(
        a,
        portable.metadata.bundle,
        item.identity,
    ) };
    result.envelope.ingress = null;
    result.continuity = .{
        .member = local,
        .original = .{
            .task = item.data.source.task,
            .revision = item.data.source.revision,
            .digest = try continuity.digest(a, retained.Snapshot, fact.snapshot),
        },
        .source_namespace = item.data.source.namespace,
        .continuation = .portable_import,
    };
    result.replacement = null;
    result.attempt = @min(try std.math.add(u32, result.attempt, 1), 2);
    result.ordinal = ordinal;
    result.model = model;
    if (result.target) |target| result.target = try continuity.importedTarget(
        index,
        portable,
        target,
    );
    result.context_references.items = try a.dupe(
        t.RevisionReference,
        &.{try memberReference(a, current.*)},
    );
    return result;
}

pub fn validateMapped(a: std.mem.Allocator, index: *const idx.Index, turn: t.Turn) !void {
    const ancestry = turn.continuity orelse return error.MissingContinuityAncestry;
    const found = try continuity.portableMember(index, ancestry.member, .turn);
    if (try superseded(
        a,
        found.portable.bundle,
        found.member,
    )) return error.SupersededContinuityTurn;
    const expected = try mappedInput(
        a,
        index,
        found.portable,
        found.member,
        turn.model,
        turn.ordinal,
    );
    if (!try continuity.equal(a, t.Turn, turn, expected)) return error.ContinuityTurnMismatch;
}

pub const Progress = struct { admitted: ?t.Id = null, remaining: u64 = 0, historical: u64 = 0 };
const Pending = struct { portable: continuity.Portable, member: continuity.Member, ordinal: u64 };

fn pending(a: std.mem.Allocator, index: *const idx.Index, progress: *Progress) ![]Pending {
    var result: std.ArrayList(Pending) = .empty;
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    for (index.portable) |portable| {
        for (portable.bundle.members.items) |item| {
            if (item.data.kind != .turn or seen.contains(item.identity)) continue;
            try seen.put(a, item.identity, {});
            const value = try continuity.decode(.turn, a, item.data);
            if (value.value.result != null or try superseded(a, portable.bundle, item)) {
                progress.historical += 1;
                continue;
            }
            const name = try operation(a, portable.metadata.bundle, item.identity);
            if (byOperation(index, name) != null) continue;
            try result.append(
                a,
                .{ .portable = portable, .member = item, .ordinal = value.value.input.ordinal },
            );
        }
    }
    std.mem.sort(Pending, result.items, {}, struct {
        fn less(_: void, left: Pending, right: Pending) bool {
            if (left.ordinal != right.ordinal) return left.ordinal < right.ordinal;
            return std.mem.order(u8, &left.member.identity, &right.member.identity) == .lt;
        }
    }.less);
    progress.remaining = result.items.len;
    return result.toOwnedSlice(a);
}

pub fn admit(driver: anytype, a: std.mem.Allocator, origin: t.Origin) !Progress {
    if (!driver.attached or origin != .local) return error.TransferLocalOnly;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var index = try driver.rebuild(scratch);
    defer index.deinit();
    if (index.recovery_purpose == .transfer) return error.TransferredNamespace;
    var progress: Progress = .{};
    const selected = try pending(scratch, &index, &progress);
    if (selected.len == 0 or index.import_hold) return progress;
    const first = selected[0];
    const input = try mappedInput(
        scratch,
        &index,
        first.portable,
        first.member,
        driver.model,
        try nextOrdinal(&index),
    );
    const admitted = try driver.service.submit(
        scratch,
        input.envelope.operation.bytes,
        .{ .turn = input },
    );
    progress.admitted = admitted.receipt.task;
    progress.remaining -= 1;
    return progress;
}

pub fn ingress(
    a: std.mem.Allocator,
    index: *const idx.Index,
    name: []const u8,
    authenticated: t.Origin,
    stable: t.Digest,
) !?t.Id {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var fallback: ?t.Id = null;
    for (index.portable) |portable| {
        for (portable.bundle.members.items) |item| {
            if (item.data.kind != .turn and item.data.kind != .directive) continue;
            const envelope = if (item.data.kind == .turn)
                try originalEnvelope(scratch, portable.bundle, item)
            else
                (try continuity.decode(.directive, scratch, item.data)).value.envelope;
            if (!std.mem.eql(u8, envelope.operation.bytes, name)) continue;
            const original = envelope.ingress orelse return error.OperationConflict;
            if (!try continuity.equal(scratch, t.Origin, envelope.origin, authenticated) or
                !std.meta.eql(original.stable_request, stable)) return error.OperationConflict;
            const local = try continuity.binding(portable.metadata.members.items, item.identity);
            const mapped_name = if (item.data.kind == .turn)
                try operation(scratch, portable.metadata.bundle, item.identity)
            else
                try continuity.directiveOperation(scratch, portable.metadata.bundle, item.identity);
            if (byOperation(index, mapped_name)) |record| return record.task;
            if (fallback == null) fallback = local.task;
        }
    }
    return fallback;
}
