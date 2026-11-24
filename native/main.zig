const std = @import("std");
const native = @import("protean_native");
const t = @import("application_types");
const application = @import("application.zig");
const configuration = @import("configuration.zig");
const compatibility = @import("compatibility.zig");
const control = @import("control.zig");
const cli = @import("cli.zig");
const socket = @import("control_socket.zig");
const restore = @import("restore.zig");
const continuity_control = @import("continuity_control.zig");
const Driver = @import("driver.zig").Driver(t);
const Daemon = @import("daemon.zig").Daemon(t);
var stop_requests: std.atomic.Value(u32) = .init(0);

const Arguments = struct {
    config: ?[]const u8,
    command: []const []const u8,

    fn parse(a: std.mem.Allocator, init: std.process.Init) !Arguments {
        var iterator = init.minimal.args.iterate();
        _ = iterator.next();
        var config: ?[]const u8 = null;
        var command: std.ArrayList([]const u8) = .empty;
        var flags = true;
        while (iterator.next()) |value| {
            if (flags and same(value, "--")) {
                flags = false;
            } else if (flags and same(value, "--config")) {
                if (config != null) return error.DuplicateConfig;
                config = iterator.next() orelse return error.MissingConfigPath;
            } else try command.append(a, value);
        }
        return .{ .config = config, .command = try command.toOwnedSlice(a) };
    }
};

pub fn run(init: std.process.Init, assets: native.discovery.Assets) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const args = try Arguments.parse(arena.allocator(), init);
    if (args.command.len == 0 or same(args.command[0], "--help")) {
        try output(init.io, cli.help);
        return 0;
    }
    const command = args.command[0];
    if (same(command, "--version")) {
        if (args.command.len != 1) return error.InvalidArguments;
        try output(init.io, "paredros " ++ t.application_version);
        return 0;
    }
    if (same(command, "describe-build") or same(command, "licenses")) {
        if (args.config != null or args.command.len != 1) return error.InvalidArguments;
        return describeBuild(init, assets);
    }
    const path = args.config orelse return error.MissingConfigPath;
    var config = try configuration.load(init.gpa, init.io, path, socket.currentUid());
    defer config.deinit();
    if (same(command, "serve")) {
        const recover = args.command.len == 2 and same(args.command[1], "--recover");
        if (args.command.len != 1 and !recover) return error.InvalidArguments;
        const config_path = try cli.callerPath(arena.allocator(), init.io, path);
        return serve(init, assets, config.value, config_path, recover);
    }
    if (same(command, "namespace")) {
        if (args.command.len != 2 or !same(args.command[1], "check")) return error.InvalidArguments;
        return checkNamespace(init, assets, config.value);
    }
    return client(init, config.value, args.command);
}

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn output(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n')
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn describeBuild(init: std.process.Init, assets: native.discovery.Assets) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var handlers = try native.Registry.init(a, application.Application.declarations);
    defer handlers.deinit();
    var admitted = try native.discovery.Application.init(t, a, assets, handlers);
    defer admitted.deinit();
    try output(init.io, try admitted.describeBuild(a, init.io));
    return 0;
}

fn client(init: std.process.Init, config: configuration.Config, supplied: []const []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const args = try cli.callerArguments(arena.allocator(), init.io, supplied);
    const command = (try cli.invocation(arena.allocator(), args)).command;
    const request = try clientRequest(init, config, supplied, args, command);
    defer if (request) |bytes| init.gpa.free(bytes);
    var connection = try socket.Client.init(init.gpa, config.control_socket_path, .{
        .expected_server_uid = config.current_uid,
        .max_frame_bytes = control.frame_bytes_max,
    });
    defer connection.deinit();
    if (request == null) return relay(init, &connection);
    const response = try connection.request(request.?);
    defer init.gpa.free(response);
    const name = if (command.len == 0) "" else command[0];
    if (same(name, "transfer") and try responseCode(init.gpa, response) == 0)
        return awaitTransfer(init, &connection, request.?, response);
    if (same(name, "ask") and try responseCode(init.gpa, response) == 0)
        return awaitTurn(init, &connection, response) catch |err| {
            try output(init.io, response);
            return err;
        };
    try output(init.io, response);
    return responseCode(init.gpa, response);
}

fn awaitTransfer(
    init: std.process.Init,
    connection: *socket.Client,
    request: []const u8,
    initial: []const u8,
) !u8 {
    var response = try init.gpa.dupe(u8, initial);
    defer init.gpa.free(response);
    const start = std.Io.Clock.awake.now(init.io).toMilliseconds();
    for (0..1500) |_| {
        const code = try responseCode(init.gpa, response);
        if (code != 0 or try transferFinished(init.gpa, response)) {
            try output(init.io, response);
            return code;
        }
        if (@as(i128, std.Io.Clock.awake.now(init.io).toMilliseconds()) - start >= 300_000)
            break;
        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
        const next = try connection.request(request);
        init.gpa.free(response);
        response = next;
    }
    try output(init.io, response);
    try resumeHint(init, response);
    return 75;
}

fn resumeHint(init: std.process.Init, bytes: []const u8) !void {
    var parsed = try native.json.parse(init.gpa, bytes, .{ .bytes = control.frame_bytes_max });
    defer parsed.deinit();
    const data = native.json.get(parsed.value, "data") orelse return error.InvalidResponse;
    const message = if (native.json.get(data, "name")) |name| try std.fmt.allocPrint(
        init.gpa,
        "paredros: export {s} is still in progress; resume it with " ++
            "`transfer export {s}` plus the same flags and --operation {s}\n",
        .{
            try native.json.text(name),
            try native.json.text(name),
            try native.json.text(native.json.get(data, "operation") orelse
                return error.InvalidResponse),
        },
    ) else try init.gpa.dupe(
        u8,
        "paredros: the daemon continues this import; repeat the command to observe it\n",
    );
    defer init.gpa.free(message);
    try std.Io.File.stderr().writeStreamingAll(init.io, message);
}

fn transferFinished(a: std.mem.Allocator, bytes: []const u8) !bool {
    var parsed = try native.json.parse(a, bytes, .{ .bytes = control.frame_bytes_max });
    defer parsed.deinit();
    const data = native.json.get(parsed.value, "data") orelse return error.InvalidResponse;
    const phase = try native.json.text(native.json.get(data, "phase") orelse
        return error.InvalidResponse);
    return same(phase, "written") or same(phase, "materialized");
}

fn clientRequest(
    init: std.process.Init,
    config: configuration.Config,
    supplied: []const []const u8,
    args: []const []const u8,
    command: []const []const u8,
) !?[]const u8 {
    if (same(supplied[0], "stdio")) {
        if (supplied.len != 1) return error.InvalidArguments;
        return null;
    }
    const operation = try cli.defaultOperation(
        init.gpa,
        init.io,
        config.namespace_path,
        config.backup_directory,
        command,
    );
    defer init.gpa.free(operation);
    return try cli.request(init.gpa, args, operation);
}

fn responseCode(a: std.mem.Allocator, bytes: []const u8) !u8 {
    var parsed = try native.json.parse(a, bytes, .{ .bytes = control.frame_bytes_max });
    defer parsed.deinit();
    const schema = try native.json.text(native.json.get(parsed.value, "schema") orelse
        return error.InvalidResponse);
    if (!same(schema, "paredros.control.v1")) return error.InvalidResponse;
    const status = try native.json.text(native.json.get(parsed.value, "status") orelse
        return error.InvalidResponse);
    if (same(status, "rejected")) return 1;
    if (same(status, "admitted") or same(status, "observed")) return 0;
    return error.InvalidResponse;
}

fn awaitTurn(init: std.process.Init, connection: *socket.Client, admission: []const u8) !u8 {
    var parsed = try native.json.parse(init.gpa, admission, .{ .bytes = control.frame_bytes_max });
    defer parsed.deinit();
    const data = native.json.get(parsed.value, "data") orelse return error.InvalidResponse;
    const task = try native.json.text(native.json.get(data, "task") orelse
        return error.InvalidResponse);
    const request = try control.encode(init.gpa, .{
        .version = 1,
        .operation = null,
        .command = .{ .task_show = try cli.hex(t.Id, task) },
    });
    defer init.gpa.free(request);
    const started = std.Io.Clock.awake.now(init.io).toMilliseconds();
    for (0..1500) |_| {
        const response = try connection.request(request);
        defer init.gpa.free(response);
        if (try turnCode(init.gpa, response)) |code| {
            try output(init.io, response);
            return code;
        }
        const elapsed = @as(i128, std.Io.Clock.awake.now(init.io).toMilliseconds()) - started;
        if (elapsed >= 300_000) {
            try output(init.io, response);
            return 75;
        }
        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
    }
    try output(init.io, admission);
    return 75;
}

fn turnCode(a: std.mem.Allocator, bytes: []const u8) !?u8 {
    if (try responseCode(a, bytes) != 0) return 1;
    var parsed = try native.json.parse(a, bytes, .{ .bytes = control.frame_bytes_max });
    defer parsed.deinit();
    const data = native.json.get(parsed.value, "data") orelse return error.InvalidResponse;
    if (native.json.get(data, "retry_pending")) |pending| {
        if (pending != .bool) return error.InvalidResponse;
        if (pending.bool) return null;
    }
    const status = try native.json.text(native.json.get(data, "task_status") orelse
        return error.InvalidResponse);
    const value = std.meta.stringToEnum(native.tasks.Status, status) orelse
        return error.InvalidResponse;
    return switch (value) {
        .completed => 0,
        .queued, .running, .cancelling => null,
        .waiting_input, .parked, .blocked, .unknown, .failed, .cancelled => 1,
    };
}

fn relay(init: std.process.Init, connection: *socket.Client) !u8 {
    const buffer = try init.gpa.alloc(u8, control.frame_bytes_max + 1);
    defer init.gpa.free(buffer);
    var input = std.Io.File.stdin().reader(init.io, buffer);
    var code: u8 = 0;
    while (try input.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        const response = try connection.request(line);
        defer init.gpa.free(response);
        try output(init.io, response);
        code = @max(code, try responseCode(init.gpa, response));
    }
    return code;
}

fn audit(
    a: std.mem.Allocator,
    io: std.Io,
    config: configuration.Config,
    registry: native.Registry,
    admitted: *const native.discovery.Application,
    runtime: t.Digest,
    selected_profile: ?native.tasks.Profile,
) !compatibility.OwnedReport {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const profile = selected_profile orelse native.tasks.Profile{
        .id = "paredros.launch.v1",
        .runtime_identity = runtime,
        .bytes = try configuration.profileBytes(scratch, config, null),
        .authority = .{
            .principal = try std.fmt.allocPrint(scratch, "uid:{d}", .{config.current_uid}),
            .tenant = configuration.tenant,
            .grants = &.{},
            .inference = false,
            .disclosure = true,
        },
    };
    var candidate = try compatibility.fromProfile(
        scratch,
        admitted.image_identity,
        admitted.controller != null,
        profile,
    );
    if (selected_profile == null and config.mode == .live and config.grants.model)
        candidate.profile = null;
    return compatibility.audit(a, io, config.namespace_path, registry, candidate);
}

fn preflight(
    init: std.process.Init,
    config: configuration.Config,
    handlers: native.Registry,
    admitted: *const native.discovery.Application,
    runtime: t.Digest,
    profile: ?native.tasks.Profile,
) !void {
    var report = try audit(init.gpa, init.io, config, handlers, admitted, runtime, profile);
    defer report.deinit();
    if (profile != null and !report.value.complete()) return error.UnresolvedExecutionBinding;
}

fn checkNamespace(
    init: std.process.Init,
    assets: native.discovery.Assets,
    config: configuration.Config,
) !u8 {
    var handlers = try native.Registry.init(init.gpa, application.Application.declarations);
    defer handlers.deinit();
    var admitted = try native.discovery.Application.init(t, init.gpa, assets, handlers);
    defer admitted.deinit();
    var report = try audit(
        init.gpa,
        init.io,
        config,
        handlers,
        &admitted,
        (try executableIdentity(init.io)).sha256,
        null,
    );
    defer report.deinit();
    const complete = report.value.complete();
    const bytes = try std.json.Stringify.valueAlloc(init.gpa, .{
        .schema = "paredros.namespace-check.v1",
        .status = if (complete) "audited" else "incomplete",
        .build = admitted.manifest_id,
        .report = report.value,
    }, .{});
    defer init.gpa.free(bytes);
    try output(init.io, bytes);
    return if (complete) 0 else 75;
}

fn nonempty(io: std.Io, path: []const u8) !bool {
    var directory = std.Io.Dir.openDirAbsolute(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    return try iterator.next(io) != null;
}

const ArtifactIdentity = struct { sha256: t.Digest, bytes: u64 };

fn executableIdentity(io: std.Io) !ArtifactIdentity {
    const file = try std.process.openExecutable(io, .{});
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.size == 0) return error.InvalidNativeArtifact;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var length: u64 = 0;
    while (length < before.size) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => return error.NativeArtifactChanged,
            else => return err,
        };
        if (count == 0) return error.NativeArtifactChanged;
        length = try std.math.add(u64, length, count);
        if (length > before.size) return error.NativeArtifactChanged;
        hasher.update(buffer[0..count]);
    }
    const after = try file.stat(io);
    if (before.inode != after.inode or before.size != after.size or
        !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime))
        return error.NativeArtifactChanged;
    return .{ .sha256 = hasher.finalResult(), .bytes = length };
}

fn wallTime(context: *anyopaque) !i64 {
    const io: *const std.Io = @ptrCast(@alignCast(context));
    return std.Io.Clock.real.now(io.*).toMilliseconds();
}

fn dispatch(
    context: *anyopaque,
    a: std.mem.Allocator,
    driver: *Driver,
    uid: u32,
    bytes: []const u8,
) ![]const u8 {
    return dispatchObserved(context, a, driver, uid, bytes, null);
}

fn dispatchAttached(
    context: *anyopaque,
    a: std.mem.Allocator,
    driver: *Driver,
    uid: u32,
    bytes: []const u8,
    index: *const @import("index.zig").Index,
) ![]const u8 {
    return dispatchObserved(context, a, driver, uid, bytes, index);
}

fn dispatchObserved(
    context: *anyopaque,
    a: std.mem.Allocator,
    driver: *Driver,
    uid: u32,
    bytes: []const u8,
    index: ?*const @import("index.zig").Index,
) ![]const u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return control.dispatchWithIndex(
        a,
        driver,
        runtime.config.*,
        uid,
        bytes,
        runtime.continuity,
        index,
        runtime.config_path,
    );
}

const Runtime = struct {
    config: *configuration.Config,
    config_path: []const u8,
    continuity: continuity_control.Environment,
};

fn serve(
    init: std.process.Init,
    assets: native.discovery.Assets,
    config: configuration.Config,
    config_path: []const u8,
    recover: bool,
) !u8 {
    const a = init.gpa;
    var io = init.io;
    var handlers = try native.Registry.init(a, application.Application.declarations);
    defer handlers.deinit();
    var admitted = try native.discovery.Application.init(t, a, assets, handlers);
    defer admitted.deinit();
    const existing = try nonempty(io, config.namespace_path);
    const runtime = (try executableIdentity(io)).sha256;
    if (existing and config.mode == .live)
        try preflight(init, config, handlers, &admitted, runtime, null);
    const launch = try configuration.prepare(a, io, config, .{
        .runtime_identity = runtime,
        .image_identity = admitted.image_identity,
    });
    defer launch.deinit();
    if (existing) try preflight(init, config, handlers, &admitted, runtime, launch.profile);
    var namespace = try native.Namespace.open(a, io, config.namespace_path);
    defer namespace.close() catch |err| fatal(err);
    var service = try native.tasks.Service(t).init(
        a,
        io,
        &namespace,
        assets,
        &admitted,
        handlers,
        launch.profile,
    );
    defer service.close(a) catch |err| fatal(err);
    var signals = Signals.install();
    defer signals.restore();
    var server = try socket.Server.init(a, config.control_socket_path, .{
        .operator_uid = config.current_uid,
        .max_frame_bytes = control.frame_bytes_max,
    });
    defer server.deinit();
    var driver = daemonDriver(&service, &io, launch);
    var runtime_context: Runtime = .{
        .config = &launch.config,
        .config_path = config_path,
        .continuity = try continuityEnvironment(io, &namespace, &admitted, runtime),
    };
    var daemon = try Daemon.init(a, &driver, &server, .{
        .context = &runtime_context,
        .call = dispatch,
        .observation = .{
            .on_start = !recover and config.mode == .offline,
            .enabled = acceptingControls,
            .read_only = control.observingFrame,
            .call = dispatchAttached,
        },
    }, .{ .stop_grace_ms = 45_000 });
    defer releaseDaemon(a, io, &daemon);
    if (recover) try beginRecovery(a, io, &driver, config.current_uid);
    return loop(a, io, &daemon);
}

fn daemonDriver(service: *native.tasks.Service(t), io: *std.Io, launch: anytype) Driver {
    return .{
        .service = service,
        .clock = .{ .context = io, .now = wallTime },
        .model = if (launch.model_binding) |binding| binding.value else null,
        .bindings = configuration.bindings(launch.config),
    };
}

fn continuityEnvironment(
    io: std.Io,
    namespace: *const native.Namespace,
    admitted: *const native.discovery.Application,
    runtime: t.Digest,
) !continuity_control.Environment {
    return .{ .io = io, .source = .{
        .namespace = namespace.identity,
        .build = try cli.hex(t.Digest, admitted.manifest_id),
        .image = admitted.image_identity,
        .runtime = runtime,
        .contracts = try cli.hex(t.Digest, admitted.protocol_schema_sha256),
        .clock_ms = 0,
    } };
}

fn acceptingControls() bool {
    return stop_requests.load(.acquire) == 0;
}

fn beginRecovery(a: std.mem.Allocator, io: std.Io, driver: *Driver, uid: u32) !void {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const operation = try std.fmt.allocPrint(a, "restore:{s}", .{
        std.fmt.bytesToHex(random, .lower),
    });
    defer a.free(operation);
    _ = try restore.begin(driver, a, operation, .{ .local = .{ .uid = uid } });
}

const Signals = struct {
    interrupt: std.posix.Sigaction,
    terminate: std.posix.Sigaction,

    fn install() Signals {
        stop_requests.store(0, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = stop },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var result: Signals = undefined;
        std.posix.sigaction(.INT, &action, &result.interrupt);
        std.posix.sigaction(.TERM, &action, &result.terminate);
        return result;
    }

    fn restore(self: *Signals) void {
        std.posix.sigaction(.INT, &self.interrupt, null);
        std.posix.sigaction(.TERM, &self.terminate, null);
    }

    fn stop(_: std.posix.SIG) callconv(.c) void {
        _ = stop_requests.fetchAdd(1, .monotonic);
    }
};

fn fatal(err: anyerror) noreturn {
    const code = native.reportFailure(err);
    std.process.exit(if (code == 0) 70 else code);
}

fn loop(a: std.mem.Allocator, io: std.Io, daemon: *Daemon) !u8 {
    while (true) { // tiger: event-loop
        const requested = stop_requests.load(.acquire);
        if (requested > 1) fatal(error.ForcedShutdown);
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (requested != 0) daemon.beginStop(now);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        switch (try daemon.poll(arena.allocator(), now)) {
            .stopped => return 0,
            .stopped_unclean => return 1,
            .force_exit_required => fatal(error.WorkerShutdownDeadline),
            .progressed => {},
            .idle => try std.Io.sleep(io, .fromMilliseconds(20), .awake),
        }
    }
}

fn releaseDaemon(a: std.mem.Allocator, io: std.Io, daemon: *Daemon) void {
    daemon.beginStop(std.Io.Clock.awake.now(io).toMilliseconds());
    _ = loop(a, io, daemon) catch |err| fatal(err);
    daemon.deinit() catch |err| fatal(err);
}
