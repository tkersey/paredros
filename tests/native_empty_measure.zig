const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const github = @import("../native/github_external.zig");
const contract = @import("../app/github_contract.zig");
const Driver = @import("../native/driver.zig").Driver(t);
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
    clock_ms = head.next_due_ms;
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

pub fn run(path: []const u8) !void {
    var f: Fixture = .{};
    defer f.deinit();
    try f.initWithGrants(&.{contract.identity});
    try f.close();
    f.temporary.?.cleanup();
    f.temporary = null;
    f.path = path;
    try f.open();
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
    const samples = if (std.testing.environ.getPosix("PAREDROS_EMPTY_SAMPLES")) |value|
        try std.fmt.parseInt(u32, value, 10)
    else
        31;
    if (samples == 0 or samples > 31) return error.InvalidArguments;
    for (0..samples) |n| try sample(&f, &driver, &session, target, @intCast(n));
}
