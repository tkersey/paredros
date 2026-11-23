const std = @import("std");
const transport = @import("../native/slack_transport.zig");
const slack = @import("../native/slack.zig");

const first = "{\"envelope_id\":\"first\",\"type\":\"events_api\",\"payload\":{" ++
    "\"api_app_id\":\"A1\",\"team_id\":\"T1\",\"type\":\"event_callback\"," ++
    "\"event_id\":\"Ev1\",\"event\":{\"type\":\"message\",\"user\":\"U1\"," ++
    "\"channel\":\"D1\",\"channel_type\":\"im\",\"text\":\"hello\",\"ts\":\"1.0\"}}}";
const duplicate = "{\"envelope_id\":\"again\",\"type\":\"events_api\",\"payload\":{" ++
    "\"api_app_id\":\"A1\",\"team_id\":\"T1\",\"type\":\"event_callback\"," ++
    "\"event_id\":\"Ev1\",\"event\":{\"type\":\"message\",\"user\":\"U1\"," ++
    "\"channel\":\"D1\",\"channel_type\":\"im\",\"text\":\"hello\",\"ts\":\"1.0\"}}}";
const binding: slack.Binding = .{
    .app_id = "A1",
    .team_id = "T1",
    .operator_id = "U1",
    .channel_id = "D1",
    .bot_id = "B1",
};

const Fake = struct {
    frames: []const []const u8,
    count: usize = 0,
    reader: std.Io.Reader = undefined,
    writer: std.Io.Writer = undefined,
    output: [8192]u8 = undefined,
    closed: usize = 0,

    fn setup(self: *Fake) transport.Backend {
        self.writer = .fixed(&self.output);
        return .{ .context = self, .open = open };
    }

    fn open(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        io: std.Io,
        _: transport.Config,
    ) !transport.Channel {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        if (self.count >= self.frames.len) {
            try io.sleep(.fromMilliseconds(10_000), .awake);
            return error.UnexpectedConnection;
        }
        self.reader = .fixed(self.frames[self.count]);
        self.count += 1;
        return .{
            .context = self,
            .reader = &self.reader,
            .writer = &self.writer,
            .flush = flush,
            .close = close,
        };
    }

    fn flush(_: *anyopaque) !void {}

    fn close(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

fn settings() transport.Config {
    return .{ .app_token = "xapp-fixture", .reconnect_min_ms = 1, .reconnect_max_ms = 2 };
}

fn frame(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return fragment(a, 0x81, bytes);
}

fn fragment(a: std.mem.Allocator, head: u8, bytes: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(a);
    errdefer writer.deinit();
    try writer.writer.writeByte(head);
    if (bytes.len < 126) {
        try writer.writer.writeByte(@intCast(bytes.len));
    } else if (bytes.len <= std.math.maxInt(u16)) {
        try writer.writer.writeByte(126);
        try writer.writer.writeInt(u16, @intCast(bytes.len), .big);
    } else {
        try writer.writer.writeByte(127);
        try writer.writer.writeInt(u64, bytes.len, .big);
    }
    try writer.writer.writeAll(bytes);
    return writer.toOwnedSlice();
}

fn oversized(a: std.mem.Allocator, tail: []const u8) ![]u8 {
    const filler = try a.alloc(u8, 160 * 1024);
    defer a.free(filler);
    @memset(filler, 'x');
    return std.mem.concat(a, u8, &.{
        "{\"payload\":{\"api_app_id\":\"A1\",\"team_id\":\"T1\",\"event\":{" ++
            "\"envelope_id\":\"nested\",\"user\":\"U1\",\"text\":\"\\\"envelope_id\\\":\\\"spoof ",
        filler,
        "\"}}",
        tail,
    });
}

fn next(t: *transport.Transport) !transport.Request {
    const deadline = millis() + 2000;
    while (millis() < deadline) {
        if (try t.pollNext()) |request| return request;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.RequestNotReceived;
}

fn waitCount(t: *transport.Transport, comptime field: []const u8, count: u64) !void {
    const deadline = millis() + 2000;
    while (millis() < deadline) {
        if (@field(t.health(), field) >= count) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.CounterNotReached;
}

fn millis() i64 {
    return std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
}

fn ackPayload(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 6 or bytes[0] != 0x81 or bytes[1] & 0x80 == 0)
        return error.InvalidAcknowledgement;
    const length = bytes[1] & 0x7f;
    if (length >= 126 or bytes.len != length + 6) return error.InvalidAcknowledgement;
    const output = try a.alloc(u8, length);
    for (output, 0..) |*byte, i| byte.* = bytes[i + 6] ^ bytes[2 + i % 4];
    return output;
}

test "Slack transport validates configuration and provider URL without making a connection" {
    const a = std.testing.allocator;
    var config = settings();
    const t = try transport.Transport.init(a, std.testing.io, config);
    defer t.deinit();
    try std.testing.expectEqual(.stopped, t.health().state);
    config.ack_timeout_ms = 3000;
    try std.testing.expectError(
        error.InvalidConfig,
        transport.Transport.init(a, std.testing.io, config),
    );
    const url = try transport.connectionUrlFromResponse(
        a,
        "{\"ok\":true,\"url\":\"wss://wss-primary.slack.com/link/?ticket=fixture\"}",
    );
    defer a.free(url);
    try std.testing.expectEqualStrings("wss://wss-primary.slack.com/link/?ticket=fixture", url);
    try std.testing.expectError(error.SlackConnectionRejected, transport.connectionUrlFromResponse(
        a,
        "{\"ok\":false,\"error\":\"invalid_auth\"}",
    ));
    try std.testing.expectError(error.InvalidEndpoint, transport.connectionUrlFromResponse(
        a,
        "{\"ok\":true,\"url\":\"wss://evil.test/link/?ticket=fixture\"}",
    ));
}

test "Slack transport one-slot mailbox ACK follows durable admission and bounds pending work" {
    const a = std.testing.allocator;
    const wire = try frame(a, first);
    defer a.free(wire);
    const doubled = try std.mem.concat(a, u8, &.{ wire, wire });
    defer a.free(doubled);
    var fake: Fake = .{ .frames = &.{doubled} };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, settings(), fake.setup());
    defer t.deinit();
    try t.start();
    var request = try next(t);
    defer request.deinit();
    try std.testing.expectEqualStrings(first, request.bytes);
    try std.testing.expectEqual(2500, request.deadline_ms - request.received_ms);
    try std.testing.expectEqual(1, t.health().received);
    try std.testing.expectEqual(0, fake.writer.buffered().len);
    try std.testing.expectEqual(null, try t.pollNext());
    var committed: u32 = 0;
    committed += 1;
    try t.complete(request.token, .admitted);
    try waitCount(t, "acknowledged", 1);
    try std.testing.expect(t.health().last_acknowledged_ms.? - request.received_ms < 1000);
    var second = try next(t);
    defer second.deinit();
    t.stop();
    try std.testing.expectEqual(1, committed);
    const payload = try ackPayload(a, fake.writer.buffered());
    defer a.free(payload);
    try std.testing.expectEqualStrings("{\"envelope_id\":\"first\"}", payload);
    try std.testing.expectEqual(1, fake.closed);
}

test "Slack transport persistence failure emits no ACK and records bounded health" {
    const a = std.testing.allocator;
    const wire = try frame(a, first);
    defer a.free(wire);
    var fake: Fake = .{ .frames = &.{wire} };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, settings(), fake.setup());
    defer t.deinit();
    try t.start();
    var request = try next(t);
    defer request.deinit();
    try t.complete(request.token, .failed);
    try waitCount(t, "admission_failures", 1);
    t.stop();
    try std.testing.expectEqual(0, fake.writer.buffered().len);
    try std.testing.expectEqual(0, t.health().acknowledged);
    try std.testing.expectEqual(.admission, t.health().last_failure.?);
}

test "Slack transport expired admitted duplicate reuses stable identity and rejects stale ACK" {
    const a = std.testing.allocator;
    const one = try frame(a, first);
    defer a.free(one);
    const two = try frame(a, duplicate);
    defer a.free(two);
    var fake: Fake = .{ .frames = &.{ one, two } };
    var config = settings();
    config.ack_timeout_ms = 100;
    const t = try transport.Transport.initWithBackend(a, std.testing.io, config, fake.setup());
    defer t.deinit();
    try t.start();
    var original = try next(t);
    defer original.deinit();
    var retained = try slack.parseEnvelope(a, binding, original.bytes, .{});
    defer retained.deinit();
    try std.testing.expect(retained.disposition == .text);
    try waitCount(t, "deadline_misses", 1);
    var redelivered = try next(t);
    defer redelivered.deinit();
    try std.testing.expectError(error.StaleEnvelope, t.complete(original.token, .admitted));
    var replay = try slack.parseEnvelope(a, binding, redelivered.bytes, .{});
    defer replay.deinit();
    try std.testing.expectEqual(
        retained.disposition.text.operation,
        replay.disposition.text.operation,
    );
    try std.testing.expectEqual(
        retained.disposition.text.stable_request,
        replay.disposition.text.stable_request,
    );
    try t.complete(redelivered.token, .admitted);
    try waitCount(t, "acknowledged", 1);
    t.stop();
    const payload = try ackPayload(a, fake.writer.buffered());
    defer a.free(payload);
    try std.testing.expectEqualStrings("{\"envelope_id\":\"again\"}", payload);
    try std.testing.expectEqual(1, t.health().deadline_misses);
}

test "Slack transport stop joins admission and canceled connection without parent completion" {
    const a = std.testing.allocator;
    const wire = try frame(a, first);
    defer a.free(wire);
    var fake: Fake = .{ .frames = &.{wire} };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, settings(), fake.setup());
    defer t.deinit();
    try t.start();
    var request = try next(t);
    defer request.deinit();
    const started = millis();
    t.stop();
    try std.testing.expect(millis() - started < 1000);
    try std.testing.expectError(error.StaleEnvelope, t.complete(request.token, .ignored));
    try std.testing.expectEqual(0, fake.writer.buffered().len);
    try t.start();
    try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    const connecting = millis();
    t.stop();
    try std.testing.expect(millis() - connecting < 1000);
    try std.testing.expectEqual(.stopped, t.health().state);
}

test "Slack transport ignores established unsupported input and answers ping before next envelope" {
    const a = std.testing.allocator;
    const envelope = try frame(a, "{\"envelope_id\":\"ignored\",\"type\":\"unsupported\"}");
    defer a.free(envelope);
    const wire = try std.mem.concat(a, u8, &.{ "\x89\x01p", envelope });
    defer a.free(wire);
    var fake: Fake = .{ .frames = &.{wire} };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, settings(), fake.setup());
    defer t.deinit();
    try t.start();
    var request = try next(t);
    defer request.deinit();
    var parsed = try slack.parseEnvelope(a, binding, request.bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.disposition == .ignored);
    try t.complete(request.token, .ignored);
    try waitCount(t, "acknowledged", 1);
    t.stop();
    const output = fake.writer.buffered();
    try std.testing.expectEqual(@as(u8, 0x8a), output[0]);
    try std.testing.expectEqual(@as(u8, 'p'), output[6] ^ output[2]);
    const payload = try ackPayload(a, output[7..]);
    defer a.free(payload);
    try std.testing.expectEqualStrings("{\"envelope_id\":\"ignored\"}", payload);
    try std.testing.expectEqual(1, t.health().ignored);
}

test "Slack transport hello refresh and duplicate envelopes preserve stable admission identity" {
    const a = std.testing.allocator;
    const hello = try frame(a, "{\"type\":\"hello\"}");
    defer a.free(hello);
    const one = try frame(a, first);
    defer a.free(one);
    const disconnect = try frame(a, "{\"type\":\"disconnect\",\"reason\":\"refresh_requested\"}");
    defer a.free(disconnect);
    const initial = try std.mem.concat(a, u8, &.{ hello, one, disconnect });
    defer a.free(initial);
    const repeated = try frame(a, duplicate);
    defer a.free(repeated);
    var fake: Fake = .{ .frames = &.{ initial, repeated } };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, settings(), fake.setup());
    defer t.deinit();
    try t.start();
    var original = try next(t);
    defer original.deinit();
    var saved = try slack.parseEnvelope(a, binding, original.bytes, .{});
    defer saved.deinit();
    var admissions: u32 = 1;
    try t.complete(original.token, .admitted);
    var replay = try next(t);
    defer replay.deinit();
    var decoded = try slack.parseEnvelope(a, binding, replay.bytes, .{});
    defer decoded.deinit();
    if (!std.meta.eql(saved.disposition.text.operation, decoded.disposition.text.operation))
        admissions += 1;
    try std.testing.expectEqual(
        saved.disposition.text.stable_request,
        decoded.disposition.text.stable_request,
    );
    try t.complete(replay.token, .admitted);
    try waitCount(t, "acknowledged", 2);
    t.stop();
    try std.testing.expectEqual(1, admissions);
    try std.testing.expectEqual(2, t.health().received);
    try std.testing.expectEqual(2, t.health().connections);
}

test "Slack transport echoes valid close before retiring the connection" {
    var fake: Fake = .{ .frames = &.{"\x88\x02\x03\xe8"} };
    const t = try transport.Transport.initWithBackend(
        std.testing.allocator,
        std.testing.io,
        settings(),
        fake.setup(),
    );
    defer t.deinit();
    try t.start();
    try waitCount(t, "reconnects", 1);
    t.stop();
    const output = fake.writer.buffered();
    try std.testing.expectEqual(8, output.len);
    try std.testing.expectEqual(@as(u8, 0x88), output[0]);
    try std.testing.expectEqual(@as(u8, 3), output[6] ^ output[2]);
    try std.testing.expectEqual(@as(u8, 0xe8), output[7] ^ output[3]);
    try std.testing.expectEqual(0, t.health().received);
    try std.testing.expectEqual(null, t.health().last_failure);
}

test "Slack transport tokens cannot cross replacement transport owners" {
    const a = std.testing.allocator;
    const wire = try frame(a, first);
    defer a.free(wire);
    var original: transport.Token = undefined;
    {
        var fake: Fake = .{ .frames = &.{wire} };
        const t = try transport.Transport.initWithBackend(
            a,
            std.testing.io,
            settings(),
            fake.setup(),
        );
        defer t.deinit();
        try t.start();
        var request = try next(t);
        defer request.deinit();
        original = request.token;
    }
    var replacement: Fake = .{ .frames = &.{wire} };
    const t = try transport.Transport.initWithBackend(
        a,
        std.testing.io,
        settings(),
        replacement.setup(),
    );
    defer t.deinit();
    try t.start();
    var request = try next(t);
    defer request.deinit();
    try std.testing.expectEqual(original.connection, request.token.connection);
    try std.testing.expectEqual(original.sequence, request.token.sequence);
    try std.testing.expectError(error.StaleEnvelope, t.complete(original, .admitted));
    t.stop();
    try std.testing.expectEqual(0, replacement.writer.buffered().len);
}

test "Slack transport acknowledges and ignores an envelope beyond the retained bound" {
    const a = std.testing.allocator;
    const broken = try oversized(a, ",\"envelope_id\":\"broken\"");
    defer a.free(broken);
    const twice = try oversized(a, ",\"envelope_id\":\"a\",\"envelope_id\":\"b\"}");
    defer a.free(twice);
    const huge = try oversized(a, ",\"envelope_id\":\"huge\",\"type\":\"events_api\"}");
    defer a.free(huge);
    const split = huge.len / 2;
    const parts = [_][]u8{
        try frame(a, broken),
        try frame(a, twice),
        try fragment(a, 0x01, huge[0..split]),
        try fragment(a, 0x89, "p"),
        try fragment(a, 0x80, huge[split..]),
        try frame(a, first),
    };
    defer for (parts) |part| a.free(part);
    const wire = try std.mem.concat(a, u8, &parts);
    defer a.free(wire);
    var fake: Fake = .{ .frames = &.{wire} };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, settings(), fake.setup());
    defer t.deinit();
    try t.start();
    var request = try next(t);
    defer request.deinit();
    try std.testing.expectEqualStrings(first, request.bytes);
    try std.testing.expectEqual(1, fake.count);
    try std.testing.expectEqual(null, t.health().last_failure);
    try std.testing.expectEqual(3, t.health().ignored);
    try t.complete(request.token, .admitted);
    try waitCount(t, "acknowledged", 2);
    t.stop();
    try std.testing.expectEqual(4, t.health().received);
    const output = fake.writer.buffered();
    try std.testing.expectEqual(@as(u8, 0x8a), output[0]);
    const boundary = 13 + @as(usize, output[8] & 0x7f);
    const ignored = try ackPayload(a, output[7..boundary]);
    defer a.free(ignored);
    try std.testing.expectEqualStrings("{\"envelope_id\":\"huge\"}", ignored);
    const admitted = try ackPayload(a, output[boundary..]);
    defer a.free(admitted);
    try std.testing.expectEqualStrings("{\"envelope_id\":\"first\"}", admitted);
}

test "Slack transport retires a connection whose message exceeds the discard bound without ACK" {
    const a = std.testing.allocator;
    const huge = try oversized(a, ",\"envelope_id\":\"huge\"}");
    defer a.free(huge);
    const wire = try frame(a, huge);
    defer a.free(wire);
    var config = settings();
    config.discard_bytes_max = 160 * 1024;
    var fake: Fake = .{ .frames = &.{wire} };
    const t = try transport.Transport.initWithBackend(a, std.testing.io, config, fake.setup());
    defer t.deinit();
    try t.start();
    try waitCount(t, "reconnects", 1);
    t.stop();
    try std.testing.expectEqual(0, fake.writer.buffered().len);
    try std.testing.expectEqual(.protocol, t.health().last_failure.?);
    try std.testing.expectEqual(0, t.health().received);
    config.discard_bytes_max = config.message_bytes_max - 1;
    try std.testing.expectError(
        error.InvalidConfig,
        transport.Transport.initWithBackend(a, std.testing.io, config, fake.setup()),
    );
}
