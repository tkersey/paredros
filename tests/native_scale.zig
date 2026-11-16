const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const catalog = @import("../native/catalog.zig");
const configuration = @import("../native/configuration.zig");
const examples = @import("contracts.zig");
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};
const Fixture = @import("native_fixture.zig").Fixture(t, Application);

fn emit(value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(std.testing.io, &buffer);
    try std.json.Stringify.value(value, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn now() i96 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}

fn execute(a: std.mem.Allocator, service: *native.tasks.Service(t), input: t.Input) !t.Id {
    const operation = switch (input) {
        inline else => |value| value.envelope.operation.bytes,
    };
    const id = (try service.submit(a, operation, input)).receipt.task;
    for (0..65536) |_| {
        var saved = try service.task(a, id);
        defer saved.deinit();
        if (saved.value.terminal()) {
            if (saved.value.outcome_kind != .completed) return error.BenchmarkTaskFailed;
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
    return error.BenchmarkTaskIncomplete;
}

fn previous(service: *native.tasks.Service(t), ordinal: u64) !?t.InputReference {
    if (ordinal == 1) return null;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const operation = try std.fmt.allocPrint(a, "scale-directive:{d}", .{ordinal - 1});
    var receipt = (try service.operationLookup(a, operation)) orelse return error.MissingPredecessor;
    defer receipt.deinit();
    var input = (try service.applicationValue(a, receipt.value.task, .input)).?;
    defer input.deinit();
    return .{ .task = receipt.value.task, .digest = @import("../native/index.zig").digest(input.bytes) };
}

fn seed(f: *Fixture, first: u64, last: u64) !void {
    var genesis = examples.genesis();
    genesis.envelope.operation = .{ .bytes = "scale-genesis" };
    const target = try execute(f.arena.allocator(), &f.service.?, .{ .genesis = genesis });
    var prior = try previous(&f.service.?, first);
    for (first..last + 1) |ordinal| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const operation = try std.fmt.allocPrint(a, "scale-directive:{d}", .{ordinal});
        const input: t.Input = .{ .directive = .{
            .envelope = .{
                .operation = .{ .bytes = operation },
                .stable_request = @import("../native/index.zig").digest(operation),
                .origin = .{ .local = .{ .uid = 501 } },
            },
            .obligation = target,
            .ordinal = ordinal,
            .predecessor = prior,
            .body = .pause,
        } };
        const started = now();
        const id = try execute(a, &f.service.?, input);
        const elapsed = now() - started;
        const bytes = try c.encodeOwned(t.Input, a, input);
        prior = .{ .task = id, .digest = @import("../native/index.zig").digest(bytes) };
        try emit(.{ .directive = ordinal, .owner_nanoseconds = elapsed });
    }
}

fn measure(f: *Fixture) !void {
    try f.close();
    const startup = now();
    try f.open();
    const startup_ns = now() - startup;
    const rebuild = now();
    var index = try catalog.rebuild(&f.service.?, std.testing.allocator, 128);
    defer index.deinit();
    try emit(.{
        .terminal_tasks = index.records.len,
        .startup_nanoseconds = startup_ns,
        .rebuild_nanoseconds = now() - rebuild,
        .obligations = index.obligations.len,
    });
}

fn productLaunch(f: *Fixture) !?*configuration.OwnedLaunch {
    const env = std.testing.environ;
    const path = env.getPosix("PAREDROS_SCALE_CONFIG") orelse return null;
    const runtime_hex = env.getPosix("PAREDROS_SCALE_RUNTIME") orelse return error.InvalidArguments;
    var runtime: t.Digest = undefined;
    if (runtime_hex.len != runtime.len * 2) return error.InvalidArguments;
    _ = try std.fmt.hexToBytes(&runtime, runtime_hex);
    var config = try configuration.load(
        std.testing.allocator,
        std.testing.io,
        path,
        std.c.geteuid(),
    );
    defer config.deinit();
    if (config.value.mode != .offline) return error.LiveMeasurementForbidden;
    if (!std.mem.eql(u8, config.value.namespace_path, f.path))
        return error.InvalidMeasurementNamespace;
    return configuration.prepare(std.testing.allocator, std.testing.io, config.value, .{
        .runtime_identity = runtime,
        .image_identity = f.application.?.image_identity,
    });
}

test "native scale measurement" {
    const env = std.testing.environ;
    const path = env.getPosix("PAREDROS_SCALE_PATH") orelse return error.InvalidArguments;
    const mode = env.getPosix("PAREDROS_SCALE_MODE") orelse return error.InvalidArguments;
    if (std.mem.eql(u8, mode, "empty")) return @import("native_empty_measure.zig").run(path);
    var launch: ?*configuration.OwnedLaunch = null;
    defer if (launch) |value| value.deinit();
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    try f.close();
    f.temporary.?.cleanup();
    f.temporary = null;
    f.path = path;
    launch = try productLaunch(&f);
    if (launch) |value| f.profile = value.profile;
    try f.open();
    if (std.mem.eql(u8, mode, "seed")) {
        const first = try std.fmt.parseInt(u64, env.getPosix("PAREDROS_SCALE_FIRST") orelse return error.InvalidArguments, 10);
        const last = try std.fmt.parseInt(u64, env.getPosix("PAREDROS_SCALE_LAST") orelse return error.InvalidArguments, 10);
        if (first == 0 or first > last or last > 100000) return error.InvalidArguments;
        try seed(&f, first, last);
    } else if (std.mem.eql(u8, mode, "measure")) {
        try measure(&f);
    } else return error.InvalidArguments;
}
