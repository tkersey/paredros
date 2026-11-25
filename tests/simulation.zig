const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const options = @import("simulation_options");
const app = @import("../native/application.zig");
const cli = @import("../native/cli.zig");
const control = @import("../native/control.zig");
const wire = @import("../native/wire.zig");
const socket = @import("../native/control_socket.zig");
const configuration = @import("../native/configuration.zig");
const continuity_control = @import("../native/continuity_control.zig");
const idx = @import("../native/index.zig");
const model_external = @import("../native/model_external.zig");
const mc = @import("../app/model_contract.zig");
const github = @import("../app/github_contract.zig");
const daemon_module = @import("../native/daemon.zig");
const world_module = @import("simulation_world.zig");
const oracle = @import("simulation_oracle.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);
const Daemon = daemon_module.Daemon(app.Types);
const Fixture = @import("native_fixture.zig").Fixture(app.Types, world_module.Application);
const World = world_module.World;
const Check = oracle.Check;
const gpa = std.testing.allocator;
const uid: u32 = 501;
const config_path = "/simulation/config.json";
const interval_max: u64 = 31_622_400_000;

const Entropy = struct {
    var prng: std.Random.DefaultPrng = .init(0);
    var lock: std.atomic.Value(bool) = .init(false);
    var vtable: std.Io.VTable = undefined;

    fn io(seed: u64) std.Io {
        prng = .init(seed);
        vtable = std.testing.io.vtable.*;
        vtable.random = random;
        vtable.randomSecure = randomSecure;
        return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    }

    fn fill(buffer: []u8) void {
        while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
        prng.random().bytes(buffer);
        lock.store(false, .release);
    }

    fn random(_: ?*anyopaque, buffer: []u8) void {
        fill(buffer);
    }

    fn randomSecure(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
        fill(buffer);
    }
};

fn digestOf(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn modelBinding(fixture: *Fixture) !mc.Binding {
    const allocator = fixture.arena.allocator();
    fixture.profile.authority.inference = true;
    const catalog = try model_external.emptyCatalog(allocator);
    const policy: mc.P.AdaptivePolicy = .{
        .schema = .{ .bytes = mc.P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://simulation.test/v1/responses" },
        .audience = .{ .bytes = "simulation" },
        .profiles = .{ .items = &.{.{
            .id = .{ .bytes = "selected" },
            .model = .{ .bytes = "simulation-model" },
            .reasoning_mode = .standard,
            .reasoning_context = .current_turn,
            .efforts = .{ .items = &.{.medium} },
            .effort_update = false,
            .explicit_cache = false,
            .additional_tools = false,
            .cache_diagnostics = false,
            .opaque_family = .{ .bytes = "simulation" },
            .max_output_tokens = 4096,
            .request_bytes = 1024 * 1024,
            .response_bytes = 2 * 1024 * 1024,
            .timeout_ms = 1000,
        }} },
        .catalog = .{ .digest = digestOf(catalog), .bytes = catalog.len },
        .core_tools = .{ true, true },
        .permitted_tools = .{ true, true },
    };
    var config = native.json.object();
    const adaptive = try native.values.toJson(mc.P.AdaptivePolicy, allocator, policy);
    try native.json.put(allocator, &config, "adaptive", adaptive);
    const responses = try native.values.toJson(c.ResponsesContract, allocator, .{
        .route = .api_key_json,
        .binding = null,
    });
    try native.json.put(allocator, &config, "responses", responses);
    fixture.profile.bytes = try native.json.canonical(allocator, config);
    fixture.profile.resources = try allocator.dupe([]const u8, &.{catalog});
    const profile = fixture.profile.bytes;
    const binding = try model_external.binding(allocator, profile, "selected", .medium);
    return binding.value;
}

const Kind = enum { monitor_add, directive, ask, confirm, transfer, other };

const Entry = struct {
    bytes: []const u8,
    kind: Kind,
    task: ?t.Id = null,
    lineage: ?t.Digest = null,
};

const Expectation = struct {
    lineage: t.Digest,
    head: ?t.Head,
    mode: t.Mode,
    pending: []const t.DirectiveBody,
    verified: bool = false,
};

const ExportState = struct {
    operation: []const u8,
    args: []const []const u8,
    snapshot: bool,
    expected: ?[]Expectation,
};

const Node = struct {
    label: u8,
    fixture: Fixture = .{},
    driver: Driver = undefined,
    server: ?socket.Server = null,
    daemon: ?Daemon = null,
    backup: std.testing.TmpDir = undefined,
    backup_path: []const u8 = "",
    socket_path: []const u8 = "",
    config: configuration.Config = undefined,
    environment: continuity_control.Environment = undefined,
    ledger: std.StringHashMapUnmanaged(Entry) = .empty,
    operations: std.ArrayList([]const u8) = .empty,
    turns: std.ArrayList(t.Id) = .empty,
    confirmed: std.ArrayList([]const u8) = .empty,
    listed: std.AutoHashMapUnmanaged(struct { t.Id, u64 }, t.Digest) = .empty,
    expectations: std.ArrayList(Expectation) = .empty,
    import_args: ?[]const []const u8 = null,
};

const Event = struct { kind: []const u8, detail: []const u8 };

const Sample = struct { wall_ns: i128, cpu_us: i64 };
const Bucket = struct { count: u64 = 0, wall_ns: i128 = 0, cpu_us: i64 = 0 };

fn sample() Sample {
    const usage = std.posix.getrusage(0);
    const cpu = (usage.utime.sec + usage.stime.sec) * 1_000_000 +
        usage.utime.usec + usage.stime.usec;
    return .{
        .wall_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds,
        .cpu_us = @intCast(cpu),
    };
}

const Profile = struct {
    enabled: bool = false,
    buckets: std.StringArrayHashMapUnmanaged(Bucket) = .empty,
    completed: std.AutoHashMapUnmanaged(t.Id, void) = .empty,
    waiting_ns: i128 = 0,

    fn charge(self: *Profile, a: std.mem.Allocator, kind: []const u8, from: Sample) !void {
        if (!self.enabled) return;
        const to = sample();
        const entry = try self.buckets.getOrPut(a, kind);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.count += 1;
        entry.value_ptr.wall_ns += to.wall_ns - from.wall_ns;
        entry.value_ptr.cpu_us += to.cpu_us - from.cpu_us;
    }
};

pub const Report = struct {
    seed: u64,
    events: usize,
    hash: t.Digest,
    calls: world_module.Calls,
    hops: u32,
    injected: u64,
    violation: ?oracle.Violation,
    at: usize,
};

const Sim = struct {
    arena: std.heap.ArenaAllocator,
    seed: u64,
    prng: std.Random.DefaultPrng,
    io: std.Io,
    wall_ms: i64 = 1_800_000_000_000,
    mono_ms: i64 = 0,
    world: World = undefined,
    nodes: std.ArrayList(*Node) = .empty,
    runtime: u8 = 0,
    operation: u64 = 0,
    events: std.ArrayList(Event) = .empty,
    violation: ?oracle.Violation = null,
    pending_export: ?ExportState = null,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    profile: Profile = .{},
    faults: std.Random.DefaultPrng = .init(0),
    injected_faults: u64 = 0,
    records: usize = 0,

    fn now(context: *anyopaque) !i64 {
        const self: *Sim = @ptrCast(@alignCast(context));
        return self.wall_ms;
    }

    fn injected(context: *anyopaque, _: @import("../native/driver.zig").Key) bool {
        const self: *Sim = @ptrCast(@alignCast(context));
        if (self.world.calm) return false;
        if (self.faults.random().uintLessThan(u8, 100) >= 4) return false;
        self.injected_faults += 1;
        return true;
    }

    fn allocator(self: *Sim) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn random(self: *Sim) std.Random {
        return self.prng.random();
    }

    fn below(self: *Sim, limit: usize) usize {
        return self.random().uintLessThan(usize, limit);
    }

    fn chance(self: *Sim, percent: u8) bool {
        return self.random().uintLessThan(u8, 100) < percent;
    }

    fn node(self: *Sim) *Node {
        return self.nodes.items[self.nodes.items.len - 1];
    }

    fn nextOperation(self: *Sim, prefix: []const u8) ![]const u8 {
        self.operation += 1;
        return std.fmt.allocPrint(self.allocator(), "{s}-{d}", .{ prefix, self.operation });
    }

    fn note(self: *Sim, kind: []const u8, comptime format: []const u8, args: anytype) !void {
        const detail = try std.fmt.allocPrint(self.allocator(), format, args);
        try self.events.append(self.allocator(), .{ .kind = kind, .detail = detail });
        self.hasher.update(kind);
        self.hasher.update(detail);
    }

    fn fail(
        self: *Sim,
        comptime invariant: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) error{ Violation, OutOfMemory } {
        self.violation = .{
            .invariant = invariant,
            .detail = try std.fmt.allocPrint(self.allocator(), format, args),
        };
        return error.Violation;
    }

    fn check(self: *Sim, a: std.mem.Allocator, index: *const idx.Index) Check {
        return .{ .a = a, .index = index, .violation = &self.violation };
    }
};

fn short(digest: t.Digest) [8]u8 {
    return std.fmt.bytesToHex(digest[0..4].*, .lower);
}

fn optionalHex(id: ?t.Id) [32]u8 {
    return if (id) |value| oracle.hex(value) else @splat('-');
}

fn runtimeDigest(variant: u8) t.Digest {
    return @splat(0x40 +% variant);
}

fn openNode(sim: *Sim, label: u8) !*Node {
    const value = try sim.allocator().create(Node);
    value.* = .{ .label = label };
    errdefer sim.allocator().destroy(value);
    const fixture = &value.fixture;
    fixture.io = sim.io;
    fixture.profile.environment = &sim.world;
    fixture.profile.runtime_identity = runtimeDigest(sim.runtime);
    const binding = try modelBinding(fixture);
    try fixture.initWithGrants(&.{ github.identity, mc.P.identity });
    value.backup = std.testing.tmpDir(.{});
    try value.backup.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var buffer: [4096]u8 = undefined;
    const length = try value.backup.dir.realPath(std.testing.io, &buffer);
    value.backup_path = try sim.allocator().dupe(u8, buffer[0..length]);
    value.socket_path = try std.fs.path.join(sim.allocator(), &.{
        std.testing.TmpDir.parent_dir_path, &fixture.temporary.?.sub_path, "control",
    });
    value.config = .{
        .version = 1,
        .current_uid = uid,
        .namespace_path = fixture.path,
        .control_socket_path = "/simulation/control.sock",
        .backup_directory = value.backup_path,
        .repository = .{
            .account = "github-test",
            .id = world_module.repository_id,
            .owner = "owner",
            .name = "test",
            .ref = "refs/heads/main",
        },
        .interval_ms = 900_000,
    };
    value.driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = sim, .now = Sim.now },
        .model = binding,
        .bindings = configuration.bindings(value.config),
    };
    value.driver.injection = .{ .context = sim, .fails = Sim.injected };
    try sim.nodes.append(sim.allocator(), value);
    try startDaemon(sim, value);
    return value;
}

fn noControl(_: *anyopaque, _: std.mem.Allocator, _: *Driver, _: u32, _: []const u8) ![]const u8 {
    return error.UnexpectedSocketControl;
}

fn startDaemon(sim: *Sim, value: *Node) !void {
    const fixture = &value.fixture;
    value.environment = try continuity_control.sourceEnvironment(
        std.testing.io,
        fixture.namespace.?.identity,
        &fixture.application.?,
        fixture.assets.image,
        fixture.profile.runtime_identity,
    );
    value.driver.service = &fixture.service.?;
    value.server = try socket.Server.init(gpa, value.socket_path, .{
        .operator_uid = socket.currentUid(),
    });
    value.daemon = try Daemon.init(gpa, &value.driver, &value.server.?, .{
        .context = value,
        .call = noControl,
    }, .{ .controls_per_poll = 8, .obligations_per_poll = 8, .stop_grace_ms = 1_000 });
    _ = sim;
}

fn settleWorker(value: *Node) !void {
    const slot = value.daemon.?.session.slot;
    const begun = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    defer waited_ns += std.Io.Clock.awake.now(std.testing.io).nanoseconds - begun;
    for (0..4_000_000) |_| {
        if (slot.future == null or slot.finished()) return;
        var pause: std.c.timespec = .{ .sec = 0, .nsec = 20_000 };
        _ = std.c.nanosleep(&pause, null);
    }
    return error.WorkerDidNotFinish;
}

var waited_ns: i128 = 0;

fn poll(sim: *Sim, value: *Node) !daemon_module.Progress {
    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();
    sim.mono_ms += 1;
    const from = sample();
    const progress = try value.daemon.?.poll(frame.allocator(), sim.mono_ms);
    try settleWorker(value);
    if (sim.profile.enabled) try chargePoll(sim, value, from);
    return progress;
}

fn chargePoll(sim: *Sim, value: *Node, from: Sample) !void {
    const to = sample();
    var index = try rebuild(sim, value);
    defer index.deinit();
    var kind: []const u8 = "poll:scheduling";
    for (index.records) |record| {
        if (record.result == null) continue;
        const entry = try sim.profile.completed.getOrPut(sim.allocator(), record.task);
        if (entry.found_existing) continue;
        kind = switch (record.result.?) {
            .step => |step| switch (step.head.phase) {
                .check => "poll:step-check",
                .render => "poll:step-render",
                .fold => "poll:step-fold",
            },
            else => |tag| try std.fmt.allocPrint(sim.allocator(), "poll:{s}", .{@tagName(tag)}),
        };
    }
    const entry = try sim.profile.buckets.getOrPut(sim.allocator(), kind);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    entry.value_ptr.count += 1;
    entry.value_ptr.wall_ns += to.wall_ns - from.wall_ns;
    entry.value_ptr.cpu_us += to.cpu_us - from.cpu_us;
    std.debug.print("poll {s} records {d} wall_us {d} cpu_us {d}\n", .{
        kind,
        index.records.len,
        @divTrunc(to.wall_ns - from.wall_ns, std.time.ns_per_us),
        to.cpu_us - from.cpu_us,
    });
}

fn stopDaemon(sim: *Sim, value: *Node, mid_dispatch: bool) !void {
    if (mid_dispatch) {
        for (0..16) |_| {
            var frame = std.heap.ArenaAllocator.init(gpa);
            defer frame.deinit();
            sim.mono_ms += 1;
            _ = try value.daemon.?.poll(frame.allocator(), sim.mono_ms);
            if (value.daemon.?.session.busy()) break;
            try settleWorker(value);
        }
    }
    value.daemon.?.beginStop(sim.mono_ms);
    for (0..10_000) |_| {
        try settleWorker(value);
        const progress = try poll(sim, value);
        if (progress == .stopped or progress == .stopped_unclean) break;
    } else return error.DaemonDidNotStop;
    try value.daemon.?.deinit();
    value.daemon = null;
    value.server.?.deinit();
    value.server = null;
}

fn restart(sim: *Sim, value: *Node, mid_dispatch: bool, reconfigure: bool) !void {
    try stopDaemon(sim, value, mid_dispatch);
    try value.fixture.close();
    if (reconfigure) {
        sim.runtime +%= 1;
        value.fixture.profile.runtime_identity = runtimeDigest(sim.runtime);
    }
    try value.fixture.open();
    try startDaemon(sim, value);
}

fn closeNode(sim: *Sim, value: *Node) !void {
    if (value.daemon != null) try stopDaemon(sim, value, false);
    try value.fixture.close();
}

fn destroyNode(value: *Node) void {
    if (value.daemon) |*daemon| {
        daemon.beginStop(0);
        var frame = std.heap.ArenaAllocator.init(gpa);
        defer frame.deinit();
        for (0..10_000) |_| {
            settleWorker(value) catch break;
            const progress = daemon.poll(frame.allocator(), 0) catch break;
            if (progress == .stopped or progress == .stopped_unclean) break;
        }
        daemon.deinit() catch |err| std.debug.print("daemon deinit: {s}\n", .{@errorName(err)});
    }
    if (value.server) |*server| server.deinit();
    value.backup.cleanup();
    value.fixture.deinit();
}

const Response = struct {
    bytes: []const u8,
    status: []const u8,
    failure: ?[]const u8,
    data: ?native.json.Value,
};

fn dispatchBytes(sim: *Sim, value: *Node, bytes: []const u8) !Response {
    return dispatchIndexed(sim, value, bytes, null);
}

fn dispatchIndexed(sim: *Sim, value: *Node, bytes: []const u8, index: ?*const idx.Index) !Response {
    const a = sim.allocator();
    const reply = try control.dispatchWithIndex(
        a,
        &value.driver,
        value.config,
        uid,
        bytes,
        value.environment,
        index,
        config_path,
    );
    const parsed = try native.json.parse(a, reply, .{ .bytes = control.frame_bytes_max });
    const object = parsed.value.object;
    return .{
        .bytes = reply,
        .status = try native.json.text(object.get("status").?),
        .failure = if (object.get("error")) |found| try native.json.text(found) else null,
        .data = object.get("data"),
    };
}

fn responseTask(response: Response) ?t.Id {
    const data = response.data orelse return null;
    if (data != .object) return null;
    const task = data.object.get("task") orelse return null;
    return wire.parse(t.Id, native.json.text(task) catch return null) catch null;
}

fn encodeArgs(sim: *Sim, args: []const []const u8) !?[]const u8 {
    return cli.request(sim.allocator(), args, "unused-generated") catch |err| {
        try sim.note("client-refused", "{s}", .{@errorName(err)});
        return null;
    };
}

fn mutate(sim: *Sim, value: *Node, kind: Kind, args: []const []const u8) !?Response {
    const operation = args[args.len - 1];
    const bytes = (try encodeArgs(sim, args)) orelse return null;
    return try send(sim, value, kind, operation, bytes);
}

fn send(sim: *Sim, value: *Node, kind: Kind, operation: []const u8, bytes: []const u8) !Response {
    const response = try dispatchBytes(sim, value, bytes);
    const shown = if (kind == .transfer) response.bytes[0..@min(response.bytes.len, 240)] else "";
    try sim.note(@tagName(kind), "{s} -> {s} {s} {s}", .{
        operation, response.status, response.failure orelse "", shown,
    });
    if (!std.mem.eql(u8, response.status, "rejected") and !value.ledger.contains(operation)) {
        try value.ledger.put(sim.allocator(), operation, .{
            .bytes = bytes,
            .kind = kind,
            .task = responseTask(response),
        });
        try value.operations.append(sim.allocator(), operation);
    }
    return response;
}

fn rebuild(sim: *Sim, value: *Node) !idx.Index {
    return value.driver.rebuild(sim.allocator());
}

fn pickObligation(sim: *Sim, index: *const idx.Index) ?t.Id {
    if (index.obligations.len == 0 or sim.chance(5)) {
        var random: t.Id = undefined;
        sim.random().bytes(&random);
        return if (index.obligations.len == 0 and !sim.chance(10)) null else random;
    }
    return index.obligations[sim.below(index.obligations.len)].task;
}

fn idText(sim: *Sim, id: t.Id) ![]const u8 {
    return sim.allocator().dupe(u8, &oracle.hex(id));
}

fn number(sim: *Sim, value: anytype) ![]const u8 {
    return std.fmt.allocPrint(sim.allocator(), "{d}", .{value});
}

fn intervalText(sim: *Sim) ![]const u8 {
    const roll = sim.below(100);
    if (roll < 3) return "0";
    if (roll < 5) return number(sim, interval_max + 1);
    if (roll < 40) return number(sim, sim.random().intRangeAtMost(u64, 60_000, 600_000));
    return number(sim, sim.random().intRangeAtMost(u64, 600_000, 7_200_000));
}

fn wordingText(sim: *Sim) ![]const u8 {
    if (!sim.chance(4)) return "Summarize the new commits.";
    const long = try sim.allocator().alloc(u8, sim.random().intRangeAtMost(usize, 400, 2_000));
    @memset(long, 'w');
    return long;
}

fn policiesText(sim: *Sim) ![]const u8 {
    var policies: t.Policies = .{
        .notification_interval_ms = sim.random().intRangeAtMost(u64, 0, 300_000),
        .clock_regression_tolerance_ms = sim.random().intRangeAtMost(u64, 0, 900_000),
        .phase_attempts = sim.random().intRangeAtMost(u32, 1, 5),
        .method_faults = sim.random().intRangeAtMost(u32, 1, 5),
        .render_input_bytes = sim.random().intRangeAtMost(u64, 1024, 65_536),
        .context_bytes = sim.random().intRangeAtMost(u64, 1024, 65_536),
    };
    if (sim.chance(5)) policies.phase_attempts = 21;
    if (sim.chance(3)) policies.render_input_bytes = 512;
    return std.json.Stringify.valueAlloc(sim.allocator(), policies, .{});
}

fn monitorAdd(sim: *Sim, value: *Node) !void {
    var args: std.ArrayList([]const u8) = .empty;
    const a = sim.allocator();
    try args.appendSlice(a, &.{ "monitor", "add" });
    if (sim.chance(70)) try args.appendSlice(a, &.{ "--interval-ms", try intervalText(sim) });
    if (sim.chance(50)) try args.appendSlice(a, &.{ "--wording", try wordingText(sim) });
    try args.appendSlice(a, &.{ "--operation", try sim.nextOperation("add") });
    const response = (try mutate(sim, value, .monitor_add, args.items)) orelse return;
    const task = responseTask(response) orelse return;
    const operation = args.items[args.items.len - 1];
    var index = try rebuild(sim, value);
    defer index.deinit();
    const record = index.record(task) orelse return;
    if (record.input == .genesis)
        value.ledger.getPtr(operation).?.lineage = record.input.genesis.lineage;
}

fn directiveArgs(sim: *Sim, index: *const idx.Index, target: t.Id) ![]const []const u8 {
    const a = sim.allocator();
    const id = try idText(sim, target);
    const roll = sim.below(100);
    const simple = [_][]const u8{ "pause", "resume", "check", "cancel" };
    if (roll < 60) {
        const name = simple[if (roll < 58) roll % 3 else 3];
        return a.dupe([]const u8, &.{ "monitor", name, id });
    }
    const revision = if (index.obligation(target)) |obligation|
        index.head(obligation).specification.revision
    else
        0;
    const expected = if (sim.chance(85)) revision else revision + 1;
    if (roll < 65)
        return a.dupe([]const u8, &.{ "method", "revert", id, try number(sim, expected) });
    if (roll < 70) {
        var question: t.Digest = undefined;
        sim.random().bytes(&question);
        return a.dupe([]const u8, &.{
            "question", "answer", id, try a.dupe(u8, &std.fmt.bytesToHex(question, .lower)), "yes",
        });
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "monitor", "amend", id, try number(sim, expected) });
    const fields = sim.random().intRangeAtMost(u8, 1, 7);
    if (fields & 1 != 0) try args.appendSlice(a, &.{ "--interval-ms", try intervalText(sim) });
    if (fields & 2 != 0) try args.appendSlice(a, &.{ "--wording", try wordingText(sim) });
    if (fields & 4 != 0) try args.appendSlice(a, &.{ "--policies-json", try policiesText(sim) });
    return args.items;
}

fn withOperation(sim: *Sim, args: []const []const u8, prefix: []const u8) ![]const []const u8 {
    return std.mem.concat(sim.allocator(), []const u8, &.{
        args, &.{ "--operation", try sim.nextOperation(prefix) },
    });
}

fn directive(sim: *Sim, value: *Node) !void {
    var index = try rebuild(sim, value);
    defer index.deinit();
    const target = pickObligation(sim, &index) orelse return;
    const args = try directiveArgs(sim, &index, target);
    _ = try mutate(sim, value, .directive, try withOperation(sim, args, "control"));
}

fn ask(sim: *Sim, value: *Node) !void {
    var index = try rebuild(sim, value);
    defer index.deinit();
    const texts = [_][]const u8{ "What are you watching?", "Pause it.", "Check every hour." };
    var args: std.ArrayList([]const u8) = .empty;
    const a = sim.allocator();
    const text = texts[sim.below(texts.len)];
    const target = if (sim.chance(60)) pickObligation(sim, &index) else null;
    if (target) |id| {
        const marker = world_module.targeted_marker;
        const marked = try std.fmt.allocPrint(a, "{s} {s}", .{ text, marker });
        try args.appendSlice(a, &.{ "ask", marked, "--target", try idText(sim, id) });
    } else try args.appendSlice(a, &.{ "ask", text });
    const request = try withOperation(sim, args.items, "ask");
    const response = (try mutate(sim, value, .ask, request)) orelse return;
    if (responseTask(response)) |task| try value.turns.append(a, task);
}

fn confirm(sim: *Sim, value: *Node) !void {
    if (value.confirmed.items.len != 0 and sim.chance(40)) return reconfirm(sim, value);
    const count = value.turns.items.len;
    if (count == 0) return;
    const start = sim.below(count);
    for (0..count) |offset| {
        const turn = value.turns.items[(start + offset) % count];
        const identity = try proposalOf(sim, value, turn) orelse continue;
        const args = try withOperation(sim, &.{ "proposal", "confirm", identity }, "confirm");
        const response = (try mutate(sim, value, .confirm, args)) orelse return;
        if (responseTask(response) == null) return;
        try value.confirmed.append(sim.allocator(), try sim.allocator().dupe(u8, identity));
        return reconfirm(sim, value);
    }
    try sim.note("confirm", "none of {d} turns offers a proposal", .{count});
}

fn proposalOf(sim: *Sim, value: *Node, turn: t.Id) !?[]const u8 {
    const bytes = (try encodeArgs(sim, &.{ "task", "show", try idText(sim, turn) })) orelse
        return null;
    const shown = try dispatchBytes(sim, value, bytes);
    const data = shown.data orelse return null;
    const items = (data.object.get("confirmations") orelse return null).array.items;
    if (items.len == 0) {
        const status = data.object.get("task_status") orelse .null;
        const result = data.object.get("result") orelse .null;
        const reply = if (result == .object) result.object.get("value") else null;
        try sim.note("turn", "{s} status {s} result {s}", .{
            oracle.hex(turn),
            if (status == .null) "none" else try native.json.text(status),
            if (reply) |found| try native.json.canonical(sim.allocator(), found) else "none",
        });
        return null;
    }
    const item = items[sim.below(items.len)];
    return try native.json.text(item.object.get("identity").?);
}

fn reconfirm(sim: *Sim, value: *Node) !void {
    const identity = value.confirmed.items[sim.below(value.confirmed.items.len)];
    const args = try withOperation(sim, &.{ "proposal", "confirm", identity }, "confirm");
    const response = (try mutate(sim, value, .confirm, args)) orelse return;
    if (responseTask(response) == null) return;
    const operation = args[args.len - 1];
    try replayChanged(sim, value, operation, value.ledger.get(operation).?);
}

fn answer(sim: *Sim, value: *Node) !void {
    var index = try rebuild(sim, value);
    var open: std.ArrayList(t.Id) = .empty;
    for (index.obligations) |*obligation|
        if (index.head(obligation).question != null)
            try open.append(sim.allocator(), obligation.task);
    index.deinit();
    if (open.items.len == 0) return sim.note("answer", "no open question", .{});
    try answerTarget(sim, value, open.items[sim.below(open.items.len)], sim.chance(50));
}

fn answerTarget(sim: *Sim, value: *Node, target: t.Id, amended: bool) !void {
    if (amended) {
        var index = try rebuild(sim, value);
        const revision = index.head(index.obligation(target).?).specification.revision;
        index.deinit();
        const id = try idText(sim, target);
        const wording = "Amended while a question is open.";
        const fields = [_][]const u8{ "monitor", "amend", id, try number(sim, revision) };
        const args = try std.mem.concat(sim.allocator(), []const u8, &.{
            &fields, &.{ "--wording", wording },
        });
        _ = try mutate(sim, value, .directive, try withOperation(sim, args, "amend"));
    }
    var index = try rebuild(sim, value);
    defer index.deinit();
    const page = try messagePage(sim, value, &index, target, null, 64);
    for (page.messages.items) |item| for (item.choices.items) |choice| {
        const line = (choice.command orelse continue).bytes;
        const args = try commandArgs(sim, line);
        _ = try mutate(sim, value, .directive, try withOperation(sim, args, "answer"));
        return;
    };
}

fn openQuestion(sim: *Sim, value: *Node, target: t.Id) !bool {
    var index = try rebuild(sim, value);
    defer index.deinit();
    const obligation = index.obligation(target) orelse return false;
    return index.head(obligation).question != null;
}

fn baseline(sim: *Sim, value: *Node) !void {
    var index = try rebuild(sim, value);
    var target: ?t.Id = null;
    for (index.obligations) |*obligation| {
        const current = index.head(obligation);
        if (current.mode != .active or current.question != null) continue;
        if (current.observed.tip != null) {
            index.deinit();
            return;
        }
        target = obligation.task;
    }
    index.deinit();
    const id = target orelse return;
    const args = try withOperation(sim, &.{ "monitor", "check", try idText(sim, id) }, "check");
    _ = try mutate(sim, value, .directive, args);
    for (0..24) |_| {
        try polls(sim, value, 8);
        var current = try rebuild(sim, value);
        defer current.deinit();
        const obligation = current.obligation(id) orelse return;
        if (current.head(obligation).observed.tip != null) return;
        sim.wall_ms += 60_000;
    }
}

fn questionScenario(sim: *Sim, value: *Node) !void {
    try baseline(sim, value);
    var index = try rebuild(sim, value);
    var target: ?t.Id = null;
    for (index.obligations) |*obligation| {
        const current = index.head(obligation);
        const tip = current.observed.tip orelse continue;
        if (current.mode != .active or current.question != null) continue;
        sim.world.divergeFrom(tip);
        target = obligation.task;
    }
    index.deinit();
    const id = target orelse return sim.note("rewrite", "no observed active monitor", .{});
    try sim.note("rewrite", "tip {d} diverges from {s}", .{ sim.world.tip, oracle.hex(id) });
    const args = try withOperation(sim, &.{ "monitor", "check", try idText(sim, id) }, "check");
    _ = try mutate(sim, value, .directive, args);
    var open = false;
    for (0..24) |_| {
        try polls(sim, value, 8);
        open = try openQuestion(sim, value, id);
        if (open) break;
    }
    try sim.note("question", "{s} open {}", .{ oracle.hex(id), open });
    if (open) try answerTarget(sim, value, id, true);
    try polls(sim, value, sim.random().intRangeAtMost(usize, 6, 24));
}

fn commandArgs(sim: *Sim, line: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    var position: usize = 0;
    while (words.next()) |word| : (position += 1) {
        if (position < 3) continue;
        try args.append(sim.allocator(), std.mem.trim(u8, word, "'"));
    }
    return args.items;
}

const MessagePage = @import("../native/messages.zig").Page;

fn messagePage(
    sim: *Sim,
    value: *Node,
    index: ?*const idx.Index,
    target: t.Id,
    after: ?u64,
    limit: u32,
) !MessagePage {
    const a = sim.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    const id = try idText(sim, target);
    try args.appendSlice(a, &.{ "messages", id, "--limit", try number(sim, limit) });
    if (after) |cursor| try args.appendSlice(a, &.{ "--after", try number(sim, cursor) });
    const response = try dispatchIndexed(sim, value, (try encodeArgs(sim, args.items)).?, index);
    if (!std.mem.eql(u8, response.status, "observed"))
        return sim.fail("L3", "messages {s} refused: {s}", .{
            oracle.hex(target), response.failure orelse response.status,
        });
    return wire.fromJson(MessagePage, a, response.data.?);
}

fn replay(sim: *Sim, value: *Node) !void {
    if (value.operations.items.len == 0) return;
    const operation = value.operations.items[sim.below(value.operations.items.len)];
    const entry = value.ledger.get(operation).?;
    if (entry.kind == .transfer) return;
    if (sim.chance(70)) return replayIdentical(sim, value, operation, entry);
    return replayChanged(sim, value, operation, entry);
}

fn replayChanged(sim: *Sim, value: *Node, operation: []const u8, entry: Entry) !void {
    var index = try rebuild(sim, value);
    defer index.deinit();
    const target = pickObligation(sim, &index) orelse return;
    const args = try std.mem.concat(sim.allocator(), []const u8, &.{
        try directiveArgs(sim, &index, target), &.{ "--operation", operation },
    });
    const bytes = (try encodeArgs(sim, args)) orelse return;
    if (std.mem.eql(u8, bytes, entry.bytes)) return replayIdentical(sim, value, operation, entry);
    const response = try dispatchBytes(sim, value, bytes);
    try sim.note("replay-changed", "{s} -> {s} {s}", .{
        operation, response.status, response.failure orelse "",
    });
    const failure = response.failure orelse "";
    if (entry.task == null and std.mem.eql(u8, failure, "ContinuityImportPending") and
        try importing(sim, value)) return;
    if (!std.mem.eql(u8, failure, "OperationConflict"))
        return sim.fail("I1", "changed request under {s} answered {s} {s}", .{
            operation, response.status, response.failure orelse "",
        });
}

fn replayIdentical(sim: *Sim, value: *Node, operation: []const u8, entry: Entry) !void {
    const response = try dispatchBytes(sim, value, entry.bytes);
    try sim.note("replay", "{s} -> {s} {s}", .{
        operation, response.status, response.failure orelse "",
    });
    if (entry.lineage != null and entry.task == null) {
        if (std.mem.eql(u8, response.failure orelse "", "ContinuityImportPending") and
            try importing(sim, value)) return;
        const task = responseTask(response) orelse
            return sim.fail("I1", "carried monitor add {s} answered {s} {s}", .{
                operation, response.status, response.failure orelse "",
            });
        var index = try rebuild(sim, value);
        defer index.deinit();
        const record = index.record(task) orelse return sim.fail("I1", "unknown task", .{});
        if (record.input != .genesis or
            !std.meta.eql(record.input.genesis.lineage, entry.lineage.?))
            return sim.fail("I1", "carried monitor add {s} named another lineage", .{operation});
        return;
    }
    const task = responseTask(response);
    if (!std.meta.eql(task, entry.task))
        return sim.fail("I1", "replay of {s} answered {s} {s}, originally {s}", .{
            operation, response.status, response.failure orelse "", optionalHex(entry.task),
        });
}

fn noncanonical(sim: *Sim, value: *Node) !void {
    var index = try rebuild(sim, value);
    defer index.deinit();
    if (index.obligations.len == 0) return;
    const target = index.obligations[sim.below(index.obligations.len)].task;
    const id = try idText(sim, target);
    const args = try withOperation(sim, &.{ "monitor", "check", id }, "spelling");
    const bytes = try sim.allocator().dupe(u8, (try encodeArgs(sim, args)).?);
    const at = std.mem.indexOf(u8, bytes, id).?;
    var changed = false;
    for (bytes[at .. at + id.len]) |*byte| if (byte.* >= 'a' and byte.* <= 'f') {
        byte.* = std.ascii.toUpper(byte.*);
        changed = true;
    };
    if (!changed) return;
    const response = try dispatchBytes(sim, value, bytes);
    try sim.note("spelling", "uppercase target -> {s} {s}", .{
        response.status, response.failure orelse "",
    });
    if (!std.mem.eql(u8, response.status, "rejected"))
        return sim.fail("L9", "uppercase identity accepted: {s}", .{response.status});
}

fn advanceTime(sim: *Sim) !void {
    const roll = sim.below(100);
    const delta: i64 = if (roll < 35)
        sim.random().intRangeAtMost(i64, 1_000, 60_000)
    else if (roll < 85)
        sim.random().intRangeAtMost(i64, 60_000, 1_800_000)
    else
        sim.random().intRangeAtMost(i64, 1_800_000, 14_400_000);
    sim.wall_ms += delta;
    try sim.note("time", "+{d} ms -> {d}", .{ delta, sim.wall_ms });
}

fn regressClock(sim: *Sim) !void {
    const delta = sim.random().intRangeAtMost(i64, 60_000, 3_600_000);
    sim.wall_ms -= delta;
    try sim.note("regress", "-{d} ms -> {d}", .{ delta, sim.wall_ms });
}

fn earlyRegression(sim: *Sim, value: *Node) !void {
    try monitorAdd(sim, value);
    try polls(sim, value, sim.random().intRangeAtMost(usize, 4, 12));
    try regressClock(sim);
    try polls(sim, value, sim.random().intRangeAtMost(usize, 8, 24));
}

fn jumpClock(sim: *Sim) !void {
    const delta = sim.random().intRangeAtMost(i64, 86_400_000, 3 * 86_400_000);
    sim.wall_ms += delta;
    try sim.note("jump", "+{d} ms -> {d}", .{ delta, sim.wall_ms });
}

fn polls(sim: *Sim, value: *Node, count: usize) !void {
    var progressed: usize = 0;
    for (0..count) |_| {
        if (try poll(sim, value) == .progressed) progressed += 1;
    }
    try sim.note("poll", "{d} polls, {d} progressed", .{ count, progressed });
}

fn exportStart(sim: *Sim, value: *Node) !void {
    if (sim.nodes.items.len >= options.hops_max + 1 or sim.events.items.len < 20) return;
    var index = try rebuild(sim, value);
    const empty = index.obligations.len == 0;
    index.deinit();
    if (empty) return;
    const snapshot = sim.chance(50);
    const name = try std.fmt.allocPrint(sim.allocator(), "hop-{c}-{d}.paredros", .{
        value.label, sim.operation,
    });
    const operation = try sim.nextOperation("export");
    const args: []const []const u8 = if (snapshot)
        &.{ "transfer", "export", name, "--snapshot", "--operation", operation }
    else
        &.{ "transfer", "export", name, "--operation", operation };
    sim.pending_export = .{
        .operation = operation,
        .args = try sim.allocator().dupe([]const u8, args),
        .snapshot = snapshot,
        .expected = if (snapshot) try expectations(sim, value, true) else null,
    };
    try exportContinue(sim, value, true);
}

fn exportContinue(sim: *Sim, value: *Node, first: bool) !void {
    const pending = sim.pending_export.?;
    const response = (try mutate(sim, value, .transfer, pending.args)) orelse return;
    if (std.mem.eql(u8, response.status, "rejected")) {
        if (pending.snapshot or first) sim.pending_export = null;
        return;
    }
    const data = response.data.?.object;
    const phase = try native.json.text(data.get("phase").?);
    if (!std.mem.eql(u8, phase, "written")) return;
    const name = try native.json.text(data.get("name").?);
    const carried = pending.expected orelse try expectations(sim, value, false);
    sim.pending_export = null;
    try hop(sim, value, name, carried, pending.snapshot);
}

fn pendingBodies(
    sim: *Sim,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]const t.DirectiveBody {
    var bodies: std.ArrayList(t.DirectiveBody) = .empty;
    const folded = index.head(obligation).folded_directive_ordinal;
    for (obligation.directives) |position| {
        const directive_value = index.records[position].input.directive;
        if (directive_value.ordinal > folded)
            try bodies.append(sim.allocator(), directive_value.body);
    }
    return bodies.items;
}

fn expectations(sim: *Sim, value: *Node, snapshot: bool) ![]Expectation {
    var index = try rebuild(sim, value);
    defer index.deinit();
    var result: std.ArrayList(Expectation) = .empty;
    const a = sim.allocator();
    for (index.obligations) |*obligation| {
        const current = index.head(obligation);
        const mode: t.Mode = if (snapshot) current.mode else switch (current.desired_mode) {
            .active => .active,
            .paused => .paused,
            .cancelled => .cancelled,
        };
        if (mode == .cancelled or current.mode == .cancelled) continue;
        const genesis = index.records[obligation.chain[0]].input.genesis;
        try result.append(a, .{
            .lineage = genesis.lineage,
            .head = try copyHead(sim, current),
            .mode = mode,
            .pending = try pendingBodies(sim, &index, obligation),
        });
    }
    for (index.records) |record| {
        if (record.input != .genesis or record.result != null) continue;
        try result.append(a, .{
            .lineage = record.input.genesis.lineage,
            .head = null,
            .mode = .active,
            .pending = &.{},
        });
    }
    return result.items;
}

fn copyHead(sim: *Sim, value: t.Head) !t.Head {
    const bytes = try c.encodeOwned(t.Head, sim.allocator(), value);
    return (try c.decodeOwned(t.Head, sim.allocator(), bytes)).value;
}

fn hop(sim: *Sim, source: *Node, name: []const u8, carried: []Expectation, snapshot: bool) !void {
    var index = try rebuild(sim, source);
    if (!snapshot) for (index.obligations) |*obligation|
        try oracle.disposedAll(sim.check(sim.allocator(), &index), obligation);
    index.deinit();
    try closeNode(sim, source);
    const destination = try openNode(sim, source.label + 1);
    try destination.expectations.appendSlice(sim.allocator(), carried);
    var operations = source.ledger.iterator();
    while (operations.next()) |item| {
        const lineage = item.value_ptr.lineage orelse continue;
        if (!carries(carried, lineage)) continue;
        try destination.ledger.put(sim.allocator(), item.key_ptr.*, .{
            .bytes = item.value_ptr.bytes,
            .kind = .monitor_add,
            .lineage = lineage,
        });
        try destination.operations.append(sim.allocator(), item.key_ptr.*);
    }
    const path = try std.fs.path.join(sim.allocator(), &.{ source.backup_path, name });
    const args = try cli.bundleArguments(sim.allocator(), std.testing.io, &.{
        "transfer", "import", path, "--operation", try sim.nextOperation("import"),
    });
    destination.import_args = args;
    try sim.note("hop", "{c} -> {c} with {d} lineages", .{
        source.label, destination.label, carried.len,
    });
    _ = try mutate(sim, destination, .transfer, args);
}

fn importing(sim: *Sim, value: *Node) !bool {
    var index = try rebuild(sim, value);
    defer index.deinit();
    const view = index.continuity_import orelse return false;
    return view.phase != .materialized;
}

fn carries(carried: []const Expectation, lineage: t.Digest) bool {
    for (carried) |expected| if (std.meta.eql(expected.lineage, lineage)) return true;
    return false;
}

fn importContinue(sim: *Sim, value: *Node) !void {
    const args = value.import_args orelse return;
    var index = try rebuild(sim, value);
    const view = index.continuity_import;
    const done = view == null or view.?.phase == .materialized;
    index.deinit();
    if (done) return;
    _ = try mutate(sim, value, .other, args);
}

fn act(sim: *Sim) !void {
    const value = sim.node();
    if (sim.pending_export != null and sim.chance(35)) return exportContinue(sim, value, false);
    if (value.import_args != null and sim.chance(35) and try importing(sim, value))
        return importContinue(sim, value);
    const roll = sim.below(100);
    switch (roll) {
        0...28 => try polls(sim, value, sim.random().intRangeAtMost(usize, 2, 24)),
        29...38 => try advanceTime(sim),
        39...41 => try regressClock(sim),
        42 => try jumpClock(sim),
        43 => try earlyRegression(sim, value),
        44...49 => try monitorAdd(sim, value),
        50...67 => try directive(sim, value),
        68...72 => try ask(sim, value),
        73...75 => try confirm(sim, value),
        76...83 => try replay(sim, value),
        84...85 => try noncanonical(sim, value),
        86...88 => try restartEvent(sim, value, false, false),
        89...90 => try restartEvent(sim, value, true, false),
        91...92 => try restartEvent(sim, value, false, true),
        93...95 => try exportEvent(sim, value),
        96 => try answer(sim, value),
        97...98 => try questionScenario(sim, value),
        else => try strand(sim, value),
    }
}

fn strand(sim: *Sim, value: *Node) !void {
    try monitorAdd(sim, value);
    try restartEvent(sim, value, false, true);
}

fn restartEvent(sim: *Sim, value: *Node, mid_dispatch: bool, reconfigure: bool) !void {
    try restart(sim, value, mid_dispatch, reconfigure);
    try sim.note("restart", "{c} mid_dispatch={} reconfigure={}", .{
        value.label, mid_dispatch, reconfigure,
    });
}

fn exportEvent(sim: *Sim, value: *Node) !void {
    if (value.import_args != null) {
        var index = try rebuild(sim, value);
        const pending = index.continuity_import != null and
            index.continuity_import.?.phase != .materialized;
        index.deinit();
        if (pending) return importContinue(sim, value);
    }
    if (sim.pending_export != null) return exportContinue(sim, value, false);
    return exportStart(sim, value);
}

fn observe(sim: *Sim) !void {
    const value = sim.node();
    var maintained = try value.driver.view(sim.allocator());
    maintained.deinit();
    var index = try rebuild(sim, value);
    defer index.deinit();
    sim.records = index.records.len;
    const check = sim.check(sim.allocator(), &index);
    try oracle.chains(check);
    try verifyImported(sim, value, &index);
    try listedMessages(sim, value, &index);
    try statusWalk(sim, value, &index);
    for (index.obligations) |*obligation| {
        const current = index.head(obligation);
        var summary: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&summary, "{d}:{s}:{d}:{d};", .{
            current.sequence,      @tagName(current.mode), current.observed.sequence,
            current.told.sequence,
        });
        sim.hasher.update(line);
    }
}

fn listedMessages(sim: *Sim, value: *Node, index: *const idx.Index) !void {
    for (index.obligations) |*obligation| {
        var expected: std.ArrayList(usize) = .empty;
        for (obligation.chain) |position| {
            if (oracle.head(index.records[position]).?.message != null)
                try expected.append(sim.allocator(), position);
        }
        const limit: u32 = @intCast(sim.random().intRangeAtMost(u32, 1, 64));
        var after: ?u64 = null;
        var seen: usize = 0;
        for (0..expected.items.len + 2) |_| {
            const page = try messagePage(sim, value, index, obligation.task, after, limit);
            for (page.messages.items) |item| {
                try listedItem(sim, value, index, obligation, expected.items, seen, item);
                seen += 1;
            }
            after = page.next orelse break;
        } else return sim.fail("L3", "messages for {s} never ended", .{
            oracle.hex(obligation.task),
        });
        if (seen != expected.items.len)
            return sim.fail("I4", "messages for {s} listed {d} of {d} heads", .{
                oracle.hex(obligation.task), seen, expected.items.len,
            });
    }
}

fn listedItem(
    sim: *Sim,
    value: *Node,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    expected: []const usize,
    seen: usize,
    item: @import("../native/messages.zig").Message,
) !void {
    if (seen >= expected.len) return sim.fail("I4", "messages listed an extra item", .{});
    const record = index.records[expected[seen]];
    const message_head = oracle.head(record).?;
    if (!std.meta.eql(item.task, record.task) or item.sequence != message_head.sequence or
        item.ordinal != seen + 1)
        return sim.fail("I4", "message {d} of {s} names head {d}, chain has {d}", .{
            seen + 1, oracle.hex(obligation.task), item.sequence, message_head.sequence,
        });
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&item.task);
    hasher.update(@tagName(item.purpose));
    hasher.update(item.text.bytes);
    const identity = hasher.finalResult();
    const entry = try value.listed.getOrPut(sim.allocator(), .{ obligation.task, item.ordinal });
    if (entry.found_existing and !std.meta.eql(entry.value_ptr.*, identity))
        return sim.fail("L3", "message {d} of {s} changed once listed", .{
            item.ordinal, oracle.hex(obligation.task),
        });
    entry.value_ptr.* = identity;
    const pending = index.head(obligation).question;
    for (item.choices.items) |choice| {
        const open = pending != null and item.question != null and
            std.meta.eql(pending.?.identity, item.question.?);
        if ((choice.command != null) != open)
            return sim.fail("L3", "message {d} of {s} command presence {} for open {}", .{
                item.ordinal, oracle.hex(obligation.task), choice.command != null, open,
            });
    }
}

fn statusWalk(sim: *Sim, value: *Node, index: *const idx.Index) !void {
    const limit = sim.random().intRangeAtMost(u32, 1, 8);
    var after: ?[]const u8 = null;
    var count: usize = 0;
    for (0..index.obligations.len + 2) |_| {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(sim.allocator(), &.{ "status", "--limit", try number(sim, limit) });
        if (after) |cursor| try args.appendSlice(sim.allocator(), &.{ "--after", cursor });
        const bytes = (try encodeArgs(sim, args.items)).?;
        const response = try dispatchIndexed(sim, value, bytes, index);
        const data = (response.data orelse
            return sim.fail("L9", "status refused: {s}", .{response.failure orelse ""})).object;
        count += data.get("obligations").?.array.items.len;
        const next = data.get("next").?;
        if (next == .null) break;
        after = try native.json.text(next);
        if (count == index.obligations.len)
            return sim.fail("L9", "status next {s} after the last of {d} obligations", .{
                after.?, count,
            });
    } else return sim.fail("L9", "status paging never ended", .{});
    if (count != index.obligations.len)
        return sim.fail("L9", "status listed {d} of {d} obligations", .{
            count, index.obligations.len,
        });
}

fn lineageObligation(index: *const idx.Index, lineage: t.Digest) ?*const idx.Obligation {
    const position = index.lineages.get(lineage) orelse return null;
    return index.obligation(index.records[position].task);
}

fn verifyImported(sim: *Sim, value: *Node, index: *const idx.Index) !void {
    for (value.expectations.items) |*expected| {
        if (expected.verified) continue;
        const obligation = lineageObligation(index, expected.lineage) orelse continue;
        if (obligation.controls_pending) continue;
        try compareImported(sim, index, obligation, expected.*);
        expected.verified = true;
        try sim.note("verified", "{c} lineage {s}", .{ value.label, short(expected.lineage) });
    }
}

fn compareImported(
    sim: *Sim,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    expected: Expectation,
) !void {
    const source = expected.head orelse return;
    const imported = oracle.head(index.records[obligation.chain[0]]).?;
    const id = oracle.hex(obligation.task);
    if (imported.mode != expected.mode)
        return sim.fail("I8", "{s} imported {s}, source {s}", .{
            id, @tagName(imported.mode), @tagName(expected.mode),
        });
    const spec = imported.specification;
    const original = source.specification;
    if (spec.revision != original.revision or spec.interval_ms != original.interval_ms or
        !std.mem.eql(u8, spec.wording.bytes, original.wording.bytes) or
        !std.meta.eql(spec.policies, original.policies))
        return sim.fail("I8", "{s} specification changed across import", .{id});
    if (!std.meta.eql(imported.observed, source.observed) or
        !std.meta.eql(imported.told, source.told))
        return sim.fail("I8", "{s} frontiers {d}/{d} imported as {d}/{d}", .{
            id,                         source.observed.sequence, source.told.sequence,
            imported.observed.sequence, imported.told.sequence,
        });
    const question = if (imported.question) |q| q.identity else null;
    const original_question = if (source.question) |q| q.identity else null;
    if (!std.meta.eql(question, original_question))
        return sim.fail("I8", "{s} pending question changed across import", .{id});
    if (std.meta.activeTag(imported.method) != std.meta.activeTag(source.method))
        return sim.fail("I8", "{s} method changed across import", .{id});
    try comparePending(sim, index, obligation, expected.pending);
}

fn comparePending(
    sim: *Sim,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    expected: []const t.DirectiveBody,
) !void {
    const id = oracle.hex(obligation.task);
    if (obligation.directives.len < expected.len)
        return sim.fail("I8", "{s} imported {d} of {d} pending controls", .{
            id, obligation.directives.len, expected.len,
        });
    for (expected, obligation.directives[0..expected.len]) |body, position| {
        const imported = index.records[position].input.directive.body;
        const left = try c.encodeOwned(t.DirectiveBody, sim.allocator(), body);
        const right = try c.encodeOwned(t.DirectiveBody, sim.allocator(), imported);
        if (!std.mem.eql(u8, left, right))
            return sim.fail("I8", "{s} pending control {s} imported as {s}", .{
                id, @tagName(body), @tagName(imported),
            });
    }
}

fn nextInstant(sim: *Sim, value: *Node, index: *const idx.Index) i64 {
    var best: i64 = sim.wall_ms + 60_000;
    for (index.obligations) |*obligation| {
        const current = index.head(obligation);
        inline for (@typeInfo(t.Schedule).@"struct".field_names) |name| {
            const instant = @field(current.schedule, name);
            if (instant > sim.wall_ms and instant < best) best = instant;
        }
    }
    var faults = value.driver.faults.items.valueIterator();
    while (faults.next()) |fault| {
        if (fault.retry_ms > sim.wall_ms and fault.retry_ms < best) best = fault.retry_ms;
    }
    return best;
}

fn settle(sim: *Sim, value: *Node) !void {
    var index = try rebuild(sim, value);
    const quiet = 8 + 3 * index.obligations.len;
    index.deinit();
    var idle: usize = 0;
    for (0..1024) |_| {
        idle = if (try poll(sim, value) == .idle) idle + 1 else 0;
        if (idle >= quiet) return;
    }
}

fn quiesce(sim: *Sim) !void {
    sim.world.calm = true;
    for (0..options.rest_rounds) |_| {
        const value = sim.node();
        try settle(sim, value);
        if (sim.pending_export != null) try exportContinue(sim, value, false);
        try importContinue(sim, sim.node());
        try observe(sim);
        if (try rested(sim, sim.node(), false)) {
            try sim.note("rest", "reached at {d}", .{sim.wall_ms});
            return;
        }
        var index = try rebuild(sim, sim.node());
        sim.wall_ms = @max(sim.wall_ms + 1, nextInstant(sim, sim.node(), &index));
        index.deinit();
    }
    if (!try rested(sim, sim.node(), true)) return error.Violation;
    return sim.fail("I9", "no resting state within {d} rounds", .{options.rest_rounds});
}

fn rested(sim: *Sim, value: *Node, final: bool) !bool {
    var index = try rebuild(sim, value);
    defer index.deinit();
    var scratch: ?oracle.Violation = null;
    const check: Check = .{ .a = sim.allocator(), .index = &index, .violation = &scratch };
    restCheck(sim, value, check) catch |err| switch (err) {
        error.Violation => {
            if (final) sim.violation = scratch;
            return false;
        },
        else => return err,
    };
    return true;
}

fn restCheck(sim: *Sim, value: *Node, check: Check) !void {
    const index = check.index;
    if (sim.pending_export) |pending|
        return check.fail("I9", "export {s} unfinished", .{pending.operation});
    if (index.continuity_import) |view| if (view.phase != .materialized)
        return check.fail("I9", "import unfinished in phase {s}", .{@tagName(view.phase)});
    for (value.expectations.items) |expected| if (!expected.verified and expected.head != null)
        return check.fail("I8", "lineage {s} never verified", .{short(expected.lineage)});
    for (index.obligations) |*obligation| try oracle.resting(check, obligation, sim.wall_ms);
    try oracle.turns(check);
    if (value.driver.faults.items.count() != 0)
        return check.fail("I7", "{d} faults remain at rest", .{value.driver.faults.items.count()});
}

fn drive(sim: *Sim, events: usize, at: *usize) !void {
    _ = try openNode(sim, 'A');
    while (at.* < events) : (at.* += 1) {
        const noted = sim.events.items.len;
        var from = sample();
        try act(sim);
        const kind = if (sim.events.items.len > noted) sim.events.items[noted].kind else "noop";
        if (sim.profile.enabled) {
            const to = sample();
            std.debug.print("event {d} {s} wall {d} ms cpu {d} ms records {d}\n", .{
                at.*,                                    kind,
                milliseconds(to.wall_ns - from.wall_ns), @divTrunc(to.cpu_us - from.cpu_us, 1000),
                sim.records,
            });
        }
        try sim.profile.charge(sim.allocator(), if (std.mem.eql(u8, kind, "poll"))
            "event:poll-overhead"
        else
            kind, from);
        from = sample();
        try observe(sim);
        try sim.profile.charge(sim.allocator(), "oracle", from);
    }
    try quiesce(sim);
    try observe(sim);
}

fn milliseconds(nanoseconds: i128) i128 {
    return @divTrunc(nanoseconds, std.time.ns_per_ms);
}

fn printProfile(sim: *const Sim) void {
    std.debug.print("profile seed {d}: kind count wall_ms cpu_ms; worker wait {d} ms\n", .{
        sim.seed, @divTrunc(waited_ns, std.time.ns_per_ms),
    });
    var buckets = sim.profile.buckets.iterator();
    while (buckets.next()) |entry| std.debug.print("  {s} {d} {d} {d}\n", .{
        entry.key_ptr.*,                       entry.value_ptr.count,
        milliseconds(entry.value_ptr.wall_ns), @divTrunc(entry.value_ptr.cpu_us, 1000),
    });
}

pub fn run(seed: u64, events: usize) !Report {
    var sim: Sim = .{
        .arena = .init(gpa),
        .seed = seed,
        .prng = .init(seed),
        .faults = .init(seed ^ 0x5bd1e995),
        .io = Entropy.io(seed),
    };
    defer sim.arena.deinit();
    sim.world = World.init(seed, &sim.wall_ms);
    defer for (sim.nodes.items) |value| destroyNode(value);
    const unverified = std.testing.environ.getPosix("PAREDROS_SIMULATION_UNVERIFIED");
    idx.verify_against_rebuild = unverified == null;
    sim.profile.enabled = std.testing.environ.getPosix("PAREDROS_SIMULATION_PROFILE") != null;
    waited_ns = 0;
    var at: usize = 0;
    defer if (sim.profile.enabled) printProfile(&sim);
    drive(&sim, events, &at) catch |err| {
        if (err != error.Violation)
            sim.violation = .{ .invariant = "E0", .detail = @errorName(err) };
    };
    const report: Report = .{
        .seed = seed,
        .events = at,
        .hash = sim.hasher.finalResult(),
        .calls = sim.world.calls,
        .hops = @intCast(sim.nodes.items.len - 1),
        .injected = sim.injected_faults,
        .violation = if (sim.violation) |found| .{
            .invariant = try gpa.dupe(u8, found.invariant),
            .detail = try gpa.dupe(u8, found.detail),
        } else null,
        .at = at,
    };
    if (std.testing.environ.getPosix("PAREDROS_SIMULATION_TRACE") != null and
        sim.violation == null) printTrace(&sim, report);
    if (sim.violation != null) {
        printTrace(&sim, report);
        dumpState(&sim) catch |err| std.debug.print("state dump: {s}\n", .{@errorName(err)});
    }
    return report;
}

fn dumpState(sim: *Sim) !void {
    const value = sim.node();
    if (value.fixture.service == null) return;
    const catalog = @import("../native/catalog.zig");
    var probe = catalog.rebuild(value.driver.service, sim.allocator(), 128) catch |err| {
        std.debug.print("rebuild fails with {s}\n", .{@errorName(err)});
        return err;
    };
    probe.deinit();
    var index = try value.driver.rebuild(sim.allocator());
    defer index.deinit();
    std.debug.print("state of {c}: {d} records, transferred {}, clock {d}\n", .{
        value.label, index.records.len, index.transferred(), sim.wall_ms,
    });
    for (index.obligations) |*obligation| {
        const current = index.head(obligation);
        std.debug.print("  {s} seq {d} mode {s}/{s} effective {s} folded {d} " ++
            "observed {d} told {d} due {d} live {} pending {} fault {?s}\n", .{
            oracle.hex(obligation.task),         current.sequence,
            @tagName(current.mode),              @tagName(current.desired_mode),
            @tagName(obligation.effective_mode), current.folded_directive_ordinal,
            current.observed.sequence,           current.told.sequence,
            current.schedule.next_due_ms,        obligation.eligible != null,
            obligation.controls_pending,         if (obligation.fault) |f| f.reason else null,
        });
        std.debug.print("    lineage {s} genesis imported {}\n", .{
            short(index.records[obligation.chain[0]].input.genesis.lineage),
            index.records[obligation.chain[0]].input.genesis.imported != null,
        });
        for (obligation.chain) |position| dumpHead(index.records[position]);
        for (obligation.directives) |position| {
            const record = index.records[position];
            std.debug.print("    directive {d} {s} done {}\n", .{
                record.input.directive.ordinal, @tagName(record.input.directive.body),
                record.result != null,
            });
        }
    }
    if (value.driver.index != null) dumpDivergence(sim, value, &index) catch |err|
        std.debug.print("divergence dump: {s}\n", .{@errorName(err)});
    for (value.expectations.items) |expected| std.debug.print("  expected {s} verified {}\n", .{
        short(expected.lineage), expected.verified,
    });
    for (index.records) |record| if (record.result == null)
        std.debug.print("  unfinished {s} {s}\n", .{
            @tagName(record.input), oracle.hex(record.task),
        });
}

fn dumpDivergence(sim: *Sim, value: *Node, rebuilt: *const idx.Index) !void {
    idx.verify_against_rebuild = false;
    defer idx.verify_against_rebuild = true;
    var maintained = try value.driver.view(sim.allocator());
    defer maintained.deinit();
    const kept = &maintained.index;
    std.debug.print("index difference: {s}\n", .{idx.difference(kept, rebuilt) orelse "none"});
    var left = kept.operations.iterator();
    while (left.next()) |entry| {
        const other = rebuilt.operations.get(entry.key_ptr.*);
        if (other == null or !std.meta.eql(
            kept.records[entry.value_ptr.*].task,
            rebuilt.records[other.?].task,
        )) std.debug.print("  maintained operation {s} -> {s} {s}\n", .{
            entry.key_ptr.*,
            oracle.hex(kept.records[entry.value_ptr.*].task),
            @tagName(kept.records[entry.value_ptr.*].input),
        });
    }
    var right = rebuilt.operations.iterator();
    while (right.next()) |entry| {
        if (kept.operations.get(entry.key_ptr.*) != null) continue;
        std.debug.print("  rebuilt operation {s} -> {s} {s}\n", .{
            entry.key_ptr.*,
            oracle.hex(rebuilt.records[entry.value_ptr.*].task),
            @tagName(rebuilt.records[entry.value_ptr.*].input),
        });
    }
}

fn dumpHead(record: idx.Record) void {
    const value = oracle.head(record).?;
    if (record.input == .step) {
        const step = record.input.step;
        std.debug.print("    step {s} attempt {d} fold_only {} folds {d} " ++
            "batches {d} cause {s}\n", .{
            oracle.hex(record.task),
            step.attempt,
            step.fold_only,
            step.directives.items.len,
            step.batches.items.len,
            if (step.supersession) |x| @tagName(x.cause) else "none",
        });
    }
    const result = record.result.?;
    const dispositions = if (result == .step) result.step.dispositions.items.len else 0;
    std.debug.print("    head {d} {s} {s} clock {d} due {d} source {d} render {d} provider {d} " ++
        "skipped {d} regressions {d} interval {d} anchor {d} disposed {d} requested {}\n", .{
        value.sequence,                      @tagName(value.phase),
        @tagName(value.mode),                value.clock_ms,
        value.schedule.next_due_ms,          value.schedule.source_not_before_ms,
        value.schedule.render_not_before_ms, value.schedule.provider_not_before_ms,
        value.skipped_slots,                 value.clock_regressions,
        value.specification.interval_ms,     value.specification.anchor_ms,
        dispositions,                        value.check_requested,
    });
}

fn printTrace(sim: *const Sim, report: Report) void {
    if (report.violation) |found| {
        std.debug.print("simulation seed {d} violated {s} at event {d}: {s}\n", .{
            report.seed, found.invariant, report.at, found.detail,
        });
    } else std.debug.print("simulation seed {d} trace\n", .{report.seed});
    for (sim.events.items, 0..) |event, position|
        std.debug.print("  {d:>4} {s}: {s}\n", .{ position, event.kind, event.detail });
    std.debug.print("replay: zig build test-native -Dnative-tests=true " ++
        "-Dnative-group=simulation -Doptimize=safe -Dsimulation-seed={d}\n", .{report.seed});
}

pub fn free(report: Report) void {
    if (report.violation) |found| {
        gpa.free(found.invariant);
        gpa.free(found.detail);
    }
}

const Pin = struct { seed: u64, events: usize };
const pinned: []const Pin = &.{
    .{ .seed = 2, .events = 60 },
    .{ .seed = 3, .events = 60 },
    .{ .seed = 4, .events = 60 },
    .{ .seed = 5, .events = 60 },
    .{ .seed = 16, .events = 60 },
};

fn selectedPin(position: usize) bool {
    if (position >= 64) return false;
    return options.pins & (@as(u64, 1) << @intCast(position)) != 0;
}

fn pinnedSeed(position: usize) Pin {
    for (pinned, 0..) |pin, at| if (at == position) return pin;
    unreachable;
}

fn expectClean(seed: u64, events: usize) !Report {
    const report = try run(seed, events);
    errdefer free(report);
    if (report.violation != null) return error.SimulationViolation;
    return report;
}

fn setting(name: [:0]const u8, default: u64) u64 {
    const text = std.testing.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(u64, text, 10) catch default;
}

test "simulation holds every invariant across the selected seeds" {
    const events: usize = setting("PAREDROS_SIMULATION_EVENTS", options.events);
    const single = if (std.testing.environ.getPosix("PAREDROS_SIMULATION_SEED")) |_|
        setting("PAREDROS_SIMULATION_SEED", 0)
    else
        options.seed;
    if (single) |seed| {
        free(try expectClean(seed, events));
        return;
    }
    const started = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    var calls: world_module.Calls = .{};
    var hops: u64 = 0;
    var injected: u64 = 0;
    var ran: u64 = 0;
    const seeds = setting("PAREDROS_SIMULATION_SEEDS", options.seeds);
    const first = setting("PAREDROS_SIMULATION_FIRST", options.first);
    const count = (if (first == options.first) pinned.len else 0) + seeds;
    const pins = count - seeds;
    for (0..count) |position| {
        if (position < pins and !selectedPin(position)) continue;
        const pin: Pin = if (position < pins)
            pinnedSeed(position)
        else
            .{ .seed = first + position - pins, .events = events };
        const seed = pin.seed;
        const begun = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
        const report = try expectClean(seed, pin.events);
        ran += 1;
        if (options.progress) std.debug.print("seed {d}: {d} ms, {d} hops\n", .{
            seed, std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - begun, report.hops,
        });
        calls.github += report.calls.github;
        calls.model += report.calls.model;
        calls.faults += report.calls.faults;
        injected += report.injected;
        hops += report.hops;
        free(report);
    }
    const elapsed = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started;
    std.debug.print("simulation: {d} seeds x {d} events in {d} ms; github {d}, model {d}, " ++
        "provider faults {d}, injected faults {d}, hops {d}\n", .{
        ran, events, elapsed, calls.github, calls.model, calls.faults, injected, hops,
    });
}

test "simulation replays one seed to the same trace" {
    if (std.testing.environ.getPosix("PAREDROS_SIMULATION_SEED") != null) return error.SkipZigTest;
    const seed = options.seed orelse options.first;
    const first = try expectClean(seed, 20);
    defer free(first);
    const second = try expectClean(seed, 20);
    defer free(second);
    try std.testing.expectEqualDeep(first.hash, second.hash);
}
