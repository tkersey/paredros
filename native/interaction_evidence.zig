const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");
const slack = @import("slack.zig");
const preparation = @import("delivery_prepare.zig");

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

pub fn target(index: *const idx.Index, record: idx.Record) ?t.Id {
    const envelope = envelopeOf(record.input);
    const ingress = envelope.ingress orelse return null;
    const proof = ingress.interaction orelse return null;
    const source = index.record(proof.delivery.task) orelse return null;
    if (source.input != .delivery or !std.meta.eql(source.input_digest, proof.delivery.digest))
        return null;
    return @import("delivery_target.zig").resolve(index, source.input.delivery);
}

pub fn envelopeOf(input: t.Input) t.Envelope {
    return switch (input) {
        inline else => |value| value.envelope,
    };
}

pub fn settlement(
    a: std.mem.Allocator,
    index: *const idx.Index,
    record: idx.Record,
) !@FieldType(t.Settlement, "delivery") {
    const envelope = envelopeOf(record.input);
    const ingress = envelope.ingress orelse return null;
    const proof = ingress.interaction orelse return null;
    const source = index.record(proof.delivery.task) orelse return error.MissingInteractionDelivery;
    if (source.input != .delivery or !std.meta.eql(source.input_digest, proof.delivery.digest))
        return error.InvalidInteractionDelivery;
    const delivery = source.input.delivery;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const metadata = try verify(arena.allocator(), source.*, envelope, ingress, delivery);
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
) !bool {
    if (envelope.origin != .slack) return error.InvalidInteractionOrigin;
    const proof = ingress.interaction.?;
    const actor = envelope.origin.slack;
    const binding: slack.Binding = .{
        .app_id = actor.app.bytes,
        .team_id = actor.workspace.bytes,
        .operator_id = actor.user.bytes,
        .channel_id = actor.channel.bytes,
        .bot_id = proof.bot_id.bytes,
    };
    const identity = slack.interactionDigest(binding, proof.message_timestamp.bytes, ingress.timestamp.bytes, proof.block_id.bytes, proof.action_id.bytes, proof.value.bytes);
    if (!std.meta.eql(identity, ingress.stable_request)) return error.InvalidInteractionIdentity;
    const operation = try std.fmt.allocPrint(a, "slack:{s}", .{
        std.fmt.bytesToHex(identity, .lower),
    });
    defer a.free(operation);
    if (!std.mem.eql(u8, operation, envelope.operation.bytes)) return error.InvalidInteractionIdentity;
    var message = try std.json.parseFromSlice(std.json.Value, a, proof.message.bytes, .{});
    defer message.deinit();
    var prepared = try preparation.verify(a, delivery.destination, delivery.key, delivery.payload, proof.bot_id.bytes);
    defer prepared.deinit();
    const timestamp = try knownTimestamp(a, source);
    const button = try selectedButton(delivery, proof);
    try slack.bindInteraction(a, .{
        .origin = binding,
        .operation = identity,
        .stable_request = identity,
        .message_timestamp = proof.message_timestamp.bytes,
        .action_timestamp = ingress.timestamp.bytes,
        .block_id = proof.block_id.bytes,
        .action_id = proof.action_id.bytes,
        .value = proof.value.bytes,
        .message = message.value,
    }, prepared, .{
        .block_id = button.block_id.bytes,
        .action_id = button.action_id.bytes,
        .value = button.value.bytes,
        .label = button.label.bytes,
    }, if (timestamp) |value| value.bytes else null);
    return timestamp == null;
}

fn selectedButton(delivery: t.Delivery, proof: anytype) !t.Button {
    for (delivery.payload.logical.buttons.items) |button| {
        if (std.mem.eql(u8, button.block_id.bytes, proof.block_id.bytes) and
            std.mem.eql(u8, button.action_id.bytes, proof.action_id.bytes) and
            std.mem.eql(u8, button.value.bytes, proof.value.bytes)) return button;
    }
    return error.UnboundInteraction;
}
