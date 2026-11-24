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
    identity: u8,
    obligation: ?t.Id,
    buttons: []const t.Button,
) !t.Delivery {
    const frozen = try preparation.materialize(a, .{
        .key = .{
            .lineage = @splat(8),
            .purpose = purpose,
            .identity = @splat(identity),
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
    const activation = try local(a, rows.ref(initial), .activation, 20, @splat(1), &.{});
    const announced = try rows.row(a, 4, .{ .delivery = activation }, confirmed);
    var failed = try rows.row(a, 5, .{ .delivery = try digest(a, rows.ref(initial)) }, null);
    failed.owner_snapshot.?.outcome = .cancelled;
    const question = try local(a, rows.ref(stepped), .question, 22, @splat(1), &.{.{
        .block_id = .{ .bytes = "source-gap" },
        .action_id = .{ .bytes = "answer" },
        .value = .{ .bytes = "accept_gap" },
        .label = .{ .bytes = "Accept explicit gap" },
    }});
    const delivered = try rows.row(a, 6, .{ .delivery = question }, confirmed);
    const foreign = try rows.row(a, 8, .{
        .delivery = try local(a, rows.ref(initial), .activation, 24, @splat(9), &.{}),
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
    const page = try messages.page(a, &observed.index, observed.target, null, 64, null);
    try std.testing.expectEqual(3, page.total);
    try std.testing.expectEqual(null, page.next);
    const items = page.messages.items;
    const Purpose = @FieldType(t.DeliveryKey, "purpose");
    const purposes = [_]Purpose{ .activation, .digest, .question };
    const states = [_]messages.State{ .delivered, .undelivered, .delivered };
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
    const folding = observed.index.record(@splat(9)).?.input.step.facts.items;
    const cancelled = for (folding) |fact| {
        if (std.meta.eql(fact.reference.task, @as(t.Id, @splat(5)))) break fact.delivery.?;
    } else return error.MissingFoldedDelivery;
    try std.testing.expect(cancelled.outcome != .confirmed);
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
    const first = try messages.page(a, &observed.index, observed.target, null, 2, null);
    try std.testing.expectEqual(2, first.messages.items.len);
    try std.testing.expectEqual(@as(?u64, 2), first.next);
    const rest = try messages.page(a, &observed.index, observed.target, first.next, 2, null);
    try std.testing.expectEqual(1, rest.messages.items.len);
    try std.testing.expectEqual(3, rest.messages.items[0].ordinal);
    try std.testing.expectEqual(null, rest.next);
    const beyond = try messages.page(a, &observed.index, observed.target, 9, 3, null);
    try std.testing.expectEqual(0, beyond.messages.items.len);
    try std.testing.expectEqual(3, beyond.total);
    try std.testing.expectError(
        error.InvalidPageLimit,
        messages.page(a, &observed.index, observed.target, null, 65, null),
    );
    try std.testing.expectError(
        error.UnknownObligation,
        messages.page(a, &observed.index, @splat(9), null, 3, null),
    );
}

test "messages render each choice as the local command that answers it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const config = "/srv/owner's configs/paredros.json";
    const page = try messages.page(a, &observed.index, observed.target, 2, 2, config);
    try std.testing.expectEqual(1, page.messages.items.len);
    const answer = page.messages.items[0].choices.items[0];
    try std.testing.expectEqualStrings("Accept explicit gap", answer.label.bytes);
    const expected = try std.fmt.allocPrint(
        a,
        "paredros --config '/srv/owner'\\''s configs/paredros.json' " ++
            "question answer {s} {s} accept_gap",
        .{
            std.fmt.bytesToHex(@as(t.Id, @splat(1)), .lower),
            std.fmt.bytesToHex(@as(t.Digest, @splat(6)), .lower),
        },
    );
    try std.testing.expectEqualStrings(expected, answer.command.?.bytes);
    const plain = try messages.page(a, &observed.index, observed.target, 2, 2, "/etc/p.json");
    try std.testing.expect(std.mem.startsWith(
        u8,
        plain.messages.items[0].choices.items[0].command.?.bytes,
        "paredros --config /etc/p.json question answer ",
    ));
    const unknown = try messages.page(a, &observed.index, observed.target, 2, 2, null);
    try std.testing.expectEqual(null, unknown.messages.items[0].choices.items[0].command);
}

test "messages keep earlier ordinals when a late local message is folded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const seen = try messages.page(a, &observed.index, observed.target, null, 64, null);
    try std.testing.expectEqual(3, seen.total);
    const late = try local(a, rows.ref(observed.rows[4]), .question, 25, observed.target, &.{});
    const reply = try rows.row(a, 11, .{ .delivery = late }, confirmed);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, observed.rows);
    try all.append(a, reply);
    const unfolded = try idx.Index.init(Native, a, all.items, &.{});
    const waiting = try messages.page(a, &unfolded, observed.target, seen.total, 64, null);
    try std.testing.expectEqual(0, waiting.messages.items.len);
    try std.testing.expectEqual(seen.total, waiting.total);
    try all.append(a, try fold(a, all.items, 12));
    const folded = try idx.Index.init(Native, a, all.items, &.{});
    const next = try messages.page(a, &folded, observed.target, seen.total, 64, null);
    try std.testing.expectEqual(1, next.messages.items.len);
    try std.testing.expectEqual(.question, next.messages.items[0].purpose);
    try std.testing.expectEqual(4, next.messages.items[0].ordinal);
    const again = try messages.page(a, &folded, observed.target, null, 64, null);
    for (seen.messages.items, again.messages.items[0..3]) |before, after| {
        try std.testing.expectEqualStrings(before.task.bytes, after.task.bytes);
        try std.testing.expectEqual(before.ordinal, after.ordinal);
    }
}
