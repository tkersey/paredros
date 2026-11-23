const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
extern "c" fn getpeereid(c_int, *c.uid_t, *c.gid_t) c_int;
extern "c" fn getentropy(*anyopaque, usize) c_int;
extern "c" fn flock(c_int, c_int) c_int;
const Credentials = extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t };

pub const Config = struct {
    operator_uid: u32,
    max_frame_bytes: usize = 1024 * 1024,
    max_clients: u32 = 32,
    io_bytes_per_poll: usize = 64 * 1024,
    accepts_per_poll: u32 = 8,
};
pub const Token = struct { epoch: [16]u8, slot: u32, generation: u64 };
pub const Request = struct {
    allocator: std.mem.Allocator,
    token: Token,
    uid: u32,
    bytes: []u8,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
const Connection = struct {
    fd: c_int = -1,
    generation: u64 = 0,
    uid: u32 = 0,
    state: enum { reading, ready, awaiting_response, writing } = .reading,
    input: std.ArrayList(u8) = .empty,
    output: ?[]u8 = null,
    written: usize = 0,
};
const Identity = struct { device: u64, inode: u64 };
const Status = struct { identity: Identity, uid: u32, mode: u32 };
const Entry = struct { status: Status, format: u32 };
const Lock = struct { fd: c_int, path: [:0]u8, identity: Identity };

pub const Selection = struct {
    allocator: std.mem.Allocator,
    permits: *const fn (std.mem.Allocator, []const u8) bool,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    config: Config,
    fd: c_int,
    identity: Identity,
    lock: Lock,
    epoch: [16]u8,
    connections: []Connection,
    next_generation: u64 = 1,
    cursor: usize = 0,

    pub fn init(a: std.mem.Allocator, path: []const u8, config: Config) !Server {
        if (config.max_frame_bytes == 0 or config.max_frame_bytes == std.math.maxInt(usize) or
            config.max_clients == 0 or config.io_bytes_per_poll == 0 or
            config.accepts_per_poll == 0) return error.InvalidConfig;
        const address = try socketAddress(path);
        const owned_path = try a.dupeSentinel(u8, path, 0);
        errdefer a.free(owned_path);
        const lock = try acquire(a, path);
        errdefer release(a, lock);
        if (try pathStatus(owned_path)) |status| try reclaimStale(owned_path, &address, status);
        const connections = try a.alloc(Connection, config.max_clients);
        errdefer a.free(connections);
        @memset(connections, .{});
        const epoch = try randomEpoch();
        const fd = try openSocket();
        errdefer closeFd(fd);
        if (c.bind(fd, @ptrCast(&address), addressLength(path)) != 0)
            return error.BindFailed;
        const identity = (try pathIdentity(owned_path)) orelse return error.SocketDisappeared;
        errdefer removeOwned(owned_path, identity);
        if (c.chmod(owned_path, 0o600) != 0) return error.PermissionFailed;
        if (c.listen(fd, @intCast(@min(config.max_clients, 128))) != 0)
            return error.ListenFailed;
        return .{
            .allocator = a,
            .path = owned_path,
            .config = config,
            .fd = fd,
            .identity = identity,
            .lock = lock,
            .epoch = epoch,
            .connections = connections,
        };
    }

    pub fn deinit(self: *Server) void {
        closeFd(self.fd);
        for (self.connections) |*connection| self.drop(connection);
        removeOwned(self.path, self.identity);
        release(self.allocator, self.lock);
        self.allocator.free(self.connections);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn pollNext(self: *Server) !?Request {
        return self.pollSelected(null);
    }

    pub fn pollSelected(self: *Server, selection: ?Selection) !?Request {
        try self.acceptClients();
        var budget = self.config.io_bytes_per_poll;
        for (0..self.connections.len) |_| {
            const slot = self.cursor;
            self.cursor = (self.cursor + 1) % self.connections.len;
            const connection = &self.connections[slot];
            if (connection.fd < 0) continue;
            switch (connection.state) {
                .reading => if (budget > 0) try self.read(connection, &budget),
                .ready => {},
                .awaiting_response => self.checkPending(connection),
                .writing => if (budget > 0) self.write(connection, &budget),
            }
            if (connection.fd < 0 or connection.state != .ready) {
                if (budget == 0) return null;
                continue;
            }
            if (selection) |filter| {
                if (!filter.permits(filter.allocator, connection.input.items)) {
                    self.cursor = slot;
                    return null;
                }
            }
            const bytes = try connection.input.toOwnedSlice(self.allocator);
            connection.state = .awaiting_response;
            return .{
                .allocator = self.allocator,
                .token = .{
                    .epoch = self.epoch,
                    .slot = @intCast(slot),
                    .generation = connection.generation,
                },
                .uid = connection.uid,
                .bytes = bytes,
            };
        }
        return null;
    }

    pub fn respond(self: *Server, token: Token, bytes: []const u8) !void {
        const connection = try self.resolve(token);
        if (connection.state != .awaiting_response) return error.InvalidConnectionState;
        try validFrame(bytes, self.config.max_frame_bytes);
        const frame = try self.allocator.alloc(u8, bytes.len + 1);
        @memcpy(frame[0..bytes.len], bytes);
        frame[bytes.len] = '\n';
        connection.output = frame;
        connection.written = 0;
        connection.state = .writing;
    }

    fn resolve(self: *Server, token: Token) !*Connection {
        if (!std.mem.eql(u8, &token.epoch, &self.epoch) or token.slot >= self.connections.len)
            return error.StaleConnection;
        const connection = &self.connections[token.slot];
        if (connection.fd < 0 or connection.generation != token.generation)
            return error.StaleConnection;
        return connection;
    }

    fn drop(self: *Server, connection: *Connection) void {
        if (connection.fd >= 0) closeFd(connection.fd);
        connection.input.deinit(self.allocator);
        if (connection.output) |bytes| self.allocator.free(bytes);
        connection.* = .{};
    }

    fn acceptClients(self: *Server) !void {
        for (0..self.config.accepts_per_poll) |_| {
            const fd = c.accept(self.fd, null, null);
            if (fd < 0) switch (std.posix.errno(fd)) {
                .AGAIN, .INTR => return,
                .CONNABORTED => continue,
                else => return error.AcceptFailed,
            };
            configureSocket(fd) catch {
                closeFd(fd);
                continue;
            };
            const uid = peerUid(fd) catch {
                closeFd(fd);
                continue;
            };
            if (uid != self.config.operator_uid) {
                closeFd(fd);
                continue;
            }
            for (self.connections) |*connection| {
                if (connection.fd >= 0) continue;
                const next = std.math.add(u64, self.next_generation, 1) catch {
                    closeFd(fd);
                    return error.GenerationExhausted;
                };
                reserveWriteBudget(fd, self.config);
                connection.* = .{ .fd = fd, .generation = self.next_generation, .uid = uid };
                self.next_generation = next;
                break;
            } else closeFd(fd);
        }
    }

    fn read(self: *Server, connection: *Connection, budget: *usize) !void {
        var buffer: [4096]u8 = undefined;
        const remaining = self.config.max_frame_bytes + 1 - connection.input.items.len;
        const capacity = @min(buffer.len, remaining, budget.*);
        const received = c.recv(connection.fd, &buffer, capacity, 0);
        if (received <= 0) {
            if (received == 0) self.drop(connection) else switch (std.posix.errno(received)) {
                .AGAIN, .INTR => {},
                else => self.drop(connection),
            }
            return;
        }
        const bytes = buffer[0..@intCast(received)];
        budget.* -= bytes.len;
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| {
            if (end != bytes.len - 1 or connection.input.items.len + end == 0) {
                self.drop(connection);
                return;
            }
            connection.input.appendSlice(self.allocator, bytes[0..end]) catch |err| {
                self.drop(connection);
                return err;
            };
            connection.state = .ready;
        } else if (connection.input.items.len + bytes.len > self.config.max_frame_bytes) {
            self.drop(connection);
        } else connection.input.appendSlice(self.allocator, bytes) catch |err| {
            self.drop(connection);
            return err;
        };
    }

    fn write(self: *Server, connection: *Connection, budget: *usize) void {
        const output = connection.output.?;
        const bytes = output[connection.written..];
        const length = @min(bytes.len, budget.*);
        const sent = c.send(connection.fd, bytes.ptr, length, sendFlags());
        if (sent <= 0) {
            if (sent == 0) self.drop(connection) else switch (std.posix.errno(sent)) {
                .AGAIN, .INTR => {},
                else => self.drop(connection),
            }
            return;
        }
        const count: usize = @intCast(sent);
        budget.* -= count;
        connection.written += count;
        if (connection.written == output.len) {
            self.allocator.free(output);
            connection.output = null;
            connection.written = 0;
            connection.state = .reading;
        }
    }

    fn checkPending(self: *Server, connection: *Connection) void {
        var byte: u8 = undefined;
        const received = c.recv(connection.fd, &byte, 1, c.MSG.PEEK);
        if (received >= 0) self.drop(connection) else switch (std.posix.errno(received)) {
            .AGAIN, .INTR => {},
            else => self.drop(connection),
        }
    }
};

pub const ClientConfig = struct {
    timeout_ms: u32 = 30_000,
    max_frame_bytes: usize = 1024 * 1024,
    expected_server_uid: ?u32 = null,
};
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    fd: c_int,

    pub fn init(a: std.mem.Allocator, path: []const u8, config: ClientConfig) !Client {
        if (config.timeout_ms == 0 or config.max_frame_bytes == 0 or
            config.max_frame_bytes == std.math.maxInt(usize)) return error.InvalidConfig;
        const address = try socketAddress(path);
        const fd = try openSocket();
        errdefer closeFd(fd);
        const until = try deadline(config.timeout_ms);
        const connected = c.connect(fd, @ptrCast(&address), addressLength(path));
        if (connected != 0) switch (std.posix.errno(connected)) {
            .INPROGRESS, .INTR => try finishConnect(fd, until),
            else => return error.ConnectFailed,
        };
        if (try peerUid(fd) != (config.expected_server_uid orelse currentUid()))
            return error.PeerDenied;
        return .{ .allocator = a, .config = config, .fd = fd };
    }

    pub fn deinit(self: *Client) void {
        if (self.fd >= 0) closeFd(self.fd);
        self.* = undefined;
    }

    pub fn request(self: *Client, bytes: []const u8) ![]u8 {
        if (self.fd < 0) return error.Disconnected;
        try validFrame(bytes, self.config.max_frame_bytes);
        errdefer {
            closeFd(self.fd);
            self.fd = -1;
        }
        const until = try deadline(self.config.timeout_ms);
        try self.sendAll(bytes, until);
        try self.sendAll("\n", until);
        return self.receive(until);
    }

    fn sendAll(self: *Client, bytes: []const u8, until: i128) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            try waitReady(self.fd, c.POLL.OUT, until);
            const count = c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, sendFlags());
            if (count < 0) switch (std.posix.errno(count)) {
                .AGAIN, .INTR => continue,
                else => return error.Disconnected,
            };
            if (count == 0) return error.Disconnected;
            sent += @intCast(count);
        }
    }

    fn receive(self: *Client, until: i128) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        var buffer: [4096]u8 = undefined;
        while (result.items.len <= self.config.max_frame_bytes) {
            try waitReady(self.fd, c.POLL.IN, until);
            const limit = @min(buffer.len, self.config.max_frame_bytes + 1 - result.items.len);
            const received = c.recv(self.fd, &buffer, limit, 0);
            if (received < 0) switch (std.posix.errno(received)) {
                .AGAIN, .INTR => continue,
                else => return error.Disconnected,
            };
            if (received == 0) return error.Disconnected;
            const bytes = buffer[0..@intCast(received)];
            if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| {
                if (end != bytes.len - 1 or result.items.len + end == 0)
                    return error.InvalidFrame;
                try result.appendSlice(self.allocator, bytes[0..end]);
                return result.toOwnedSlice(self.allocator);
            }
            try result.appendSlice(self.allocator, bytes);
        }
        return error.FrameTooLarge;
    }
};

pub fn currentUid() u32 {
    return @intCast(c.getuid());
}

fn validFrame(bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum) return error.FrameTooLarge;
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, '\n') != null)
        return error.InvalidFrame;
}

fn socketAddress(path: []const u8) !c.sockaddr.un {
    var address: c.sockaddr.un = std.mem.zeroes(c.sockaddr.un);
    if (path.len == 0 or path.len >= address.path.len or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    address.family = c.AF.UNIX;
    if (builtin.os.tag == .macos) address.len = @intCast(addressLength(path));
    @memcpy(address.path[0..path.len], path);
    return address;
}

fn addressLength(path: []const u8) c.socklen_t {
    return @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
}

fn openSocket() !c_int {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer closeFd(fd);
    try configureSocket(fd);
    return fd;
}

fn reserveWriteBudget(fd: c_int, config: Config) void {
    const budget: c_int = @intCast(
        @min(config.io_bytes_per_poll, config.max_frame_bytes + 1, std.math.maxInt(c_int)),
    );
    var current: c_int = 0;
    var length: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &current, &length) == 0 and current < budget)
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &budget, @sizeOf(c_int));
}

fn configureSocket(fd: c_int) !void {
    const status = c.fcntl(fd, c.F.GETFL);
    if (status < 0) return error.SocketFailed;
    var flags: c.O = @bitCast(@as(u32, @bitCast(status)));
    flags.NONBLOCK = true;
    if (c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(flags))) < 0) return error.SocketFailed;
    const descriptor = c.fcntl(fd, c.F.GETFD);
    if (descriptor < 0 or c.fcntl(fd, c.F.SETFD, @as(c_int, descriptor | c.FD_CLOEXEC)) < 0)
        return error.SocketFailed;
    if (builtin.os.tag == .macos) {
        const enabled: c_int = 1;
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0)
            return error.SocketFailed;
    }
}

fn closeFd(fd: c_int) void {
    std.Io.Threaded.closeFd(fd);
}

fn sendFlags() u32 {
    return if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
}

fn peerUid(fd: c_int) !u32 {
    if (builtin.os.tag == .macos) {
        var uid: c.uid_t = undefined;
        var gid: c.gid_t = undefined;
        if (getpeereid(fd, &uid, &gid) != 0) return error.PeerUnavailable;
        return @intCast(uid);
    } else if (builtin.os.tag == .linux) {
        var credentials: Credentials = undefined;
        var size: c.socklen_t = @sizeOf(Credentials);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &credentials, &size) != 0 or
            size != @sizeOf(Credentials)) return error.PeerUnavailable;
        return @intCast(credentials.uid);
    } else @compileError("local control requires macOS or Linux");
}

fn pathIdentity(path: [:0]const u8) !?Identity {
    const status = (try pathStatus(path)) orelse return null;
    return status.identity;
}

fn pathStatus(path: [:0]const u8) !?Status {
    const found = (try entryStatus(c.AT.FDCWD, path, c.AT.SYMLINK_NOFOLLOW)) orelse return null;
    if (found.format != c.S.IFSOCK) return error.PathOccupied;
    return found.status;
}

fn descriptorStatus(fd: c_int) !Entry {
    const flags: u32 = if (builtin.os.tag == .linux) c.AT.EMPTY_PATH else 0;
    return (try entryStatus(fd, "", flags)) orelse error.PathUnavailable;
}

fn entryStatus(directory: c_int, path: [:0]const u8, flags: u32) !?Entry {
    if (builtin.os.tag == .linux) {
        var stat: std.os.linux.Statx = undefined;
        const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .INO = true };
        if (c.statx(directory, path, flags, mask, &stat) != 0) return absent();
        if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID or !stat.mask.INO)
            return error.PathUnavailable;
        return .{ .format = stat.mode & c.S.IFMT, .status = .{
            .identity = .{
                .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
                .inode = stat.ino,
            },
            .uid = stat.uid,
            .mode = stat.mode & 0o7777,
        } };
    }
    var stat: c.Stat = undefined;
    const result = if (path.len == 0)
        c.fstat(directory, &stat)
    else
        c.fstatat(directory, path, &stat, flags);
    if (result != 0) return absent();
    return .{ .format = stat.mode & c.S.IFMT, .status = .{
        .identity = .{ .device = @as(u32, @bitCast(stat.dev)), .inode = stat.ino },
        .uid = stat.uid,
        .mode = stat.mode & 0o7777,
    } };
}

fn absent() !?Entry {
    return switch (std.posix.errno(-1)) {
        .NOENT => null,
        else => error.PathUnavailable,
    };
}

fn acquire(a: std.mem.Allocator, path: []const u8) !Lock {
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}.lock", .{path}, 0);
    errdefer a.free(lock_path);
    for (0..4) |_| {
        if (try lockAt(lock_path)) |held| return .{
            .fd = held.fd,
            .path = lock_path,
            .identity = held.identity,
        };
    }
    return error.PathOccupied;
}

fn lockAt(path: [:0]const u8) !?struct { fd: c_int, identity: Identity } {
    const flags: c.O = .{ .ACCMODE = .RDONLY, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true };
    const fd = c.open(path, flags, @as(c_uint, 0o600));
    if (fd < 0) return switch (std.posix.errno(fd)) {
        .LOOP => error.PathOccupied,
        else => error.PathUnavailable,
    };
    errdefer closeFd(fd);
    const held = try descriptorStatus(fd);
    if (held.format != c.S.IFREG or held.status.uid != currentUid()) return error.PathOccupied;
    if (flock(fd, c.LOCK.EX | c.LOCK.NB) != 0) return switch (std.posix.errno(-1)) {
        .AGAIN => error.PathOccupied,
        else => error.PathUnavailable,
    };
    const current = try entryStatus(c.AT.FDCWD, path, c.AT.SYMLINK_NOFOLLOW);
    if (current) |found| if (std.meta.eql(found.status.identity, held.status.identity))
        return .{ .fd = fd, .identity = held.status.identity };
    closeFd(fd);
    return null;
}

fn release(a: std.mem.Allocator, lock: Lock) void {
    const current = entryStatus(c.AT.FDCWD, lock.path, c.AT.SYMLINK_NOFOLLOW) catch null;
    if (current) |found| {
        if (std.meta.eql(found.status.identity, lock.identity)) _ = c.unlink(lock.path);
    }
    closeFd(lock.fd);
    a.free(lock.path);
}

fn reclaimStale(path: [:0]const u8, address: *const c.sockaddr.un, stale: Status) !void {
    if (stale.uid != currentUid()) return error.PathOccupied;
    if (!try refused(address, path)) return error.PathOccupied;
    const current = (try pathStatus(path)) orelse return;
    if (!std.meta.eql(current, stale)) return error.PathOccupied;
    if (c.unlink(path) != 0 and std.posix.errno(-1) != .NOENT) return error.PathUnavailable;
}

fn refused(address: *const c.sockaddr.un, path: []const u8) !bool {
    const fd = try openSocket();
    defer closeFd(fd);
    const connected = c.connect(fd, @ptrCast(address), addressLength(path));
    return connected != 0 and std.posix.errno(connected) == .CONNREFUSED;
}

fn removeOwned(path: [:0]const u8, identity: Identity) void {
    const current = (pathIdentity(path) catch return) orelse return;
    if (std.meta.eql(current, identity)) _ = c.unlink(path);
}

fn randomEpoch() ![16]u8 {
    var epoch: [16]u8 = undefined;
    for (0..8) |_| {
        if (getentropy(&epoch, epoch.len) == 0) return epoch;
        if (std.posix.errno(-1) != .INTR) return error.EntropyUnavailable;
    }
    return error.EntropyUnavailable;
}

fn milliseconds() !i128 {
    var time: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &time) != 0) return error.ClockUnavailable;
    return @as(i128, time.sec) * 1000 + @divTrunc(@as(i128, time.nsec), 1_000_000);
}

fn deadline(timeout_ms: u32) !i128 {
    return try milliseconds() + timeout_ms;
}

fn waitReady(fd: c_int, events: c_short, until: i128) !void {
    var selected: c.pollfd = .{ .fd = fd, .events = events, .revents = 0 };
    var remaining = until - try milliseconds();
    while (remaining > 0) : (remaining = until - try milliseconds()) {
        const timeout: c_int = @intCast(@min(remaining, std.math.maxInt(c_int)));
        const ready = c.poll(@ptrCast(&selected), 1, timeout);
        if (ready < 0) switch (std.posix.errno(ready)) {
            .INTR => continue,
            else => return error.Disconnected,
        };
        if (ready == 0) continue;
        if (selected.revents & c.POLL.NVAL != 0) return error.Disconnected;
        return;
    }
    return error.Timeout;
}

fn finishConnect(fd: c_int, until: i128) !void {
    try waitReady(fd, c.POLL.OUT, until);
    var failure: c_int = undefined;
    var size: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &failure, &size) != 0 or
        size != @sizeOf(c_int) or failure != 0) return error.ConnectFailed;
}
