const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

pub const Message = struct {
    allocator: std.mem.Allocator,
    opcode: Opcode,
    bytes: []u8,
    oversized: ?u64 = null,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Overflow = struct {
    context: *anyopaque,
    bytes_max: u64,
    feed: *const fn (*anyopaque, []const u8) void,
};

const Header = struct { final: bool, opcode: Opcode, length: u64 };

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    message_bytes_max: usize,
    overflow: ?Overflow = null,
    fragments: std.ArrayList(u8) = .empty,
    fragmented_opcode: ?Opcode = null,
    received: u64 = 0,
    discarding: bool = false,

    pub fn init(a: std.mem.Allocator, maximum: usize) !Decoder {
        if (maximum == 0) return error.InvalidLimit;
        return .{ .allocator = a, .message_bytes_max = maximum };
    }

    pub fn deinit(self: *Decoder) void {
        self.fragments.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *Decoder, reader: *std.Io.Reader) !Message {
        while (true) { // tiger: event-loop
            const header = try readHeader(reader);
            if (try self.accept(reader, header)) |message| return message;
        }
    }

    fn accept(self: *Decoder, reader: *std.Io.Reader, header: Header) !?Message {
        switch (header.opcode) {
            .close, .ping, .pong => {
                const bytes = try self.allocator.alloc(u8, @intCast(header.length));
                errdefer self.allocator.free(bytes);
                try reader.readSliceAll(bytes);
                if (header.opcode == .close) try validateClose(bytes);
                return .{ .allocator = self.allocator, .opcode = header.opcode, .bytes = bytes };
            },
            .text, .binary => {
                if (self.fragmented_opcode != null) return error.InterleavedMessage;
                self.fragmented_opcode = header.opcode;
                self.received = 0;
                self.discarding = false;
                self.fragments.clearRetainingCapacity();
            },
            .continuation => if (self.fragmented_opcode == null)
                return error.UnexpectedContinuation,
        }
        const opcode = self.fragmented_opcode.?;
        const total = self.received +| header.length;
        if (self.discarding or total > self.message_bytes_max) {
            try self.discard(reader, opcode, header.length, total);
        } else {
            try self.retain(reader, @intCast(header.length));
        }
        self.received = total;
        if (!header.final) return null;
        return try self.complete(opcode);
    }

    fn retain(self: *Decoder, reader: *std.Io.Reader, length: usize) !void {
        if (self.fragments.items.len == 0) {
            try self.fragments.ensureTotalCapacityPrecise(self.allocator, length);
        } else {
            try self.fragments.ensureUnusedCapacity(self.allocator, length);
        }
        try reader.readSliceAll(self.fragments.unusedCapacitySlice()[0..length]);
        self.fragments.items.len += length;
    }

    fn discard(
        self: *Decoder,
        reader: *std.Io.Reader,
        opcode: Opcode,
        length: u64,
        total: u64,
    ) !void {
        const overflow = self.overflow orelse return error.MessageTooLarge;
        if (opcode != .text or total > overflow.bytes_max) return error.MessageTooLarge;
        if (!self.discarding) {
            overflow.feed(overflow.context, self.fragments.items);
            self.fragments.clearAndFree(self.allocator);
            self.discarding = true;
        }
        var remaining = length;
        while (remaining > 0) {
            const buffered = try reader.peekGreedy(1);
            const count: usize = @intCast(@min(buffered.len, remaining));
            overflow.feed(overflow.context, buffered[0..count]);
            reader.toss(count);
            remaining -= count;
        }
    }

    fn complete(self: *Decoder, opcode: Opcode) !Message {
        self.fragmented_opcode = null;
        if (self.discarding) {
            self.discarding = false;
            return .{
                .allocator = self.allocator,
                .opcode = opcode,
                .bytes = &.{},
                .oversized = self.received,
            };
        }
        try validateText(opcode, self.fragments.items);
        const bytes = try self.fragments.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .opcode = opcode, .bytes = bytes };
    }
};

fn validateText(opcode: Opcode, bytes: []const u8) !void {
    if (opcode == .text and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
}

fn readHeader(reader: *std.Io.Reader) !Header {
    const head = try reader.takeArray(2);
    if (head[0] & 0x70 != 0) return error.ReservedBits;
    if (head[1] & 0x80 != 0) return error.MaskedServerFrame;
    const opcode = std.enums.fromInt(Opcode, head[0] & 0x0f) orelse return error.InvalidOpcode;
    const final = head[0] & 0x80 != 0;
    const length = try frameLength(reader, head[1] & 0x7f);
    const control = @backingInt(opcode) >= 8;
    if (control and (!final or length > 125)) return error.InvalidControlFrame;
    return .{ .final = final, .opcode = opcode, .length = length };
}

fn frameLength(reader: *std.Io.Reader, short: u8) !u64 {
    if (short < 126) return short;
    if (short == 126) {
        const length = std.mem.readInt(u16, try reader.takeArray(2), .big);
        if (length < 126) return error.NoncanonicalLength;
        return length;
    }
    const length = std.mem.readInt(u64, try reader.takeArray(8), .big);
    if (length > std.math.maxInt(i64)) return error.InvalidLength;
    if (length <= std.math.maxInt(u16)) return error.NoncanonicalLength;
    return length;
}

fn validateClose(bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (bytes.len == 1) return error.InvalidClose;
    const code = std.mem.readInt(u16, bytes[0..2], .big);
    const standard = code >= 1000 and code <= 1014 and
        code != 1004 and code != 1005 and code != 1006;
    if (!standard and !(code >= 3000 and code <= 4999)) return error.InvalidClose;
    if (!std.unicode.utf8ValidateSlice(bytes[2..])) return error.InvalidUtf8;
}

pub fn writeFrame(
    writer: *std.Io.Writer,
    opcode: Opcode,
    bytes: []const u8,
    mask: [4]u8,
) !void {
    if (opcode == .continuation) return error.InvalidOpcode;
    if (@backingInt(opcode) >= 8 and bytes.len > 125) return error.InvalidControlFrame;
    if (opcode == .close) try validateClose(bytes);
    try validateText(opcode, bytes);
    try writer.writeByte(0x80 | @as(u8, @backingInt(opcode)));
    if (bytes.len < 126) {
        try writer.writeByte(0x80 | @as(u8, @intCast(bytes.len)));
    } else if (bytes.len <= std.math.maxInt(u16)) {
        try writer.writeByte(0xfe);
        try writer.writeInt(u16, @intCast(bytes.len), .big);
    } else {
        try writer.writeByte(0xff);
        try writer.writeInt(u64, bytes.len, .big);
    }
    try writer.writeAll(&mask);
    var offset: usize = 0;
    var scratch: [4096]u8 = undefined;
    while (offset < bytes.len) {
        const count = @min(scratch.len, bytes.len - offset);
        for (scratch[0..count], 0..) |*byte, index|
            byte.* = bytes[offset + index] ^ mask[(offset + index) % mask.len];
        try writer.writeAll(scratch[0..count]);
        offset += count;
    }
}

pub fn key(entropy: [16]u8) [24]u8 {
    var result: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &entropy);
    return result;
}

pub fn acceptKey(client_key: []const u8) [28]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(client_key);
    hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    const digest = hash.finalResult();
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

pub fn validateUpgrade(head: std.http.Client.Response.Head, client_key: []const u8) !void {
    if (head.status != .switching_protocols or head.version != .@"HTTP/1.1")
        return error.UpgradeRejected;
    if (head.transfer_encoding != .none or (head.content_length orelse 0) != 0)
        return error.InvalidUpgrade;
    var upgrade = false;
    var connection = false;
    var accepted = false;
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            if (upgrade or !std.ascii.eqlIgnoreCase(header.value, "websocket"))
                return error.InvalidUpgrade;
            upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            connection = connection or hasToken(header.value, "upgrade");
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            if (accepted or !std.mem.eql(u8, header.value, &acceptKey(client_key)))
                return error.InvalidUpgrade;
            accepted = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-extensions") or
            std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol"))
            return error.UnrequestedExtension;
    }
    if (!upgrade or !connection or !accepted) return error.InvalidUpgrade;
}

fn hasToken(bytes: []const u8, expected: []const u8) bool {
    var parts = std.mem.splitScalar(u8, bytes, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), expected)) return true;
    }
    return false;
}

pub fn endpoint(url: []const u8, maximum: usize) !std.Uri {
    if (url.len == 0 or url.len > maximum) return error.InvalidEndpoint;
    for (url) |byte| if (byte < 0x21 or byte > 0x7e or byte == '\\')
        return error.InvalidEndpoint;
    var uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (!std.mem.eql(u8, uri.scheme, "wss") or uri.host == null or uri.user != null or
        uri.password != null or uri.fragment != null or (uri.port orelse 443) != 443)
        return error.InvalidEndpoint;
    var buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Io.net.HostName.fromUri(uri, &buffer) catch return error.InvalidEndpoint;
    const suffix = ".slack.com";
    if (host.bytes.len <= suffix.len or !std.ascii.endsWithIgnoreCase(host.bytes, suffix))
        return error.InvalidEndpoint;
    const raw = switch (uri.host.?) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    if (std.mem.findScalar(u8, raw, '%') != null) return error.InvalidEndpoint;
    uri.scheme = "https";
    return uri;
}
