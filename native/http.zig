const std = @import("std");

pub const Method = enum { GET, POST };
pub const Limits = struct {
    uri_bytes_max: usize = 8192,
    request_body_bytes_max: usize = 128 * 1024,
    request_header_bytes_max: usize = 16 * 1024,
    response_body_bytes_max: usize = 2 * 1024 * 1024,
    response_header_bytes_max: usize = 32 * 1024,
    timeout_ms: u32 = 30_000,
};
pub const Config = struct {
    account: []const u8,
    origin: []const u8,
    token: []const u8,
    trust_root: ?[]const u8 = null,
    limits: Limits = .{},

    pub fn validate(self: Config) !std.Uri {
        if (self.account.len == 0 or self.token.len == 0 or self.limits.timeout_ms == 0)
            return error.InvalidConfiguration;
        inline for (@typeInfo(Limits).@"struct".field_names) |name| {
            if (@field(self.limits, name) == 0) return error.InvalidConfiguration;
        }
        try visible(self.account, false);
        try visible(self.token, false);
        if (self.token.len > self.limits.request_header_bytes_max)
            return error.RequestHeaderCapacity;
        if (self.trust_root) |root| if (root.len == 0) return error.InvalidConfiguration;
        const uri = try endpoint(self.origin, self.limits.uri_bytes_max);
        const path = component(uri.path);
        if ((path.len != 0 and !std.mem.eql(u8, path, "/")) or uri.query != null)
            return error.InvalidOrigin;
        return uri;
    }
};
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
};
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    account: []const u8,
    request: Request,
    identity: [32]u8,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Capture = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    headers: []const std.http.Header,
    identity_encoding: bool,
    body: []const u8,

    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn header(self: Capture, name: []const u8) !?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.headers) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) {
            if (found != null) return error.DuplicateResponseHeader;
            found = item.value;
        };
        return found;
    }
};
pub const Outcome = union(enum) {
    captured: Capture,
    definitely_not_sent: anyerror,
    unknown: anyerror,
};

pub fn prepare(a: std.mem.Allocator, config: Config, request: Request) !Prepared {
    _ = try validateRequest(config, request);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    const account = try scratch.dupe(u8, config.account);
    const headers = try scratch.alloc(std.http.Header, request.headers.len);
    for (headers, request.headers) |*dest, src| {
        dest.* = .{
            .name = try std.ascii.allocLowerString(scratch, src.name),
            .value = try scratch.dupe(u8, src.value),
        };
    }
    std.mem.sort(std.http.Header, headers, {}, struct {
        fn less(_: void, left: std.http.Header, right: std.http.Header) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.less);
    const owned: Request = .{
        .method = request.method,
        .url = try scratch.dupe(u8, request.url),
        .headers = headers,
        .body = try scratch.dupe(u8, request.body),
    };
    return .{
        .arena = arena,
        .account = account,
        .request = owned,
        .identity = identity(account, owned),
    };
}

fn component(value: std.Uri.Component) []const u8 {
    return switch (value) {
        .raw, .percent_encoded => |bytes| bytes,
    };
}

fn visible(bytes: []const u8, spaces: bool) !void {
    for (bytes) |byte| if (byte < 0x20 or byte >= 0x7f or (!spaces and byte == 0x20))
        return error.InvalidConfiguration;
}

fn endpoint(url: []const u8, limit: usize) !std.Uri {
    if (url.len == 0 or url.len > limit) return error.UriCapacity;
    try visible(url, false);
    if (std.mem.findScalar(u8, url, '\\') != null) return error.InvalidEndpoint;
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or
        uri.password != null or uri.fragment != null or uri.port == 0)
        return error.InvalidEndpoint;
    if (std.mem.findScalar(u8, component(uri.host.?), '%') != null)
        return error.InvalidEndpoint;
    var buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    _ = std.Io.net.HostName.fromUri(uri, &buffer) catch return error.InvalidEndpoint;
    return uri;
}

fn validateRequest(config: Config, request: Request) !std.Uri {
    const origin = try config.validate();
    const uri = try endpoint(request.url, config.limits.uri_bytes_max);
    if (!std.ascii.eqlIgnoreCase(component(origin.host.?), component(uri.host.?)) or
        (origin.port orelse 443) != (uri.port orelse 443)) return error.CrossOrigin;
    if (request.body.len > config.limits.request_body_bytes_max) return error.RequestBodyCapacity;
    if (request.method == .GET and request.body.len != 0) return error.UnexpectedRequestBody;
    try rejectCredential(request.url, config.token);
    try rejectCredential(request.body, config.token);
    var header_bytes = try std.math.add(usize, 160, request.url.len);
    header_bytes = try std.math.add(usize, header_bytes, config.token.len);
    if (header_bytes > config.limits.request_header_bytes_max)
        return error.RequestHeaderCapacity;
    for (request.headers, 0..) |header, index| {
        if (!requestHeader(header.name)) return error.UnsafeRequestHeader;
        try visible(header.value, true);
        try rejectCredential(header.value, config.token);
        header_bytes = try std.math.add(
            usize,
            header_bytes,
            try std.math.add(usize, header.name.len, 4),
        );
        header_bytes = try std.math.add(usize, header_bytes, header.value.len);
        if (header_bytes > config.limits.request_header_bytes_max)
            return error.RequestHeaderCapacity;
        for (request.headers[0..index]) |prior|
            if (std.ascii.eqlIgnoreCase(prior.name, header.name))
                return error.DuplicateRequestHeader;
    }
    return uri;
}

fn rejectCredential(bytes: []const u8, credential: []const u8) !void {
    if (credential.len == 0 or std.mem.find(u8, bytes, credential) != null)
        return error.CredentialDisclosure;
}

fn requestHeader(name: []const u8) bool {
    for ([_][]const u8{
        "accept",
        "content-type",
        "user-agent",
        "x-github-api-version",
        "if-none-match",
        "if-modified-since",
    }) |allowed|
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    return false;
}

fn responseHeader(name: []const u8) bool {
    for ([_][]const u8{
        "date",
        "retry-after",
        "x-ratelimit-limit",
        "x-ratelimit-remaining",
        "x-ratelimit-reset",
        "x-ratelimit-used",
        "x-ratelimit-resource",
        "link",
        "etag",
        "x-request-id",
        "x-github-request-id",
        "x-slack-req-id",
        "content-type",
        "content-encoding",
        "content-length",
    }) |allowed|
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    return false;
}

fn identity(account: []const u8, request: Request) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("paredros.http.request.v1\x00");
    for ([_][]const u8{ account, @tagName(request.method), request.url, request.body }) |field|
        identityField(&hash, field);
    for (request.headers) |header| {
        identityField(&hash, header.name);
        identityField(&hash, header.value);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn identityField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hash.update(&length);
    hash.update(bytes);
}

fn noBody(status: u16) bool {
    return status < 200 or status == 204 or status == 304;
}

pub fn captureResponse(
    a: std.mem.Allocator,
    head: std.http.Client.Response.Head,
    reader: *std.Io.Reader,
    limits: Limits,
    credential: []const u8,
) !Capture {
    if (head.bytes.len > limits.response_header_bytes_max) return error.ResponseHeaderCapacity;
    const status: u16 = @intCast(@backingInt(head.status));
    const bodyless = noBody(status);
    if (!bodyless) if (head.content_length) |length|
        if (length > limits.response_body_bytes_max) return error.ResponseBodyCapacity;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var headers: std.ArrayList(std.http.Header) = .empty;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!responseHeader(header.name)) continue;
        try rejectCredential(header.value, credential);
        try headers.append(scratch, .{
            .name = try std.ascii.allocLowerString(scratch, header.name),
            .value = try scratch.dupe(u8, header.value),
        });
    }
    const body = reader.allocRemaining(
        scratch,
        .limited(limits.response_body_bytes_max),
    ) catch |err|
        switch (err) {
            error.StreamTooLong => return error.ResponseBodyCapacity,
            else => return err,
        };
    try rejectCredential(body, credential);
    if (bodyless and body.len != 0) return error.UnexpectedResponseBody;
    if (!bodyless and head.transfer_encoding == .none) {
        if (head.content_length) |length| if (length != body.len) return error.TruncatedResponse;
    }
    return .{
        .arena = arena,
        .status = status,
        .headers = try headers.toOwnedSlice(scratch),
        .identity_encoding = head.content_encoding == .identity,
        .body = body,
    };
}

const Exchange = struct {
    a: std.mem.Allocator,
    io: std.Io,
    config: Config,
    prepared: *const Prepared,
    uri: std.Uri,
    sent: bool = false,
    capture: ?Capture = null,
    failure: ?anyerror = null,

    fn perform(self: *Exchange) void {
        self.capture = self.send() catch |err| {
            self.failure = err;
            return;
        };
    }

    fn send(self: *Exchange) !Capture {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var client: std.http.Client = .{
            .allocator = scratch,
            .io = self.io,
            .read_buffer_size = self.config.limits.response_header_bytes_max,
        };
        defer client.deinit();
        if (self.config.trust_root) |der| {
            const now = std.Io.Clock.real.now(self.io);
            try client.ca_bundle.bytes.appendSlice(scratch, der);
            try client.ca_bundle.parseCert(scratch, 0, now.toSeconds());
            client.now = now;
        }
        const authorization = try std.fmt.allocPrint(scratch, "Bearer {s}", .{self.config.token});
        defer std.crypto.secureZero(u8, authorization);
        var request = try client.request(switch (self.prepared.request.method) {
            .GET => .GET,
            .POST => .POST,
        }, self.uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .extra_headers = self.prepared.request.headers,
            .headers = .{
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .omit,
                .content_type = .omit,
            },
        });
        defer release(&request);
        try self.transmit(&request);
        var response = try request.receiveHead(&.{});
        const head_bytes = try scratch.dupe(u8, response.head.bytes);
        const retained_head = try std.http.Client.Response.Head.parse(head_bytes);
        const reader = if (noBody(@intCast(@backingInt(retained_head.status))))
            std.Io.Reader.ending
        else
            response.reader(&.{});
        return captureResponse(
            self.a,
            retained_head,
            reader,
            self.config.limits,
            self.config.token,
        ) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => return err,
        };
    }

    fn transmit(self: *Exchange, request: *std.http.Client.Request) !void {
        if (self.prepared.request.method == .POST)
            request.transfer_encoding = .{ .content_length = self.prepared.request.body.len };
        self.sent = true;
        if (self.prepared.request.method == .GET) {
            try request.sendBodiless();
        } else {
            var body = try request.sendBodyUnflushed(&.{});
            try body.writer.writeAll(self.prepared.request.body);
            try body.end();
            try request.connection.?.flush();
        }
    }
};

fn release(request: *std.http.Client.Request) void {
    if (request.connection) |connection| {
        connection.closing = true;
        std.crypto.secureZero(u8, connection.writer().buffer);
        std.crypto.secureZero(u8, connection.stream_writer.interface.buffer);
    }
    request.deinit();
}

fn deadline(io: std.Io, milliseconds: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(milliseconds), .awake);
}

pub fn execute(
    a: std.mem.Allocator,
    io: std.Io,
    config: Config,
    prepared: *const Prepared,
) Outcome {
    const uri = validateRequest(config, prepared.request) catch |err|
        return .{ .definitely_not_sent = err };
    if (!std.mem.eql(u8, config.account, prepared.account) or
        !std.meta.eql(prepared.identity, identity(prepared.account, prepared.request)))
        return .{ .definitely_not_sent = error.RequestChanged };
    var exchange: Exchange = .{
        .a = a,
        .io = io,
        .config = config,
        .prepared = prepared,
        .uri = uri,
    };
    const Event = union(enum) { response: void, timer: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &events);
    select.concurrent(.timer, deadline, .{ io, config.limits.timeout_ms }) catch |err|
        return .{ .definitely_not_sent = err };
    select.concurrent(.response, Exchange.perform, .{&exchange}) catch |err| {
        select.cancelDiscard();
        return .{ .definitely_not_sent = err };
    };
    const first: ?Event = select.await() catch null;
    select.cancelDiscard();
    if (exchange.capture) |capture| return .{ .captured = capture };
    const failure = if (first == null) error.Canceled else if (first.? == .timer)
        error.Timeout
    else
        exchange.failure orelse error.TransportFailure;
    return if (exchange.sent) .{ .unknown = failure } else .{ .definitely_not_sent = failure };
}
