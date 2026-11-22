const std = @import("std");
const slack = @import("../native/slack.zig");
const a = std.testing.allocator;
const binding: slack.Binding = .{
    .app_id = "A1",
    .team_id = "T1",
    .operator_id = "U1",
    .channel_id = "D1",
    .bot_id = "B1",
};
const button: slack.Button = .{
    .block_id = "proposal-1",
    .action_id = "confirm",
    .value = "operation-digest:issue-1",
    .label = "Confirm pause",
};
const marker: slack.Marker = .{
    .key = @splat(1),
    .generation = 1,
    .issue = 1,
    .content = @splat(0),
    .lineage = "root",
    .obligation = "watch",
    .source_epoch = "epoch-1",
    .kind = .digest,
    .prior = 1,
    .covered = 4,
    .evidence = @splat(2),
};
const history_limits: slack.HistoryLimits = .{ .pages = 4, .messages = 20, .page_bytes = 65536 };

fn envelope(
    allocator: std.mem.Allocator,
    id: []const u8,
    event: []const u8,
    body: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .envelope_id = id,
        .type = "events_api",
        .payload = .{
            .api_app_id = "A1",
            .team_id = "T1",
            .type = "event_callback",
            .event_id = event,
            .event = .{
                .type = "message",
                .user = "U1",
                .channel = "D1",
                .channel_type = "im",
                .ts = "1730000000.000001",
                .text = body,
            },
        },
    }, .{});
}

fn modified(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    path: []const []const u8,
    value: std.json.Value,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var cursor = &parsed.value;
    for (path[0 .. path.len - 1]) |key| cursor = cursor.object.getPtr(key).?;
    try cursor.object.put(parsed.arena.allocator(), path[path.len - 1], value);
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn interaction(allocator: std.mem.Allocator, prepared: slack.Prepared, id: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, prepared.body, .{});
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(allocator, .{
        .envelope_id = id,
        .type = "interactive",
        .payload = .{
            .type = "block_actions",
            .api_app_id = "A1",
            .team = .{ .id = "T1" },
            .user = .{ .id = "U1" },
            .channel = .{ .id = "D1" },
            .container = .{
                .type = "message",
                .channel_id = "D1",
                .message_ts = "1730000000.000003",
            },
            .message = .{
                .app_id = "A1",
                .bot_id = "B1",
                .team = "T1",
                .ts = "1730000000.000003",
                .text = "Slack rendered this differently",
                .blocks = parsed.value.object.get("blocks").?,
                .metadata = parsed.value.object.get("metadata").?,
            },
            .actions = .{.{
                .type = "button",
                .block_id = button.block_id,
                .action_id = button.action_id,
                .value = button.value,
                .action_ts = "1730000000.000004",
            }},
        },
    }, .{});
}

fn historyMessage(
    allocator: std.mem.Allocator,
    prepared: slack.Prepared,
    ts: []const u8,
    app: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, prepared.body, .{});
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(allocator, .{
        .type = "message",
        .app_id = app,
        .bot_id = if (std.mem.eql(u8, app, "A1")) "B1" else "B2",
        .team = "T1",
        .ts = ts,
        .text = "provider-rewritten & escaped content",
        .metadata = parsed.value.object.get("metadata").?,
    }, .{});
}

fn historyPage(
    allocator: std.mem.Allocator,
    messages: []const []const u8,
    cursor: []const u8,
    more: bool,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const values = try scratch.alloc(std.json.Value, messages.len);
    for (messages, values) |bytes, *value| {
        const parsed = try std.json.parseFromSlice(std.json.Value, scratch, bytes, .{});
        value.* = parsed.value;
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = true,
        .messages = values,
        .has_more = more,
        .response_metadata = .{ .next_cursor = cursor },
    }, .{});
}

test "Slack timestamp comparisons retain precision beyond floating point and trailing zeroes" {
    const first = try slack.Timestamp.parse("9007199254740993.000001");
    const second = try slack.Timestamp.parse("9007199254740993.000002");
    try std.testing.expectEqual(.lt, first.order(second));
    try std.testing.expectEqual(
        .eq,
        (try slack.Timestamp.parse("1.10")).order(try slack.Timestamp.parse("1.1")),
    );
    for ([_][]const u8{ "1", "1.", ".1", "01.1", "1e3.1", "1.1.1", "-1.0" }) |bad|
        try std.testing.expectError(error.InvalidTimestamp, slack.Timestamp.parse(bad));
}

test "Slack event identity survives envelope changes while conflicting stable content differs" {
    const original = try envelope(a, "envelope-1", "event-1", "yes");
    defer a.free(original);
    const retry = try envelope(a, "envelope-2", "event-1", "yes");
    defer a.free(retry);
    const changed = try envelope(a, "envelope-3", "event-1", "pause");
    defer a.free(changed);
    var first = try slack.parseEnvelope(a, binding, original, .{});
    defer first.deinit();
    var second = try slack.parseEnvelope(a, binding, retry, .{});
    defer second.deinit();
    var third = try slack.parseEnvelope(a, binding, changed, .{});
    defer third.deinit();
    try std.testing.expectEqual(
        first.disposition.text.operation,
        second.disposition.text.operation,
    );
    try std.testing.expectEqual(
        first.disposition.text.stable_request,
        second.disposition.text.stable_request,
    );
    try std.testing.expectEqual(first.disposition.text.operation, third.disposition.text.operation);
    try std.testing.expect(
        !std.meta.eql(first.disposition.text.stable_request, third.disposition.text.stable_request),
    );
    try std.testing.expectEqualStrings("yes", first.disposition.text.text);
}

test "Slack ingress rejects forged origins unsupported messages duplicate keys and oversize input" {
    const original = try envelope(a, "envelope", "event", "ordinary text");
    defer a.free(original);
    for ([_][]const u8{
        "user",
        "channel",
        "channel_type",
        "subtype",
        "thread_ts",
        "bot_id",
        "files",
        "edited",
    }) |field| {
        const changed = try modified(
            a,
            original,
            &.{ "payload", "event", field },
            .{ .string = "other" },
        );
        defer a.free(changed);
        var result = try slack.parseEnvelope(a, binding, changed, .{});
        defer result.deinit();
        try std.testing.expect(result.disposition == .ignored);
    }
    for ([_][]const u8{ "api_app_id", "team_id" }) |field| {
        const changed = try modified(a, original, &.{ "payload", field }, .{ .string = "other" });
        defer a.free(changed);
        var result = try slack.parseEnvelope(a, binding, changed, .{});
        defer result.deinit();
        try std.testing.expectEqual(.wrong_origin, result.disposition.ignored);
    }
    var duplicate = try slack.parseEnvelope(
        a,
        binding,
        "{\"envelope_id\":\"a\",\"envelope_id\":\"b\"}",
        .{},
    );
    defer duplicate.deinit();
    try std.testing.expectEqual(.malformed, duplicate.disposition.ignored);
    var oversized = try slack.parseEnvelope(a, binding, original, .{ .envelope_bytes = 4 });
    defer oversized.deinit();
    try std.testing.expectEqual(.oversized, oversized.disposition.ignored);
}

test "Slack parsed ingress owns strings beyond caller storage" {
    const bytes = try envelope(a, "owned-envelope", "owned-event", "owned text");
    var parsed = try slack.parseEnvelope(a, binding, bytes, .{});
    defer parsed.deinit();
    @memset(bytes, 0);
    a.free(bytes);
    try std.testing.expectEqualStrings("owned-envelope", parsed.envelope_id.?);
    try std.testing.expectEqualStrings("owned text", parsed.disposition.text.text);
}

test "Slack button identity is envelope independent and requires retained exact prompt binding" {
    var prepared = try slack.prepare(a, binding, "Pause watch at revision 2", &.{button}, marker);
    defer prepared.deinit();
    const bytes = try interaction(a, prepared, "first");
    defer a.free(bytes);
    const retry = try interaction(a, prepared, "second");
    defer a.free(retry);
    var first = try slack.parseEnvelope(a, binding, bytes, .{});
    defer first.deinit();
    var second = try slack.parseEnvelope(a, binding, retry, .{});
    defer second.deinit();
    try std.testing.expectEqual(
        first.disposition.interaction.operation,
        second.disposition.interaction.operation,
    );
    try slack.bindInteraction(a, first.disposition.interaction, prepared, button, null);
    try slack.bindInteraction(
        a,
        first.disposition.interaction,
        prepared,
        button,
        "1730000000.000003",
    );
    try std.testing.expectError(
        error.UnboundInteraction,
        slack.bindInteraction(
            a,
            first.disposition.interaction,
            prepared,
            button,
            "1730000000.000002",
        ),
    );
    var other = button;
    other.value = "other digest";
    try std.testing.expectError(
        error.UnboundInteraction,
        slack.bindInteraction(a, first.disposition.interaction, prepared, other, null),
    );
    var wrong_binding = binding;
    wrong_binding.channel_id = "D2";
    var wrong_destination = try slack.prepare(
        a,
        wrong_binding,
        "Pause watch at revision 2",
        &.{button},
        marker,
    );
    defer wrong_destination.deinit();
    try std.testing.expectError(
        error.UnboundInteraction,
        slack.bindInteraction(
            a,
            first.disposition.interaction,
            wrong_destination,
            button,
            "1730000000.000003",
        ),
    );
    const wrong_app = try modified(
        a,
        bytes,
        &.{ "payload", "message", "app_id" },
        .{ .string = "A2" },
    );
    defer a.free(wrong_app);
    var refused = try slack.parseEnvelope(a, binding, wrong_app, .{});
    defer refused.deinit();
    try std.testing.expectEqual(.wrong_origin, refused.disposition.ignored);
}

test "Slack output disables parsing escapes mentions and bounds rendered fields" {
    var prepared = try slack.prepare(
        a,
        binding,
        "<& @here <@U2> https://example.com",
        &.{button},
        marker,
    );
    defer prepared.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, prepared.body, .{});
    defer parsed.deinit();
    const fields = parsed.value.object;
    try std.testing.expectEqualStrings("none", fields.get("parse").?.string);
    for ([_][]const u8{ "mrkdwn", "link_names", "unfurl_links", "unfurl_media" }) |field|
        try std.testing.expect(!fields.get(field).?.bool);
    try std.testing.expectEqualStrings(
        "&lt;&amp; @here &lt;@U2&gt; https://example.com",
        fields.get("text").?.string,
    );
    const section = fields.get("blocks").?.array.items[0].object.get("text").?;
    try std.testing.expectEqualStrings("plain_text", section.object.get("type").?.string);
    var next_marker = marker;
    next_marker.generation = std.math.maxInt(u64);
    var retry = try slack.prepare(
        a,
        binding,
        "<& @here <@U2> https://example.com",
        &.{button},
        next_marker,
    );
    defer retry.deinit();
    try std.testing.expectEqual(prepared.marker.content, retry.marker.content);
    const too_long = try a.alloc(u8, 4001);
    defer a.free(too_long);
    @memset(too_long, 'x');
    try std.testing.expectError(error.Oversized, slack.prepare(a, binding, too_long, &.{}, marker));
    var split = try slack.prepare(a, binding, too_long[0..3001], &.{button}, marker);
    defer split.deinit();
    try std.testing.expectEqual(3, split.blocks.array.items.len);
}

test "Slack comparison blocks preserve long Unicode text and escaped entities across sections" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    for (0..2998) |_| try body.appendSlice(a, "é");
    try body.append(a, '&');
    for (0..500) |_| try body.appendSlice(a, "日");
    const link: slack.Link = .{
        .label = "Comparison",
        .url = "https://github.com/o/r/compare/a...b",
    };
    var prepared = try slack.prepareLinked(a, binding, body.items, &.{button}, &.{link}, marker);
    defer prepared.deinit();
    try std.testing.expectEqual(4, prepared.blocks.array.items.len);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (prepared.blocks.array.items[0..2]) |block| {
        const section = block.object.get("text").?.object.get("text").?.string;
        try std.testing.expect(try std.unicode.utf8CountCodepoints(section) <= 3000);
        try text.appendSlice(a, section);
    }
    try std.testing.expectEqualStrings(body.items[0..5996], text.items[0..5996]);
    try std.testing.expectEqualStrings("&amp;", text.items[5996..6001]);
    try std.testing.expectEqualStrings(body.items[5997..], text.items[6001..]);
    try std.testing.expectEqualStrings(
        body.items[0..5996],
        prepared.blocks.array.items[0].object.get("text").?.object.get("text").?.string,
    );
    var duplicate = button;
    duplicate.block_id = "paredros_verified_comparison";
    try std.testing.expectError(
        error.DuplicateBlock,
        slack.prepareLinked(a, binding, body.items, &.{duplicate}, &.{link}, marker),
    );
    try std.testing.expectError(
        error.Oversized,
        slack.prepareLinked(a, binding, body.items, &.{}, &.{ link, link }, marker),
    );
}

test "Slack history positive match authenticates marker without comparing rewritten prose" {
    var prepared = try slack.prepare(a, binding, "original text", &.{}, marker);
    defer prepared.deinit();
    const message = try historyMessage(a, prepared, "1730000000.000003", "A1");
    defer a.free(message);
    const page = try historyPage(a, &.{message}, "", false);
    defer a.free(page);
    var audit = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer audit.deinit();
    try audit.ingest(audit.request(), .{ .status = 200, .body = page });
    try std.testing.expectEqualStrings("1730000000.000003", audit.finding().present);
    try std.testing.expectEqualStrings(page, audit.pages.items[0].response.body);
    const other = try historyMessage(a, prepared, "1730000000.000003", "A2");
    defer a.free(other);
    const foreign = try historyPage(a, &.{other}, "", false);
    defer a.free(foreign);
    var denied = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer denied.deinit();
    try denied.ingest(denied.request(), .{ .status = 200, .body = foreign });
    try std.testing.expectEqual(.no_canary, denied.finding().inconclusive);
}

test "Slack negative history requires canary and cursor exhaustion despite short has_more false" {
    var prepared = try slack.prepare(a, binding, "wanted", &.{}, marker);
    defer prepared.deinit();
    var canary_marker = marker;
    canary_marker.key = @splat(4);
    var canary = try slack.prepare(a, binding, "canary", &.{}, canary_marker);
    defer canary.deinit();
    const message = try historyMessage(a, canary, "1730000000.000001", "A1");
    defer a.free(message);
    const first = try historyPage(a, &.{message}, "next-page", false);
    defer a.free(first);
    const last = try historyPage(a, &.{}, "", false);
    defer a.free(last);
    var audit = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        .{ .timestamp = "1730000000.000001", .marker = canary.marker },
        history_limits,
    );
    defer audit.deinit();
    try std.testing.expect(audit.request().inclusive and audit.request().include_all_metadata);
    try audit.ingest(audit.request(), .{ .status = 200, .body = first });
    try std.testing.expectEqual(.incomplete, audit.finding().inconclusive);
    try std.testing.expectEqualStrings("next-page", audit.request().cursor);
    try audit.ingest(audit.request(), .{ .status = 200, .body = last });
    try std.testing.expect(audit.finding() == .not_observed);
}

test "Slack history conflicts unmarked app messages cursor cycles and budgets remain inconclusive" {
    var prepared = try slack.prepare(a, binding, "wanted", &.{}, marker);
    defer prepared.deinit();
    const first = try historyMessage(a, prepared, "1730000000.000003", "A1");
    defer a.free(first);
    const second = try historyMessage(a, prepared, "1730000000.000004", "A1");
    defer a.free(second);
    const duplicate = try historyPage(a, &.{ first, second }, "", false);
    defer a.free(duplicate);
    var audit = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer audit.deinit();
    try audit.ingest(audit.request(), .{ .status = 200, .body = duplicate });
    try std.testing.expectEqual(.conflict, audit.finding().inconclusive);
    const missing = try modified(a, first, &.{"metadata"}, .null);
    defer a.free(missing);
    const unmarked = try historyPage(a, &.{missing}, "", false);
    defer a.free(unmarked);
    var unclear = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer unclear.deinit();
    try unclear.ingest(unclear.request(), .{ .status = 200, .body = unmarked });
    try std.testing.expectEqual(.metadata, unclear.finding().inconclusive);
    const repeated = try historyPage(a, &.{}, "cycle", false);
    defer a.free(repeated);
    var cycle = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer cycle.deinit();
    try cycle.ingest(cycle.request(), .{ .status = 200, .body = repeated });
    try cycle.ingest(cycle.request(), .{ .status = 200, .body = repeated });
    try std.testing.expectEqual(.cursor, cycle.finding().inconclusive);
    var limited = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        .{ .pages = 0, .messages = 1, .page_bytes = 65536 },
    );
    defer limited.deinit();
    try limited.ingest(limited.request(), .{ .status = 200, .body = duplicate });
    try std.testing.expectEqual(.budget, limited.finding().inconclusive);
}

test "Slack delivery classifies only reviewed pre-effect failures and keeps confirmed degradation" {
    for ([_][]const u8{
        "fatal_error",
        "internal_error",
        "unknown_error",
        "duplicate_message",
    }) |failure| {
        const body = try std.json.Stringify.valueAlloc(
            a,
            .{ .ok = false, .@"error" = failure },
            .{},
        );
        defer a.free(body);
        var result = try slack.interpretDelivery(
            a,
            binding,
            marker,
            .{ .status = 200, .body = body },
            65536,
        );
        defer result.deinit();
        try std.testing.expect(result.outcome == .indeterminate);
    }
    var rejected = try slack.interpretDelivery(
        a,
        binding,
        marker,
        .{ .status = 200, .body = "{\"ok\":false,\"error\":\"invalid_auth\"}" },
        65536,
    );
    defer rejected.deinit();
    try std.testing.expect(!rejected.outcome.rejected.retryable);
    var limited = try slack.interpretDelivery(
        a,
        binding,
        marker,
        .{ .status = 429, .body = "{\"ok\":false,\"error\":\"ratelimited\"}" },
        65536,
    );
    defer limited.deinit();
    try std.testing.expect(limited.outcome.rejected.retryable);
    var confirmed = try slack.interpretDelivery(
        a,
        binding,
        marker,
        .{
            .status = 200,
            .body = "{\"ok\":true,\"channel\":\"D1\",\"ts\":\"1730000000.000003\"," ++
                "\"response_metadata\":{\"warnings\":[\"message_truncated\"]}}",
        },
        65536,
    );
    defer confirmed.deinit();
    try std.testing.expect(confirmed.outcome.confirmed.metadata_degraded);
    try std.testing.expect(confirmed.outcome.confirmed.rendering_fault);
    var malformed = try slack.interpretDelivery(
        a,
        binding,
        marker,
        .{ .status = 200, .body = "{" },
        65536,
    );
    defer malformed.deinit();
    try std.testing.expect(malformed.outcome == .indeterminate);
}

test "Slack history rejects wrong destinations metadata conflicts partial windows bad markers" {
    var prepared = try slack.prepare(a, binding, "wanted", &.{}, marker);
    defer prepared.deinit();
    const message = try historyMessage(a, prepared, "1730000000.000003", "A1");
    defer a.free(message);
    const corrupted = try modified(
        a,
        message,
        &.{ "metadata", "event_payload", "covered_observation" },
        .{ .string = "5" },
    );
    defer a.free(corrupted);
    const page = try historyPage(a, &.{corrupted}, "", false);
    defer a.free(page);
    var conflict = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer conflict.deinit();
    try conflict.ingest(conflict.request(), .{ .status = 200, .body = page });
    try std.testing.expectEqual(.conflict, conflict.finding().inconclusive);
    var wrong = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer wrong.deinit();
    var request = wrong.request();
    request.channel = "D2";
    try std.testing.expectError(
        error.InvalidHistoryRequest,
        wrong.ingest(request, .{ .status = 200, .body = page }),
    );
    try std.testing.expectEqual(.incomplete, wrong.finding().inconclusive);
    const malformed = try modified(
        a,
        message,
        &.{ "metadata", "event_payload", "generation" },
        .{ .integer = 1 },
    );
    defer a.free(malformed);
    const invalid_page = try historyPage(a, &.{malformed}, "", false);
    defer a.free(invalid_page);
    var invalid = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer invalid.deinit();
    try invalid.ingest(invalid.request(), .{ .status = 200, .body = invalid_page });
    try std.testing.expectEqual(.metadata, invalid.finding().inconclusive);
}

fn without(allocator: std.mem.Allocator, bytes: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    _ = parsed.value.object.orderedRemove(key);
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn auditPage(
    prepared: slack.Prepared,
    canary: ?slack.Canary,
    page: []const u8,
) !slack.HistoryAudit {
    var audit = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        canary,
        history_limits,
    );
    errdefer audit.deinit();
    try audit.ingest(audit.request(), .{ .status = 200, .body = page });
    return audit;
}

test "Slack history treats an absent or null final cursor as exhaustion" {
    var prepared = try slack.prepare(a, binding, "wanted", &.{}, marker);
    defer prepared.deinit();
    const message = try historyMessage(a, prepared, "1730000000.000003", "A1");
    defer a.free(message);
    const page = try historyPage(a, &.{message}, "", false);
    defer a.free(page);
    const bare = try without(a, page, "response_metadata");
    defer a.free(bare);
    var present = try auditPage(prepared, null, bare);
    defer present.deinit();
    try std.testing.expectEqualStrings("1730000000.000003", present.finding().present);
    const empty = try modified(a, page, &.{"response_metadata"}, .{ .object = .empty });
    defer a.free(empty);
    var exhausted = try auditPage(prepared, null, empty);
    defer exhausted.deinit();
    try std.testing.expect(exhausted.finding() == .present);
    const nulled = try modified(a, page, &.{ "response_metadata", "next_cursor" }, .null);
    defer a.free(nulled);
    var ended = try auditPage(prepared, null, nulled);
    defer ended.deinit();
    try std.testing.expect(ended.finding() == .present);
    const more = try modified(a, bare, &.{"has_more"}, .{ .bool = true });
    defer a.free(more);
    var truncated = try auditPage(prepared, null, more);
    defer truncated.deinit();
    try std.testing.expectEqual(.cursor, truncated.finding().inconclusive);
    const broken = try modified(a, page, &.{"response_metadata"}, .{ .string = "" });
    defer a.free(broken);
    var malformed = try auditPage(prepared, null, broken);
    defer malformed.deinit();
    try std.testing.expectEqual(.malformed, malformed.finding().inconclusive);
}

test "Slack thread parents stay top level while thread replies remain disqualified" {
    var prepared = try slack.prepare(a, binding, "wanted", &.{button}, marker);
    defer prepared.deinit();
    const ts = "1730000000.000003";
    const message = try historyMessage(a, prepared, ts, "A1");
    defer a.free(message);
    const parent = try modified(a, message, &.{"thread_ts"}, .{ .string = ts });
    defer a.free(parent);
    const parent_page = try historyPage(a, &.{parent}, "", false);
    defer a.free(parent_page);
    var present = try auditPage(prepared, null, parent_page);
    defer present.deinit();
    try std.testing.expectEqualStrings(ts, present.finding().present);
    const reply = try modified(a, message, &.{"thread_ts"}, .{ .string = "1730000000.000002" });
    defer a.free(reply);
    const reply_page = try historyPage(a, &.{reply}, "", false);
    defer a.free(reply_page);
    var unclear = try auditPage(prepared, null, reply_page);
    defer unclear.deinit();
    try std.testing.expectEqual(.metadata, unclear.finding().inconclusive);
    const bytes = try interaction(a, prepared, "envelope");
    defer a.free(bytes);
    const thread = [_][]const u8{ "payload", "message", "thread_ts" };
    const clicked = try modified(a, bytes, &thread, .{ .string = ts });
    defer a.free(clicked);
    var accepted = try slack.parseEnvelope(a, binding, clicked, .{});
    defer accepted.deinit();
    try slack.bindInteraction(a, accepted.disposition.interaction, prepared, button, ts);
    const replied = try modified(a, bytes, &thread, .{ .string = "1730000000.000002" });
    defer a.free(replied);
    var refused = try slack.parseEnvelope(a, binding, replied, .{});
    defer refused.deinit();
    try std.testing.expectEqual(.wrong_origin, refused.disposition.ignored);
}

fn allocationWitness(allocator: std.mem.Allocator) !void {
    const bytes = try envelope(allocator, "first", "event", "input");
    defer allocator.free(bytes);
    var ingress = try slack.parseEnvelope(allocator, binding, bytes, .{});
    defer ingress.deinit();
    var prepared = try slack.prepare(allocator, binding, "request", &.{button}, marker);
    defer prepared.deinit();
    var audit = try slack.HistoryAudit.init(
        allocator,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer audit.deinit();
    try audit.ingest(
        audit.request(),
        .{
            .status = 200,
            .body = "{\"ok\":true,\"messages\":[],\"response_metadata\":{\"next_cursor\":\"\"}}",
        },
    );
    var result = try slack.interpretDelivery(
        allocator,
        binding,
        marker,
        .{ .status = 200, .body = "{\"ok\":true,\"channel\":\"D1\",\"ts\":\"1730000000.000003\"}" },
        65536,
    );
    defer result.deinit();
}

test "Slack owned protocol results clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(a, allocationWitness, .{});
}

test "Slack history retains same lineage observations before exact delivery filtering" {
    var prepared = try slack.prepare(a, binding, "known", &.{}, marker);
    defer prepared.deinit();
    var later_marker = marker;
    later_marker.key = @splat(9);
    later_marker.generation = 7;
    var later = try slack.prepare(a, binding, "later", &.{}, later_marker);
    defer later.deinit();
    later_marker.lineage = "foreign";
    var foreign = try slack.prepare(a, binding, "foreign", &.{}, later_marker);
    defer foreign.deinit();
    const unseen = try historyMessage(a, later, "1730000000.000003", "A1");
    defer a.free(unseen);
    const other = try historyMessage(a, foreign, "1730000000.000004", "A1");
    defer a.free(other);
    const page = try historyPage(a, &.{ unseen, other }, "", false);
    defer a.free(page);
    var audit = try slack.HistoryAudit.init(
        a,
        binding,
        prepared.marker,
        "1730000000.000001",
        "1730000000.000009",
        null,
        history_limits,
    );
    defer audit.deinit();
    try audit.ingest(audit.request(), .{ .status = 200, .body = page });
    try std.testing.expectEqual(.no_canary, audit.finding().inconclusive);
    try std.testing.expectEqual(@as(usize, 1), audit.observations.items.len);
    const observed = audit.observations.items[0];
    try std.testing.expectEqualStrings("1730000000.000003", observed.timestamp);
    const payload = observed.metadata.object.get("event_payload").?;
    try std.testing.expectEqualStrings("7", payload.object.get("generation").?.string);
    try std.testing.expect(audit.match == null);
}

test "Slack lineage history retains authenticated candidates on inconclusive pages" {
    const lineage = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    var later_marker = marker;
    later_marker.lineage = lineage;
    var prepared = try slack.prepare(a, binding, "later", &.{}, later_marker);
    defer prepared.deinit();
    const message = try historyMessage(a, prepared, "1730000000.000003", "A1");
    defer a.free(message);
    const foreign = try historyMessage(a, prepared, "1730000000.000004", "A2");
    defer a.free(foreign);
    const tampered = try modified(
        a,
        message,
        &.{ "metadata", "event_payload", "generation" },
        .{ .string = "01" },
    );
    defer a.free(tampered);
    const page = try historyPage(a, &.{ tampered, foreign, message }, "", false);
    defer a.free(page);
    var audit = try slack.HistoryAudit.initLineage(
        a,
        binding,
        lineage,
        "1730000000.000001",
        "1730000000.000009",
        history_limits,
    );
    defer audit.deinit();
    try audit.ingest(audit.request(), .{ .status = 200, .body = page });
    try std.testing.expectEqual(.metadata, audit.reason.?);
    try std.testing.expectEqual(@as(usize, 1), audit.observations.items.len);
    try std.testing.expectEqualStrings("1730000000.000003", audit.observations.items[0].timestamp);
    try std.testing.expect(audit.complete);
}

test "Slack lineage history validates lowercase lineage and bounded cursor traversal" {
    const lineage = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try std.testing.expectError(error.InvalidLineage, slack.HistoryAudit.initLineage(
        a,
        binding,
        "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        "1.0",
        "2.0",
        history_limits,
    ));
    var audit = try slack.HistoryAudit.initLineage(a, binding, lineage, "1.0", "2.0", .{
        .pages = 1,
        .messages = 100,
        .page_bytes = 65536,
    });
    defer audit.deinit();
    const page = try historyPage(a, &.{}, "next", true);
    defer a.free(page);
    try audit.ingest(audit.request(), .{ .status = 200, .body = page });
    try std.testing.expectEqual(@as(usize, 0), audit.pages_left);
    try std.testing.expect(!audit.complete);
    try audit.ingest(audit.request(), .{ .status = 200, .body = page });
    try std.testing.expectEqual(.budget, audit.reason.?);
    try std.testing.expectEqual(@as(usize, 1), audit.pages.items.len);
}
