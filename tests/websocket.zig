const std = @import("std");
const ws = @import("../native/websocket.zig");

const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
const accepted = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
const upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
    "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: " ++ accepted ++ "\r\n\r\n";

test "WebSocket verifies RFC handshake and rejects unsupported negotiations" {
    try std.testing.expectEqualStrings(accepted, &ws.acceptKey(client_key));
    try ws.validateUpgrade(try std.http.Client.Response.Head.parse(upgrade), client_key);
    try ws.validateUpgrade(try std.http.Client.Response.Head.parse(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Accept: " ++ accepted ++ "\r\n\r\n",
    ), client_key);
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\n" ++
            "Sec-WebSocket-Accept: wrong\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\n" ++
            "Sec-WebSocket-Accept: " ++ accepted ++ "\r\nSec-WebSocket-Accept: " ++
            accepted ++ "\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\n" ++
            "Sec-WebSocket-Accept: " ++ accepted ++ "\r\nSec-WebSocket-Extensions: deflate\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\n" ++
            "Sec-WebSocket-Accept: " ++ accepted ++ "\r\nSec-WebSocket-Protocol: other\r\n\r\n",
    }) |bytes| {
        const head = try std.http.Client.Response.Head.parse(bytes);
        if (ws.validateUpgrade(head, client_key)) |_| return error.UnsafeUpgradeAccepted else |_| {}
    }
}

test "WebSocket restricts issued endpoints without accepting suffix tricks or credentials" {
    const uri = try ws.endpoint("wss://wss-primary.slack.com/link/?ticket=private", 8192);
    try std.testing.expectEqualStrings("https", uri.scheme);
    for ([_][]const u8{
        "ws://wss.slack.com/link/",
        "wss://wss.slack.com.evil.test/link/",
        "wss://evilslack.com/link/",
        "wss://slack.com/link/",
        "wss://user@wss.slack.com/link/",
        "wss://wss.slack.com:444/link/",
        "wss://%77ss.slack.com/link/",
        "wss://wss.slack.com/link/#fragment",
        "wss://wss.slack.com\\@evil.test/link/",
        "wss://wss.slack.com/link/\r\nInjected: yes",
        "wss://127.0.0.1/link/",
    }) |url| try std.testing.expectError(error.InvalidEndpoint, ws.endpoint(url, 8192));
}

test "WebSocket assembles fragmented UTF8 text while delivering intervening controls" {
    var decoder = try ws.Decoder.init(std.testing.allocator, 16);
    defer decoder.deinit();
    var reader = std.Io.Reader.fixed("\x01\x02A\xc2\x89\x01p\x80\x02\xa2B");
    var ping = try decoder.next(&reader);
    defer ping.deinit();
    try std.testing.expectEqual(.ping, ping.opcode);
    try std.testing.expectEqualStrings("p", ping.bytes);
    var text = try decoder.next(&reader);
    defer text.deinit();
    try std.testing.expectEqual(.text, text.opcode);
    try std.testing.expectEqualStrings("A¢B", text.bytes);
}

test "WebSocket rejects invalid frames fragmentation UTF8 and aggregate capacity" {
    const Case = struct { bytes: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .bytes = "\xc1\x00", .expected = error.ReservedBits },
        .{ .bytes = "\x81\x80", .expected = error.MaskedServerFrame },
        .{ .bytes = "\x83\x00", .expected = error.InvalidOpcode },
        .{ .bytes = "\x09\x00", .expected = error.InvalidControlFrame },
        .{ .bytes = "\x89\x7e\x00\x7e", .expected = error.InvalidControlFrame },
        .{ .bytes = "\x81\x7e\x00\x01", .expected = error.NoncanonicalLength },
        .{ .bytes = "\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00", .expected = error.InvalidLength },
        .{ .bytes = "\x80\x00", .expected = error.UnexpectedContinuation },
        .{ .bytes = "\x01\x01a\x81\x01b", .expected = error.InterleavedMessage },
        .{ .bytes = "\x81\x01\xff", .expected = error.InvalidUtf8 },
        .{ .bytes = "\x88\x01a", .expected = error.InvalidClose },
        .{ .bytes = "\x88\x02\x03\xed", .expected = error.InvalidClose },
        .{ .bytes = "\x88\x03\x03\xe8\xff", .expected = error.InvalidUtf8 },
        .{ .bytes = "\x81\x09", .expected = error.MessageTooLarge },
        .{ .bytes = "\x01\x05abcde\x80\x04fghi", .expected = error.MessageTooLarge },
        .{ .bytes = "\x81\x03ab", .expected = error.EndOfStream },
    }) |item| {
        var decoder = try ws.Decoder.init(std.testing.allocator, 8);
        defer decoder.deinit();
        var reader = std.Io.Reader.fixed(item.bytes);
        try std.testing.expectError(item.expected, decoder.next(&reader));
    }
}

test "WebSocket client frames mask payloads and use canonical extended lengths" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ws.writeFrame(&writer, .text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    try std.testing.expectEqualSlices(u8, &.{
        0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58,
    }, writer.buffered());
    var payload: [126]u8 = @splat('x');
    writer = .fixed(&buffer);
    try ws.writeFrame(&writer, .binary, &payload, .{ 1, 2, 3, 4 });
    const frame = writer.buffered();
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0xfe, 0, 126, 1, 2, 3, 4 }, frame[0..8]);
    for (frame[8..], 0..) |byte, i|
        try std.testing.expectEqual(@as(u8, 'x') ^ @as(u8, @intCast(i % 4 + 1)), byte);
}

test "WebSocket accepts canonical 64-bit lengths and enforces exact message bound" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, 65536 + 10);
    defer a.free(bytes);
    bytes[0] = 0x81;
    bytes[1] = 127;
    std.mem.writeInt(u64, bytes[2..10], 65536, .big);
    @memset(bytes[10..], 'x');
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try ws.Decoder.init(a, 65536);
    defer decoder.deinit();
    var message = try decoder.next(&reader);
    defer message.deinit();
    try std.testing.expectEqual(65536, message.bytes.len);
    try std.testing.expectEqual(@as(u8, 'x'), message.bytes[65535]);
    var small = try ws.Decoder.init(a, 65535);
    defer small.deinit();
    reader = .fixed(bytes);
    try std.testing.expectError(error.MessageTooLarge, small.next(&reader));
    std.mem.writeInt(u64, bytes[2..10], 125, .big);
    reader = .fixed(bytes);
    try std.testing.expectError(error.NoncanonicalLength, decoder.next(&reader));
}
