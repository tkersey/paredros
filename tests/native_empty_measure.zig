const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const github = @import("../native/github_external.zig");
const contract = @import("../app/github_contract.zig");
const Driver = @import("../native/driver.zig").Driver(t);
const Daemon = @import("../native/daemon.zig").Daemon(t);
const socket = @import("../native/control_socket.zig");
const index_module = @import("../native/index.zig");
const examples = @import("contracts.zig");
const Application = struct {
    pub const use_product_assets = true;
    const values = declarationsValue();
    pub const declarations: []const native.Declaration = &values;

    fn declarationsValue() [app.Application.declarations.len]native.Declaration {
        var result: [app.Application.declarations.len]native.Declaration = undefined;
        @memcpy(&result, app.Application.declarations);
        result[0].capture.?.acquire = acquire;
        return result;
    }
};
const Fixture = @import("native_fixture.zig").Fixture(t, Application);
var clock_ms: i64 = 100;

fn clock(_: *anyopaque) !i64 {
    return clock_ms;
}

fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    var request = try c.decodeOwned(contract.Request, ctx.allocator, bytes);
    defer request.deinit();
    var prepared = try @import("../native/github_adapter.zig").prepare(
        ctx.allocator,
        request.value,
    );
    defer prepared.deinit();
    const body = switch (request.value.phase) {
        .repository_before, .repository_after => "{\"id\":123}",
        .reference => "{\"ref\":\"refs/heads/main\",\"object\":{\"type\":\"commit\",\"sha\":\"" ++
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}",
        .page => return error.UnexpectedComparison,
    };
    var capture: @import("../native/http.zig").Capture = .{
        .arena = .init(ctx.allocator),
        .status = 200,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .identity_encoding = true,
        .body = body,
    };
    defer capture.deinit();
    return .{ .captured = try github.captureBytes(ctx.allocator, prepared, capture, clock_ms) };
}

fn drive(f: *Fixture, session: *native.Session(t), a: std.mem.Allocator, task: t.Id) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() + 90_000;
    while (std.Io.Clock.awake.now(std.testing.io).toMilliseconds() < deadline) {
        _ = try session.tick(a);
        var state = try f.service.?.task(a, task);
        defer state.deinit();
        if (state.value.terminal()) {
            if (state.value.outcome_kind != .completed) return error.EmptyCheckFailed;
            return;
        }
        if (session.busy()) try std.testing.io.sleep(.fromMicroseconds(100), .awake);
    }
    return error.EmptyCheckTimedOut;
}

fn storageBytes(a: std.mem.Allocator, path: []const u8) !u64 {
    const name = try std.fmt.allocPrint(a, "{s}/state.sqlite", .{path});
    defer a.free(name);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    return (try file.stat(std.testing.io)).size;
}

fn sample(f: *Fixture, driver: *Driver, session: *native.Session(t), target: t.Id, n: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try storageBytes(a, f.path);
    const started = std.Io.Clock.awake.now(std.testing.io);
    const task = (try driver.nextStep(a, target)) orelse return error.EmptyCheckNotDue;
    try drive(f, session, a, task);
    const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - started.nanoseconds;
    var index = try driver.rebuild(a);
    defer index.deinit();
    const head = index.head(index.obligation(target).?);
    try std.testing.expectEqual(@as(?t.Oid, @splat('a')), head.observed.tip);
    try std.testing.expectEqual(0, head.observed.sequence);
    try std.testing.expectEqual(0, head.last_observation.?.commit_count);
    try std.testing.expectEqual(0, head.check_failure_streak);
    clock_ms = head.schedule.next_due_ms;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(std.testing.io, &buffer);
    try std.json.Stringify.value(.{
        .empty_check = n,
        .baseline = n == 0,
        .owner_nanoseconds = elapsed,
        .database_growth_bytes = (try storageBytes(a, f.path)) - before,
    }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn environment(name: []const u8, default: u32) !u32 {
    const value = std.testing.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(u32, value, 10);
}

fn openAt(f: *Fixture, path: []const u8) !void {
    try f.initWithGrants(&.{contract.identity});
    try f.close();
    f.temporary.?.cleanup();
    f.temporary = null;
    f.path = path;
    try f.open();
}

pub fn run(path: []const u8) !void {
    index_module.verify_against_rebuild = false;
    const phase = std.testing.environ.getPosix("PAREDROS_EMPTY_PHASE") orelse "";
    if (std.mem.eql(u8, phase, "seed")) return seedPhase(path);
    if (std.mem.eql(u8, phase, "daemon")) return daemonPhase(path);
    if (phase.len != 0) return error.InvalidArguments;
    var f: Fixture = .{};
    defer f.deinit();
    try openAt(&f, path);
    const initial = examples.genesis();
    const target = try f.execute(initial.envelope.operation.bytes, .{ .genesis = initial });
    var context: u8 = 0;
    var driver: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = &context, .now = clock },
    };
    try driver.attach(f.arena.allocator());
    defer driver.detach();
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("measurement session busy");
    const samples = try environment("PAREDROS_EMPTY_SAMPLES", 31);
    if (samples == 0 or samples > 31) return error.InvalidArguments;
    for (0..samples) |n| try sample(&f, &driver, &session, target, @intCast(n));
}

fn executePure(service: *native.tasks.Service(t), input: t.Input) !t.Id {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const operation = switch (input) {
        inline else => |value| value.envelope.operation.bytes,
    };
    const id = (try service.submit(a, operation, input)).receipt.task;
    for (0..65536) |_| {
        var saved = try service.task(a, id);
        defer saved.deinit();
        if (saved.value.terminal()) {
            if (saved.value.outcome_kind != .completed) return error.HistoryTaskFailed;
            return id;
        }
        switch (try service.pump(a)) {
            .work => |work| {
                try service.notSent(a, work);
                return error.UnexpectedExternalWork;
            },
            else => {},
        }
    }
    return error.HistoryTaskIncomplete;
}

fn historyDirective(
    service: *native.tasks.Service(t),
    target: t.Id,
    ordinal: u64,
    prior: ?t.InputReference,
    body: t.DirectiveBody,
) !t.InputReference {
    var buffer: [64]u8 = undefined;
    const operation = try std.fmt.bufPrint(&buffer, "history-directive:{d}", .{ordinal});
    const input: t.Input = .{ .directive = .{
        .envelope = .{
            .operation = .{ .bytes = operation },
            .stable_request = index_module.digest(operation),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .obligation = target,
        .ordinal = ordinal,
        .predecessor = prior,
        .body = body,
    } };
    const id = try executePure(service, input);
    const bytes = try c.encodeOwned(t.Input, std.testing.allocator, input);
    defer std.testing.allocator.free(bytes);
    return .{ .task = id, .digest = index_module.digest(bytes) };
}

fn seedHistory(f: *Fixture, tasks: u32) !void {
    if (tasks < 4) return error.InvalidArguments;
    var genesis = examples.genesis();
    genesis.envelope.operation = .{ .bytes = "history-genesis" };
    genesis.envelope.stable_request = @splat(9);
    genesis.lineage = @splat(10);
    const service = &f.service.?;
    const target = try executePure(service, .{ .genesis = genesis });
    var prior = try historyDirective(service, target, 1, null, .{ .cancel = {} });
    var context: u8 = 0;
    var driver: Driver = .{ .service = service, .clock = .{ .context = &context, .now = clock } };
    try driver.attach(f.arena.allocator());
    {
        defer driver.detach();
        var session = try native.Session(t).init(service);
        defer session.deinit() catch @panic("history session busy");
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const fold = (try driver.nextStep(arena.allocator(), target)) orelse
            return error.HistoryFoldNotDue;
        try drive(f, &session, arena.allocator(), fold);
    }
    for (2..tasks - 1) |ordinal| {
        prior = try historyDirective(service, target, ordinal, prior, .{ .pause = {} });
    }
}

fn seedPhase(path: []const u8) !void {
    var f: Fixture = .{};
    defer f.deinit();
    try openAt(&f, path);
    const history = try environment("PAREDROS_EMPTY_HISTORY", 0);
    if (history != 0) try seedHistory(&f, history);
    const initial = examples.genesis();
    _ = try executePure(&f.service.?, .{ .genesis = initial });
}

const Idle = struct {
    fn call(_: *anyopaque, _: std.mem.Allocator, _: *Driver, _: u32, _: []const u8) ![]const u8 {
        return error.UnexpectedControl;
    }
};

fn nanoseconds() i96 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}

fn stepTerminal(f: *Fixture, a: std.mem.Allocator, target: t.Id, sequence: u64) !bool {
    var buffer: [96]u8 = undefined;
    const operation = try std.fmt.bufPrint(&buffer, "step:{s}:{d}:0", .{
        std.fmt.bytesToHex(target, .lower), sequence,
    });
    var receipt = (try f.service.?.operationLookup(a, operation)) orelse return false;
    defer receipt.deinit();
    var state = try f.service.?.task(a, receipt.value.task);
    defer state.deinit();
    if (!state.value.terminal()) return false;
    if (state.value.outcome_kind != .completed) return error.EmptyCheckFailed;
    return true;
}

const Measured = struct { owner: i96 = 0, wall: i96 = 0, polls: u32 = 0 };

fn daemonCheck(f: *Fixture, daemon: *Daemon, target: t.Id, sequence: u64) !Measured {
    var measured: Measured = .{};
    const started = nanoseconds();
    while (measured.polls < 1_000_000) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const before = nanoseconds();
        const progress = try daemon.poll(arena.allocator(), 0);
        measured.owner += nanoseconds() - before;
        measured.polls += 1;
        if (try stepTerminal(f, arena.allocator(), target, sequence)) {
            measured.wall = nanoseconds() - started;
            return measured;
        }
        if (progress == .idle) try std.testing.io.sleep(.fromMicroseconds(100), .awake);
    }
    return error.EmptyCheckTimedOut;
}

fn currentHead(driver: *Driver, target: t.Id, checked: bool) !t.Head {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = try driver.rebuild(arena.allocator());
    defer index.deinit();
    const head = index.head(index.obligation(target).?);
    if (!checked) return head;
    try std.testing.expectEqual(@as(?t.Oid, @splat('a')), head.observed.tip);
    try std.testing.expectEqual(0, head.observed.sequence);
    try std.testing.expectEqual(0, head.check_failure_streak);
    return head;
}

fn daemonPhase(path: []const u8) !void {
    var f: Fixture = .{};
    defer f.deinit();
    try openAt(&f, path);
    const target = blk: {
        var receipt = (try f.service.?.operationLookup(
            f.arena.allocator(),
            examples.genesis().envelope.operation.bytes,
        )) orelse return error.MissingMonitor;
        defer receipt.deinit();
        break :blk receipt.value.task;
    };
    var name: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&name, "/tmp/paredros-measure-{d}.sock", .{
        std.c.getpid(),
    });
    var server = try socket.Server.init(std.testing.allocator, socket_path, .{
        .operator_uid = socket.currentUid(),
    });
    defer server.deinit();
    var context: u8 = 0;
    var driver: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = &context, .now = clock },
    };
    const attach_started = nanoseconds();
    var daemon = try Daemon.init(f.arena.allocator(), &driver, &server, .{
        .context = &context,
        .call = Idle.call,
    }, .{});
    try emit(.{ .daemon_attach_nanoseconds = nanoseconds() - attach_started });
    defer stopDaemon(&daemon);
    try daemonSamples(&f, &driver, &daemon, target);
}

fn stopDaemon(daemon: *Daemon) void {
    daemon.beginStop(0);
    for (0..100_000) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const progress = daemon.poll(arena.allocator(), 0) catch @panic("measurement stop");
        if (progress == .stopped) break;
    } else @panic("measurement stop deadline");
    daemon.deinit() catch @panic("measurement daemon busy");
}

fn daemonSamples(f: *Fixture, driver: *Driver, daemon: *Daemon, target: t.Id) !void {
    const samples = try environment("PAREDROS_EMPTY_SAMPLES", 31);
    const idle_polls = try environment("PAREDROS_EMPTY_IDLE_POLLS", 24);
    if (samples == 0 or samples > 31) return error.InvalidArguments;
    var head = try currentHead(driver, target, false);
    for (0..samples) |n| {
        clock_ms = head.schedule.next_due_ms;
        const before = try storageBytes(f.arena.allocator(), f.path);
        const counters = driver.index.?.counters;
        const measured = try daemonCheck(f, daemon, target, head.sequence + 1);
        const after = driver.index.?.counters;
        head = try currentHead(driver, target, true);
        try emit(.{
            .empty_check = n,
            .baseline = n == 0,
            .owner_nanoseconds = measured.owner,
            .wall_nanoseconds = measured.wall,
            .polls = measured.polls,
            .probes = after.probes - counters.probes,
            .loads = after.loads - counters.loads,
            .derivations = after.derivations - counters.derivations,
            .database_growth_bytes = (try storageBytes(f.arena.allocator(), f.path)) - before,
        });
    }
    for (0..idle_polls) |n| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const counters = driver.index.?.counters;
        const before = nanoseconds();
        _ = try daemon.poll(arena.allocator(), 0);
        const elapsed = nanoseconds() - before;
        const after = driver.index.?.counters;
        try emit(.{
            .idle_poll = n,
            .owner_nanoseconds = elapsed,
            .probes = after.probes - counters.probes,
            .loads = after.loads - counters.loads,
            .derivations = after.derivations - counters.derivations,
            .records = driver.index.?.current.records.len,
        });
    }
}

fn emit(value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(std.testing.io, &buffer);
    try std.json.Stringify.value(value, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
