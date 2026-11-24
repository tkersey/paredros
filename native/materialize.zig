const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const admission = @import("admission.zig");
const delivery = @import("delivery_fact.zig");
const continuity = @import("continuity.zig");
const delivery_target = @import("delivery_target.zig");
const measure = @import("render_measure.zig");

pub fn step(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    clock_ms: i64,
    model: ?t.ModelBinding,
) !c.Decoded(t.Step) {
    return compose(a, index, target, clock_ms, model, null);
}

pub fn replacement(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    clock_ms: i64,
    model: ?t.ModelBinding,
    supersession: t.Supersession,
) !c.Decoded(t.Step) {
    return compose(a, index, target, clock_ms, model, supersession);
}

fn compose(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    clock_ms: i64,
    model: ?t.ModelBinding,
    supersession: ?t.Supersession,
) !c.Decoded(t.Step) {
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    const attempt = if (supersession) |replaced| blk: {
        const position = obligation.eligible orelse return error.NoEligibleStep;
        const old = index.records[position];
        if (!std.meta.eql(replaced.input.task, old.task) or
            !std.meta.eql(replaced.input.digest, old.input_digest) or
            replaced.attempt != old.input.step.attempt or
            !std.meta.eql(replaced.cancellation.task, old.task)) return error.StaleSupersession;
        break :blk try std.math.add(u32, replaced.attempt, 1);
    } else blk: {
        if (obligation.eligible != null) return error.LiveStep;
        break :blk @as(u32, 0);
    };
    const head = index.head(obligation);
    if (head.mode == .cancelled or head.mode == .transferred) return error.FinalObligation;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const predecessor = index.reference(obligation.chain[obligation.chain.len - 1]);
    const sequence = try std.math.add(u64, head.sequence, 1);
    const identity: struct { obligation: t.Id, sequence: u64, attempt: u32 } = .{
        .obligation = target,
        .sequence = sequence,
        .attempt = attempt,
    };
    const operation = try std.fmt.allocPrint(scratch, "step:{s}:{d}:{d}", .{
        std.fmt.bytesToHex(target, .lower), sequence, attempt,
    });
    const pending = try directives(scratch, index, obligation);
    const fold_only = supersession != null or controlBoundary(pending);
    var selected_source = if (!fold_only and head.method == .retained)
        try @import("method_catalog.zig").qualified(scratch, index, head.method.retained)
    else
        null;
    defer if (selected_source) |*source| source.deinit();
    const value: t.Step = .{
        .envelope = .{
            .operation = .{ .bytes = operation },
            .stable_request = try admission.stableDigest(scratch, identity),
            .origin = .{ .derived = .{ .predecessor = predecessor } },
        },
        .obligation = target,
        .predecessor = predecessor,
        .previous = head,
        .sequence = sequence,
        .attempt = attempt,
        .supersession = supersession,
        .directives = .{ .items = pending },
        .facts = .{ .items = try facts(scratch, index, obligation) },
        .batches = .{ .items = try batches(scratch, index, obligation) },
        .clock_ms = clock_ms,
        .fold_only = fold_only,
        .method_source = if (selected_source) |source| source.value else null,
        .model = model,
    };
    return c.decodeOwned(t.Step, a, try c.encodeOwned(t.Step, scratch, value));
}

fn controlBoundary(pending: []const t.DirectiveFact) bool {
    for (pending) |fact| switch (fact.value.body) {
        .adopt,
        .revert,
        .@"resume",
        .recovery_hold,
        .recovery_release,
        => return true,
        else => {},
    };
    return false;
}

fn directives(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]const t.DirectiveFact {
    const head = index.head(obligation);
    var result: std.ArrayList(t.DirectiveFact) = .empty;
    for (obligation.directives) |position| {
        const record = index.records[position];
        if (record.input.directive.ordinal <= head.folded_directive_ordinal) continue;
        if (result.items.len == 128) break;
        try result.append(a, .{
            .reference = .{ .task = record.task, .digest = record.input_digest },
            .value = record.input.directive,
        });
    }
    return result.toOwnedSlice(a);
}

pub fn factTarget(index: *const idx.Index, record: idx.Record) ?t.Id {
    return switch (record.input) {
        .step => |value| value.obligation,
        .delivery => |value| delivery_target.resolve(index, value),
        .turn => |value| value.target,
        .genesis,
        .directive,
        .experiment,
        .continuity_member,
        .continuity_cut,
        .restore,
        => null,
    };
}

fn belongs(index: *const idx.Index, record: idx.Record, target: t.Id) bool {
    const selected = factTarget(index, record) orelse return false;
    return std.meta.eql(selected, target);
}

fn facts(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]const t.Settlement {
    var result: std.ArrayList(t.Settlement) = .empty;
    var ordered: std.ArrayList(usize) = .empty;
    for (index.records, 0..) |record, position| {
        if (belongs(index, record, obligation.task)) try ordered.append(a, position);
    }
    std.mem.sort(usize, ordered.items, index, struct {
        fn less(context: *const idx.Index, left: usize, right: usize) bool {
            return std.mem.order(
                u8,
                &context.records[left].task,
                &context.records[right].task,
            ) == .lt;
        }
    }.less);
    for (ordered.items) |position| {
        const record = index.records[position];
        if (!unsettled(obligation, record)) continue;
        if (result.items.len == 128) break;
        const previous = obligation.settlements.get(record.task);
        try result.append(a, try settlement(a, record, previous));
    }
    return result.toOwnedSlice(a);
}

pub fn unsettled(obligation: *const idx.Obligation, record: idx.Record) bool {
    if (!readyFact(record)) return false;
    const previous = obligation.settlements.get(record.task) orelse return true;
    return previous.reference.revision != record.revision;
}

pub fn readyFact(record: idx.Record) bool {
    if (record.input != .delivery) return true;
    const snapshot = record.owner_snapshot orelse return false;
    if (snapshot.outcome == .completed or snapshot.outcome == .failed or
        snapshot.outcome == .cancelled) return true;
    const evidence = record.owner_evidence orelse return false;
    return evidence.status == .unknown;
}

fn settlement(
    a: std.mem.Allocator,
    record: idx.Record,
    previous: ?t.Settlement,
) !t.Settlement {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    const bytes = try c.encodeOwned(retained.Snapshot, a, snapshot);
    const disposition = if (record.input == .delivery)
        (try delivery.settlement(
            a,
            snapshot,
            record.owner_evidence orelse return error.MissingOwnerEvidence,
        )).value
    else
        null;
    return .{
        .reference = .{
            .task = record.task,
            .revision = record.revision,
            .digest = idx.digest(bytes),
        },
        .owner_snapshot = .{ .bytes = bytes },
        .kind = switch (record.input) {
            .step => if (record.superseded) .superseded else .phase,
            .delivery => .delivery,
            .turn => .turn,
            else => return error.UnexpectedSettlement,
        },
        .accounting = snapshot.accounting,
        .previous_accounting = if (previous) |value| value.accounting else .{},
        .previous_reference = if (previous) |value| value.reference else null,
        .delivery = disposition,
    };
}

const BatchFact = @FieldType(t.Step, "batches").Child;

pub const Backlog = struct {
    untold_batches: u64,
    oldest: ?struct {
        sequence: u64,
        reference: t.Reference,
        acquired_ms: i64,
        coverage: t.Coverage,
    } = null,
};

pub fn backlog(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) !Backlog {
    const head = index.head(obligation);
    const count = try std.math.sub(u64, head.observed.sequence, head.told.sequence);
    if (count == 0) return .{ .untold_batches = 0 };
    const wanted = head.told.sequence + 1;
    for (obligation.chain) |position| {
        const output = index.records[position].result.?;
        if (output != .step) continue;
        const batch = output.step.batch orelse continue;
        if (batch.sequence == wanted)
            return backlogWithEvidence(
                count,
                .{ .reference = index.reference(position), .value = batch },
            );
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var imported: std.ArrayList(BatchFact) = .empty;
    try importedBatches(arena.allocator(), index, obligation, wanted, &imported);
    if (imported.items.len != 0) return backlogWithEvidence(count, imported.items[0]);
    return .{ .untold_batches = count };
}

fn backlogWithEvidence(count: u64, fact: BatchFact) Backlog {
    return .{ .untold_batches = count, .oldest = .{
        .sequence = fact.value.sequence,
        .reference = fact.reference,
        .acquired_ms = fact.value.acquired_ms,
        .coverage = fact.value.coverage,
    } };
}

fn batches(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]const @FieldType(t.Step, "batches").Child {
    const head = index.head(obligation);
    var candidates: std.ArrayList(BatchFact) = .empty;
    try importedBatches(a, index, obligation, null, &candidates);
    for (obligation.chain) |position| {
        const output = index.records[position].result.?;
        if (output != .step) continue;
        const batch = output.step.batch orelse continue;
        try candidates.append(a, .{ .reference = index.reference(position), .value = batch });
    }
    std.mem.sort(BatchFact, candidates.items, {}, struct {
        fn less(_: void, left: BatchFact, right: BatchFact) bool {
            return left.value.sequence < right.value.sequence;
        }
    }.less);
    var result: std.ArrayList(BatchFact) = .empty;
    var prefix = try measure.Prefix.forHead(head);
    var sequence = head.told.sequence;
    for (candidates.items) |fact| {
        const batch = fact.value;
        if (batch.sequence <= head.told.sequence) continue;
        if (batch.sequence > head.observed.sequence) return error.BatchBeyondObserved;
        sequence = try std.math.add(u64, sequence, 1);
        if (batch.sequence != sequence) return error.BatchCoverageGap;
        try prefix.add(a, fact);
        const fits = !try prefix.crowded();
        if (!fits and result.items.len > 0) break;
        try result.append(a, fact);
        if (!fits or batch.coverage != .complete) break;
    }
    return result.toOwnedSlice(a);
}

fn importedBatches(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    wanted: ?u64,
    result: *std.ArrayList(BatchFact),
) !void {
    const imported = continuity.findImport(index, obligation.task) orelse return;
    const head = index.head(obligation);
    for (imported.bundle.members.items) |member| {
        if (member.data.kind != .batch or !std.meta.eql(member.data.lineage, head.lineage))
            continue;
        const reference = try continuity.binding(imported.metadata.members.items, member.identity);
        const source = try continuity.resolve(index, obligation.task, reference, .batch);
        var decoded = try continuity.decode(.batch, a, source);
        if (wanted) |sequence| if (sequence != decoded.value.sequence) {
            decoded.deinit();
            continue;
        };
        try result.append(a, .{ .reference = reference, .value = decoded.value });
        if (wanted != null) return;
    }
}
