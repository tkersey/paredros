const std = @import("std");
const c = @import("protean_contracts");
const horos = @import("horos");
const native = @import("protean_native");
const t = @import("application_types");
const retained = @import("../native/retained.zig");
const facts = @import("../native/delivery_fact.zig");
const index = @import("../native/index.zig");
const legacy = @import("../native/legacy.zig");
const examples = @import("contracts.zig");
const a = std.testing.allocator;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: retained.Snapshot,
    evidence: retained.Evidence,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const delivery: t.Delivery = .{
            .envelope = examples.genesis().envelope,
            .destination = examples.specification().destination,
            .key = .{
                .lineage = @splat(1),
                .purpose = .activation,
                .identity = @splat(2),
                .generation = 0,
            },
            .payload = .{
                .logical = .{
                    .obligation = @splat(3),
                    .specification_revision = 1,
                    .prior_sequence = 0,
                    .through_sequence = 1,
                    .frozen_text = .{ .bytes = "digest" },
                    .prompt = null,
                    .supersedes = null,
                },
                .content_digest = @splat(4),
                .marker_digest = @splat(5),
                .evidence_digest = @splat(6),
                .wire_json = .{ .bytes = "{}" },
            },
        };
        const bytes = try c.encodeOwned(t.Input, allocator, .{ .delivery = delivery });
        const reference = object(bytes);
        return .{
            .arena = arena,
            .snapshot = .{
                .task = @splat(1),
                .revision = 1,
                .event_cut = 1,
                .outcome = .requested,
                .input = .{
                    .schema_id = .{ .bytes = t.input_schema_id },
                    .encoding = .contract,
                    .reference = reference,
                },
                .result = null,
                .profile = object(""),
                .inference_attempts = 0,
                .inference_request_bytes = 0,
                .inference_output_tokens = 0,
                .evidence_bytes = 0,
                .attempts = .{ .items = &.{} },
                .unknown_calls = .{ .items = &.{} },
                .accounting = .{},
            },
            .evidence = .{
                .input = .{
                    .task = @splat(1),
                    .revision = 1,
                    .digest = reference.digest,
                    .schema_id = t.input_schema_id,
                    .encoding = .contract,
                    .bytes = bytes,
                },
                .result = null,
                .profile_bytes = "",
                .attempts = &.{},
            },
        };
    }

    fn retarget(self: *Fixture, purpose: @FieldType(t.DeliveryKey, "purpose"), renderer: u32) !void {
        const allocator = self.arena.allocator();
        var input = try c.decodeOwned(t.Input, allocator, self.evidence.input.bytes);
        input.value.delivery.key.purpose = purpose;
        input.value.delivery.payload.renderer_version = renderer;
        const bytes = try c.encodeOwned(t.Input, allocator, input.value);
        self.snapshot.input.reference = object(bytes);
        self.evidence.input.digest = self.snapshot.input.reference.digest;
        self.evidence.input.bytes = bytes;
    }

    fn complete(self: *Fixture, outcome: t.DeliveryOutcome) !void {
        const allocator = self.arena.allocator();
        const output = try native.values.toJson(t.Output, allocator, .{ .delivery = outcome });
        const bytes = try std.json.Stringify.valueAlloc(allocator, output, .{});
        self.snapshot.outcome = .completed;
        self.snapshot.result = .{
            .schema_id = .{ .bytes = t.output_schema_id },
            .encoding = .json,
            .reference = object(bytes),
        };
        self.evidence.result = .{
            .task = @splat(1),
            .revision = 1,
            .digest = self.snapshot.result.?.reference.digest,
            .schema_id = t.output_schema_id,
            .encoding = .json,
            .bytes = bytes,
        };
    }

    fn addReply(self: *Fixture, outcome: t.DeliveryOutcome) !void {
        const allocator = self.arena.allocator();
        const value = try c.encodeOwned(t.DeliveryOutcome, allocator, outcome);
        const reply: horos.data.invocation.Result = .{
            .request_identity = @splat(1),
            .value = value,
        };
        const bytes = try allocator.alloc(
            u8,
            try horos.data.invocation.encodedLength(horos.data.invocation.Result, reply),
        );
        _ = try horos.data.invocation.encode(horos.data.invocation.Result, allocator, reply, bytes);
        const attempts = try allocator.alloc(retained.Attempt, 1);
        attempts[0] = attempt(1, .complete);
        attempts[0].capture.?.reply = object(bytes);
        const evidence = try allocator.alloc(retained.AttemptEvidence, 1);
        evidence[0] = .{ .id = attempts[0].id, .response = "capture", .reply = bytes };
        self.snapshot.attempts.items = attempts;
        self.evidence.attempts = evidence;
    }
};

fn object(bytes: []const u8) retained.Object {
    return .{ .digest = index.digest(bytes), .bytes = bytes.len };
}

fn attempt(id: u8, disposition: ?@FieldType(retained.Capture, "disposition")) retained.Attempt {
    return .{
        .id = @splat(id),
        .occurrence = @splat(id),
        .capability = .{ .bytes = legacy.notification_identity },
        .inference = false,
        .request = object("request"),
        .prepared = object("prepared"),
        .capture = if (disposition) |kind| .{
            .disposition = kind,
            .response = if (kind == .complete) object("capture") else null,
            .reply = null,
            .output_tokens = null,
        } else null,
        .usage = null,
    };
}

test "delivery facts distinguish live queued and dispatching from terminal non transmission" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    var live = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer live.deinit();
    try std.testing.expect(live.value == null);
    fixture.snapshot.attempts.items = &.{attempt(1, null)};
    var dispatching = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer dispatching.deinit();
    try std.testing.expect(dispatching.value == null);
    fixture.evidence.status = .unknown;
    var lost = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer lost.deinit();
    try std.testing.expect(lost.value.?.outcome == .indeterminate);
    fixture.evidence.status = null;
    fixture.snapshot.outcome = .failed;
    fixture.snapshot.attempts.items = &.{};
    var terminal = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer terminal.deinit();
    try std.testing.expect(terminal.value.?.outcome.rejected.retryable);
    fixture.snapshot.attempts.items = &.{
        attempt(1, .definitely_not_sent),
        attempt(2, .definitely_not_sent),
    };
    var excluded = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer excluded.deinit();
    try std.testing.expect(excluded.value.?.outcome.rejected.retryable);
    fixture.snapshot.attempts.items = &.{ attempt(1, null), attempt(2, .definitely_not_sent) };
    var unknown = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer unknown.deinit();
    try std.testing.expect(unknown.value.?.outcome == .indeterminate);
}

test "delivery facts reuse retained confirmed write reply before terminal publication" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    try fixture.addReply(.{ .confirmed = .{
        .timestamp = .{ .bytes = "1700000000.000001" },
        .metadata_observed = true,
    } });
    var result = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer result.deinit();
    try std.testing.expect(result.value.?.outcome == .confirmed);
    try std.testing.expectEqualDeep(result.value.?.admitted.key, result.value.?.receipt.?.key);
    try std.testing.expectEqualDeep(
        fixture.snapshot.attempts.items[0].capture.?.reply.?.digest,
        result.value.?.receipt.?.evidence.digest,
    );
    var altered = fixture.snapshot.attempts.items[0];
    altered.capture.?.reply.?.digest = @splat(9);
    fixture.snapshot.attempts.items = &.{altered};
    try std.testing.expectError(
        error.DeliveryProjectionMismatch,
        facts.settlement(a, fixture.snapshot, fixture.evidence, .current),
    );
}

test "delivery facts retain provider rejection only when all write history excludes send" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    try fixture.addReply(.{ .rejected = .{
        .code = .{ .bytes = "ratelimited" },
        .retryable = true,
        .retry_after = .{ .bytes = "30" },
    } });
    var pending = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer pending.deinit();
    try std.testing.expect(pending.value == null);
    fixture.snapshot.outcome = .completed;
    var rejected = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer rejected.deinit();
    try std.testing.expectEqualStrings("30", rejected.value.?.outcome.rejected.retry_after.?.bytes);
    const history = [_]retained.Attempt{ fixture.snapshot.attempts.items[0], attempt(2, .unknown) };
    fixture.snapshot.attempts.items = &history;
    var unknown = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer unknown.deinit();
    try std.testing.expect(unknown.value.?.outcome == .indeterminate);
}

test "delivery facts settle retired digests once without a Slack write" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    try fixture.retarget(.digest, 1);
    var unsent = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer unsent.deinit();
    const rejected = unsent.value.?.outcome.rejected;
    try std.testing.expectEqualStrings("slack_removed", rejected.code.bytes);
    try std.testing.expect(rejected.retryable);
    try std.testing.expect(unsent.value.?.receipt == null);
    var historical = try facts.settlement(
        a,
        fixture.snapshot,
        fixture.evidence,
        .before_removal,
    );
    defer historical.deinit();
    try std.testing.expect(historical.value == null);
    fixture.snapshot.attempts.items = &.{attempt(1, null)};
    var possible = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer possible.deinit();
    try std.testing.expectEqualStrings(
        "possibly_transmitted",
        possible.value.?.outcome.indeterminate.bytes,
    );
    fixture.snapshot.attempts.items = &.{};
    try fixture.retarget(.digest, 2);
    var local = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer local.deinit();
    try std.testing.expect(local.value == null);
}

test "delivery facts confirm completed local deliveries from the task result" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    try fixture.retarget(.digest, 2);
    try fixture.complete(.{ .confirmed = .{
        .timestamp = .{ .bytes = "local" },
        .metadata_observed = true,
    } });
    var result = try facts.settlement(a, fixture.snapshot, fixture.evidence, .current);
    defer result.deinit();
    const receipt = result.value.?.receipt.?;
    try std.testing.expectEqualStrings("local", receipt.timestamp.bytes);
    try std.testing.expectEqual(.captured_response, receipt.basis);
    try std.testing.expectEqual(fixture.snapshot.result.?.reference.digest, receipt.evidence.digest);
    try std.testing.expectEqual(fixture.snapshot.task, receipt.evidence.task);
}
