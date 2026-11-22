const std = @import("std");

pub const Digest = [32]u8;
pub const Binding = struct {
    app_id: []const u8,
    team_id: []const u8,
    operator_id: []const u8,
    channel_id: []const u8,
    bot_id: []const u8,
};
pub const Limits = struct { envelope_bytes: usize = 65536, text_characters: usize = 4000 };
pub const Timestamp = struct {
    seconds: []const u8,
    fraction: []const u8,

    pub fn parse(bytes: []const u8) !Timestamp {
        const dot = std.mem.indexOfScalar(u8, bytes, '.') orelse return error.InvalidTimestamp;
        if (dot == 0 or dot + 1 == bytes.len or bytes.len > 64) return error.InvalidTimestamp;
        for (bytes[0..dot]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
        for (bytes[dot + 1 ..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
        if (dot > 1 and bytes[0] == '0') return error.InvalidTimestamp;
        return .{ .seconds = bytes[0..dot], .fraction = bytes[dot + 1 ..] };
    }

    pub fn order(self: Timestamp, other: Timestamp) std.math.Order {
        const lengths = std.math.order(self.seconds.len, other.seconds.len);
        if (lengths != .eq) return lengths;
        const seconds = std.mem.order(u8, self.seconds, other.seconds);
        if (seconds != .eq) return seconds;
        for (0..@max(self.fraction.len, other.fraction.len)) |i| {
            const left = if (i < self.fraction.len) self.fraction[i] else '0';
            const right = if (i < other.fraction.len) other.fraction[i] else '0';
            if (left != right) return std.math.order(left, right);
        }
        return .eq;
    }
};
pub const Ignore = enum { malformed, oversized, wrong_origin, unsupported };
pub const Text = struct {
    operation: Digest,
    stable_request: Digest,
    event_id: []const u8,
    timestamp: []const u8,
    text: []const u8,
};
pub const Interaction = struct {
    origin: Binding,
    operation: Digest,
    stable_request: Digest,
    message_timestamp: []const u8,
    action_timestamp: []const u8,
    block_id: []const u8,
    action_id: []const u8,
    value: []const u8,
    message: std.json.Value,
};
pub const Ingress = struct {
    arena: std.heap.ArenaAllocator,
    envelope_id: ?[]const u8 = null,
    disposition: union(enum) { ignored: Ignore, text: Text, interaction: Interaction },

    pub fn deinit(self: *Ingress) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn get(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.Malformed;
    return value.object.get(key) orelse error.Malformed;
}

fn text(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.Malformed;
    return value.string;
}

fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    return text(try get(value, key));
}

fn optional(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn equals(value: std.json.Value, key: []const u8, expected: []const u8) bool {
    return same(string(value, key) catch return false, expected);
}

fn topLevel(message: std.json.Value) bool {
    const thread = optional(message, "thread_ts") orelse return true;
    return same(text(thread) catch return false, string(message, "ts") catch return false);
}

fn digest(parts: []const []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(part.len), .big);
        hash.update(&length);
        hash.update(part);
    }
    return hash.finalResult();
}

fn count(text_value: []const u8, max: usize) !void {
    const characters = std.unicode.utf8CountCodepoints(text_value) catch return error.Malformed;
    if (characters > max) return error.Oversized;
}

fn validateAddress(binding: Binding) !void {
    for ([_][]const u8{
        binding.app_id,
        binding.team_id,
        binding.operator_id,
        binding.channel_id,
    }) |id|
        if (id.len == 0 or id.len > 128) return error.InvalidBinding;
    if (binding.channel_id[0] != 'D') return error.InvalidBinding;
}

pub fn validateBinding(binding: Binding) !void {
    try validateAddress(binding);
    if (binding.bot_id.len == 0 or binding.bot_id.len > 128) return error.InvalidBinding;
}

fn copyBinding(a: std.mem.Allocator, binding: Binding) !Binding {
    var result = binding;
    inline for (@typeInfo(Binding).@"struct".field_names) |name|
        @field(result, name) = try a.dupe(u8, @field(binding, name));
    return result;
}

pub fn parseEnvelope(
    a: std.mem.Allocator,
    binding: Binding,
    bytes: []const u8,
    limits: Limits,
) !Ingress {
    try validateBinding(binding);
    var result: Ingress = .{
        .arena = .init(a),
        .disposition = .{ .ignored = .malformed },
    };
    errdefer result.deinit();
    if (bytes.len > limits.envelope_bytes) {
        result.disposition = .{ .ignored = .oversized };
        return result;
    }
    const allocator = result.arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return result,
    };
    result.envelope_id = string(parsed.value, "envelope_id") catch return result;
    if (result.envelope_id.?.len == 0) return result;
    result.disposition = classify(binding, parsed.value, limits) catch |err| switch (err) {
        error.WrongOrigin => .{ .ignored = .wrong_origin },
        error.Unsupported => .{ .ignored = .unsupported },
        error.Oversized => .{ .ignored = .oversized },
        else => .{ .ignored = .malformed },
    };
    return result;
}

fn classify(
    binding: Binding,
    envelope: std.json.Value,
    limits: Limits,
) !@FieldType(Ingress, "disposition") {
    const payload = try get(envelope, "payload");
    if (!equals(payload, "api_app_id", binding.app_id)) return error.WrongOrigin;
    if (equals(envelope, "type", "events_api")) {
        if (!equals(payload, "team_id", binding.team_id)) return error.WrongOrigin;
        if (!equals(payload, "type", "event_callback")) return error.Unsupported;
        return .{ .text = try parseText(binding, payload, limits) };
    }
    if (!equals(envelope, "type", "interactive") or
        !equals(payload, "type", "block_actions")) return error.Unsupported;
    if (!equals(try get(payload, "team"), "id", binding.team_id) or
        !equals(try get(payload, "user"), "id", binding.operator_id) or
        !equals(try get(payload, "channel"), "id", binding.channel_id)) return error.WrongOrigin;
    return .{ .interaction = try parseInteraction(binding, payload) };
}

fn parseText(binding: Binding, payload: std.json.Value, limits: Limits) !Text {
    const event = try get(payload, "event");
    if (!equals(event, "user", binding.operator_id) or
        !equals(event, "channel", binding.channel_id)) return error.WrongOrigin;
    if (!equals(event, "type", "message") or !equals(event, "channel_type", "im"))
        return error.Unsupported;
    for ([_][]const u8{
        "subtype",
        "thread_ts",
        "bot_id",
        "files",
        "attachments",
        "edited",
    }) |field|
        if (optional(event, field) != null) return error.Unsupported;
    const event_id = try string(payload, "event_id");
    if (event_id.len == 0 or event_id.len > 128) return error.Malformed;
    const body = try string(event, "text");
    if (body.len == 0) return error.Unsupported;
    try count(body, limits.text_characters);
    const ts = try string(event, "ts");
    _ = try Timestamp.parse(ts);
    const operation = digest(
        &.{ "paredros.slack.event/1", binding.app_id, binding.team_id, event_id },
    );
    return .{
        .operation = operation,
        .stable_request = digest(
            &.{ &operation, binding.operator_id, binding.channel_id, ts, body },
        ),
        .event_id = event_id,
        .timestamp = ts,
        .text = body,
    };
}

fn appOrigin(binding: Binding, message: std.json.Value) bool {
    if (!botOrigin(binding, message)) return false;
    const app = optional(message, "app_id") orelse blk: {
        const profile = optional(message, "bot_profile") orelse return false;
        break :blk optional(profile, "app_id") orelse return false;
    };
    if (!same(text(app) catch return false, binding.app_id)) return false;
    if (optional(message, "team")) |team| if (!same(text(team) catch return false, binding.team_id))
        return false;
    if (optional(message, "bot_profile")) |profile| if (optional(profile, "team_id")) |team|
        if (!same(text(team) catch return false, binding.team_id)) return false;
    return true;
}

fn botOrigin(binding: Binding, message: std.json.Value) bool {
    if (!equals(message, "bot_id", binding.bot_id)) return false;
    if (optional(message, "app_id")) |app|
        if (!same(text(app) catch return false, binding.app_id)) return false;
    if (optional(message, "team")) |team|
        if (!same(text(team) catch return false, binding.team_id)) return false;
    if (optional(message, "bot_profile")) |profile| {
        if (optional(profile, "app_id")) |app|
            if (!same(text(app) catch return false, binding.app_id)) return false;
        if (optional(profile, "team_id")) |team|
            if (!same(text(team) catch return false, binding.team_id)) return false;
    }
    return true;
}

fn parseInteraction(binding: Binding, payload: std.json.Value) !Interaction {
    const container = try get(payload, "container");
    if (!equals(container, "type", "message") or
        !equals(container, "channel_id", binding.channel_id)) return error.WrongOrigin;
    const message = try get(payload, "message");
    if (!botOrigin(binding, message) or !topLevel(message)) return error.WrongOrigin;
    const ts = try string(message, "ts");
    _ = try Timestamp.parse(ts);
    if (!equals(container, "message_ts", ts)) return error.Malformed;
    const actions = try get(payload, "actions");
    if (actions != .array or actions.array.items.len != 1) return error.Unsupported;
    const action = actions.array.items[0];
    if (!equals(action, "type", "button")) return error.Unsupported;
    const action_ts = try string(action, "action_ts");
    _ = try Timestamp.parse(action_ts);
    const block = try string(action, "block_id");
    const id = try string(action, "action_id");
    const value = try string(action, "value");
    try boundedIdentifier(block, 255);
    try boundedIdentifier(id, 255);
    try boundedIdentifier(value, 2000);
    const operation = interactionDigest(binding, ts, action_ts, block, id, value);
    return .{
        .origin = .{
            .app_id = try string(payload, "api_app_id"),
            .team_id = try string(try get(payload, "team"), "id"),
            .operator_id = try string(try get(payload, "user"), "id"),
            .channel_id = try string(try get(payload, "channel"), "id"),
            .bot_id = try string(message, "bot_id"),
        },
        .operation = operation,
        .stable_request = operation,
        .message_timestamp = ts,
        .action_timestamp = action_ts,
        .block_id = block,
        .action_id = id,
        .value = value,
        .message = message,
    };
}

pub fn interactionDigest(
    binding: Binding,
    message_timestamp: []const u8,
    action_timestamp: []const u8,
    block: []const u8,
    action: []const u8,
    value: []const u8,
) Digest {
    return digest(&.{
        "paredros.slack.interaction/1", binding.app_id,    binding.team_id, binding.operator_id,
        binding.channel_id,             message_timestamp, block,           action,
        value,                          action_timestamp,
    });
}

fn boundedIdentifier(value: []const u8, maximum: usize) !void {
    if (value.len == 0) return error.Malformed;
    try count(value, maximum);
}

pub const Button = struct {
    block_id: []const u8,
    action_id: []const u8,
    value: []const u8,
    label: []const u8,
};
pub const Marker = struct {
    key: Digest,
    generation: u64,
    issue: u64,
    content: Digest,
    lineage: []const u8,
    obligation: []const u8,
    source_epoch: []const u8,
    kind: enum { digest, activation, question, directive, reply },
    prior: u64,
    covered: u64,
    evidence: Digest,
    base_oid: []const u8 = "",
    tip_oid: []const u8 = "",
};
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    binding: Binding,
    body: []const u8,
    marker: Marker,
    blocks: std.json.Value,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Link = struct { label: []const u8, url: []const u8 };

pub fn escape(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    for (bytes) |byte| switch (byte) {
        '&' => try output.appendSlice(a, "&amp;"),
        '<' => try output.appendSlice(a, "&lt;"),
        '>' => try output.appendSlice(a, "&gt;"),
        else => try output.append(a, byte),
    };
    return output.toOwnedSlice(a);
}

fn put(
    a: std.mem.Allocator,
    target: *std.json.Value,
    key: []const u8,
    value: std.json.Value,
) !void {
    try target.object.put(a, try a.dupe(u8, key), value);
}

fn object(a: std.mem.Allocator) std.json.Value {
    _ = a;
    return .{ .object = .empty };
}

fn valueString(a: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try a.dupe(u8, value) };
}

fn hex(a: std.mem.Allocator, value: Digest) !std.json.Value {
    return valueString(a, &std.fmt.bytesToHex(value, .lower));
}

fn decimal(a: std.mem.Allocator, value: u64) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(a, "{d}", .{value}) };
}

fn markerValue(a: std.mem.Allocator, marker: Marker) !std.json.Value {
    if (marker.covered < marker.prior) return error.InvalidMarker;
    for ([_][]const u8{ marker.lineage, marker.obligation, marker.source_epoch }) |id|
        try boundedIdentifier(id, 128);
    for ([_][]const u8{ marker.base_oid, marker.tip_oid }) |oid| {
        if (oid.len != 0 and oid.len != 40) return error.InvalidMarker;
        for (oid) |byte| if (!std.ascii.isHex(byte)) return error.InvalidMarker;
    }
    var payload = object(a);
    try put(a, &payload, "marker_schema", try valueString(a, "paredros.delivery/1"));
    try put(a, &payload, "delivery_key", try hex(a, marker.key));
    try put(a, &payload, "generation", try decimal(a, marker.generation));
    try put(a, &payload, "issue", try decimal(a, marker.issue));
    try put(a, &payload, "content_sha256", try hex(a, marker.content));
    try put(a, &payload, "lineage_root", try valueString(a, marker.lineage));
    try put(a, &payload, "obligation", try valueString(a, marker.obligation));
    try put(a, &payload, "source_epoch", try valueString(a, marker.source_epoch));
    try put(a, &payload, "kind", try valueString(a, @tagName(marker.kind)));
    try put(a, &payload, "prior_observation", try decimal(a, marker.prior));
    try put(a, &payload, "covered_observation", try decimal(a, marker.covered));
    try put(a, &payload, "evidence_manifest", try hex(a, marker.evidence));
    try put(a, &payload, "base_oid", try valueString(a, marker.base_oid));
    try put(a, &payload, "tip_oid", try valueString(a, marker.tip_oid));
    var metadata = object(a);
    try put(a, &metadata, "event_type", try valueString(a, "paredros_delivery"));
    try put(a, &metadata, "event_payload", payload);
    return metadata;
}

fn sectionEnd(body: []const u8, start: usize) !usize {
    var end = start;
    var characters: usize = 0;
    while (end < body.len and characters < 3000) {
        var width: usize = try std.unicode.utf8ByteSequenceLength(body[end]);
        var count_chars: usize = 1;
        if (body[end] == '&') {
            const semicolon = std.mem.indexOfScalar(u8, body[end..], ';') orelse
                return error.InvalidEncoding;
            width = semicolon + 1;
            count_chars = width;
        }
        if (characters + count_chars > 3000) break;
        end += width;
        characters += count_chars;
    }
    return end;
}

fn descriptionBlocks(a: std.mem.Allocator, body: []const u8, blocks: *std.json.Value) !void {
    var start: usize = 0;
    while (start < body.len) {
        const end = try sectionEnd(body, start);
        var label = object(a);
        try put(a, &label, "type", try valueString(a, "plain_text"));
        try put(a, &label, "text", try valueString(a, body[start..end]));
        try put(a, &label, "emoji", .{ .bool = false });
        var section = object(a);
        try put(a, &section, "type", try valueString(a, "section"));
        const id = if (start == 0) "paredros_description" else try std.fmt.allocPrint(
            a,
            "paredros_description_{d}",
            .{blocks.array.items.len},
        );
        try put(a, &section, "block_id", try valueString(a, id));
        try put(a, &section, "text", label);
        try blocks.array.append(section);
        start = end;
    }
}

fn buttonBlocks(
    a: std.mem.Allocator,
    body: []const u8,
    buttons: []const Button,
    links: []const Link,
) !std.json.Value {
    if (buttons.len > 49 or links.len > 1) return error.Oversized;
    var blocks: std.json.Value = .{ .array = std.array_list.Managed(std.json.Value).init(a) };
    if (buttons.len != 0 or links.len != 0) try descriptionBlocks(a, body, &blocks);
    if (blocks.array.items.len + buttons.len + links.len > 50) return error.Oversized;
    for (buttons, 0..) |button, index| {
        try boundedIdentifier(button.block_id, 255);
        if (std.mem.startsWith(u8, button.block_id, "paredros_description") or
            same(button.block_id, "paredros_verified_comparison")) return error.DuplicateBlock;
        try boundedIdentifier(button.action_id, 255);
        try boundedIdentifier(button.value, 2000);
        const escaped_label = try escape(a, button.label);
        try boundedIdentifier(escaped_label, 75);
        for (buttons[0..index]) |prior| if (same(prior.block_id, button.block_id))
            return error.DuplicateBlock;
        var label = object(a);
        try put(a, &label, "type", try valueString(a, "plain_text"));
        try put(a, &label, "text", .{ .string = escaped_label });
        try put(a, &label, "emoji", .{ .bool = false });
        var element = object(a);
        try put(a, &element, "type", try valueString(a, "button"));
        try put(a, &element, "text", label);
        try put(a, &element, "action_id", try valueString(a, button.action_id));
        try put(a, &element, "value", try valueString(a, button.value));
        var elements: std.json.Value = .{ .array = std.array_list.Managed(std.json.Value).init(a) };
        try elements.array.append(element);
        var block = object(a);
        try put(a, &block, "type", try valueString(a, "actions"));
        try put(a, &block, "block_id", try valueString(a, button.block_id));
        try put(a, &block, "elements", elements);
        try blocks.array.append(block);
    }
    for (links) |link| try blocks.array.append(try linkBlock(a, link));
    return blocks;
}

fn linkBlock(a: std.mem.Allocator, link: Link) !std.json.Value {
    try boundedIdentifier(link.label, 75);
    try boundedIdentifier(link.url, 3000);
    if (!std.mem.startsWith(u8, link.url, "https://github.com/")) return error.InvalidLink;
    var label = object(a);
    try put(a, &label, "type", try valueString(a, "plain_text"));
    try put(a, &label, "text", try valueString(a, link.label));
    try put(a, &label, "emoji", .{ .bool = false });
    var element = object(a);
    try put(a, &element, "type", try valueString(a, "button"));
    try put(a, &element, "text", label);
    try put(a, &element, "url", try valueString(a, link.url));
    try put(a, &element, "action_id", try valueString(a, "paredros_open_comparison"));
    var elements: std.json.Value = .{ .array = std.array_list.Managed(std.json.Value).init(a) };
    try elements.array.append(element);
    var block = object(a);
    try put(a, &block, "type", try valueString(a, "actions"));
    try put(a, &block, "block_id", try valueString(a, "paredros_verified_comparison"));
    try put(a, &block, "elements", elements);
    return block;
}

pub fn prepare(
    a: std.mem.Allocator,
    binding: Binding,
    body: []const u8,
    buttons: []const Button,
    marker: Marker,
) !Prepared {
    return prepareLinked(a, binding, body, buttons, &.{}, marker);
}

pub fn prepareLinked(
    a: std.mem.Allocator,
    binding: Binding,
    body: []const u8,
    buttons: []const Button,
    links: []const Link,
    marker: Marker,
) !Prepared {
    try validateAddress(binding);
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const escaped = try escape(allocator, body);
    try boundedIdentifier(escaped, 4000);
    var payload = object(allocator);
    try put(allocator, &payload, "channel", try valueString(allocator, binding.channel_id));
    try put(allocator, &payload, "text", .{ .string = escaped });
    try put(allocator, &payload, "parse", try valueString(allocator, "none"));
    for ([_][]const u8{ "mrkdwn", "link_names", "unfurl_links", "unfurl_media" }) |field|
        try put(allocator, &payload, field, .{ .bool = false });
    const blocks = try buttonBlocks(allocator, escaped, buttons, links);
    if (buttons.len != 0 or links.len != 0) try put(allocator, &payload, "blocks", blocks);
    const canonical = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    var frozen = marker;
    std.crypto.hash.sha2.Sha256.hash(canonical, &frozen.content, .{});
    frozen.lineage = try allocator.dupe(u8, marker.lineage);
    frozen.obligation = try allocator.dupe(u8, marker.obligation);
    frozen.source_epoch = try allocator.dupe(u8, marker.source_epoch);
    frozen.base_oid = try allocator.dupe(u8, marker.base_oid);
    frozen.tip_oid = try allocator.dupe(u8, marker.tip_oid);
    try put(allocator, &payload, "metadata", try markerValue(allocator, frozen));
    const encoded = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    const frozen_binding = try copyBinding(allocator, binding);
    return .{
        .arena = arena,
        .binding = frozen_binding,
        .body = encoded,
        .marker = frozen,
        .blocks = blocks,
    };
}

pub fn equalJson(left: std.json.Value, right: std.json.Value) bool {
    const Pair = struct { left: std.json.Value, right: std.json.Value };
    var pending: [512]Pair = undefined;
    pending[0] = .{ .left = left, .right = right };
    var length: usize = 1;
    while (length != 0) {
        length -= 1;
        const pair = pending[length];
        if (std.meta.activeTag(pair.left) != std.meta.activeTag(pair.right)) return false;
        switch (pair.left) {
            .null => {},
            .bool => |value| if (value != pair.right.bool) return false,
            .integer => |value| if (value != pair.right.integer) return false,
            .float => |value| if (value != pair.right.float) return false,
            .number_string => |value| if (!same(value, pair.right.number_string)) return false,
            .string => |value| if (!same(value, pair.right.string)) return false,
            .array => |items| {
                if (items.items.len != pair.right.array.items.len or
                    items.items.len > pending.len - length) return false;
                for (items.items, pair.right.array.items) |a, b| {
                    pending[length] = .{ .left = a, .right = b };
                    length += 1;
                }
            },
            .object => |fields| {
                if (fields.count() != pair.right.object.count() or
                    fields.count() > pending.len - length) return false;
                var iterator = fields.iterator();
                while (iterator.next()) |field| {
                    pending[length] = .{
                        .left = field.value_ptr.*,
                        .right = pair.right.object.get(field.key_ptr.*) orelse return false,
                    };
                    length += 1;
                }
            },
        }
    }
    return true;
}

pub fn bindInteraction(
    a: std.mem.Allocator,
    interaction: Interaction,
    prepared: Prepared,
    button: Button,
    known_ts: ?[]const u8,
) !void {
    if (!botOrigin(prepared.binding, interaction.message) or
        !topLevel(interaction.message) or
        !equals(interaction.message, "ts", interaction.message_timestamp))
        return error.UnboundInteraction;
    inline for (@typeInfo(Binding).@"struct".field_names) |name| {
        if (!same(@field(interaction.origin, name), @field(prepared.binding, name)))
            return error.UnboundInteraction;
    }
    if (!same(interaction.block_id, button.block_id) or
        !same(interaction.action_id, button.action_id) or
        !same(interaction.value, button.value)) return error.UnboundInteraction;
    if (known_ts) |ts| {
        _ = try Timestamp.parse(ts);
        if (!same(ts, interaction.message_timestamp)) return error.UnboundInteraction;
    }
    const blocks = try get(interaction.message, "blocks");
    if (!equalJson(blocks, prepared.blocks)) return error.UnboundInteraction;
    var found = false;
    for (prepared.blocks.array.items) |block| {
        if (!equals(block, "block_id", button.block_id)) continue;
        const elements = try get(block, "elements");
        for (elements.array.items) |element| {
            if (equals(element, "action_id", button.action_id) and
                equals(element, "value", button.value)) found = true;
        }
    }
    if (!found) return error.UnboundInteraction;
    if (known_ts == null) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const metadata = try get(interaction.message, "metadata");
        if (!equalJson(metadata, try markerValue(arena.allocator(), prepared.marker)))
            return error.UnboundInteraction;
    }
}

pub const HistoryRequest = struct {
    team_id: []const u8,
    channel: []const u8,
    oldest: []const u8,
    latest: ?[]const u8,
    cursor: []const u8,
    inclusive: bool = true,
    include_all_metadata: bool = true,
};
pub const Response = struct { status: u16, body: []const u8 };
pub const Canary = struct { timestamp: []const u8, marker: Marker };
pub const HistoryLimits = struct { pages: usize, messages: usize, page_bytes: usize };
pub const HistoryPage = struct { request: HistoryRequest, response: Response };
pub const AuditReason = enum {
    incomplete,
    budget,
    malformed,
    cursor,
    metadata,
    conflict,
    no_canary,
    access,
    moving_window,
};
pub const Finding = union(enum) {
    present: []const u8,
    not_observed,
    inconclusive: AuditReason,
};
pub const HistoryObservation = struct { timestamp: []const u8, metadata: std.json.Value };
pub const HistoryAudit = struct {
    arena: std.heap.ArenaAllocator,
    binding: Binding,
    marker: std.json.Value = .null,
    lineage: []const u8,
    canary: ?struct { timestamp: []const u8, marker: std.json.Value } = null,
    oldest: []const u8,
    latest: ?[]const u8,
    cursor: []const u8 = "",
    cursors: std.StringHashMapUnmanaged(void) = .empty,
    match: ?[]const u8 = null,
    canary_seen: bool = false,
    complete: bool = false,
    reason: ?AuditReason = null,
    pages_left: usize,
    messages_left: usize,
    page_bytes: usize,
    pages: std.ArrayList(HistoryPage) = .empty,
    observations: std.ArrayList(HistoryObservation) = .empty,

    pub fn init(
        a: std.mem.Allocator,
        binding: Binding,
        marker: Marker,
        oldest: []const u8,
        latest: ?[]const u8,
        canary: ?Canary,
        limits: HistoryLimits,
    ) !HistoryAudit {
        var result = try initWindow(a, binding, marker.lineage, oldest, latest, limits);
        errdefer result.deinit();
        const allocator = result.arena.allocator();
        result.marker = try markerValue(allocator, marker);
        if (canary) |item| {
            if (!same(oldest, item.timestamp)) return error.InvalidWindow;
            result.canary = .{
                .timestamp = try allocator.dupe(u8, item.timestamp),
                .marker = try markerValue(allocator, item.marker),
            };
        }
        return result;
    }

    pub fn initLineage(
        a: std.mem.Allocator,
        binding: Binding,
        lineage: []const u8,
        oldest: []const u8,
        latest: ?[]const u8,
        limits: HistoryLimits,
    ) !HistoryAudit {
        if (lineage.len != 64) return error.InvalidLineage;
        for (lineage) |byte|
            if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidLineage;
        return initWindow(a, binding, lineage, oldest, latest, limits);
    }

    fn initWindow(
        a: std.mem.Allocator,
        binding: Binding,
        lineage: []const u8,
        oldest: []const u8,
        latest: ?[]const u8,
        limits: HistoryLimits,
    ) !HistoryAudit {
        try validateBinding(binding);
        const oldest_time = try Timestamp.parse(oldest);
        if (latest) |upper| if (oldest_time.order(try Timestamp.parse(upper)) == .gt)
            return error.InvalidWindow;
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const frozen_binding = try copyBinding(allocator, binding);
        const frozen_lineage = try allocator.dupe(u8, lineage);
        const frozen_oldest = try allocator.dupe(u8, oldest);
        const frozen_latest = if (latest) |upper| try allocator.dupe(u8, upper) else null;
        return .{
            .arena = arena,
            .binding = frozen_binding,
            .lineage = frozen_lineage,
            .oldest = frozen_oldest,
            .latest = frozen_latest,
            .pages_left = limits.pages,
            .messages_left = limits.messages,
            .page_bytes = limits.page_bytes,
        };
    }

    pub fn deinit(self: *HistoryAudit) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn request(self: *const HistoryAudit) HistoryRequest {
        return .{
            .team_id = self.binding.team_id,
            .channel = self.binding.channel_id,
            .oldest = self.oldest,
            .latest = self.latest,
            .cursor = self.cursor,
        };
    }

    pub fn ingest(self: *HistoryAudit, requested: HistoryRequest, response: Response) !void {
        if (self.complete or self.reason != null) return error.AuditFinished;
        if (self.pages_left == 0 or response.body.len > self.page_bytes) {
            self.reason = .budget;
            return;
        }
        self.pages_left -= 1;
        const expected = self.request();
        if (!same(
            requested.team_id,
            expected.team_id,
        ) or !same(requested.channel, expected.channel) or
            !same(
                requested.oldest,
                expected.oldest,
            ) or !sameOptional(requested.latest, expected.latest) or
            !same(requested.cursor, expected.cursor) or !requested.inclusive or
            !requested.include_all_metadata) return error.InvalidHistoryRequest;
        const retained = try self.arena.allocator().dupe(u8, response.body);
        try self.pages.append(self.arena.allocator(), .{
            .request = expected,
            .response = .{ .status = response.status, .body = retained },
        });
        if (response.status != 200) {
            self.reason = .access;
            return;
        }
        self.ingestBody(retained) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => self.reason = .malformed,
        };
    }

    fn ingestBody(self: *HistoryAudit, bytes: []const u8) !void {
        const a = self.arena.allocator();
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            a,
            bytes,
            .{ .allocate = .alloc_always },
        );
        const ok = try get(parsed.value, "ok");
        if (ok != .bool or !ok.bool) {
            self.reason = .access;
            return;
        }
        const messages = try get(parsed.value, "messages");
        if (messages != .array) return error.Malformed;
        for (messages.array.items) |message| {
            if (self.messages_left == 0) {
                self.reason = .budget;
                return;
            }
            self.messages_left -= 1;
            try self.observe(message);
        }
        const next = try nextCursor(parsed.value);
        if (next.len == 0) {
            if (optional(parsed.value, "has_more")) |more| {
                if (more != .bool or more.bool) {
                    self.reason = .cursor;
                    return;
                }
            }
            self.complete = true;
            return;
        }
        const found = try self.cursors.getOrPut(a, next);
        if (found.found_existing) {
            self.reason = .cursor;
            return;
        }
        self.cursor = next;
    }

    fn observe(self: *HistoryAudit, message: std.json.Value) !void {
        const ts = try string(message, "ts");
        const time = try Timestamp.parse(ts);
        if (time.order(try Timestamp.parse(self.oldest)) == .lt) return error.Malformed;
        if (self.latest) |upper| if (time.order(try Timestamp.parse(upper)) == .gt)
            return error.Malformed;
        if (!appOrigin(self.binding, message)) {
            if (equals(message, "bot_id", self.binding.bot_id)) self.reason = .metadata;
            return;
        }
        if (!equals(message, "type", "message") or !topLevel(message)) {
            self.reason = .metadata;
            return;
        }
        const metadata = optional(message, "metadata") orelse {
            self.reason = .metadata;
            return;
        };
        if (!equals(metadata, "event_type", "paredros_delivery")) {
            self.reason = .metadata;
            return;
        }
        if (!validMetadata(metadata)) {
            self.reason = .metadata;
            return;
        }
        if (self.canary) |canary| if (same(ts, canary.timestamp)) {
            if (equalJson(
                metadata,
                canary.marker,
            )) self.canary_seen = true else self.reason = .metadata;
        };
        const payload = try get(metadata, "event_payload");
        if (equals(payload, "lineage_root", self.lineage))
            try self.observations.append(self.arena.allocator(), .{
                .timestamp = ts,
                .metadata = metadata,
            });
        if (self.marker == .null) return;
        const expected = try get(self.marker, "event_payload");
        if (!equals(payload, "delivery_key", try string(expected, "delivery_key"))) return;
        if (!equals(payload, "generation", try string(expected, "generation"))) return;
        if (!equalJson(metadata, self.marker)) {
            self.reason = .conflict;
            return;
        }
        if (self.match) |prior| {
            if (!same(prior, ts)) self.reason = .conflict;
        } else self.match = ts;
    }

    pub fn finding(self: *const HistoryAudit) Finding {
        if (self.reason) |reason| return .{ .inconclusive = reason };
        if (!self.complete) return .{ .inconclusive = .incomplete };
        if (self.match) |ts| return .{ .present = ts };
        if (!self.canary_seen) return .{ .inconclusive = .no_canary };
        if (self.latest == null) return .{ .inconclusive = .moving_window };
        return .not_observed;
    }
};

fn nextCursor(page: std.json.Value) ![]const u8 {
    const metadata = optional(page, "response_metadata") orelse return "";
    if (metadata != .object) return error.Malformed;
    const next = optional(metadata, "next_cursor") orelse return "";
    if (next == .null) return "";
    return text(next);
}

fn sameOptional(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return same(left.?, right.?);
}

fn validMetadata(metadata: std.json.Value) bool {
    if (metadata != .object or metadata.object.count() != 2 or
        !equals(metadata, "event_type", "paredros_delivery")) return false;
    const payload = get(metadata, "event_payload") catch return false;
    if (payload != .object or payload.object.count() != 14 or
        !equals(payload, "marker_schema", "paredros.delivery/1")) return false;
    for ([_][]const u8{
        "generation",
        "issue",
        "prior_observation",
        "covered_observation",
    }) |field| {
        const value = string(payload, field) catch return false;
        if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
        for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
        _ = std.fmt.parseInt(u64, value, 10) catch return false;
    }
    for ([_][]const u8{ "delivery_key", "content_sha256", "evidence_manifest" }) |field| {
        const value = string(payload, field) catch return false;
        if (value.len != 64) return false;
        for (value) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    for ([_][]const u8{ "lineage_root", "obligation", "source_epoch", "kind" }) |field| {
        boundedIdentifier(string(payload, field) catch return false, 128) catch return false;
    }
    _ = std.meta.stringToEnum(
        @FieldType(Marker, "kind"),
        string(payload, "kind") catch return false,
    ) orelse return false;
    const prior = std.fmt.parseInt(
        u64,
        string(payload, "prior_observation") catch return false,
        10,
    ) catch return false;
    const covered = std.fmt.parseInt(
        u64,
        string(payload, "covered_observation") catch return false,
        10,
    ) catch return false;
    if (covered < prior) return false;
    for ([_][]const u8{ "base_oid", "tip_oid" }) |field| {
        const value = string(payload, field) catch return false;
        if (value.len != 0 and value.len != 40) return false;
        for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub const DeliveryResult = struct {
    arena: std.heap.ArenaAllocator,
    outcome: union(enum) {
        indeterminate,
        confirmed: struct { timestamp: []const u8, metadata_degraded: bool, rendering_fault: bool },
        rejected: struct { retryable: bool, reason: []const u8 },
    } = .indeterminate,

    pub fn deinit(self: *DeliveryResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn interpretDelivery(
    a: std.mem.Allocator,
    binding: Binding,
    marker: Marker,
    response: Response,
    bytes_max: usize,
) !DeliveryResult {
    try validateBinding(binding);
    var result: DeliveryResult = .{ .arena = .init(a) };
    errdefer result.deinit();
    if (response.status >= 500 or response.body.len > bytes_max) return result;
    result.outcome = deliveryOutcome(
        result.arena.allocator(),
        binding,
        marker,
        response,
    ) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => .indeterminate,
        };
    return result;
}

fn deliveryOutcome(
    a: std.mem.Allocator,
    binding: Binding,
    marker: Marker,
    response: Response,
) !@FieldType(DeliveryResult, "outcome") {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        response.body,
        .{ .allocate = .alloc_always },
    );
    const ok = try get(parsed.value, "ok");
    if (ok != .bool) return error.Malformed;
    if (!ok.bool) {
        const failure = try string(parsed.value, "error");
        for ([_][]const u8{
            "not_authed",
            "invalid_auth",
            "account_inactive",
            "token_revoked",
            "missing_scope",
            "no_permission",
            "channel_not_found",
            "not_in_channel",
            "is_archived",
            "msg_too_long",
            "invalid_arguments",
            "invalid_blocks",
            "invalid_metadata",
        }) |known| if (same(
            failure,
            known,
        )) return .{ .rejected = .{ .retryable = false, .reason = failure } };
        if (same(failure, "ratelimited") or same(failure, "rate_limited"))
            return .{ .rejected = .{ .retryable = true, .reason = failure } };
        return .indeterminate;
    }
    if (response.status != 200 or !equals(parsed.value, "channel", binding.channel_id))
        return .indeterminate;
    const ts = try string(parsed.value, "ts");
    _ = try Timestamp.parse(ts);
    var degraded = true;
    if (optional(parsed.value, "message")) |message| {
        if (optional(message, "metadata")) |metadata|
            degraded = !equalJson(metadata, try markerValue(a, marker));
    }
    var rendering_fault = false;
    if (optional(parsed.value, "response_metadata")) |metadata| {
        if (optional(metadata, "warnings")) |warnings| {
            if (warnings == .array) for (warnings.array.items) |warning| {
                if (warning == .string and same(warning.string, "message_truncated"))
                    rendering_fault = true;
            };
        }
    }
    return .{
        .confirmed = .{
            .timestamp = ts,
            .metadata_degraded = degraded,
            .rendering_fault = rendering_fault,
        },
    };
}
