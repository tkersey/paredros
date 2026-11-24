const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const preparation = @import("delivery_prepare.zig");
const delivery_fact = @import("delivery_fact.zig");
const delivery_target = @import("delivery_target.zig");

const answer_action = "answer";

pub const State = enum { delivered, pending };
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
    purpose: u8,
    key: t.Digest,

    fn less(_: void, left: Entry, right: Entry) bool {
        if (left.segment != right.segment) return left.segment < right.segment;
        if (left.purpose != right.purpose) return left.purpose < right.purpose;
        return std.mem.order(u8, &left.key, &right.key) == .lt;
    }
};

pub fn page(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    after: ?u64,
    limit: u32,
) !Page {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);
    try obligationEntries(a, index, obligation, &entries);
    const confirmed = try confirmedKeys(a, index, obligation);
    defer a.free(confirmed);
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
    const tail: ?u64 = if (final) obligation.chain.len else null;
    for (index.records, 0..) |record, position| {
        if (record.input != .delivery) continue;
        const delivery = record.input.delivery;
        const owner = delivery_target.resolve(index, delivery) orelse continue;
        if (!std.meta.eql(owner, obligation.task)) continue;
        try entries.append(a, .{
            .position = position,
            .segment = folds.get(record.task) orelse tail orelse continue,
            .purpose = @backingInt(delivery.key.purpose),
            .key = try preparation.keyDigest(a, delivery.key),
        });
    }
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
    for (confirmed) |key| if (std.meta.eql(key, delivery.key)) return .delivered;
    const snapshot = record.owner_snapshot orelse return .pending;
    const evidence = record.owner_evidence orelse return .pending;
    var proof = try delivery_fact.inspect(a, snapshot, evidence);
    defer proof.deinit();
    const outcome = proof.value.outcome orelse return .pending;
    return if (outcome == .confirmed) .delivered else .pending;
}

fn command(
    a: std.mem.Allocator,
    obligation: t.Id,
    payload: t.LogicalPayload,
    button: t.Button,
) !?c.Text(4096) {
    if (!std.mem.eql(u8, button.action_id.bytes, answer_action)) return null;
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
    owner: t.Id,
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
