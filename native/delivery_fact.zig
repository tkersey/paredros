const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const retained = @import("retained.zig");

pub const Result = struct {
    admitted: t.Delivery,
    outcome: ?t.DeliveryOutcome,
    evidence: ?t.Reference,
    terminal: bool,
};

pub fn inspect(
    a: std.mem.Allocator,
    snapshot: retained.Snapshot,
    raw: retained.Evidence,
) !c.Decoded(Result) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const result = try inspectIn(arena.allocator(), snapshot, raw);
    return .{ .arena = arena, .value = result };
}

fn inspectIn(
    a: std.mem.Allocator,
    snapshot: retained.Snapshot,
    raw: retained.Evidence,
) !Result {
    if (!std.mem.eql(u8, snapshot.input.schema_id.bytes, t.input_schema_id))
        return error.WrongApplicationSchema;
    const input = try c.decodeOwned(t.Input, a, raw.input.bytes);
    if (input.value != .delivery) return error.WrongTaskKind;
    var result: Result = .{
        .admitted = input.value.delivery,
        .outcome = null,
        .evidence = null,
        .terminal = snapshot.outcome == .completed or snapshot.outcome == .failed or
            snapshot.outcome == .cancelled,
    };
    const value = snapshot.result orelse return result;
    if (!std.mem.eql(u8, value.schema_id.bytes, t.output_schema_id)) return result;
    const bytes = (raw.result orelse return error.MissingOwnerEvidence).bytes;
    if (bytes.len != value.reference.bytes or
        !std.meta.eql(@import("index.zig").digest(bytes), value.reference.digest))
        return error.DeliveryProjectionMismatch;
    const parsed = try native.json.parseAsset(a, bytes, bytes.len);
    const decoded = try native.values.fromJson(t.Output, a, parsed.value);
    if (decoded != .delivery) return error.WrongTaskKind;
    result.outcome = decoded.delivery;
    result.evidence = .{ .task = snapshot.task, .digest = value.reference.digest };
    return result;
}

pub fn settlement(
    a: std.mem.Allocator,
    snapshot: retained.Snapshot,
    raw: retained.Evidence,
) !c.Decoded(@FieldType(t.Settlement, "delivery")) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const result = try settlementIn(arena.allocator(), snapshot, raw);
    return .{ .arena = arena, .value = result };
}

fn settlementIn(
    a: std.mem.Allocator,
    snapshot: retained.Snapshot,
    raw: retained.Evidence,
) !@FieldType(t.Settlement, "delivery") {
    const evidence = try inspectIn(a, snapshot, raw);
    const confirmed = evidence.outcome != null and evidence.outcome.? == .confirmed;
    if (!evidence.terminal and !confirmed) return null;
    const outcome = evidence.outcome orelse t.DeliveryOutcome{ .rejected = .{
        .code = .{ .bytes = "no_transmitted_write" },
        .retryable = true,
    } };
    const receipt: ?t.Receipt = if (outcome == .confirmed) .{
        .key = evidence.admitted.key,
        .timestamp = outcome.confirmed.timestamp,
        .payload_digest = evidence.admitted.payload.content_digest,
        .evidence = evidence.evidence orelse return error.MissingDeliveryEvidence,
    } else null;
    return .{ .admitted = evidence.admitted, .outcome = outcome, .receipt = receipt };
}
