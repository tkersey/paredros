const std = @import("std");
const c = @import("protean_contracts");
const Native = @import("protean_native");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const messages = @import("../native/messages.zig");
const preparation = @import("../native/delivery_prepare.zig");
const legacy = @import("../native/legacy.zig");
const retained = @import("../native/retained.zig");
const rows = @import("index.zig");
const materialize = @import("../native/materialize.zig");
const examples = @import("contracts.zig");

pub fn retire(a: std.mem.Allocator, value: t.Delivery) !t.Delivery {
    var delivery = value;
    delivery.payload.renderer_version = preparation.legacy_renderer_version;
    delivery.payload.wire_json = .{ .bytes = "{\"channel\":\"D1\"}" };
    delivery.envelope.operation = .{ .bytes = try preparation.operation(a, delivery.key) };
    const request = try c.encodeOwned(struct {
        destination: t.Destination,
        key: t.DeliveryKey,
        payload: t.DeliveryPayload,
    }, a, .{
        .destination = delivery.destination,
        .key = delivery.key,
        .payload = delivery.payload,
    });
    delivery.envelope.stable_request = preparation.hash(request);
    return delivery;
}

fn local(
    a: std.mem.Allocator,
    producer: t.Reference,
    purpose: @FieldType(t.DeliveryKey, "purpose"),
    obligation: ?t.Id,
    buttons: []const t.Button,
) !t.Delivery {
    const frozen = try preparation.materialize(a, .{
        .destination = @import("contracts.zig").specification().destination,
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

fn inFlight(a: std.mem.Allocator, source: idx.Row) !idx.Row {
    var value = source;
    const attempts = try a.dupe(retained.Attempt, &.{.{
        .id = @splat(1),
        .occurrence = @splat(1),
        .capability = .{ .bytes = legacy.notification_identity },
        .inference = false,
        .request = .{ .digest = @splat(2), .bytes = 1 },
        .prepared = null,
        .capture = null,
        .usage = null,
    }});
    value.owner_snapshot.?.attempts.items = attempts;
    value.owner_evidence.?.attempts = try a.dupe(retained.AttemptEvidence, &.{.{
        .id = @splat(1),
        .response = null,
        .reply = null,
    }});
    return value;
}

const Witness = struct { index: idx.Index, target: t.Id, rows: []const idx.Row };

const confirmed: t.Output = .{ .delivery = .{
    .confirmed = .{ .timestamp = .{ .bytes = "local" }, .metadata_observed = true },
} };

fn fold(a: std.mem.Allocator, all: []const idx.Row, task: u8) !idx.Row {
    var index = try idx.Index.init(Native, a, all, &.{});
    const frozen = try materialize.step(a, &index, @splat(1), 101, null);
    var output = rows.successor(frozen.value);
    var consumed: std.ArrayList(t.RevisionReference) = .empty;
    for (frozen.value.facts.items) |fact| try consumed.append(a, fact.reference);
    output.step.head.consumed.items = consumed.items;
    return rows.row(a, task, .{ .step = frozen.value }, output);
}

const Answered = struct { turn: idx.Row, reply: t.Delivery };

fn answered(a: std.mem.Allocator, task: u8, target: ?t.Id, ordinal: u64) !Answered {
    const destination = examples.specification().destination;
    const reply: t.DeliveryIntent = .{
        .destination = destination,
        .key = .{
            .lineage = @splat(task),
            .purpose = .turn,
            .identity = @splat(task),
            .generation = 0,
        },
        .payload = .{
            .obligation = target,
            .specification_revision = 0,
            .prior_sequence = 0,
            .through_sequence = 0,
            .frozen_text = .{ .bytes = "reply" },
            .prompt = null,
            .supersedes = null,
        },
    };
    const turn = try slackTurn(a, task, target, ordinal, .{ .turn = .{
        .reply = .{ .bytes = "reply" },
        .proposals = .{ .items = &.{} },
        .delivery = reply,
    } });
    const frozen = try preparation.materialize(a, reply, rows.ref(turn), @splat(7));
    return .{ .turn = turn, .reply = frozen.value };
}

fn slackTurn(
    a: std.mem.Allocator,
    task: u8,
    target: ?t.Id,
    ordinal: u64,
    output: ?t.Output,
) !idx.Row {
    const destination = examples.specification().destination;
    return rows.row(a, task, .{ .turn = .{
        .envelope = .{
            .operation = .{ .bytes = try std.fmt.allocPrint(a, "slack-event-{d}", .{task}) },
            .stable_request = @splat(task),
            .origin = .{ .slack = .{
                .app = destination.app,
                .workspace = destination.workspace,
                .user = destination.operator,
                .channel = destination.channel,
            } },
        },
        .ordinal = ordinal,
        .destination = destination,
        .text = .{ .bytes = "hello" },
        .context = .{ .bytes = "" },
        .context_references = .{ .items = &.{} },
        .attempt = 0,
        .target = target,
    } }, output);
}

fn witness(a: std.mem.Allocator) !Witness {
    const initial = try rows.genesis(a);
    const first = rows.step(rows.head(), rows.ref(initial), "message-step");
    const stepped = try rows.row(a, 3, .{ .step = first }, rows.successor(first));
    var activation = try rows.pendingDelivery(a, rows.ref(initial));
    activation.key.purpose = .activation;
    activation.payload.logical.coverage = null;
    const possible = try inFlight(
        a,
        try rows.row(a, 4, .{ .delivery = try retire(a, activation) }, null),
    );
    var digest = try rows.pendingDelivery(a, rows.ref(initial));
    digest.payload.logical.comparison = .{
        .repository = @import("contracts.zig").specification().repository,
        .base = @splat('a'),
        .tip = @splat('b'),
    };
    const unsent = try rows.row(a, 5, .{ .delivery = try retire(a, digest) }, null);
    const question = try local(a, rows.ref(stepped), .question, @splat(1), &.{.{
        .block_id = .{ .bytes = "source-gap" },
        .action_id = .{ .bytes = "answer" },
        .value = .{ .bytes = "accept_gap" },
        .label = .{ .bytes = "Accept explicit gap" },
    }});
    const delivered = try rows.row(a, 6, .{ .delivery = question }, confirmed);
    const notice = try local(a, rows.ref(stepped), .control, @splat(1), &.{.{
        .block_id = .{ .bytes = "paredros_proposal_1" },
        .action_id = .{ .bytes = "paredros.proposal.confirm.v1" },
        .value = .{ .bytes = "ab:0:1" },
        .label = .{ .bytes = "Confirm proposal 1" },
    }});
    const sent = try rows.row(a, 7, .{ .delivery = notice }, confirmed);
    const foreign = try rows.row(a, 8, .{
        .delivery = try local(a, rows.ref(initial), .failure, @splat(9), &.{}),
    }, null);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, &.{ foreign, sent, delivered, unsent, possible, stepped, initial });
    try all.append(a, try fold(a, all.items, 9));
    return .{
        .index = try idx.Index.init(Native, a, all.items, &.{}),
        .target = @splat(1),
        .rows = all.items,
    };
}

test "messages list an obligation's local and legacy records in stable order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const page = try messages.page(a, &observed.index, observed.target, null, 64);
    try std.testing.expectEqual(4, page.total);
    try std.testing.expectEqual(null, page.next);
    const items = page.messages.items;
    const Purpose = @FieldType(t.DeliveryKey, "purpose");
    const purposes = [_]Purpose{ .activation, .digest, .question, .control };
    const states = [_]messages.State{
        .legacy_possibly_sent,
        .legacy_unsent,
        .delivered,
        .delivered,
    };
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
    const first = try messages.page(a, &observed.index, observed.target, null, 3);
    try std.testing.expectEqual(3, first.messages.items.len);
    try std.testing.expectEqual(@as(?u64, 3), first.next);
    const rest = try messages.page(a, &observed.index, observed.target, first.next, 3);
    try std.testing.expectEqual(1, rest.messages.items.len);
    try std.testing.expectEqual(4, rest.messages.items[0].ordinal);
    try std.testing.expectEqual(null, rest.next);
    const beyond = try messages.page(a, &observed.index, observed.target, 9, 3);
    try std.testing.expectEqual(0, beyond.messages.items.len);
    try std.testing.expectEqual(4, beyond.total);
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
    const answer = page.messages.items[0].choices.items[0];
    try std.testing.expectEqualStrings("Accept explicit gap", answer.label.bytes);
    const expected = try std.fmt.allocPrint(a, "paredros question answer {s} {s} accept_gap", .{
        std.fmt.bytesToHex(@as(t.Id, @splat(1)), .lower),
        std.fmt.bytesToHex(@as(t.Digest, @splat(6)), .lower),
    });
    try std.testing.expectEqualStrings(expected, answer.command.?.bytes);
    const proposal = page.messages.items[1].choices.items[0];
    try std.testing.expectEqualStrings(
        "paredros proposal confirm ab:0:1",
        proposal.command.?.bytes,
    );
}

test "messages keep earlier ordinals when a late conversation reply is folded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const seen = try messages.page(a, &observed.index, observed.target, null, 64);
    try std.testing.expectEqual(4, seen.total);
    const late = try answered(a, 10, observed.target, 1);
    const reply = try rows.row(a, 11, .{ .delivery = late.reply }, confirmed);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, observed.rows);
    try all.appendSlice(a, &.{ late.turn, reply });
    const unfolded = try idx.Index.init(Native, a, all.items, &.{});
    const waiting = try messages.page(a, &unfolded, observed.target, seen.total, 64);
    try std.testing.expectEqual(0, waiting.messages.items.len);
    try std.testing.expectEqual(seen.total, waiting.total);
    try all.append(a, try fold(a, all.items, 12));
    const folded = try idx.Index.init(Native, a, all.items, &.{});
    const next = try messages.page(a, &folded, observed.target, seen.total, 64);
    try std.testing.expectEqual(1, next.messages.items.len);
    try std.testing.expectEqual(.turn, next.messages.items[0].purpose);
    try std.testing.expectEqual(5, next.messages.items[0].ordinal);
    const again = try messages.page(a, &folded, observed.target, null, 64);
    for (seen.messages.items, again.messages.items[0..4]) |before, after| {
        try std.testing.expectEqualStrings(before.task.bytes, after.task.bytes);
        try std.testing.expectEqual(before.ordinal, after.ordinal);
    }
}

test "messages list untargeted conversation replies once Slack-era turns finish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try rows.genesis(a);
    const old = try answered(a, 20, null, 1);
    const retired = try rows.row(a, 21, .{ .delivery = try retire(a, old.reply) }, null);
    const fresh = try answered(a, 22, null, 2);
    const reply = try rows.row(a, 23, .{ .delivery = fresh.reply }, confirmed);
    const running = try slackTurn(a, 24, null, 3, null);
    const finished = [_]idx.Row{ old.turn, retired, fresh.turn, reply, initial };
    const open = try idx.Index.init(Native, a, &(finished ++ [_]idx.Row{running}), &.{});
    const partial = try messages.page(a, &open, null, null, 64);
    try std.testing.expectEqual(1, partial.total);
    try std.testing.expectEqual(.legacy_unsent, partial.messages.items[0].state);
    const closed = try idx.Index.init(Native, a, &finished, &.{});
    const listed = try messages.page(a, &closed, null, null, 64);
    try std.testing.expectEqual(2, listed.total);
    try std.testing.expectEqual(.legacy_unsent, listed.messages.items[0].state);
    try std.testing.expectEqual(.delivered, listed.messages.items[1].state);
    try std.testing.expectEqual(2, listed.messages.items[1].ordinal);
    const owned = try messages.page(a, &closed, @splat(1), null, 64);
    try std.testing.expectEqual(0, owned.total);
}
