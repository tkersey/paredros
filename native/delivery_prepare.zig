const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const slack = @import("slack.zig");

pub const renderer_version: u32 = 1;

pub fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn keyDigest(a: std.mem.Allocator, key: t.DeliveryKey) !t.Digest {
    const bytes = try c.encodeOwned(t.DeliveryKey, a, key);
    defer a.free(bytes);
    return hash(bytes);
}

pub fn markerDigest(a: std.mem.Allocator, wire_bytes: []const u8) !t.Digest {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, wire_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const metadata = parsed.value.object.get("metadata") orelse return error.InvalidPayload;
    const bytes = try std.json.Stringify.valueAlloc(a, metadata, .{});
    defer a.free(bytes);
    return hash(bytes);
}

pub fn projectIntent(delivery: t.Delivery) t.DeliveryIntent {
    return .{
        .destination = delivery.destination,
        .key = delivery.key,
        .payload = delivery.payload.logical,
    };
}

pub fn binding(destination: t.Destination, bot_id: []const u8) slack.Binding {
    return .{
        .app_id = destination.app.bytes,
        .team_id = destination.workspace.bytes,
        .operator_id = destination.operator.bytes,
        .channel_id = destination.channel.bytes,
        .bot_id = bot_id,
    };
}

fn route(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(a);
    const alphabet = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') {
            try encoded.append(a, byte);
        } else try encoded.appendSlice(a, &.{ '%', alphabet[byte >> 4], alphabet[byte & 15] });
    }
    return encoded.toOwnedSlice(a);
}

fn oid(value: t.Oid) !void {
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPayload;
}

fn marker(a: std.mem.Allocator, intent: t.DeliveryIntent, evidence: t.Digest) !slack.Marker {
    const payload = intent.payload;
    if (payload.schema_version != 1 or payload.prior_sequence > payload.through_sequence)
        return error.InvalidPayload;
    if (intent.key.purpose == .digest and
        (payload.coverage == null or payload.prior_sequence == payload.through_sequence))
        return error.InvalidPayload;
    var tip: []const u8 = "";
    var epoch: u64 = 0;
    if (payload.coverage) |coverage| {
        if (coverage.sequence != payload.through_sequence) return error.InvalidPayload;
        epoch = coverage.epoch;
        if (coverage.tip) |value| {
            try oid(value);
            tip = try a.dupe(u8, &value);
        }
    }
    var base: []const u8 = "";
    if (payload.comparison) |comparison| {
        try oid(comparison.base);
        try oid(comparison.tip);
        if (intent.key.purpose == .digest and !std.mem.eql(u8, tip, &comparison.tip))
            return error.InvalidPayload;
        tip = try a.dupe(u8, &comparison.tip);
        base = try a.dupe(u8, &comparison.base);
    }
    return .{
        .key = try keyDigest(a, intent.key),
        .generation = intent.key.generation,
        .issue = payload.issue,
        .content = @splat(0),
        .lineage = try a.dupe(u8, &std.fmt.bytesToHex(intent.key.lineage, .lower)),
        .obligation = if (payload.obligation) |id|
            try a.dupe(u8, &std.fmt.bytesToHex(id, .lower))
        else
            "none",
        .source_epoch = try std.fmt.allocPrint(a, "{d}", .{epoch}),
        .kind = switch (intent.key.purpose) {
            .activation => .activation,
            .digest => .digest,
            .question => .question,
            .control => .directive,
            .turn, .failure => .reply,
        },
        .prior = payload.prior_sequence,
        .covered = payload.through_sequence,
        .evidence = evidence,
        .base_oid = base,
        .tip_oid = tip,
    };
}

pub fn wire(
    a: std.mem.Allocator,
    intent: t.DeliveryIntent,
    evidence: t.Digest,
    bot_id: []const u8,
) !slack.Prepared {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const buttons = try scratch.alloc(slack.Button, intent.payload.buttons.items.len);
    for (buttons, intent.payload.buttons.items) |*target, source| target.* = .{
        .block_id = source.block_id.bytes,
        .action_id = source.action_id.bytes,
        .value = source.value.bytes,
        .label = source.label.bytes,
    };
    var links: []const slack.Link = &.{};
    if (intent.payload.comparison) |comparison| {
        const url = try std.fmt.allocPrint(scratch, "https://github.com/{s}/{s}/compare/{s}...{s}", .{
            try route(scratch, comparison.repository.owner.bytes),
            try route(scratch, comparison.repository.name.bytes),
            comparison.base,
            comparison.tip,
        });
        links = try scratch.dupe(slack.Link, &.{.{ .label = "Comparison", .url = url }});
    }
    return slack.prepareLinked(a, binding(intent.destination, bot_id), intent.payload.frozen_text.bytes, buttons, links, try marker(scratch, intent, evidence));
}

pub fn verify(
    a: std.mem.Allocator,
    destination: t.Destination,
    key: t.DeliveryKey,
    payload: t.DeliveryPayload,
    bot_id: []const u8,
) !slack.Prepared {
    if (payload.renderer_version != renderer_version) return error.UnsupportedRenderer;
    var prepared = try wire(a, .{
        .destination = destination,
        .key = key,
        .payload = payload.logical,
    }, payload.evidence_digest, bot_id);
    errdefer prepared.deinit();
    if (!std.mem.eql(u8, prepared.body, payload.wire_json.bytes) or
        !std.meta.eql(prepared.marker.content, payload.content_digest) or
        !std.meta.eql(try markerDigest(a, prepared.body), payload.marker_digest))
        return error.InvalidPayload;
    return prepared;
}

pub fn operation(a: std.mem.Allocator, key: t.DeliveryKey) ![]u8 {
    return std.fmt.allocPrint(a, "delivery:{s}", .{
        std.fmt.bytesToHex(try keyDigest(a, key), .lower),
    });
}

pub fn verifyStored(a: std.mem.Allocator, delivery: t.Delivery) !void {
    if (delivery.envelope.version != 1 or delivery.envelope.origin != .derived)
        return error.InvalidPayload;
    var prepared = try verify(a, delivery.destination, delivery.key, delivery.payload, "");
    defer prepared.deinit();
    const expected_operation = try operation(a, delivery.key);
    defer a.free(expected_operation);
    const request = try c.encodeOwned(struct {
        destination: t.Destination,
        key: t.DeliveryKey,
        payload: t.DeliveryPayload,
    }, a, .{
        .destination = delivery.destination,
        .key = delivery.key,
        .payload = delivery.payload,
    });
    defer a.free(request);
    if (!std.mem.eql(u8, delivery.envelope.operation.bytes, expected_operation) or
        !std.meta.eql(delivery.envelope.stable_request, hash(request))) return error.InvalidPayload;
}

pub fn materialize(
    a: std.mem.Allocator,
    intent: t.DeliveryIntent,
    producer: t.Reference,
    evidence: t.Digest,
    bot_id: []const u8,
) !c.Decoded(t.Delivery) {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var prepared = try wire(scratch, intent, evidence, bot_id);
    defer prepared.deinit();
    const payload: t.DeliveryPayload = .{
        .logical = intent.payload,
        .content_digest = prepared.marker.content,
        .marker_digest = try markerDigest(scratch, prepared.body),
        .evidence_digest = evidence,
        .wire_json = .{ .bytes = prepared.body },
    };
    const request = try c.encodeOwned(struct {
        destination: t.Destination,
        key: t.DeliveryKey,
        payload: t.DeliveryPayload,
    }, scratch, .{ .destination = intent.destination, .key = intent.key, .payload = payload });
    const encoded = try c.encodeOwned(t.Delivery, scratch, .{
        .envelope = .{
            .operation = .{ .bytes = try operation(scratch, intent.key) },
            .stable_request = hash(request),
            .origin = .{ .derived = .{ .predecessor = producer } },
        },
        .destination = intent.destination,
        .key = intent.key,
        .payload = payload,
    });
    return c.decodeOwned(t.Delivery, a, encoded);
}
