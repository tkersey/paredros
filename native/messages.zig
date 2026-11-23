const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const preparation = @import("delivery_prepare.zig");
const delivery_fact = @import("delivery_fact.zig");
const delivery_target = @import("delivery_target.zig");

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
    sequence: u64,
    purpose: u8,
    key: t.Digest,

    fn less(_: void, left: Entry, right: Entry) bool {
        if (left.sequence != right.sequence) return left.sequence < right.sequence;
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
    for (index.records, 0..) |record, position| {
        if (record.input != .delivery) continue;
        const delivery = record.input.delivery;
        const owner = delivery_target.resolve(index, delivery) orelse continue;
        if (!std.meta.eql(owner, target)) continue;
        try entries.append(a, .{
            .position = position,
            .sequence = producerSequence(index, target, delivery),
            .purpose = @backingInt(delivery.key.purpose),
            .key = try preparation.keyDigest(a, delivery.key),
        });
    }
    std.mem.sort(Entry, entries.items, {}, Entry.less);
    const confirmed = try confirmedKeys(a, index, obligation);
    defer a.free(confirmed);
    const total: u64 = entries.items.len;
    const start: usize = @intCast(@min(after orelse 0, total));
    const end = @min(entries.items.len, start + limit);
    const items = try a.alloc(Message, end - start);
    for (items, entries.items[start..end], start + 1..) |*item, entry, ordinal| {
        item.* = try message(a, index.records[entry.position], ordinal, confirmed);
    }
    return .{
        .messages = .{ .items = items },
        .total = total,
        .next = if (end < entries.items.len) end else null,
    };
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
    payload: t.LogicalPayload,
    button: t.Button,
) !?c.Text(4096) {
    if (std.mem.eql(u8, button.action_id.bytes, proposal_action))
        return .{ .bytes = try std.fmt.allocPrint(a, "paredros proposal confirm {s}", .{
            button.value.bytes,
        }) };
    if (!std.mem.eql(u8, button.action_id.bytes, answer_action)) return null;
    const obligation = payload.obligation orelse return null;
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
        .command = try command(a, payload, button),
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
