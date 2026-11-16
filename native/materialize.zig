const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const admission = @import("admission.zig");
const delivery = @import("delivery_fact.zig");
const continuity = @import("continuity.zig");
const interaction = @import("interaction_evidence.zig");

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
        .adopt, .revert, .@"resume", .recovery_hold, .recovery_release, .audit, .frontier_audit => return true,
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

fn belongs(index: *const idx.Index, record: idx.Record, target: t.Id) bool {
    if (interaction.target(index, record)) |selected| return std.meta.eql(selected, target);
    return switch (record.input) {
        .step => |value| std.meta.eql(value.obligation, target),
        .delivery => |value| sameTarget(
            @import("delivery_target.zig").resolve(index, value),
            target,
        ),
        .audit => |value| sameTarget(
            @import("audit_control.zig").deliveryTarget(index, value.delivery),
            target,
        ),
        .turn => |value| sameTarget(value.target, target),
        .genesis, .directive, .experiment, .continuity_member, .continuity_cut, .restore, .lineage_audit => false,
    };
}

fn sameTarget(value: ?t.Id, target: t.Id) bool {
    return value != null and std.meta.eql(value.?, target);
}

fn priorFact(index: *const idx.Index, obligation: *const idx.Obligation, task: t.Id) ?t.Settlement {
    var previous: ?t.Settlement = null;
    for (obligation.chain) |position| {
        const input = index.records[position].input;
        if (input != .step) continue;
        for (input.step.facts.items) |fact| {
            if (std.meta.eql(fact.reference.task, task)) previous = fact;
        }
    }
    return previous;
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
        if (!readyFact(record)) continue;
        const previous = priorFact(index, obligation, record.task);
        if (previous != null and previous.?.reference.revision == record.revision) continue;
        if (result.items.len == 128) break;
        try result.append(a, try settlement(a, index, record, previous));
    }
    return result.toOwnedSlice(a);
}

pub fn readyFact(record: idx.Record) bool {
    if (record.input != .delivery) return true;
    const snapshot = record.owner_snapshot orelse return false;
    if (snapshot.outcome == .completed or snapshot.outcome == .failed or
        snapshot.outcome == .cancelled) return true;
    const evidence = record.owner_evidence orelse return false;
    if (evidence.status == .unknown) return true;
    for (snapshot.attempts.items) |attempt| if (attempt.capture) |capture| {
        if (capture.reply != null) return true;
    };
    return false;
}

fn settlement(
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: idx.Record,
    previous: ?t.Settlement,
) !t.Settlement {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    const bytes = try c.encodeOwned(retained.Snapshot, a, snapshot);
    const bound_interaction = try interaction.settlement(a, index, record);
    const disposition = if (bound_interaction) |value|
        value
    else if (record.input == .delivery)
        (try delivery.settlement(
            a,
            snapshot,
            record.owner_evidence orelse return error.MissingOwnerEvidence,
        )).value
    else if (record.input == .audit) try auditFact(record) else null;
    return .{
        .reference = .{
            .task = record.task,
            .revision = record.revision,
            .digest = idx.digest(bytes),
        },
        .owner_snapshot = .{ .bytes = bytes },
        .kind = if (bound_interaction != null) .interaction else switch (record.input) {
            .step => if (record.superseded) .superseded else .phase,
            .delivery => .delivery,
            .audit => .audit,
            .turn => .turn,
            else => return error.UnexpectedSettlement,
        },
        .accounting = snapshot.accounting,
        .previous_accounting = if (previous) |value| value.accounting else .{},
        .previous_reference = if (previous) |value| value.reference else null,
        .delivery = disposition,
    };
}

fn auditFact(record: idx.Record) !@FieldType(t.Settlement, "delivery") {
    const output = record.result orelse return null;
    if (output != .audit) return error.WrongTaskKind;
    if (output.audit != .found) return null;
    const admitted = record.input.audit.delivery;
    const timestamp = output.audit.found.timestamp;
    return .{
        .admitted = admitted,
        .outcome = .{ .confirmed = .{ .timestamp = timestamp, .metadata_observed = true } },
        .receipt = .{
            .key = admitted.key,
            .destination = admitted.destination,
            .timestamp = timestamp,
            .payload_digest = admitted.payload.content_digest,
            .evidence = .{ .task = record.task, .digest = record.result_digest.? },
            .basis = .history_match,
        },
    };
}

fn batches(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]const @FieldType(t.Step, "batches").Child {
    const BatchFact = @FieldType(t.Step, "batches").Child;
    const head = index.head(obligation);
    var candidates: std.ArrayList(BatchFact) = .empty;
    try importedBatches(a, index, obligation, &candidates);
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
    var size: u64 = 0;
    var sequence = head.told.sequence;
    for (candidates.items) |fact| {
        const batch = fact.value;
        if (batch.sequence <= head.told.sequence) continue;
        if (batch.sequence > head.observed.sequence) return error.BatchBeyondObserved;
        sequence = try std.math.add(u64, sequence, 1);
        if (batch.sequence != sequence) return error.BatchCoverageGap;
        const encoded = try c.encodeOwned(BatchFact, a, fact);
        size = try std.math.add(u64, size, encoded.len);
        if (size > head.specification.policies.render_input_bytes and result.items.len > 0) break;
        try result.append(a, fact);
        if (size > head.specification.policies.render_input_bytes or
            batch.coverage != .complete) break;
    }
    return result.toOwnedSlice(a);
}

fn importedBatches(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    result: *std.ArrayList(@FieldType(t.Step, "batches").Child),
) !void {
    const imported = continuity.findImport(index, obligation.task) orelse return;
    const head = index.head(obligation);
    for (imported.bundle.members.items) |member| {
        if (member.data.kind != .batch or !std.meta.eql(member.data.lineage, head.lineage))
            continue;
        const reference = try continuity.binding(imported.metadata.members.items, member.identity);
        const source = try continuity.resolve(index, obligation.task, reference, .batch);
        const decoded = try continuity.decode(.batch, a, source);
        try result.append(a, .{ .reference = reference, .value = decoded.value });
    }
}
