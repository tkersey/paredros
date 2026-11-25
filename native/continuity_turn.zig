const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");
const Catalog = continuity.Catalog;
const Replaced = std.AutoHashMapUnmanaged(t.Digest, void);

pub fn sourceFact(
    a: std.mem.Allocator,
    catalog: *const Catalog,
    item: continuity.Member,
) !continuity.SourceFact {
    const position = catalog.facts.get(.{
        .namespace = item.data.source.namespace,
        .task = item.data.source.task,
        .revision = item.data.source.revision,
    }) orelse return error.MissingContinuityFact;
    const data = catalog.bundle.members.items[position].data;
    return (try continuity.decode(.settlement, a, data)).value;
}

fn historicalMember(
    a: std.mem.Allocator,
    catalog: *const Catalog,
    imported: t.TurnContinuity,
) !continuity.Member {
    const found = catalog.sourced.get(.{ .kind = .turn, .source = .{
        .namespace = imported.source_namespace,
        .task = imported.original.task,
        .revision = imported.original.revision,
    } }) orelse return error.MissingContinuityAncestry;
    const source = catalog.bundle.members.items[found.position];
    const fact = try sourceFact(a, catalog, source);
    if (!std.meta.eql(
        try continuity.digest(a, retained.Snapshot, fact.snapshot),
        imported.original.digest,
    )) return error.InvalidContinuityAncestry;
    return source;
}

fn previousTurn(
    a: std.mem.Allocator,
    catalog: *const Catalog,
    item: continuity.Member,
) !?continuity.Member {
    const value = try continuity.decode(.turn, a, item.data);
    if (value.value.input.replacement) |replacement| {
        const position = catalog.turns.get(.{
            .namespace = item.data.source.namespace,
            .task = replacement.input.task,
            .digest = replacement.input.digest,
        }) orelse return error.MissingContinuityAncestry;
        return catalog.bundle.members.items[position];
    }
    const imported = value.value.input.continuity orelse return null;
    return try historicalMember(a, catalog, imported);
}

fn originate(
    a: std.mem.Allocator,
    catalog: *const Catalog,
    originated: *Replaced,
    item: continuity.Member,
) !void {
    var walked: std.ArrayList(t.Digest) = .empty;
    defer walked.deinit(a);
    var current = item;
    for (0..catalog.bundle.members.items.len + 1) |_| {
        if (originated.contains(current.identity)) break;
        try walked.append(a, current.identity);
        current = try previousTurn(a, catalog, current) orelse break;
    } else return error.CyclicContinuityAncestry;
    for (walked.items) |identity| try originated.put(a, identity, {});
}

pub fn replacedTurns(a: std.mem.Allocator, catalog: *const Catalog) !Replaced {
    var replaced: Replaced = .empty;
    for (catalog.bundle.members.items) |item| {
        if (item.data.kind != .turn) continue;
        const previous = try previousTurn(a, catalog, item) orelse continue;
        try replaced.put(a, previous.identity, {});
    }
    return replaced;
}

pub fn validateBundle(a: std.mem.Allocator, catalog: *const Catalog) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var originated: Replaced = .empty;
    for (catalog.bundle.members.items) |item| {
        if (item.data.kind != .turn) continue;
        try originate(arena.allocator(), catalog, &originated, item);
    }
    for (try pendingTurns(arena.allocator(), catalog)) |item| {
        try validateTarget(arena.allocator(), catalog, item);
    }
}

pub fn pendingTurns(a: std.mem.Allocator, catalog: *const Catalog) ![]continuity.Member {
    const replaced = try replacedTurns(a, catalog);
    var result: std.ArrayList(continuity.Member) = .empty;
    for (catalog.bundle.members.items) |item| {
        if (item.data.kind != .turn or replaced.contains(item.identity)) continue;
        const value = try continuity.decode(.turn, a, item.data);
        if (value.value.result == null) try result.append(a, item);
    }
    return result.toOwnedSlice(a);
}

fn validateTarget(a: std.mem.Allocator, catalog: *const Catalog, item: continuity.Member) !void {
    const value = try continuity.decode(.turn, a, item.data);
    const target = value.value.input.target orelse return;
    if (!catalog.rooted(item.data.lineage)) return error.MissingContinuityTarget;
    const position = catalog.task_facts.get(.{
        .namespace = item.data.source.namespace,
        .task = target,
    }) orelse return error.MissingContinuityTarget;
    const fact = try continuity.decode(.settlement, a, catalog.bundle.members.items[position].data);
    const input = try continuity.sourceInput(a, fact.value.input);
    if (input != .genesis or !std.meta.eql(input.genesis.lineage, item.data.lineage))
        return error.InvalidContinuityTarget;
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
    catalog: *const Catalog,
    item: continuity.Member,
    model: ?t.ModelBinding,
    ordinal: u64,
) !t.Turn {
    const decoded = try continuity.decode(.turn, a, item.data);
    if (decoded.value.result != null) return error.CompletedContinuityTurn;
    const local = try continuity.binding(portable.bindings, item.identity);
    const current = index.record(local.task) orelse return error.MissingContinuityMember;
    const fact = try sourceFact(a, catalog, item);
    var result = decoded.value.input;
    result.envelope.operation = .{ .bytes = try operation(
        a,
        portable.metadata.bundle,
        item.identity,
    ) };
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
    if (result.target != null) result.target = try continuity.importedTarget(
        index,
        portable,
        item.data.lineage,
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
    var catalog = try Catalog.init(a, found.portable.bundle);
    defer catalog.deinit();
    if ((try replacedTurns(a, &catalog)).contains(found.member.identity))
        return error.SupersededContinuityTurn;
    const expected = try mappedInput(
        a,
        index,
        found.portable,
        &catalog,
        found.member,
        turn.model,
        turn.ordinal,
    );
    if (!try continuity.equal(a, t.Turn, turn, expected)) return error.ContinuityTurnMismatch;
}

pub const Progress = struct { admitted: ?t.Id = null, remaining: u64 = 0, historical: u64 = 0 };
const Pending = struct {
    portable: continuity.Portable,
    catalog: *const Catalog,
    member: continuity.Member,
    ordinal: u64,
};

fn pending(a: std.mem.Allocator, index: *const idx.Index, progress: *Progress) ![]Pending {
    var result: std.ArrayList(Pending) = .empty;
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    for (index.portable) |portable| {
        const catalog = try a.create(Catalog);
        catalog.* = try Catalog.init(a, portable.bundle);
        const replaced = try replacedTurns(a, catalog);
        for (portable.bundle.members.items) |item| {
            if (item.data.kind != .turn or seen.contains(item.identity)) continue;
            try seen.put(a, item.identity, {});
            const value = try continuity.decode(.turn, a, item.data);
            if (value.value.result != null or replaced.contains(item.identity)) {
                progress.historical += 1;
                continue;
            }
            const name = try operation(a, portable.metadata.bundle, item.identity);
            if (byOperation(index, name) != null) continue;
            try result.append(a, .{
                .portable = portable,
                .catalog = catalog,
                .member = item,
                .ordinal = value.value.input.ordinal,
            });
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
    if (index.transferred()) return error.TransferredNamespace;
    var progress: Progress = .{};
    const selected = try pending(scratch, &index, &progress);
    if (selected.len == 0) return progress;
    const first = selected[0];
    const input = try mappedInput(
        scratch,
        &index,
        first.portable,
        first.catalog,
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
