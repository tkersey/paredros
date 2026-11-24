const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const retained = @import("../native/retained.zig");
const facts = @import("../native/delivery_fact.zig");
const index = @import("../native/index.zig");
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

    fn retarget(self: *Fixture, purpose: @FieldType(t.DeliveryKey, "purpose")) !void {
        const allocator = self.arena.allocator();
        var input = try c.decodeOwned(t.Input, allocator, self.evidence.input.bytes);
        input.value.delivery.key.purpose = purpose;
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
};

fn object(bytes: []const u8) retained.Object {
    return .{ .digest = index.digest(bytes), .bytes = bytes.len };
}

test "delivery facts wait for live tasks and settle terminal non completion once" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    var live = try facts.settlement(a, fixture.snapshot, fixture.evidence);
    defer live.deinit();
    try std.testing.expect(live.value == null);
    fixture.evidence.status = .unknown;
    var lost = try facts.settlement(a, fixture.snapshot, fixture.evidence);
    defer lost.deinit();
    try std.testing.expect(lost.value == null);
    fixture.evidence.status = null;
    for ([_]@TypeOf(fixture.snapshot.outcome){ .failed, .cancelled }) |outcome| {
        fixture.snapshot.outcome = outcome;
        var terminal = try facts.settlement(a, fixture.snapshot, fixture.evidence);
        defer terminal.deinit();
        const rejected = terminal.value.?.outcome.rejected;
        try std.testing.expectEqualStrings("no_transmitted_write", rejected.code.bytes);
        try std.testing.expect(rejected.retryable);
        try std.testing.expect(terminal.value.?.receipt == null);
    }
}

test "delivery facts confirm completed local deliveries from the task result" {
    var fixture = try Fixture.init();
    defer fixture.arena.deinit();
    try fixture.retarget(.digest);
    try fixture.complete(.{ .confirmed = .{
        .timestamp = .{ .bytes = "local" },
        .metadata_observed = true,
    } });
    var result = try facts.settlement(a, fixture.snapshot, fixture.evidence);
    defer result.deinit();
    const receipt = result.value.?.receipt.?;
    try std.testing.expectEqualStrings("local", receipt.timestamp.bytes);
    try std.testing.expectEqualDeep(result.value.?.admitted.key, receipt.key);
    const published = fixture.snapshot.result.?;
    try std.testing.expectEqual(published.reference.digest, receipt.evidence.digest);
    try std.testing.expectEqual(fixture.snapshot.task, receipt.evidence.task);
    fixture.snapshot.result.?.reference.digest = @splat(9);
    try std.testing.expectError(
        error.DeliveryProjectionMismatch,
        facts.settlement(a, fixture.snapshot, fixture.evidence),
    );
}
