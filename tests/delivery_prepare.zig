const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const prepare = @import("../native/delivery_prepare.zig");
const fixtures = @import("contracts.zig");
const a = std.testing.allocator;

fn intent() t.DeliveryIntent {
    return .{
        .key = .{
            .lineage = @splat(1),
            .purpose = .digest,
            .identity = @splat(2),
            .generation = 1,
        },
        .payload = .{
            .obligation = @splat(3),
            .specification_revision = 1,
            .prior_sequence = 2,
            .through_sequence = 5,
            .frozen_text = .{ .bytes = "Three complete observations" },
            .prompt = null,
            .supersedes = null,
            .coverage = .{ .sequence = 5, .epoch = 1, .tip = @splat('b') },
            .comparison = .{
                .repository = fixtures.specification().repository,
                .base = @splat('a'),
                .tip = @splat('b'),
            },
        },
    };
}

fn materialization(allocator: std.mem.Allocator) !void {
    var first = try prepare.materialize(allocator, intent(), .{
        .task = @splat(4),
        .digest = @splat(5),
    }, @splat(6));
    defer first.deinit();
    try prepare.verifyStored(allocator, first.value);
    var second = try prepare.materialize(allocator, intent(), .{
        .task = @splat(7),
        .digest = @splat(8),
    }, @splat(6));
    defer second.deinit();
    try std.testing.expectEqualSlices(
        u8,
        first.value.payload.wire_json.bytes,
        second.value.payload.wire_json.bytes,
    );
    try std.testing.expectEqual(
        first.value.envelope.stable_request,
        second.value.envelope.stable_request,
    );
    try std.testing.expectEqualStrings(
        first.value.envelope.operation.bytes,
        second.value.envelope.operation.bytes,
    );
    try std.testing.expect(!std.meta.eql(
        first.value.envelope.origin.derived.predecessor,
        second.value.envelope.origin.derived.predecessor,
    ));
}

test "delivery preparation has stable local wire identity independent of producer" {
    try materialization(a);
    try std.testing.checkAllAllocationFailures(a, materialization, .{});
}

test "delivery preparation freezes the local message record" {
    var logical = intent();
    logical.payload.buttons.items = &.{.{
        .block_id = .{ .bytes = "source-gap" },
        .action_id = .{ .bytes = "answer" },
        .value = .{ .bytes = "accept_gap" },
        .label = .{ .bytes = "Accept explicit gap" },
    }};
    var frozen = try prepare.materialize(a, logical, .{
        .task = @splat(4),
        .digest = @splat(5),
    }, @splat(6));
    defer frozen.deinit();
    const payload = frozen.value.payload;
    try std.testing.expectEqual(prepare.hash(payload.wire_json.bytes), payload.content_digest);
    try std.testing.expectEqual(
        try prepare.markerDigest(a, payload.wire_json.bytes),
        payload.marker_digest,
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, a, payload.wire_json.bytes, .{});
    defer parsed.deinit();
    const record = parsed.value.object;
    try std.testing.expectEqualStrings(prepare.message_schema, record.get("schema").?.string);
    try std.testing.expectEqualStrings(
        "Three complete observations",
        record.get("text").?.string,
    );
    const choice = record.get("choices").?.array.items[0].object;
    try std.testing.expectEqualStrings("Accept explicit gap", choice.get("label").?.string);
    try std.testing.expectEqualStrings("accept_gap", choice.get("value").?.string);
    const metadata = record.get("metadata").?.object;
    try std.testing.expectEqualStrings("digest", metadata.get("kind").?.string);
    try std.testing.expectEqual(5, metadata.get("covered_observation").?.integer);
    try std.testing.expectEqual(1, record.get("links").?.array.items.len);
}

test "delivery preparation checks seals operation and envelope before accepting retained bytes" {
    var frozen = try prepare.materialize(a, intent(), .{
        .task = @splat(4),
        .digest = @splat(5),
    }, @splat(6));
    defer frozen.deinit();
    for (0..8) |mutation| {
        var changed = frozen.value;
        switch (mutation) {
            0 => changed.envelope.operation.bytes = "delivery:forged",
            1 => changed.envelope.stable_request = @splat(0),
            2 => changed.payload.logical.frozen_text.bytes = "Different authorized statement",
            3 => changed.payload.evidence_digest = @splat(0),
            4 => changed.payload.marker_digest = @splat(0),
            5 => changed.payload.content_digest = @splat(0),
            6 => changed.payload.wire_json.bytes = "{}",
            7 => changed.envelope.origin = .{ .local = .{ .uid = 42 } },
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidPayload, prepare.verifyStored(a, changed));
    }
}

test "delivery preparation refuses inconsistent coverage and freezes route escaping" {
    var logical = intent();
    logical.payload.coverage.?.sequence = 4;
    try std.testing.expectError(
        error.InvalidPayload,
        prepare.materialize(a, logical, .{ .task = @splat(4), .digest = @splat(5) }, @splat(6)),
    );
    logical = intent();
    logical.payload.comparison.?.repository.owner.bytes = "a/b";
    logical.payload.comparison.?.repository.name.bytes = "r?x";
    var frozen = try prepare.materialize(a, logical, .{
        .task = @splat(4),
        .digest = @splat(5),
    }, @splat(6));
    defer frozen.deinit();
    try prepare.verifyStored(a, frozen.value);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            frozen.value.payload.wire_json.bytes,
            "https://github.com/a%2Fb/r%3Fx/compare/",
        ) != null,
    );
}
