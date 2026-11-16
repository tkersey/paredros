const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const horos = @import("horos");
const t = @import("application_types");
const contract = @import("../app/slack_contract.zig");
const retained = @import("retained.zig");

pub const Result = struct {
    admitted: t.Delivery,
    outcome: ?t.DeliveryOutcome,
    evidence: ?t.Reference,
    transmission_excluded: bool,
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
        .transmission_excluded = true,
        .terminal = snapshot.outcome == .completed or snapshot.outcome == .failed or
            snapshot.outcome == .cancelled,
    };
    for (snapshot.attempts.items) |attempt| {
        if (!std.mem.eql(u8, attempt.capability.bytes, contract.notification_identity)) continue;
        try inspectAttempt(a, snapshot.task, raw, attempt, &result);
    }
    if (snapshot.result) |value| {
        if (!std.mem.eql(u8, value.schema_id.bytes, t.output_schema_id)) return result;
        const bytes = (raw.result orelse return error.MissingOwnerEvidence).bytes;
        if (bytes.len != value.reference.bytes or
            !std.meta.eql(@import("index.zig").digest(bytes), value.reference.digest))
            return error.DeliveryProjectionMismatch;
        const parsed = try native.json.parseAsset(a, bytes, bytes.len);
        const decoded = try native.values.fromJson(t.Output, a, parsed.value);
        if (decoded != .delivery) return error.WrongTaskKind;
        if (result.outcome) |projected| {
            const left = try c.encodeOwned(t.DeliveryOutcome, a, projected);
            const right = try c.encodeOwned(t.DeliveryOutcome, a, decoded.delivery);
            if (!std.mem.eql(u8, left, right)) return error.DeliveryProjectionMismatch;
        }
        result.outcome = decoded.delivery;
        result.evidence = .{ .task = snapshot.task, .digest = value.reference.digest };
    }
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
    const dead_unknown = raw.status == .unknown and !evidence.transmission_excluded;
    if (!evidence.terminal and !dead_unknown and
        (evidence.outcome == null or evidence.outcome.? != .confirmed)) return null;
    const outcome = if (evidence.outcome != null and evidence.outcome.? == .confirmed)
        evidence.outcome.?
    else if (!evidence.transmission_excluded)
        t.DeliveryOutcome{ .indeterminate = .{ .bytes = "possibly_transmitted" } }
    else
        evidence.outcome orelse t.DeliveryOutcome{ .rejected = .{
            .code = .{ .bytes = "no_transmitted_write" },
            .retryable = true,
        } };
    const receipt: ?t.Receipt = if (outcome == .confirmed) .{
        .key = evidence.admitted.key,
        .destination = evidence.admitted.destination,
        .timestamp = outcome.confirmed.timestamp,
        .payload_digest = evidence.admitted.payload.content_digest,
        .evidence = evidence.evidence orelse return error.MissingDeliveryEvidence,
        .basis = .captured_response,
    } else null;
    return .{ .admitted = evidence.admitted, .outcome = outcome, .receipt = receipt };
}

fn replyBytes(raw: retained.Evidence, id: t.Digest, reference: retained.Object) ![]const u8 {
    for (raw.attempts) |attempt| {
        if (!std.meta.eql(attempt.id, id)) continue;
        const bytes = attempt.reply orelse return error.MissingOwnerEvidence;
        if (bytes.len != reference.bytes or
            !std.meta.eql(@import("index.zig").digest(bytes), reference.digest))
            return error.DeliveryProjectionMismatch;
        return bytes;
    }
    return error.MissingOwnerEvidence;
}

fn inspectAttempt(
    a: std.mem.Allocator,
    task: t.Id,
    raw: retained.Evidence,
    attempt: retained.Attempt,
    result: *Result,
) !void {
    const capture = attempt.capture orelse {
        result.transmission_excluded = false;
        return;
    };
    if (capture.disposition == .definitely_not_sent) return;
    const reference = capture.reply orelse {
        result.transmission_excluded = false;
        return;
    };
    const bytes = try replyBytes(raw, attempt.id, reference);
    const reply = try horos.data.invocation.decode(horos.data.invocation.Result, a, bytes);
    const decoded = try c.decodeOwned(t.DeliveryOutcome, a, reply.value.value);
    if (decoded.value != .rejected) result.transmission_excluded = false;
    if (result.outcome != null) return error.AmbiguousNotificationOutcome;
    result.outcome = decoded.value;
    result.evidence = .{ .task = task, .digest = reference.digest };
}
