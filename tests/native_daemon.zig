const std = @import("std");
const builtin = @import("builtin");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const app = @import("../native/application.zig");
const t = @import("application_types");
const github = @import("../native/github_external.zig");
const github_contract = @import("../app/github_contract.zig");
const socket = @import("../native/control_socket.zig");
const daemon_module = @import("../native/daemon.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);
const Daemon = daemon_module.Daemon(app.Types);
const values = @import("contracts.zig");
const a = std.testing.allocator;

const Application = struct {
    pub const use_product_assets = true;
    const declaration_values = declarationsValue();
    pub const declarations: []const native.Declaration = &declaration_values;

    fn declarationsValue() [app.Application.declarations.len]native.Declaration {
        var result: [app.Application.declarations.len]native.Declaration = undefined;
        @memcpy(&result, app.Application.declarations);
        result[0].capture.?.acquire = Probe.acquire;
        return result;
    }
};
const Fixture = @import("native_fixture.zig").Fixture(app.Types, Application);

const Probe = struct {
    started: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),
    task: t.Id = @splat(0),

    fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *Probe = @ptrCast(@alignCast(ctx.environment orelse
            return error.MissingProbe));
        _ = self.calls.fetchAdd(1, .monotonic);
        _ = try std.fmt.hexToBytes(&self.task, ctx.task_id);
        self.started.store(true, .release);
        for (0..10_000) |_| {
            if (self.release.load(.acquire)) {
                var digest: t.Digest = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                return .{ .captured = try contracts.encodeOwned(github.Capture, ctx.allocator, .{
                    .local_rejection = .{ .request_digest = digest, .reason = .unavailable },
                }) };
            }
            var duration: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = std.c.nanosleep(&duration, null);
        }
        return error.ProbeDeadline;
    }
};

const Control = struct {
    target: t.Id,
    count: usize = 0,
    pause_task: ?t.Id = null,
    durable_before_ack: bool = false,

    fn call(
        context: *anyopaque,
        frame: std.mem.Allocator,
        driver: *Driver,
        uid: u32,
        bytes: []const u8,
    ) ![]const u8 {
        const self: *Control = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(socket.currentUid(), uid);
        self.count += 1;
        if (std.mem.eql(u8, bytes, "pause")) {
            self.pause_task = try driver.directive(frame, "daemon-pause", .{
                .local = .{ .uid = uid },
            }, self.target, .{ .pause = {} });
            var receipt = (try driver.service.operationLookup(frame, "daemon-pause")).?;
            defer receipt.deinit();
            try std.testing.expectEqual(self.pause_task.?, receipt.value.task);
            self.durable_before_ack = true;
            return "paused";
        }
        var index = try driver.rebuild(frame);
        defer index.deinit();
        const obligation = index.obligation(self.target).?;
        return if (obligation.ordinaryDispatch()) "active" else "fenced";
    }
};

fn now(context: *anyopaque) !i64 {
    _ = context;
    return 200;
}

fn pause() !void {
    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
}

const Setup = struct {
    fixture: Fixture = .{},
    probe: Probe = .{},
    driver: Driver = undefined,
    control: Control = undefined,
    server: ?socket.Server = null,
    daemon: ?Daemon = null,

    fn init(self: *Setup) !void {
        self.fixture.profile.environment = &self.probe;
        try self.fixture.initWithGrants(&.{github_contract.identity});
        const frame = self.fixture.arena.allocator();
        const initial = values.genesis();
        const task = try self.fixture.execute(initial.envelope.operation.bytes, .{
            .genesis = initial,
        });
        const path = try std.fmt.allocPrint(frame, "{s}-control", .{self.fixture.path});
        self.server = try socket.Server.init(a, path, .{ .operator_uid = socket.currentUid() });
        self.driver = .{ .service = &self.fixture.service.?, .clock = .{
            .context = self,
            .now = now,
        } };
        self.control = .{ .target = task };
        self.daemon = try Daemon.init(frame, &self.driver, &self.server.?, .{
            .context = &self.control,
            .call = Control.call,
        }, .{ .controls_per_poll = 1, .obligations_per_poll = 1, .stop_grace_ms = 100 });
    }

    fn deinit(self: *Setup) void {
        self.cleanup() catch |err| std.debug.panic("daemon cleanup: {s}", .{@errorName(err)});
    }

    fn cleanup(self: *Setup) !void {
        self.probe.release.store(true, .release);
        if (self.daemon) |*daemon| {
            daemon.beginStop(0);
            for (0..10_000) |_| {
                const result = try daemon.poll(self.fixture.arena.allocator(), 0);
                if (result == .stopped or result == .stopped_unclean) break;
                try pause();
            } else return error.CleanupDeadline;
            try daemon.deinit();
        }
        if (self.server) |*server| server.deinit();
        self.fixture.deinit();
    }

    fn poll(self: *Setup, time: i64) !daemon_module.Progress {
        return self.daemon.?.poll(self.fixture.arena.allocator(), time);
    }

    fn start(self: *Setup) !void {
        for (0..2000) |_| {
            _ = try self.poll(0);
            if (self.probe.started.load(.acquire)) return;
            try pause();
        }
        return error.WorkerDidNotStart;
    }
};

fn send(client: *socket.Client, bytes: []const u8) !void {
    const flags = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;
    const sent = std.c.send(client.fd, bytes.ptr, bytes.len, flags);
    if (sent < 0 or @as(usize, @intCast(sent)) != bytes.len) return error.SendFailed;
}

fn response(setup: *Setup, client: *socket.Client, expected: []const u8) !void {
    var buffer: [128]u8 = undefined;
    var length: usize = 0;
    for (0..2000) |_| {
        _ = try setup.poll(0);
        const received = std.c.recv(client.fd, buffer[length..].ptr, buffer.len - length, 0);
        if (received > 0) {
            length += @intCast(received);
            if (std.mem.indexOfScalar(u8, buffer[0..length], '\n')) |end| {
                try std.testing.expectEqualStrings(expected, buffer[0..end]);
                return;
            }
        } else if (received == 0 or std.posix.errno(received) != .AGAIN)
            return error.ResponseFailed;
        try pause();
    }
    return error.ResponseDeadline;
}

test "native daemon two socket clients admit durable pause while worker is withheld" {
    var setup: Setup = .{};
    defer setup.deinit();
    try setup.init();
    try setup.start();
    var first = try socket.Client.init(a, setup.server.?.path, .{});
    defer first.deinit();
    var second = try socket.Client.init(a, setup.server.?.path, .{});
    defer second.deinit();
    try send(&first, "pause\n");
    try response(&setup, &first, "paused");
    try send(&second, "status\n");
    try response(&setup, &second, "fenced");
    try std.testing.expect(setup.daemon.?.session.busy());
    try std.testing.expect(!setup.probe.release.load(.acquire));
    try std.testing.expect(setup.control.durable_before_ack);
    try std.testing.expectEqual(2, setup.control.count);
    try std.testing.expectEqual(1, setup.probe.calls.load(.acquire));
    try std.testing.expectError(error.Busy, setup.daemon.?.deinit());
    try std.testing.expectError(
        error.Busy,
        native.Session(app.Types).init(&setup.fixture.service.?),
    );
    try std.testing.expectError(
        error.Busy,
        native.Namespace.open(a, std.testing.io, setup.fixture.path),
    );
    var other = setup.driver;
    other.attached = false;
    try std.testing.expectError(error.Busy, Daemon.init(
        setup.fixture.arena.allocator(),
        &other,
        &setup.server.?,
        .{
            .context = &setup.control,
            .call = Control.call,
        },
        .{},
    ));
    try std.testing.expect(setup.driver.service.dispatch_gate == .selected);
}

test "native daemon clean stop captures worker and admits no queued control" {
    var setup: Setup = .{};
    defer setup.deinit();
    try setup.init();
    try setup.start();
    var client = try socket.Client.init(a, setup.server.?.path, .{});
    defer client.deinit();
    try send(&client, "pause\n");
    setup.daemon.?.beginStop(10);
    try std.testing.expectEqual(.held, setup.driver.service.dispatch_gate);
    try std.testing.expectEqual(.idle, try setup.poll(50));
    try std.testing.expectEqual(0, setup.control.count);
    setup.probe.release.store(true, .release);
    for (0..2000) |_| {
        if (try setup.poll(50) == .stopped) break;
        try pause();
    } else return error.StopDeadline;
    try std.testing.expect(!setup.daemon.?.session.busy());
    try std.testing.expectEqual(.stopped, try setup.poll(500));
    try std.testing.expectEqual(1, setup.probe.calls.load(.acquire));
    try std.testing.expectEqual(0, setup.control.count);
    try expectCaptured(&setup);
}

fn expectCaptured(setup: *Setup) !void {
    const frame = setup.fixture.arena.allocator();
    var task = try setup.driver.service.task(frame, setup.probe.task);
    defer task.deinit();
    var attempts = try setup.driver.service.attemptPage(
        frame,
        setup.probe.task,
        task.value.revision,
        null,
        16,
    );
    defer attempts.deinit();
    try std.testing.expectEqual(1, attempts.attempts.len);
    try std.testing.expect(attempts.attempts[0].capture.?.response != null);
}

test "native daemon grace expiry requests nonblocking cancellation and forbids teardown" {
    var setup: Setup = .{};
    defer setup.deinit();
    try setup.init();
    try setup.start();
    setup.daemon.?.beginStop(10);
    setup.daemon.?.beginStop(100);
    const began = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    try std.testing.expectEqual(.force_exit_required, try setup.poll(110));
    const ended = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    try std.testing.expect(ended - began < 1000);
    try std.testing.expectError(error.Busy, setup.daemon.?.deinit());
    setup.probe.release.store(true, .release);
    for (0..2000) |_| {
        if (try setup.poll(111) == .stopped_unclean) break;
        try pause();
    } else return error.StopDeadline;
    try std.testing.expectEqual(1, setup.probe.calls.load(.acquire));
}

test "native daemon idle stop stays clean after its deadline" {
    var setup: Setup = .{};
    defer setup.deinit();
    try setup.init();
    setup.daemon.?.beginStop(0);
    try std.testing.expectEqual(.stopped, try setup.poll(1000));
    try std.testing.expectEqual(0, setup.probe.calls.load(.acquire));
    try std.testing.expectEqual(0, setup.control.count);
}

test "native daemon failed gate rebuild releases its idle session reservation" {
    var setup: Setup = .{};
    defer setup.deinit();
    try setup.init();
    try setup.daemon.?.deinit();
    setup.daemon = null;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const handler: Daemon.Handler = .{ .context = &setup.control, .call = Control.call };
    try std.testing.expectError(error.OutOfMemory, Daemon.init(
        failing.allocator(),
        &setup.driver,
        &setup.server.?,
        handler,
        .{},
    ));
    try std.testing.expect(!setup.driver.attached);
    try std.testing.expectEqual(.held, setup.driver.service.dispatch_gate);
    setup.daemon = try Daemon.init(
        setup.fixture.arena.allocator(),
        &setup.driver,
        &setup.server.?,
        handler,
        .{},
    );
    try std.testing.expect(setup.driver.service.dispatch_gate == .selected);
}

test "native daemon startup installs pending pause fence before worker dispatch" {
    var setup: Setup = .{};
    defer setup.deinit();
    try setup.init();
    const frame = setup.fixture.arena.allocator();
    _ = try setup.driver.nextStep(frame, setup.control.target);
    _ = try setup.driver.directive(frame, "startup-pause", .{
        .local = .{ .uid = socket.currentUid() },
    }, setup.control.target, .{ .pause = {} });
    setup.daemon.?.beginStop(0);
    try std.testing.expectEqual(.stopped, try setup.poll(0));
    try setup.daemon.?.deinit();
    setup.daemon = null;
    try setup.fixture.close();
    try setup.fixture.open();
    setup.driver.service = &setup.fixture.service.?;
    setup.daemon = try Daemon.init(frame, &setup.driver, &setup.server.?, .{
        .context = &setup.control,
        .call = Control.call,
    }, .{});
    for (0..64) |_| _ = try setup.poll(0);
    try std.testing.expectEqual(0, setup.probe.calls.load(.acquire));
    var index = try setup.driver.rebuild(frame);
    defer index.deinit();
    try std.testing.expect(!index.obligation(setup.control.target).?.ordinaryDispatch());
}
