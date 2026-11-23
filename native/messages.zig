const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const preparation = @import("delivery_prepare.zig");
const delivery_fact = @import("delivery_fact.zig");
const delivery_target = @import("delivery_target.zig");
const restore_eligibility = @import("restore_eligibility.zig");

const proposal_action = @import("../app/turn_delivery.zig").action_id;
const answer_action = "answer";

pub const State = enum {
    delivered,
    pending,
    legacy_delivered,
    legacy_unsent,
    legacy_possibly_sent,
};
pub const Choice = struct {
    label: @FieldType(t.Button, "label"),
    value: @FieldType(t.Button, "value"),
    command: ?c.Text(4096),
};
pub const Message = struct {
    ordinal: u64,
    task: c.Text(32),
    purpose: @FieldType(t.DeliveryKey, "purpose"),
    key: t.DeliveryKey,
    issue: u32,
    supersedes: ?t.DeliveryKey,
    prior_sequence: u64,
    through_sequence: u64,
    text: t.Text,
    links: c.Vector(c.Text(4096), 1),
    choices: c.Vector(Choice, 8),
    state: State,
};
pub const Page = struct {
    messages: c.Vector(Message, 64),
    total: u64,
    next: ?u64,
};

const Entry = struct {
    position: usize,
    segment: u64,
    sequence: u64,
    purpose: u8,
    key: t.Digest,

    fn less(_: void, left: Entry, right: Entry) bool {
        if (left.segment != right.segment) return left.segment < right.segment;
        if (left.sequence != right.sequence) return left.sequence < right.sequence;
        if (left.purpose != right.purpose) return left.purpose < right.purpose;
        return std.mem.order(u8, &left.key, &right.key) == .lt;
    }
};

pub fn page(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: ?t.Id,
    after: ?u64,
    limit: u32,
) !Page {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);
    var confirmed: []const t.DeliveryKey = &.{};
    defer a.free(confirmed);
    if (target) |id| {
        const obligation = index.obligation(id) orelse return error.UnknownObligation;
        try obligationEntries(a, index, obligation, &entries);
        confirmed = try confirmedKeys(a, index, obligation);
    } else try conversationEntries(a, index, &entries);
    std.mem.sort(Entry, entries.items, {}, Entry.less);
    const total: u64 = entries.items.len;
    const start: usize = @intCast(@min(after orelse 0, total));
    const end = @min(entries.items.len, start + limit);
    const items = try a.alloc(Message, end - start);
    for (items, entries.items[start..end], start + 1..) |*item, entry, ordinal| {
        const record = index.records[entry.position];
        item.* = try message(a, record, target, ordinal, confirmed);
    }
    return .{
        .messages = .{ .items = items },
        .total = total,
        .next = if (end < entries.items.len) end else null,
    };
}

fn obligationEntries(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    entries: *std.ArrayList(Entry),
) !void {
    var folds = try foldSegments(a, index, obligation);
    defer folds.deinit(a);
    const mode = index.head(obligation).mode;
    const final = mode == .cancelled or mode == .transferred;
    const tail: ?u64 = if (final and try sealed(a, index, obligation.task, obligation))
        obligation.chain.len
    else
        null;
    for (index.records, 0..) |record, position| {
        if (record.input != .delivery) continue;
        const delivery = record.input.delivery;
        const owner = delivery_target.resolve(index, delivery) orelse continue;
        if (!std.meta.eql(owner, obligation.task)) continue;
        const segment: u64 = if (retired(delivery)) 0 else folds.get(record.task) orelse
            tail orelse continue;
        try entries.append(a, .{
            .position = position,
            .segment = segment,
            .sequence = if (segment == 0) producerSequence(index, owner, delivery) else 0,
            .purpose = @backingInt(delivery.key.purpose),
            .key = try preparation.keyDigest(a, delivery.key),
        });
    }
}

fn conversationEntries(
    a: std.mem.Allocator,
    index: *const idx.Index,
    entries: *std.ArrayList(Entry),
) !void {
    const open = !try sealed(a, index, null, null);
    for (index.records, 0..) |record, position| {
        if (record.input != .delivery) continue;
        const delivery = record.input.delivery;
        if (delivery.key.purpose != .turn or delivery.payload.logical.obligation != null) continue;
        if (open and !retired(delivery)) continue;
        try entries.append(a, .{
            .position = position,
            .segment = @intFromBool(!retired(delivery)),
            .sequence = turnOrdinal(index, delivery),
            .purpose = @backingInt(delivery.key.purpose),
            .key = try preparation.keyDigest(a, delivery.key),
        });
    }
}

fn retired(delivery: t.Delivery) bool {
    return delivery.payload.renderer_version == preparation.legacy_renderer_version;
}

fn foldSegments(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) !std.AutoHashMapUnmanaged(t.Id, u64) {
    var folds: std.AutoHashMapUnmanaged(t.Id, u64) = .empty;
    errdefer folds.deinit(a);
    for (obligation.chain, 0..) |position, segment| {
        const input = index.records[position].input;
        if (input != .step) continue;
        for (input.step.facts.items) |fact| {
            const entry = try folds.getOrPut(a, fact.reference.task);
            if (!entry.found_existing) entry.value_ptr.* = segment;
        }
    }
    return folds;
}

fn sealed(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: ?t.Id,
    obligation: ?*const idx.Obligation,
) !bool {
    if (index.recovery_purpose == .transfer) return true;
    if (obligation) |selected| {
        for (selected.chain) |position| {
            const result = index.records[position].result orelse continue;
            if (result != .step) continue;
            for (result.step.notices.items) |notice|
                if (try awaited(a, index, notice.key)) return false;
        }
    }
    for (index.records) |record| if (try replying(a, index, record, target)) return false;
    return true;
}

fn awaited(a: std.mem.Allocator, index: *const idx.Index, key: t.DeliveryKey) !bool {
    if (!restore_eligibility.allowsKey(index, key)) return false;
    const operation = try preparation.operation(a, key);
    defer a.free(operation);
    return !index.operations.contains(operation);
}

fn replying(
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: idx.Record,
    target: ?t.Id,
) !bool {
    if (record.input != .turn or record.superseded) return false;
    const turn = record.input.turn;
    if (turn.envelope.origin != .slack or !std.meta.eql(turn.target, target)) return false;
    const result = record.result orelse return live(record);
    if (result != .turn) return false;
    const intent = result.turn.delivery orelse return false;
    return awaited(a, index, intent.key);
}

fn live(record: idx.Record) bool {
    if (record.input.turn.attempt < 2) return true;
    const evidence = record.owner_evidence orelse return true;
    return switch (evidence.status orelse return true) {
        .failed, .cancelled, .unknown, .blocked => false,
        else => true,
    };
}

fn turnOrdinal(index: *const idx.Index, delivery: t.Delivery) u64 {
    if (delivery.envelope.origin != .derived) return 0;
    const reference = delivery.envelope.origin.derived.predecessor;
    const record = index.record(reference.task) orelse return 0;
    return if (record.input == .turn) record.input.turn.ordinal else 0;
}

fn headOf(record: *const idx.Record) ?t.Head {
    return switch (record.result orelse return null) {
        .genesis => |head| head,
        .step => |step| step.head,
        else => null,
    };
}

fn producerSequence(index: *const idx.Index, target: t.Id, delivery: t.Delivery) u64 {
    if (delivery.envelope.origin != .derived) return 0;
    const reference = delivery.envelope.origin.derived.predecessor;
    const record = index.record(reference.task) orelse return 0;
    if (headOf(record)) |head| return head.sequence;
    if (record.input != .turn) return 0;
    var sequence: u64 = 0;
    for (record.input.turn.context_references.items) |context| {
        const source = index.record(context.task) orelse continue;
        const head = headOf(source) orelse continue;
        const owner = switch (head.obligation) {
            .self => source.task,
            .task => |id| id,
        };
        if (std.meta.eql(owner, target)) sequence = @max(sequence, head.sequence);
    }
    return sequence;
}

fn confirmedKeys(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]t.DeliveryKey {
    var keys: std.ArrayList(t.DeliveryKey) = .empty;
    errdefer keys.deinit(a);
    for (obligation.chain) |position| {
        const input = index.records[position].input;
        if (input != .step) continue;
        for (input.step.facts.items) |fact| {
            const settled = fact.delivery orelse continue;
            if (settled.outcome == .confirmed) try keys.append(a, settled.admitted.key);
        }
    }
    return keys.toOwnedSlice(a);
}

fn state(
    a: std.mem.Allocator,
    record: idx.Record,
    confirmed: []const t.DeliveryKey,
) !State {
    const delivery = record.input.delivery;
    var sent = false;
    for (confirmed) |key| sent = sent or std.meta.eql(key, delivery.key);
    var excluded = true;
    if (record.owner_snapshot) |snapshot| if (record.owner_evidence) |evidence| {
        var proof = try delivery_fact.inspect(a, snapshot, evidence);
        defer proof.deinit();
        if (proof.value.outcome) |outcome| sent = sent or outcome == .confirmed;
        excluded = proof.value.transmission_excluded;
    };
    if (delivery.payload.renderer_version != preparation.legacy_renderer_version)
        return if (sent) .delivered else .pending;
    if (sent) return .legacy_delivered;
    return if (excluded) .legacy_unsent else .legacy_possibly_sent;
}

fn command(
    a: std.mem.Allocator,
    owner: ?t.Id,
    payload: t.LogicalPayload,
    button: t.Button,
) !?c.Text(4096) {
    if (std.mem.eql(u8, button.action_id.bytes, proposal_action))
        return .{ .bytes = try std.fmt.allocPrint(a, "paredros proposal confirm {s}", .{
            button.value.bytes,
        }) };
    if (!std.mem.eql(u8, button.action_id.bytes, answer_action)) return null;
    const obligation = owner orelse return null;
    const prompt = payload.prompt orelse return null;
    return .{ .bytes = try std.fmt.allocPrint(a, "paredros question answer {s} {s} {s}", .{
        std.fmt.bytesToHex(obligation, .lower),
        std.fmt.bytesToHex(prompt, .lower),
        button.value.bytes,
    }) };
}

fn message(
    a: std.mem.Allocator,
    record: idx.Record,
    owner: ?t.Id,
    ordinal: u64,
    confirmed: []const t.DeliveryKey,
) !Message {
    const delivery = record.input.delivery;
    const payload = delivery.payload.logical;
    const link = try preparation.comparisonLink(a, payload);
    const links = try a.alloc(c.Text(4096), @intFromBool(link != null));
    if (link) |url| links[0] = .{ .bytes = url };
    const choices = try a.alloc(Choice, payload.buttons.items.len);
    for (choices, payload.buttons.items) |*choice, button| choice.* = .{
        .label = button.label,
        .value = button.value,
        .command = try command(a, owner, payload, button),
    };
    return .{
        .ordinal = ordinal,
        .task = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(record.task, .lower)) },
        .purpose = delivery.key.purpose,
        .key = delivery.key,
        .issue = payload.issue,
        .supersedes = payload.supersedes,
        .prior_sequence = payload.prior_sequence,
        .through_sequence = payload.through_sequence,
        .text = payload.frozen_text,
        .links = .{ .items = links },
        .choices = .{ .items = choices },
        .state = try state(a, record, confirmed),
    };
}
