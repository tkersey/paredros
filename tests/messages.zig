const std = @import("std");
const Native = @import("protean_native");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const messages = @import("../native/messages.zig");
const preparation = @import("../native/delivery_prepare.zig");
const rows = @import("index.zig");
const materialize = @import("../native/materialize.zig");
const examples = @import("contracts.zig");

fn local(
    a: std.mem.Allocator,
    producer: t.Reference,
    purpose: @FieldType(t.DeliveryKey, "purpose"),
    obligation: ?t.Id,
    buttons: []const t.Button,
) !t.Delivery {
    const frozen = try preparation.materialize(a, .{
        .key = .{
            .lineage = @splat(8),
            .purpose = purpose,
            .identity = @splat(@as(u8, @backingInt(purpose)) + 20),
            .generation = 0,
        },
        .payload = .{
            .obligation = obligation,
            .specification_revision = 1,
            .prior_sequence = 0,
            .through_sequence = 0,
            .frozen_text = .{ .bytes = @tagName(purpose) },
            .prompt = if (purpose == .question) @splat(6) else null,
            .supersedes = null,
            .buttons = .{ .items = buttons },
        },
    }, producer, @splat(7));
    return frozen.value;
}

const Witness = struct { index: idx.Index, target: t.Id, rows: []const idx.Row };

const confirmed: t.Output = .{ .delivery = .{
    .confirmed = .{ .timestamp = .{ .bytes = "local" }, .metadata_observed = true },
} };

fn digest(a: std.mem.Allocator, producer: t.Reference) !t.Delivery {
    const frozen = try preparation.materialize(a, .{
        .key = .{
            .lineage = @splat(8),
            .purpose = .digest,
            .identity = @splat(9),
            .generation = 0,
        },
        .payload = .{
            .obligation = @splat(1),
            .specification_revision = 1,
            .prior_sequence = 0,
            .through_sequence = 1,
            .frozen_text = .{ .bytes = "one commit" },
            .coverage = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') },
            .comparison = .{
                .repository = examples.specification().repository,
                .base = @splat('a'),
                .tip = @splat('b'),
            },
            .prompt = null,
            .supersedes = null,
        },
    }, producer, @splat(7));
    return frozen.value;
}

fn witness(a: std.mem.Allocator) !Witness {
    const initial = try rows.genesis(a);
    const first = rows.step(rows.head(), rows.ref(initial), "message-step");
    const stepped = try rows.row(a, 3, .{ .step = first }, rows.successor(first));
    const activation = try local(a, rows.ref(initial), .activation, @splat(1), &.{});
    const announced = try rows.row(a, 4, .{ .delivery = activation }, confirmed);
    var failed = try rows.row(a, 5, .{ .delivery = try digest(a, rows.ref(initial)) }, null);
    failed.owner_snapshot.?.outcome = .cancelled;
    const question = try local(a, rows.ref(stepped), .question, @splat(1), &.{.{
        .block_id = .{ .bytes = "source-gap" },
        .action_id = .{ .bytes = "answer" },
        .value = .{ .bytes = "accept_gap" },
        .label = .{ .bytes = "Accept explicit gap" },
    }});
    const delivered = try rows.row(a, 6, .{ .delivery = question }, confirmed);
    const foreign = try rows.row(a, 8, .{
        .delivery = try local(a, rows.ref(initial), .failure, @splat(9), &.{}),
    }, null);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, &.{ foreign, delivered, failed, announced, stepped, initial });
    try all.append(a, try fold(a, all.items, 9));
    return .{
        .index = try idx.Index.init(Native, a, all.items, &.{}),
        .target = @splat(1),
        .rows = all.items,
    };
}

fn fold(a: std.mem.Allocator, all: []const idx.Row, task: u8) !idx.Row {
    var index = try idx.Index.init(Native, a, all, &.{});
    const frozen = try materialize.step(a, &index, @splat(1), 101, null);
    var output = rows.successor(frozen.value);
    var consumed: std.ArrayList(t.RevisionReference) = .empty;
    for (frozen.value.facts.items) |fact| try consumed.append(a, fact.reference);
    output.step.head.consumed.items = consumed.items;
    return rows.row(a, task, .{ .step = frozen.value }, output);
}

test "messages list an obligation's local records in stable order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const page = try messages.page(a, &observed.index, observed.target, null, 64);
    try std.testing.expectEqual(3, page.total);
    try std.testing.expectEqual(null, page.next);
    const items = page.messages.items;
    const Purpose = @FieldType(t.DeliveryKey, "purpose");
    const purposes = [_]Purpose{ .activation, .digest, .question };
    const states = [_]messages.State{ .delivered, .pending, .delivered };
    for (items, purposes, states, 1..) |item, purpose, state, ordinal| {
        try std.testing.expectEqual(ordinal, item.ordinal);
        try std.testing.expectEqual(purpose, item.purpose);
        try std.testing.expectEqual(state, item.state);
    }
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(@as(t.Id, @splat(6)), .lower),
        items[2].task.bytes,
    );
    try std.testing.expectEqualStrings("question", items[2].text.bytes);
    try std.testing.expectEqual(1, items[1].links.items.len);
    try std.testing.expect(std.mem.startsWith(
        u8,
        items[1].links.items[0].bytes,
        "https://github.com/",
    ));
    _ = try Native.values.toJson(messages.Page, a, page);
}

test "messages page from a stable ordinal cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const first = try messages.page(a, &observed.index, observed.target, null, 2);
    try std.testing.expectEqual(2, first.messages.items.len);
    try std.testing.expectEqual(@as(?u64, 2), first.next);
    const rest = try messages.page(a, &observed.index, observed.target, first.next, 2);
    try std.testing.expectEqual(1, rest.messages.items.len);
    try std.testing.expectEqual(3, rest.messages.items[0].ordinal);
    try std.testing.expectEqual(null, rest.next);
    const beyond = try messages.page(a, &observed.index, observed.target, 9, 3);
    try std.testing.expectEqual(0, beyond.messages.items.len);
    try std.testing.expectEqual(3, beyond.total);
    try std.testing.expectError(
        error.InvalidPageLimit,
        messages.page(a, &observed.index, observed.target, null, 65),
    );
    try std.testing.expectError(
        error.UnknownObligation,
        messages.page(a, &observed.index, @splat(9), null, 3),
    );
}

test "messages render each choice as the local command that answers it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const page = try messages.page(a, &observed.index, observed.target, 2, 2);
    try std.testing.expectEqual(1, page.messages.items.len);
    const answer = page.messages.items[0].choices.items[0];
    try std.testing.expectEqualStrings("Accept explicit gap", answer.label.bytes);
    const expected = try std.fmt.allocPrint(a, "paredros question answer {s} {s} accept_gap", .{
        std.fmt.bytesToHex(@as(t.Id, @splat(1)), .lower),
        std.fmt.bytesToHex(@as(t.Digest, @splat(6)), .lower),
    });
    try std.testing.expectEqualStrings(expected, answer.command.?.bytes);
}

test "messages keep earlier ordinals when a late local message is folded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const seen = try messages.page(a, &observed.index, observed.target, null, 64);
    try std.testing.expectEqual(3, seen.total);
    const late = try local(a, rows.ref(observed.rows[4]), .turn, observed.target, &.{});
    const reply = try rows.row(a, 11, .{ .delivery = late }, confirmed);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, observed.rows);
    try all.append(a, reply);
    const unfolded = try idx.Index.init(Native, a, all.items, &.{});
    const waiting = try messages.page(a, &unfolded, observed.target, seen.total, 64);
    try std.testing.expectEqual(0, waiting.messages.items.len);
    try std.testing.expectEqual(seen.total, waiting.total);
    try all.append(a, try fold(a, all.items, 12));
    const folded = try idx.Index.init(Native, a, all.items, &.{});
    const next = try messages.page(a, &folded, observed.target, seen.total, 64);
    try std.testing.expectEqual(1, next.messages.items.len);
    try std.testing.expectEqual(.turn, next.messages.items[0].purpose);
    try std.testing.expectEqual(4, next.messages.items[0].ordinal);
    const again = try messages.page(a, &folded, observed.target, null, 64);
    for (seen.messages.items, again.messages.items[0..3]) |before, after| {
        try std.testing.expectEqualStrings(before.task.bytes, after.task.bytes);
        try std.testing.expectEqual(before.ordinal, after.ordinal);
    }
}
