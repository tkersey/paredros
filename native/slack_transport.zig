const std = @import("std");
const http = @import("http.zig");
const websocket = @import("websocket.zig");

pub const Config = struct {
    app_token: []const u8,
    message_bytes_max: usize = 128 * 1024,
    discard_bytes_max: u64 = 16 * 1024 * 1024,
    ack_timeout_ms: u32 = 2500,
    connect_timeout_ms: u32 = 15_000,
    idle_timeout_ms: u32 = 60_000,
    reconnect_min_ms: u32 = 1000,
    reconnect_max_ms: u32 = 30_000,
};

pub const Disposition = enum { admitted, ignored, failed };
pub const Token = struct { owner: [16]u8, connection: u64, sequence: u64 };
pub const State = enum { stopped, connecting, connected, waiting_for_owner, reconnecting };
pub const Failure = enum {
    connection,
    protocol,
    admission,
    acknowledgement_deadline,
    acknowledgement_write,
};
pub const Health = struct {
    state: State = .stopped,
    last_failure: ?Failure = null,
    connections: u64 = 0,
    received: u64 = 0,
    acknowledged: u64 = 0,
    ignored: u64 = 0,
    admission_failures: u64 = 0,
    deadline_misses: u64 = 0,
    reconnects: u64 = 0,
    last_received_ms: ?i64 = null,
    last_acknowledged_ms: ?i64 = null,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    token: Token,
    received_ms: i64,
    deadline_ms: i64,
    bytes: []u8,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Channel = struct {
    context: *anyopaque,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    flush: *const fn (*anyopaque) anyerror!void,
    close: *const fn (*anyopaque) void,
};

pub const Backend = struct {
    context: ?*anyopaque = null,
    open: *const fn (?*anyopaque, std.mem.Allocator, std.Io, Config) anyerror!Channel,
};

const Slot = struct {
    token: Token,
    received_ms: i64,
    deadline_ms: i64,
    bytes: ?[]u8,
    state: enum { queued, claimed, admitted, ignored, failed, expired } = .queued,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    backend: Backend,
    owner: [16]u8,
    future: ?std.Io.Future(void) = null,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    slot: ?Slot = null,
    connection: u64 = 0,
    sequence: u64 = 0,
    stopping: bool = true,
    report: Health = .{},

    pub fn init(a: std.mem.Allocator, io: std.Io, config: Config) !*Transport {
        return initWithBackend(a, io, config, .{ .open = Network.open });
    }

    pub fn initWithBackend(
        a: std.mem.Allocator,
        io: std.Io,
        config: Config,
        backend: Backend,
    ) !*Transport {
        try validateConfig(config);
        var owner: [16]u8 = undefined;
        try io.randomSecure(&owner);
        const self = try a.create(Transport);
        errdefer a.destroy(self);
        var copied = config;
        copied.app_token = try a.dupe(u8, config.app_token);
        self.* = .{
            .allocator = a,
            .io = io,
            .config = copied,
            .backend = backend,
            .owner = owner,
        };
        return self;
    }

    pub fn start(self: *Transport) !void {
        if (self.future != null) return error.AlreadyStarted;
        self.mutex.lockUncancelable(self.io);
        self.stopping = false;
        self.report.state = .connecting;
        self.mutex.unlock(self.io);
        self.future = self.io.concurrent(run, .{self}) catch |err| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.stopping = true;
            self.report.state = .stopped;
            return err;
        };
    }

    pub fn stop(self: *Transport) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.future) |*future| future.cancel(self.io);
        self.future = null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearSlot();
        self.report.state = .stopped;
    }

    pub fn deinit(self: *Transport) void {
        self.stop();
        const a = self.allocator;
        const token = @constCast(self.config.app_token);
        std.crypto.secureZero(u8, token);
        a.free(token);
        a.destroy(self);
    }

    pub fn health(self: *Transport) Health {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.report;
    }

    pub fn pollNext(self: *Transport) !?Request {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return null;
        const slot = if (self.slot) |*value| value else return null;
        if (slot.state != .queued) return null;
        if (now(self.io) >= slot.deadline_ms) {
            slot.state = .expired;
            self.changed.signal(self.io);
            return null;
        }
        const bytes = slot.bytes.?;
        slot.bytes = null;
        slot.state = .claimed;
        return .{
            .allocator = self.allocator,
            .token = slot.token,
            .received_ms = slot.received_ms,
            .deadline_ms = slot.deadline_ms,
            .bytes = bytes,
        };
    }

    pub fn complete(self: *Transport, token: Token, disposition: Disposition) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const slot = if (self.slot) |*value| value else return error.StaleEnvelope;
        if (self.stopping or !std.meta.eql(slot.token, token) or slot.state != .claimed)
            return error.StaleEnvelope;
        if (now(self.io) >= slot.deadline_ms) {
            slot.state = .expired;
            self.changed.signal(self.io);
            return error.AcknowledgementExpired;
        }
        slot.state = switch (disposition) {
            .admitted => .admitted,
            .ignored => .ignored,
            .failed => .failed,
        };
        self.changed.signal(self.io);
    }

    fn clearSlot(self: *Transport) void {
        if (self.slot) |slot| if (slot.bytes) |bytes| self.allocator.free(bytes);
        self.slot = null;
    }

    fn setState(self: *Transport, state: State, failure: ?Failure) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.report.state = state;
        if (failure) |value| {
            self.report.last_failure = value;
            if (value == .acknowledgement_deadline) self.report.deadline_misses +|= 1;
        }
    }

    fn stopped(self: *Transport) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopping;
    }

    fn run(self: *Transport) void {
        var delay = self.config.reconnect_min_ms;
        while (!self.stopped()) { // tiger: event-loop
            self.setState(.connecting, null);
            const before = self.health().acknowledged;
            self.connected() catch |err| {
                if (err == error.Canceled or self.stopped()) break;
                self.setState(.reconnecting, classifyFailure(err));
            };
            if (self.stopped()) break;
            self.mutex.lockUncancelable(self.io);
            self.clearSlot();
            self.report.reconnects +|= 1;
            self.report.state = .reconnecting;
            self.mutex.unlock(self.io);
            if (self.health().acknowledged != before) delay = self.config.reconnect_min_ms;
            self.io.sleep(.fromMilliseconds(delay), .awake) catch break;
            delay = @min(self.config.reconnect_max_ms, delay *| 2);
        }
        self.setState(.stopped, null);
    }

    fn connected(self: *Transport) !void {
        var opening: Opening = .{ .transport = self };
        defer if (opening.channel) |channel| channel.close(channel.context);
        try timed(self.io, self.config.connect_timeout_ms, Opening.perform, &opening);
        if (opening.failure) |failure| return failure;
        const channel = opening.channel orelse return error.ConnectionFailed;
        self.mutex.lockUncancelable(self.io);
        self.connection = std.math.add(u64, self.connection, 1) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.report.connections +|= 1;
        self.report.state = .connected;
        self.mutex.unlock(self.io);
        var identity: Identity = undefined;
        identity.reset();
        var decoder = try websocket.Decoder.init(self.allocator, self.config.message_bytes_max);
        defer decoder.deinit();
        decoder.overflow = .{
            .context = &identity,
            .bytes_max = self.config.discard_bytes_max,
            .feed = Identity.feed,
        };
        while (!self.stopped()) { // tiger: event-loop
            var reading: Reading = .{ .decoder = &decoder, .reader = channel.reader };
            defer if (reading.message) |*message| message.deinit();
            try timed(self.io, self.config.idle_timeout_ms, Reading.perform, &reading);
            if (reading.failure) |failure| return failure;
            const message = reading.message orelse return error.Disconnected;
            switch (message.opcode) {
                .ping => try self.send(channel, .pong, message.bytes, self.config.ack_timeout_ms),
                .pong => {},
                .close => {
                    try self.send(channel, .close, message.bytes, self.config.ack_timeout_ms);
                    return;
                },
                .text => if (message.oversized) |size| {
                    try self.oversized(channel, identity.finish(), size, now(self.io));
                    identity.reset();
                } else if (!try self.envelope(channel, message.bytes, now(self.io))) return,
                .binary, .continuation => return error.UnsupportedMessage,
            }
        }
    }

    fn envelope(self: *Transport, channel: Channel, bytes: []const u8, received_ms: i64) !bool {
        var metadata = try Metadata.parse(self.allocator, bytes);
        defer metadata.deinit();
        switch (metadata.kind) {
            .hello => return true,
            .disconnect => return false,
            .envelope => {},
        }
        const deadline_ms = try std.math.add(i64, received_ms, self.config.ack_timeout_ms);
        try self.publish(bytes, received_ms, deadline_ms);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.clearSlot();
            self.mutex.unlock(self.io);
        }
        const disposition = try self.awaitDisposition(deadline_ms);
        if (metadata.envelope_id) |id| {
            try self.acknowledge(channel, id, deadline_ms);
        } else if (disposition == .admitted) return error.MissingEnvelopeIdentity;
        self.setState(.connected, null);
        return true;
    }

    fn oversized(
        self: *Transport,
        channel: Channel,
        envelope_id: ?[]const u8,
        size: u64,
        received_ms: i64,
    ) !void {
        const deadline_ms = try std.math.add(i64, received_ms, self.config.ack_timeout_ms);
        try self.mutex.lock(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            return error.Canceled;
        }
        self.report.received +|= 1;
        self.report.ignored +|= 1;
        self.report.last_received_ms = received_ms;
        self.mutex.unlock(self.io);
        std.log.warn("Slack envelope ignored: oversized ({d} bytes)", .{size});
        if (envelope_id) |id| try self.acknowledge(channel, id, deadline_ms);
    }

    fn acknowledge(self: *Transport, channel: Channel, id: []const u8, deadline_ms: i64) !void {
        const ack = try std.json.Stringify.valueAlloc(self.allocator, .{ .envelope_id = id }, .{});
        defer self.allocator.free(ack);
        const remaining = deadline_ms - now(self.io);
        if (remaining <= 0) return error.AcknowledgementExpired;
        self.send(channel, .text, ack, @intCast(remaining)) catch |err| switch (err) {
            error.Canceled => return err,
            error.Timeout => return error.AcknowledgementExpired,
            else => return error.AcknowledgementWriteFailed,
        };
        self.mutex.lockUncancelable(self.io);
        self.report.acknowledged +|= 1;
        self.report.last_acknowledged_ms = now(self.io);
        self.mutex.unlock(self.io);
    }

    fn publish(self: *Transport, bytes: []const u8, received_ms: i64, deadline_ms: i64) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Canceled;
        if (self.slot != null) return error.QueueFull;
        self.sequence = try std.math.add(u64, self.sequence, 1);
        self.slot = .{
            .token = .{
                .owner = self.owner,
                .connection = self.connection,
                .sequence = self.sequence,
            },
            .received_ms = received_ms,
            .deadline_ms = deadline_ms,
            .bytes = copy,
        };
        self.report.received +|= 1;
        self.report.last_received_ms = received_ms;
        self.report.state = .waiting_for_owner;
    }

    fn awaitDisposition(self: *Transport, deadline_ms: i64) !Disposition {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.stopping) { // tiger: event-loop
            const slot = if (self.slot) |*value| value else return error.StaleEnvelope;
            if (now(self.io) >= deadline_ms or slot.state == .expired) {
                return error.AcknowledgementExpired;
            }
            switch (slot.state) {
                .admitted => return .admitted,
                .ignored => {
                    self.report.ignored +|= 1;
                    return .ignored;
                },
                .failed => {
                    self.report.admission_failures +|= 1;
                    self.report.last_failure = .admission;
                    return error.AdmissionFailed;
                },
                .queued, .claimed, .expired => {},
            }
            const remaining: u32 = @intCast(@max(1, deadline_ms - now(self.io)));
            self.changed.waitTimeout(self.io, &self.mutex, .{
                .duration = .{ .clock = .awake, .raw = .fromMilliseconds(remaining) },
            }) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => return err,
            };
        }
        return error.Canceled;
    }

    fn send(
        self: *Transport,
        channel: Channel,
        opcode: websocket.Opcode,
        bytes: []const u8,
        ms: u32,
    ) !void {
        var writing: Writing = .{
            .transport = self,
            .channel = channel,
            .opcode = opcode,
            .bytes = bytes,
        };
        try timed(self.io, ms, Writing.perform, &writing);
        if (writing.failure) |failure| return failure;
    }
};

fn validateConfig(config: Config) !void {
    if (config.app_token.len == 0 or config.app_token.len > 4096 or
        config.message_bytes_max == 0 or config.discard_bytes_max < config.message_bytes_max or
        config.ack_timeout_ms == 0 or
        config.ack_timeout_ms >= 3000 or config.connect_timeout_ms == 0 or
        config.idle_timeout_ms == 0 or config.reconnect_min_ms == 0 or
        config.reconnect_max_ms < config.reconnect_min_ms) return error.InvalidConfig;
    for (config.app_token) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidConfig;
}

fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn classifyFailure(err: anyerror) Failure {
    return switch (err) {
        error.AdmissionFailed => .admission,
        error.AcknowledgementExpired => .acknowledgement_deadline,
        error.AcknowledgementWriteFailed => .acknowledgement_write,
        error.InvalidOpcode,
        error.ReservedBits,
        error.MaskedServerFrame,
        error.InvalidControlFrame,
        error.MessageTooLarge,
        error.NoncanonicalLength,
        error.InvalidLength,
        error.InvalidClose,
        error.InvalidUtf8,
        error.InterleavedMessage,
        error.UnexpectedContinuation,
        error.UnsupportedMessage,
        error.InvalidUpgrade,
        error.UpgradeRejected,
        error.UnrequestedExtension,
        => .protocol,
        else => .connection,
    };
}

const Opening = struct {
    transport: *Transport,
    channel: ?Channel = null,
    failure: ?anyerror = null,

    fn perform(self: *@This()) void {
        const t = self.transport;
        self.channel = t.backend.open(t.backend.context, t.allocator, t.io, t.config) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const Reading = struct {
    decoder: *websocket.Decoder,
    reader: *std.Io.Reader,
    message: ?websocket.Message = null,
    failure: ?anyerror = null,

    fn perform(self: *@This()) void {
        self.message = self.decoder.next(self.reader) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const Writing = struct {
    transport: *Transport,
    channel: Channel,
    opcode: websocket.Opcode,
    bytes: []const u8,
    failure: ?anyerror = null,

    fn perform(self: *@This()) void {
        self.write() catch |err| {
            self.failure = err;
        };
    }

    fn write(self: *@This()) !void {
        var mask: [4]u8 = undefined;
        try self.transport.io.randomSecure(&mask);
        try websocket.writeFrame(self.channel.writer, self.opcode, self.bytes, mask);
        try self.channel.flush(self.channel.context);
    }
};

fn sleep(io: std.Io, ms: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(ms), .awake);
}

fn timed(io: std.Io, ms: u32, comptime function: anytype, context: anytype) !void {
    const Event = union(enum) { work: void, timer: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.timer, sleep, .{ io, ms });
    try select.concurrent(.work, function, .{context});
    const result = try select.await();
    if (result == .timer) {
        try result.timer;
        return error.Timeout;
    }
}

const Metadata = struct {
    parsed: ?std.json.Parsed(std.json.Value),
    kind: enum { hello, disconnect, envelope } = .envelope,
    envelope_id: ?[]const u8 = null,

    fn parse(a: std.mem.Allocator, bytes: []const u8) !Metadata {
        const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch |err|
            switch (err) {
                error.OutOfMemory => return err,
                else => return .{ .parsed = null },
            };
        var result: Metadata = .{ .parsed = parsed };
        if (parsed.value != .object) return result;
        if (parsed.value.object.get("type")) |kind| if (kind == .string) {
            if (std.mem.eql(u8, kind.string, "hello")) result.kind = .hello;
            if (std.mem.eql(u8, kind.string, "disconnect")) result.kind = .disconnect;
        };
        if (parsed.value.object.get("envelope_id")) |id| {
            if (id == .string and id.string.len > 0 and id.string.len <= 256)
                result.envelope_id = id.string;
        }
        return result;
    }

    fn deinit(self: *Metadata) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};

const Identity = struct {
    memory: [256]u8,
    fixed: std.heap.FixedBufferAllocator,
    scanner: std.json.Scanner,
    text: [256]u8,
    length: usize,
    long: bool,
    key: bool,
    selected: bool,
    seen: bool,
    found: ?[256]u8,
    found_length: usize,
    state: enum { scanning, done, failed },

    fn reset(self: *Identity) void {
        self.fixed = .init(&self.memory);
        self.scanner = .initStreaming(self.fixed.allocator());
        self.length = 0;
        self.long = false;
        self.key = true;
        self.selected = false;
        self.seen = false;
        self.found = null;
        self.found_length = 0;
        self.state = .scanning;
    }

    fn feed(context: *anyopaque, bytes: []const u8) void {
        const self: *Identity = @ptrCast(@alignCast(context));
        if (self.state != .scanning or bytes.len == 0) return;
        self.scanner.feedInput(bytes);
        self.drain(bytes.len) catch {
            self.state = .failed;
        };
    }

    fn finish(self: *Identity) ?[]const u8 {
        if (self.state == .scanning) {
            self.scanner.endInput();
            self.drain(0) catch {
                self.state = .failed;
            };
        }
        if (self.state != .done) return null;
        const found = &(self.found orelse return null);
        return found[0..self.found_length];
    }

    fn drain(self: *Identity, bytes: usize) !void {
        for (0..bytes + 2) |_| {
            const item = self.scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => return,
                else => return err,
            };
            if (item == .end_of_document) {
                self.state = .done;
                return;
            }
            try self.take(item);
        }
        return error.ScannerStalled;
    }

    fn take(self: *Identity, item: std.json.Token) !void {
        const height = self.scanner.stackHeight();
        if (height == 0 and item != .object_end) return error.NotObject;
        if (height != 1) return;
        switch (item) {
            .array_begin => return error.NotObject,
            .object_begin, .partial_number => {},
            .partial_string => |piece| self.append(piece),
            .partial_string_escaped_1 => |piece| self.append(&piece),
            .partial_string_escaped_2 => |piece| self.append(&piece),
            .partial_string_escaped_3 => |piece| self.append(&piece),
            .partial_string_escaped_4 => |piece| self.append(&piece),
            .string => |piece| {
                self.append(piece);
                try self.complete(true);
            },
            else => try self.complete(false),
        }
    }

    fn append(self: *Identity, piece: []const u8) void {
        if (self.long or piece.len > self.text.len - self.length) {
            self.long = true;
            return;
        }
        @memcpy(self.text[self.length..][0..piece.len], piece);
        self.length += piece.len;
    }

    fn complete(self: *Identity, string: bool) !void {
        defer {
            self.length = 0;
            self.long = false;
        }
        if (self.key) {
            self.key = false;
            self.selected = !self.long and
                std.mem.eql(u8, self.text[0..self.length], "envelope_id");
            return;
        }
        self.key = true;
        if (!self.selected) return;
        if (self.seen) return error.DuplicateField;
        self.seen = true;
        if (!string or self.long or self.length == 0) return;
        self.found = self.text;
        self.found_length = self.length;
    }
};

const Network = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    request: ?std.http.Client.Request = null,
    url: []u8,

    fn open(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, config: Config) !Channel {
        const url = try connectionUrl(a, io, config);
        errdefer {
            std.crypto.secureZero(u8, url);
            a.free(url);
        }
        const uri = try websocket.endpoint(url, 8192);
        const self = try a.create(Network);
        errdefer a.destroy(self);
        self.* = .{
            .allocator = a,
            .client = .{ .allocator = a, .io = io, .read_buffer_size = 32 * 1024 },
            .url = url,
        };
        errdefer self.release();
        var entropy: [16]u8 = undefined;
        try io.randomSecure(&entropy);
        const client_key = websocket.key(entropy);
        self.request = try self.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .omit,
                .connection = .{ .override = "Upgrade" },
                .accept_encoding = .omit,
                .user_agent = .omit,
            },
            .extra_headers = &.{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Sec-WebSocket-Version", .value = "13" },
                .{ .name = "Sec-WebSocket-Key", .value = &client_key },
            },
        });
        const request = &self.request.?;
        try request.sendBodiless();
        const response = try request.receiveHead(&.{});
        try websocket.validateUpgrade(response.head, &client_key);
        request.extra_headers = &.{};
        const connection = request.connection.?;
        return .{
            .context = self,
            .reader = connection.reader(),
            .writer = connection.writer(),
            .flush = flush,
            .close = close,
        };
    }

    fn flush(context: *anyopaque) !void {
        const self: *Network = @ptrCast(@alignCast(context));
        try self.request.?.connection.?.flush();
    }

    fn release(self: *Network) void {
        if (self.request) |*request| {
            if (request.connection) |connection| {
                connection.closing = true;
                std.crypto.secureZero(u8, connection.writer().buffer);
                std.crypto.secureZero(u8, connection.stream_writer.interface.buffer);
            }
            request.deinit();
        }
        self.client.deinit();
    }

    fn close(context: *anyopaque) void {
        const self: *Network = @ptrCast(@alignCast(context));
        self.release();
        std.crypto.secureZero(u8, self.url);
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }
};

pub fn connectionUrlFromResponse(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConnectionResponse;
    const ok = parsed.value.object.get("ok") orelse return error.InvalidConnectionResponse;
    if (ok != .bool or !ok.bool) return error.SlackConnectionRejected;
    const url = parsed.value.object.get("url") orelse return error.InvalidConnectionResponse;
    if (url != .string) return error.InvalidConnectionResponse;
    defer std.crypto.secureZero(u8, @constCast(url.string));
    _ = try websocket.endpoint(url.string, 8192);
    return a.dupe(u8, url.string);
}

fn connectionUrl(a: std.mem.Allocator, io: std.Io, config: Config) ![]u8 {
    const settings: http.Config = .{
        .account = "slack-socket-mode",
        .origin = "https://slack.com",
        .token = config.app_token,
        .limits = .{
            .response_body_bytes_max = 16 * 1024,
            .timeout_ms = config.connect_timeout_ms,
        },
    };
    var prepared = try http.prepare(a, settings, .{
        .method = .POST,
        .url = "https://slack.com/api/apps.connections.open",
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
    });
    defer prepared.deinit();
    const outcome = http.execute(a, io, settings, &prepared);
    var capture = switch (outcome) {
        .captured => |value| value,
        .definitely_not_sent, .unknown => return error.ConnectionFailed,
    };
    defer capture.deinit();
    defer std.crypto.secureZero(u8, @constCast(capture.body));
    if (capture.status != 200 or !capture.identity_encoding) return error.ConnectionFailed;
    return connectionUrlFromResponse(a, capture.body);
}
