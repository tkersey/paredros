const std = @import("std");
const builtin = @import("builtin");
const transport = @import("../native/control_socket.zig");
const c = std.c;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

const a = std.testing.allocator;

const Directory = struct {
    path: [:0]u8,
    socket: [:0]u8,

    fn init() !Directory {
        const path = try a.dupeSentinel(u8, "/tmp/paredros-control-XXXXXX", 0);
        errdefer a.free(path);
        if (mkdtemp(path) == null) return error.TemporaryDirectoryFailed;
        errdefer _ = c.rmdir(path);
        const socket = try std.fmt.allocPrintSentinel(a, "{s}/control", .{path}, 0);
        return .{ .path = path, .socket = socket };
    }

    fn deinit(self: *Directory) void {
        _ = c.unlink(self.socket);
        _ = c.rmdir(self.path);
        a.free(self.path);
        a.free(self.socket);
    }
};

fn pause() !void {
    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
}

fn send(fd: c_int, bytes: []const u8) !void {
    const flags = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
    const sent = c.send(fd, bytes.ptr, bytes.len, flags);
    if (sent < 0 or @as(usize, @intCast(sent)) != bytes.len) return error.TestSendFailed;
}

fn next(server: *transport.Server) !transport.Request {
    for (0..2000) |_| {
        if (try server.pollNext()) |request| return request;
        try pause();
    }
    return error.MissingRequest;
}

fn disconnected(server: *transport.Server, fd: c_int) !void {
    for (0..2000) |_| {
        if (try server.pollNext()) |request_value| {
            var request = request_value;
            request.deinit();
            return error.UnexpectedRequest;
        }
        var byte: u8 = undefined;
        const received = c.recv(fd, &byte, 1, 0);
        if (received == 0) return;
        if (received < 0 and std.posix.errno(received) != .AGAIN) return;
        try pause();
    }
    return error.ConnectionStillOpen;
}

const Exchange = struct {
    client: *transport.Client,
    texts: []const []const u8,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    count: usize = 0,

    fn run(self: *Exchange) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn execute(self: *Exchange) !void {
        for (self.texts) |text| {
            const response = try self.client.request(text);
            defer a.free(response);
            try std.testing.expectEqualStrings(text, response);
            self.count += 1;
        }
    }
};

fn serve(server: *transport.Server, exchanges: []const *Exchange) !usize {
    var admitted: usize = 0;
    for (0..4000) |_| {
        if (try server.pollNext()) |request_value| {
            var request = request_value;
            defer request.deinit();
            try std.testing.expectEqual(transport.currentUid(), request.uid);
            admitted += 1;
            try server.respond(request.token, request.bytes);
        }
        var complete = true;
        for (exchanges) |exchange| complete = complete and exchange.done.load(.acquire);
        if (complete) return admitted;
        try pause();
    }
    return error.ClientsDidNotFinish;
}

test "control socket serves two persistent authenticated clients without a second owner" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
        .io_bytes_per_poll = 7,
    });
    defer server.deinit();
    var first = try transport.Client.init(a, directory.socket, .{ .timeout_ms = 3000 });
    defer first.deinit();
    var second = try transport.Client.init(a, directory.socket, .{ .timeout_ms = 3000 });
    defer second.deinit();
    var one: Exchange = .{ .client = &first, .texts = &.{ "{\"first\":1}", "{\"first\":2}" } };
    var two: Exchange = .{ .client = &second, .texts = &.{ "{\"second\":1}", "{\"second\":2}" } };
    const worker_one = try std.Thread.spawn(.{}, Exchange.run, .{&one});
    defer worker_one.join();
    const worker_two = try std.Thread.spawn(.{}, Exchange.run, .{&two});
    defer worker_two.join();
    try std.testing.expectEqual(4, try serve(&server, &.{ &one, &two }));
    try std.testing.expectEqual(null, one.failure);
    try std.testing.expectEqual(null, two.failure);
    try std.testing.expectEqual(2, one.count);
    try std.testing.expectEqual(2, two.count);
}

test "control socket partial client cannot monopolize bounded round robin polling" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
        .io_bytes_per_poll = 1,
    });
    defer server.deinit();
    var slow = try transport.Client.init(a, directory.socket, .{});
    defer slow.deinit();
    var ready = try transport.Client.init(a, directory.socket, .{});
    defer ready.deinit();
    try send(slow.fd, "{");
    try send(ready.fd, "{\"ok\":1}\n");
    var found = false;
    for (0..16) |_| if (try server.pollNext()) |request_value| {
        var request = request_value;
        defer request.deinit();
        try std.testing.expectEqualStrings("{\"ok\":1}", request.bytes);
        found = true;
        break;
    };
    try std.testing.expect(found);
}

test "control socket rejects unauthorized client and server UIDs" {
    var directory = try Directory.init();
    defer directory.deinit();
    const other = try std.math.add(u32, transport.currentUid(), 1);
    var server = try transport.Server.init(a, directory.socket, .{ .operator_uid = other });
    defer server.deinit();
    try std.testing.expectError(error.PeerDenied, transport.Client.init(a, directory.socket, .{
        .expected_server_uid = other,
    }));
    var client = try transport.Client.init(a, directory.socket, .{});
    defer client.deinit();
    try send(client.fd, "{}\n");
    try disconnected(&server, client.fd);
}

test "control socket enforces mode and refuses existing files and sockets" {
    var directory = try Directory.init();
    defer directory.deinit();
    const file = c.open(
        directory.socket,
        .{ .CREAT = true, .EXCL = true, .ACCMODE = .WRONLY },
        @as(c_uint, 0o600),
    );
    if (file < 0) return error.TestFileFailed;
    std.Io.Threaded.closeFd(file);
    const config: transport.Config = .{ .operator_uid = transport.currentUid() };
    try std.testing.expectError(
        error.PathOccupied,
        transport.Server.init(a, directory.socket, config),
    );
    var status = try std.Io.Dir.cwd().statFile(std.testing.io, directory.socket, .{
        .follow_symlinks = false,
    });
    try std.testing.expectEqual(.file, status.kind);
    try std.testing.expectEqual(0, c.unlink(directory.socket));
    var server = try transport.Server.init(a, directory.socket, config);
    var active = true;
    defer if (active) server.deinit();
    status = try std.Io.Dir.cwd().statFile(std.testing.io, directory.socket, .{
        .follow_symlinks = false,
    });
    try std.testing.expectEqual(.unix_domain_socket, status.kind);
    try std.testing.expectEqual(0o600, status.permissions.toMode() & 0o777);
    try std.testing.expectError(
        error.PathOccupied,
        transport.Server.init(a, directory.socket, config),
    );
    server.deinit();
    active = false;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(
        std.testing.io,
        directory.socket,
        .{ .follow_symlinks = false },
    ));
}

fn bound(path: [:0]const u8, mode: c.mode_t, listening: bool) !c_int {
    var address: c.sockaddr.un = std.mem.zeroes(c.sockaddr.un);
    address.family = c.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.TestSocketFailed;
    errdefer std.Io.Threaded.closeFd(fd);
    if (c.bind(fd, @ptrCast(&address), @sizeOf(c.sockaddr.un)) != 0 or
        c.chmod(path, mode) != 0) return error.TestSocketFailed;
    if (listening and c.listen(fd, 1) != 0) return error.TestSocketFailed;
    return fd;
}

fn kind(path: [:0]const u8) !std.Io.File.Kind {
    const status = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{
        .follow_symlinks = false,
    });
    return status.kind;
}

test "control socket reclaims only a dead owner-only socket left by a killed daemon" {
    var directory = try Directory.init();
    defer directory.deinit();
    const config: transport.Config = .{ .operator_uid = transport.currentUid() };
    const live = try bound(directory.socket, 0o600, true);
    try std.testing.expectError(
        error.PathOccupied,
        transport.Server.init(a, directory.socket, config),
    );
    try std.testing.expectEqual(.unix_domain_socket, try kind(directory.socket));
    std.Io.Threaded.closeFd(live);
    try std.testing.expectEqual(0, c.chmod(directory.socket, 0o666));
    try std.testing.expectError(
        error.PathOccupied,
        transport.Server.init(a, directory.socket, config),
    );
    try std.testing.expectEqual(.unix_domain_socket, try kind(directory.socket));
    try std.testing.expectEqual(0, c.unlink(directory.socket));
    std.Io.Threaded.closeFd(try bound(directory.socket, 0o600, false));
    var server = try transport.Server.init(a, directory.socket, config);
    defer server.deinit();
    var client = try transport.Client.init(a, directory.socket, .{});
    defer client.deinit();
    try send(client.fd, "{}\n");
    var request = try next(&server);
    defer request.deinit();
    try std.testing.expectEqualStrings("{}", request.bytes);
}

test "control socket cleanup preserves a replacement regular file or another socket" {
    var directory = try Directory.init();
    defer directory.deinit();
    const config: transport.Config = .{ .operator_uid = transport.currentUid() };
    var first = try transport.Server.init(a, directory.socket, config);
    try std.testing.expectEqual(0, c.unlink(directory.socket));
    const file = c.open(
        directory.socket,
        .{ .CREAT = true, .EXCL = true, .ACCMODE = .WRONLY },
        @as(c_uint, 0o600),
    );
    if (file < 0) return error.TestFileFailed;
    std.Io.Threaded.closeFd(file);
    first.deinit();
    const status = try std.Io.Dir.cwd().statFile(std.testing.io, directory.socket, .{
        .follow_symlinks = false,
    });
    try std.testing.expectEqual(.file, status.kind);
    try std.testing.expectEqual(0, c.unlink(directory.socket));
    var old = try transport.Server.init(a, directory.socket, config);
    try std.testing.expectEqual(0, c.unlink(directory.socket));
    var replacement = try transport.Server.init(a, directory.socket, config);
    defer replacement.deinit();
    old.deinit();
    var client = try transport.Client.init(a, directory.socket, .{});
    defer client.deinit();
    try send(client.fd, "{}\n");
    var request = try next(&replacement);
    defer request.deinit();
    try std.testing.expectEqualStrings("{}", request.bytes);
}

test "control socket drops partial disconnects oversized frames and pipelined frames" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
        .max_frame_bytes = 8,
        .max_clients = 1,
    });
    defer server.deinit();
    var partial = try transport.Client.init(a, directory.socket, .{});
    try send(partial.fd, "{\"old\"");
    try std.testing.expectEqual(null, try server.pollNext());
    partial.deinit();
    try std.testing.expectEqual(null, try server.pollNext());
    for ([_][]const u8{ "123456789\n", "{}\n{}\n", "\n" }) |invalid| {
        var client = try transport.Client.init(a, directory.socket, .{});
        defer client.deinit();
        try send(client.fd, invalid);
        try disconnected(&server, client.fd);
    }
    var valid = try transport.Client.init(a, directory.socket, .{});
    defer valid.deinit();
    try send(valid.fd, "\"123456\"\n");
    var request = try next(&server);
    defer request.deinit();
    try std.testing.expectEqualStrings("\"123456\"", request.bytes);
}

test "control socket stale connection tokens cannot answer a reused slot" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
        .max_clients = 1,
    });
    defer server.deinit();
    var first = try transport.Client.init(a, directory.socket, .{});
    try send(first.fd, "{}\n");
    var old = try next(&server);
    defer old.deinit();
    var excess = try transport.Client.init(a, directory.socket, .{});
    defer excess.deinit();
    try send(excess.fd, "{}\n");
    try disconnected(&server, excess.fd);
    first.deinit();
    try std.testing.expectEqual(null, try server.pollNext());
    try std.testing.expectError(error.StaleConnection, server.respond(old.token, "{}"));
    var second = try transport.Client.init(a, directory.socket, .{});
    defer second.deinit();
    try send(second.fd, "{\"new\":1}\n");
    var current = try next(&server);
    defer current.deinit();
    try std.testing.expectEqual(old.token.slot, current.token.slot);
    try std.testing.expect(old.token.generation != current.token.generation);
    try std.testing.expectError(error.StaleConnection, server.respond(old.token, "{}"));
    try server.respond(current.token, "{}");
    try std.testing.expectError(error.InvalidConnectionState, server.respond(current.token, "{}"));
}

test "control socket client times out and cannot reuse an uncertain stream" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
    });
    defer server.deinit();
    var client = try transport.Client.init(a, directory.socket, .{ .timeout_ms = 20 });
    defer client.deinit();
    try std.testing.expectError(error.InvalidFrame, client.request("{}\n"));
    try std.testing.expectError(error.Timeout, client.request("{}"));
    try std.testing.expectError(error.Disconnected, client.request("{}"));
}

fn interrupt(_: c.SIG) callconv(.c) void {}

test "control socket client survives interrupted response waits" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
    });
    defer server.deinit();
    var client = try transport.Client.init(a, directory.socket, .{ .timeout_ms = 3000 });
    defer client.deinit();
    var action = std.mem.zeroes(c.Sigaction);
    action.handler.handler = interrupt;
    var previous: c.Sigaction = undefined;
    try std.testing.expectEqual(0, c.sigaction(.USR1, &action, &previous));
    defer _ = c.sigaction(.USR1, &previous, null);
    var exchange: Exchange = .{ .client = &client, .texts = &.{"{}"} };
    const worker = try std.Thread.spawn(.{}, Exchange.run, .{&exchange});
    defer worker.join();
    var request = try next(&server);
    defer request.deinit();
    for (0..8) |_| {
        try std.testing.expectEqual(0, c.pthread_kill(worker.getHandle(), .USR1));
        try pause();
    }
    try std.testing.expect(!exchange.done.load(.acquire));
    try server.respond(request.token, request.bytes);
    _ = try serve(&server, &.{&exchange});
    try std.testing.expectEqual(null, exchange.failure);
    try std.testing.expectEqual(1, exchange.count);
}

test "control socket tokens remain stale across server replacement" {
    var directory = try Directory.init();
    defer directory.deinit();
    const config: transport.Config = .{ .operator_uid = transport.currentUid(), .max_clients = 1 };
    var previous: transport.Token = undefined;
    {
        var server = try transport.Server.init(a, directory.socket, config);
        defer server.deinit();
        var client = try transport.Client.init(a, directory.socket, .{});
        defer client.deinit();
        try send(client.fd, "{}\n");
        var request = try next(&server);
        defer request.deinit();
        previous = request.token;
    }
    var current = try transport.Server.init(a, directory.socket, config);
    defer current.deinit();
    var client = try transport.Client.init(a, directory.socket, .{});
    defer client.deinit();
    try send(client.fd, "{}\n");
    var request = try next(&current);
    defer request.deinit();
    try std.testing.expectEqual(previous.slot, request.token.slot);
    try std.testing.expectEqual(previous.generation, request.token.generation);
    try std.testing.expectError(error.StaleConnection, current.respond(previous, "{}"));
    try current.respond(request.token, "{}");
}

test "control socket response bounds preserve pending state and close an oversized client stream" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(a, directory.socket, .{
        .operator_uid = transport.currentUid(),
        .max_frame_bytes = 16,
    });
    defer server.deinit();
    var client = try transport.Client.init(a, directory.socket, .{
        .timeout_ms = 3000,
        .max_frame_bytes = 8,
    });
    defer client.deinit();
    var exchange: Exchange = .{ .client = &client, .texts = &.{"{}"} };
    const worker = try std.Thread.spawn(.{}, Exchange.run, .{&exchange});
    defer worker.join();
    var request = try next(&server);
    defer request.deinit();
    try std.testing.expectError(
        error.FrameTooLarge,
        server.respond(request.token, "xxxxxxxxxxxxxxxxx"),
    );
    try server.respond(request.token, "\"123456789\"");
    _ = try serve(&server, &.{&exchange});
    try std.testing.expectEqual(error.FrameTooLarge, exchange.failure.?);
    try std.testing.expectError(error.Disconnected, client.request("{}"));
}

test "control socket enqueues a response within its write budget before the next owner operation" {
    var directory = try Directory.init();
    defer directory.deinit();
    var server = try transport.Server.init(
        a,
        directory.socket,
        .{ .operator_uid = transport.currentUid() },
    );
    defer server.deinit();
    var client = try transport.Client.init(a, directory.socket, .{});
    defer client.deinit();
    try send(client.fd, "read\n");
    var request = try next(&server);
    defer request.deinit();

    const body: [16 * 1024]u8 = @splat('x');
    try server.respond(request.token, &body);
    try std.testing.expect(try server.pollNext() == null);
    var frame: [body.len + 1]u8 = undefined;
    var length: usize = 0;
    while (length < frame.len) {
        const received = c.recv(client.fd, frame[length..].ptr, frame.len - length, 0);
        if (received <= 0) return error.IncompleteWriteBudget;
        length += @intCast(received);
    }
    try std.testing.expectEqualStrings(&body, frame[0..body.len]);
    try std.testing.expectEqual('\n', frame[body.len]);
}
