const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");

pub const notification_identity = "agent.notification.deliver.v1.slack";
pub const history_identity = "paredros.slack.history.v1";
pub const lineage_history_identity = "paredros.slack.lineage-history.v1";

const Fact = @FieldType(t.Settlement, "delivery");

pub fn interactionDigest(
    actor: @FieldType(t.Origin, "slack"),
    message_timestamp: []const u8,
    action_timestamp: []const u8,
    block: []const u8,
    action: []const u8,
    value: []const u8,
) t.Digest {
    const parts = [_][]const u8{
        "paredros.slack.interaction/1", actor.app.bytes,     actor.workspace.bytes,
        actor.user.bytes,               actor.channel.bytes, message_timestamp,
        block,                          action,              value,
        action_timestamp,
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(part.len), .big);
        hash.update(&length);
        hash.update(part);
    }
    return hash.finalResult();
}

pub fn knownTimestamp(a: std.mem.Allocator, record: idx.Record) !?t.Timestamp {
    if (record.result) |result| if (result == .delivery and result.delivery == .confirmed)
        return result.delivery.confirmed.timestamp;
    const snapshot = record.owner_snapshot orelse return null;
    const raw = record.owner_evidence orelse return null;
    var proof = try @import("delivery_fact.zig").inspect(a, snapshot, raw);
    defer proof.deinit();
    const outcome = proof.value.outcome orelse return null;
    if (outcome != .confirmed) return null;
    return .{ .bytes = try a.dupe(u8, outcome.confirmed.timestamp.bytes) };
}

pub fn interactionTarget(index: *const idx.Index, record: idx.Record) ?t.Id {
    const envelope = envelopeOf(record.input);
    const ingress = envelope.ingress orelse return null;
    const proof = ingress.interaction orelse return null;
    const source = index.record(proof.delivery.task) orelse return null;
    if (source.input != .delivery or !std.meta.eql(source.input_digest, proof.delivery.digest))
        return null;
    return @import("delivery_target.zig").resolve(index, source.input.delivery);
}

fn envelopeOf(input: t.Input) t.Envelope {
    return switch (input) {
        inline else => |value| value.envelope,
    };
}

pub fn interaction(a: std.mem.Allocator, index: *const idx.Index, record: idx.Record) !Fact {
    return bound(a, index, record, null);
}

pub fn copiedInteraction(
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: idx.Record,
    metadata: bool,
) !Fact {
    return bound(a, index, record, metadata);
}

fn bound(
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: idx.Record,
    claimed: ?bool,
) !Fact {
    const envelope = envelopeOf(record.input);
    const ingress = envelope.ingress orelse return null;
    const proof = ingress.interaction orelse return null;
    const source = index.record(proof.delivery.task) orelse return error.MissingInteractionDelivery;
    if (source.input != .delivery or !std.meta.eql(source.input_digest, proof.delivery.digest))
        return error.InvalidInteractionDelivery;
    const delivery = source.input.delivery;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const metadata = try verify(arena.allocator(), source.*, envelope, ingress, delivery, claimed);
    return .{
        .admitted = delivery,
        .outcome = .{ .confirmed = .{
            .timestamp = proof.message_timestamp,
            .metadata_observed = metadata,
        } },
        .receipt = .{
            .key = delivery.key,
            .destination = delivery.destination,
            .timestamp = proof.message_timestamp,
            .payload_digest = delivery.payload.content_digest,
            .evidence = .{ .task = record.task, .digest = record.input_digest },
            .basis = .bound_interaction,
        },
    };
}

fn verify(
    a: std.mem.Allocator,
    source: idx.Record,
    envelope: t.Envelope,
    ingress: t.Ingress,
    delivery: t.Delivery,
    claimed: ?bool,
) !bool {
    if (envelope.origin != .slack) return error.InvalidInteractionOrigin;
    const proof = ingress.interaction.?;
    const identity = interactionDigest(
        envelope.origin.slack,
        proof.message_timestamp.bytes,
        ingress.timestamp.bytes,
        proof.block_id.bytes,
        proof.action_id.bytes,
        proof.value.bytes,
    );
    if (!std.meta.eql(identity, ingress.stable_request)) return error.InvalidInteractionIdentity;
    const operation = try std.fmt.allocPrint(a, "slack:{s}", .{
        std.fmt.bytesToHex(identity, .lower),
    });
    defer a.free(operation);
    if (!std.mem.eql(u8, operation, envelope.operation.bytes))
        return error.InvalidInteractionIdentity;
    const metadata = try path(a, source, proof.message_timestamp, claimed);
    try selectedButton(delivery, proof);
    return metadata;
}

fn path(
    a: std.mem.Allocator,
    source: idx.Record,
    message: t.Timestamp,
    claimed: ?bool,
) !bool {
    const known = try knownTimestamp(a, source);
    const matched = known != null and std.mem.eql(u8, known.?.bytes, message.bytes);
    const metadata = claimed orelse !matched;
    if (!metadata and !matched) return error.CopiedInteractionMismatch;
    return metadata;
}

fn selectedButton(delivery: t.Delivery, proof: anytype) !void {
    for (delivery.payload.logical.buttons.items) |button| {
        if (std.mem.eql(u8, button.block_id.bytes, proof.block_id.bytes) and
            std.mem.eql(u8, button.action_id.bytes, proof.action_id.bytes) and
            std.mem.eql(u8, button.value.bytes, proof.value.bytes)) return;
    }
    return error.UnboundInteraction;
}
