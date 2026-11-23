const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");

pub const renderer_version: u32 = 2;
pub const legacy_renderer_version: u32 = 1;
pub const message_schema = "paredros.message.v1";
pub const Stored = enum { local, legacy };

const Metadata = struct {
    delivery_key: []const u8,
    generation: u32,
    issue: u32,
    lineage_root: []const u8,
    obligation: ?[]const u8,
    source_epoch: u64,
    kind: []const u8,
    prior_observation: u64,
    covered_observation: u64,
    evidence_manifest: []const u8,
    base_oid: ?[]const u8,
    tip_oid: ?[]const u8,
};
const Choice = struct { label: []const u8, value: []const u8 };
const Message = struct {
    schema: []const u8,
    metadata: Metadata,
    text: []const u8,
    links: []const []const u8,
    choices: []const Choice,
};

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

pub fn comparisonLink(a: std.mem.Allocator, payload: t.LogicalPayload) !?[]const u8 {
    const comparison = payload.comparison orelse return null;
    try oid(comparison.base);
    try oid(comparison.tip);
    const owner = try route(a, comparison.repository.owner.bytes);
    defer a.free(owner);
    const name = try route(a, comparison.repository.name.bytes);
    defer a.free(name);
    return try std.fmt.allocPrint(a, "https://github.com/{s}/{s}/compare/{s}...{s}", .{
        owner, name, comparison.base, comparison.tip,
    });
}

fn oid(value: t.Oid) !void {
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPayload;
}

fn describe(a: std.mem.Allocator, intent: t.DeliveryIntent, evidence: t.Digest) !Metadata {
    const payload = intent.payload;
    if (payload.schema_version != 1 or payload.prior_sequence > payload.through_sequence)
        return error.InvalidPayload;
    if (intent.key.purpose == .digest and
        (payload.coverage == null or payload.prior_sequence == payload.through_sequence))
        return error.InvalidPayload;
    var tip: ?[]const u8 = null;
    var epoch: u64 = 0;
    if (payload.coverage) |coverage| {
        if (coverage.sequence != payload.through_sequence) return error.InvalidPayload;
        epoch = coverage.epoch;
        if (coverage.tip) |value| {
            try oid(value);
            tip = try a.dupe(u8, &value);
        }
    }
    var base: ?[]const u8 = null;
    if (payload.comparison) |comparison| {
        try oid(comparison.base);
        try oid(comparison.tip);
        if (intent.key.purpose == .digest and
            (tip == null or !std.mem.eql(u8, tip.?, &comparison.tip)))
            return error.InvalidPayload;
        tip = try a.dupe(u8, &comparison.tip);
        base = try a.dupe(u8, &comparison.base);
    }
    return .{
        .delivery_key = try a.dupe(u8, &std.fmt.bytesToHex(try keyDigest(a, intent.key), .lower)),
        .generation = intent.key.generation,
        .issue = payload.issue,
        .lineage_root = try a.dupe(u8, &std.fmt.bytesToHex(intent.key.lineage, .lower)),
        .obligation = if (payload.obligation) |id|
            try a.dupe(u8, &std.fmt.bytesToHex(id, .lower))
        else
            null,
        .source_epoch = epoch,
        .kind = @tagName(intent.key.purpose),
        .prior_observation = payload.prior_sequence,
        .covered_observation = payload.through_sequence,
        .evidence_manifest = try a.dupe(u8, &std.fmt.bytesToHex(evidence, .lower)),
        .base_oid = base,
        .tip_oid = tip,
    };
}

pub fn wire(a: std.mem.Allocator, intent: t.DeliveryIntent, evidence: t.Digest) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const buttons = intent.payload.buttons.items;
    const choices = try scratch.alloc(Choice, buttons.len);
    for (choices, buttons) |*choice, button| choice.* = .{
        .label = button.label.bytes,
        .value = button.value.bytes,
    };
    const link = try comparisonLink(scratch, intent.payload);
    const links: []const []const u8 = if (link) |url|
        try scratch.dupe([]const u8, &.{url})
    else
        &.{};
    return std.json.Stringify.valueAlloc(a, Message{
        .schema = message_schema,
        .metadata = try describe(scratch, intent, evidence),
        .text = intent.payload.frozen_text.bytes,
        .links = links,
        .choices = choices,
    }, .{});
}

pub fn operation(a: std.mem.Allocator, key: t.DeliveryKey) ![]u8 {
    return std.fmt.allocPrint(a, "delivery:{s}", .{
        std.fmt.bytesToHex(try keyDigest(a, key), .lower),
    });
}

fn stableRequest(
    a: std.mem.Allocator,
    destination: t.Destination,
    key: t.DeliveryKey,
    payload: t.DeliveryPayload,
) !t.Digest {
    const request = try c.encodeOwned(struct {
        destination: t.Destination,
        key: t.DeliveryKey,
        payload: t.DeliveryPayload,
    }, a, .{ .destination = destination, .key = key, .payload = payload });
    defer a.free(request);
    return hash(request);
}

pub fn verifyStored(a: std.mem.Allocator, delivery: t.Delivery) !Stored {
    if (delivery.envelope.version != 1 or delivery.envelope.origin != .derived)
        return error.InvalidPayload;
    const stored: Stored = switch (delivery.payload.renderer_version) {
        renderer_version => .local,
        legacy_renderer_version => .legacy,
        else => return error.UnsupportedRenderer,
    };
    const expected_operation = try operation(a, delivery.key);
    defer a.free(expected_operation);
    if (!std.mem.eql(u8, delivery.envelope.operation.bytes, expected_operation) or
        !std.meta.eql(
            delivery.envelope.stable_request,
            try stableRequest(a, delivery.destination, delivery.key, delivery.payload),
        )) return error.InvalidPayload;
    if (stored == .legacy) return stored;
    const expected = try wire(a, projectIntent(delivery), delivery.payload.evidence_digest);
    defer a.free(expected);
    if (!std.mem.eql(u8, expected, delivery.payload.wire_json.bytes) or
        !std.meta.eql(hash(expected), delivery.payload.content_digest) or
        !std.meta.eql(try markerDigest(a, expected), delivery.payload.marker_digest))
        return error.InvalidPayload;
    return stored;
}

pub fn materialize(
    a: std.mem.Allocator,
    intent: t.DeliveryIntent,
    producer: t.Reference,
    evidence: t.Digest,
) !c.Decoded(t.Delivery) {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const body = try wire(scratch, intent, evidence);
    const payload: t.DeliveryPayload = .{
        .renderer_version = renderer_version,
        .logical = intent.payload,
        .content_digest = hash(body),
        .marker_digest = try markerDigest(scratch, body),
        .evidence_digest = evidence,
        .wire_json = .{ .bytes = body },
    };
    const encoded = try c.encodeOwned(t.Delivery, scratch, .{
        .envelope = .{
            .operation = .{ .bytes = try operation(scratch, intent.key) },
            .stable_request = try stableRequest(scratch, intent.destination, intent.key, payload),
            .origin = .{ .derived = .{ .predecessor = producer } },
        },
        .destination = intent.destination,
        .key = intent.key,
        .payload = payload,
    });
    return c.decodeOwned(t.Delivery, a, encoded);
}
