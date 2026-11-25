const std = @import("std");
const native = @import("protean_native");
const t = @import("application_types");
const control = @import("control.zig");
const commands = @import("commands.zig");
const wire = @import("wire.zig");
const Command = @FieldType(control.Request, "command");

pub const help =
    \\paredros --config PATH COMMAND
    \\  serve                             Run the daemon
    \\  status [--after ID] [--limit N]    Inspect durable state
    \\  ask TEXT [--target ID]            Admit a conversation turn
    \\  monitor add [--wording TEXT] [--interval-ms N]
    \\  monitor list | show ID | check ID | pause ID | resume ID | cancel ID
    \\  monitor directives ID [--after ORDINAL] [--limit N]
    \\  monitor amend ID REVISION [--interval-ms N] [--wording TEXT] [--policies-json JSON]
    \\  messages ID [--after ORDINAL] [--limit N]  Read local updates
    \\  question answer ID QUESTION_DIGEST CHOICE
    \\  proposal show | confirm REQUEST_DIGEST:ATTEMPT:ORDINAL
    \\  task show ID                     Inspect admitted input and result
    \\  method show ID | revert ID REVISION | adopt ID REVISION METHOD_JSON
    \\  experiment run CAMPAIGN ATTEMPT PLAN_JSON [--live] | show CAMPAIGN
    \\  namespace check                   Audit without modifying
    \\  transfer export NAME [--snapshot]
    \\  transfer import PATH [--bytes-max N] [--sha256 DIGEST]
    \\  request JSON | stdio              Machine-readable daemon access
    \\Mutations accept --operation ID; new IDs may not contain `:`.
    \\Success means admission, not remote completion. Intervals are 1 to 31622400000 ms.
    \\paredros describe-build | licenses  Build identities and notices (no --config)
;

pub const Invocation = struct { operation: ?[]const u8, command: []const []const u8 };

pub fn invocation(a: std.mem.Allocator, args: []const []const u8) !Invocation {
    var command: std.ArrayList([]const u8) = .empty;
    var operation: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!same(args[i], "--operation")) {
            try command.append(a, args[i]);
            continue;
        }
        if (operation != null or i + 1 == args.len) return error.InvalidArguments;
        i += 1;
        operation = args[i];
    }
    return .{ .operation = operation, .command = try command.toOwnedSlice(a) };
}

pub fn defaultOperation(
    a: std.mem.Allocator,
    io: std.Io,
    namespace: []const u8,
    backup_directory: ?[]const u8,
    command: []const []const u8,
) ![]u8 {
    if (command.len == 0 or !same(command[0], "transfer") or snapshotExport(command)) {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        return a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
    }
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .namespace = namespace,
        .backup_directory = backup_directory,
        .arguments = command,
    }, .{});
    defer a.free(bytes);
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn callerPath(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidArguments;
    if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    return joinPath(a, try std.process.currentPathAlloc(io, a), path);
}

pub fn joinPath(a: std.mem.Allocator, directory: []const u8, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(directory) or path.len == 0) return error.InvalidArguments;
    if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    const separator = if (std.mem.endsWith(u8, directory, "/")) "" else "/";
    return std.mem.concat(a, u8, &.{ directory, separator, path });
}

pub fn callerArguments(
    a: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) ![]const []const u8 {
    const parsed = try invocation(a, args);
    const command = try a.dupe([]const u8, parsed.command);
    if (command.len >= 3 and same(command[0], "transfer") and same(command[1], "import"))
        command[2] = try callerPath(a, io, command[2]);
    const operation = parsed.operation orelse return command;
    return std.mem.concat(a, []const u8, &.{ command, &.{ "--operation", operation } });
}

pub fn bundleArguments(
    a: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) ![]const []const u8 {
    const command = (try invocation(a, args)).command;
    if (command.len < 3 or !same(command[0], "transfer") or !same(command[1], "import"))
        return args;
    for (command[3..]) |arg| if (same(arg, "--sha256")) return args;
    const digest = wire.hex(try fileDigest(io, command[2]));
    return std.mem.concat(a, []const u8, &.{ args, &.{ "--sha256", try a.dupe(u8, &digest) } });
}

pub fn fileDigest(io: std.Io, path: []const u8) !t.Digest {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    const size = (try file.stat(io)).size;
    var length: u64 = 0;
    while (length < size) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => return error.BundleChanged,
            else => return err,
        };
        if (count == 0) return error.BundleChanged;
        length = try std.math.add(u64, length, count);
        if (length > size) return error.BundleChanged;
        hasher.update(buffer[0..count]);
    }
    return hasher.finalResult();
}

fn snapshotExport(command: []const []const u8) bool {
    if (command.len < 3 or !same(command[1], "export")) return false;
    for (command[3..]) |arg| if (same(arg, "--snapshot")) return true;
    return false;
}

pub fn request(
    a: std.mem.Allocator,
    args: []const []const u8,
    generated_operation: []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = try invocation(scratch, args);
    const operation = parsed.operation orelse generated_operation;
    const values = parsed.command;
    if (values.len == 2 and std.mem.eql(u8, values[0], "request")) {
        var json = try native.json.parse(scratch, values[1], .{});
        defer json.deinit();
        const decoded = try wire.fromJson(control.Request, scratch, json.value);
        return control.encode(a, decoded);
    }
    const command = try parse(scratch, values);
    const mutation = switch (command) {
        .status,
        .monitor_show,
        .monitor_directives,
        .messages,
        .task_show,
        .method_show,
        .proposal_show,
        .experiment_show,
        => false,
        else => true,
    };
    return control.encode(a, .{
        .version = 1,
        .operation = if (mutation) .{ .bytes = operation } else null,
        .command = command,
    });
}

fn parse(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 0) return error.MissingCommand;
    const name = args[0];
    if (same(name, "status")) return status(args[1..]);
    if (same(name, "monitor")) return monitor(a, args[1..]);
    if (same(name, "ask")) return ask(args[1..]);
    if (same(name, "messages")) return messagePage(args[1..]);
    if (same(name, "task") and args.len == 3 and same(args[1], "show"))
        return .{ .task_show = try wire.parse(t.Id, args[2]) };
    if (same(name, "proposal")) return proposal(args[1..]);
    if (same(name, "experiment")) return experiment(a, args[1..]);
    if (same(name, "question") and args.len == 5 and same(args[1], "answer"))
        return directive(try wire.parse(t.Id, args[2]), .{ .answer = .{
            .question = try wire.parse(t.Digest, args[3]),
            .choice = .{ .bytes = args[4] },
        } });
    if (same(name, "method")) return method(a, args[1..]);
    if (same(name, "transfer")) return transfer(args[1..]);
    return error.InvalidArguments;
}

fn transfer(args: []const []const u8) !Command {
    if (args.len < 2) return error.InvalidArguments;
    if (same(args[0], "export")) {
        if (args.len > 3 or (args.len == 3 and !same(args[2], "--snapshot")))
            return error.InvalidArguments;
        return .{ .transfer_export = .{
            .name = .{ .bytes = args[1] },
            .snapshot = args.len == 3,
        } };
    }
    if (!same(args[0], "import")) return error.InvalidArguments;
    if (!std.fs.path.isAbsolute(args[1])) return error.RelativeTransferPath;
    var bytes_max: ?u64 = null;
    var digest: ?t.Digest = null;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (same(args[i], "--bytes-max") and bytes_max == null) {
            bytes_max = try number(u64, args[i + 1]);
        } else if (same(args[i], "--sha256") and digest == null) {
            digest = try wire.parse(t.Digest, args[i + 1]);
        } else return error.InvalidArguments;
    }
    if (i != args.len) return error.InvalidArguments;
    return .{ .transfer_import = .{
        .path = .{ .bytes = args[1] },
        .digest = digest orelse return error.MissingBundleDigest,
        .bytes_max = bytes_max,
    } };
}

fn proposal(args: []const []const u8) !Command {
    if (args.len != 2) return error.InvalidArguments;
    const value: commands.ProposalSelector = .{
        .identity = try wire.parse(commands.ProposalIdentity, args[1]),
    };
    if (same(args[0], "show")) return .{ .proposal_show = value };
    if (same(args[0], "confirm")) return .{ .proposal_confirm = value };
    return error.InvalidArguments;
}

fn experiment(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 2 and same(args[0], "show"))
        return .{ .experiment_show = try wire.parse(t.Digest, args[1]) };
    if (args.len < 4 or args.len > 5 or !same(args[0], "run")) return error.InvalidArguments;
    const live = args.len == 5;
    if (live and !same(args[4], "--live")) return error.InvalidArguments;
    return .{ .experiment_run = .{
        .campaign = try wire.parse(t.Digest, args[1]),
        .attempt = try number(u32, args[2]),
        .plan = try decode(@import("../app/experiment_contract.zig").Plan, a, args[3]),
        .live_model = live,
    } };
}

pub fn commandLine(
    a: std.mem.Allocator,
    config_path: []const u8,
    args: []const []const u8,
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(a);
    try line.appendSlice(a, "paredros --config ");
    try quote(a, &line, config_path);
    for (args) |arg| {
        try line.append(a, ' ');
        try quote(a, &line, arg);
    }
    return line.toOwnedSlice(a);
}

fn quote(a: std.mem.Allocator, line: *std.ArrayList(u8), arg: []const u8) !void {
    for (arg) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "%+,-./:=@_", byte) == null) break;
    } else if (arg.len != 0) return line.appendSlice(a, arg);
    try line.append(a, '\'');
    for (arg) |byte| {
        if (byte == '\'') try line.appendSlice(a, "'\\''") else try line.append(a, byte);
    }
    try line.append(a, '\'');
}

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn number(comptime T: type, value: []const u8) !T {
    return wire.number(T, value);
}

fn decode(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !T {
    return wire.argument(T, a, bytes);
}

fn directive(target: t.Id, body: commands.CallerDirective) Command {
    return .{ .directive = .{ .target = target, .body = body } };
}

fn status(args: []const []const u8) !Command {
    var value: @FieldType(Command, "status") = .{ .after = null, .limit = 16 };
    var seen_after = false;
    var seen_limit = false;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.InvalidArguments;
        if (same(args[i], "--after") and !seen_after) {
            seen_after = true;
            value.after = try wire.parse(t.Id, args[i + 1]);
        } else if (same(args[i], "--limit") and !seen_limit) {
            seen_limit = true;
            value.limit = try number(u32, args[i + 1]);
        } else return error.InvalidArguments;
    }
    return .{ .status = value };
}

fn monitor(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 0) return error.InvalidArguments;
    if (same(args[0], "list")) return status(args[1..]);
    if (same(args[0], "add")) return add(args[1..]);
    if (same(args[0], "amend")) return amend(a, args[1..]);
    if (same(args[0], "directives")) return directivePage(args[1..]);
    if (args.len != 2) return error.InvalidArguments;
    const target = try wire.parse(t.Id, args[1]);
    if (same(args[0], "show")) return .{ .monitor_show = target };
    inline for (.{ "pause", "resume", "cancel", "check" }) |name| {
        if (same(args[0], name))
            return directive(target, @unionInit(commands.CallerDirective, name, {}));
    }
    return error.InvalidArguments;
}

fn directivePage(args: []const []const u8) !Command {
    return .{ .monitor_directives = try page(@FieldType(Command, "monitor_directives"), args) };
}

fn messagePage(args: []const []const u8) !Command {
    return .{ .messages = try page(@FieldType(Command, "messages"), args) };
}

fn page(comptime Page: type, args: []const []const u8) !Page {
    if (args.len == 0) return error.InvalidArguments;
    const cursor = try paging(args[1..]);
    const target = try wire.parse(t.Id, args[0]);
    return .{ .target = target, .after = cursor.after, .limit = cursor.limit };
}

const Cursor = struct { after: ?u64 = null, limit: u32 = 16 };

fn paging(args: []const []const u8) !Cursor {
    var value: Cursor = .{};
    var seen_limit = false;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.InvalidArguments;
        if (same(args[i], "--after") and value.after == null) {
            value.after = try number(u64, args[i + 1]);
        } else if (same(args[i], "--limit") and !seen_limit) {
            value.limit = try number(u32, args[i + 1]);
            seen_limit = true;
        } else return error.InvalidArguments;
    }
    return value;
}

fn add(args: []const []const u8) !Command {
    var value: @FieldType(Command, "monitor_add") = .{
        .wording = .{ .bytes = "Report new commits with source links." },
        .interval_ms = null,
    };
    var wording = false;
    var interval = false;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.InvalidArguments;
        if (same(args[i], "--wording") and !wording) {
            wording = true;
            value.wording = .{ .bytes = args[i + 1] };
        } else if (same(args[i], "--interval-ms") and !interval) {
            interval = true;
            value.interval_ms = try number(u64, args[i + 1]);
        } else return error.InvalidArguments;
    }
    return .{ .monitor_add = value };
}

fn ask(args: []const []const u8) !Command {
    if (args.len != 1 and args.len != 3) return error.InvalidArguments;
    var target: ?t.Id = null;
    if (args.len == 3) {
        if (!same(args[1], "--target")) return error.InvalidArguments;
        target = try wire.parse(t.Id, args[2]);
    }
    return .{ .ask = .{ .text = .{ .bytes = args[0] }, .target = target } };
}

fn amend(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len < 4 or args.len % 2 != 0) return error.InvalidArguments;
    var value: t.Amendment = .{
        .expected_revision = try number(u64, args[1]),
        .interval_ms = null,
        .wording = null,
        .policies = null,
        .repository_route = null,
    };
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const flag = args[i];
        const bytes = args[i + 1];
        if (same(flag, "--interval-ms") and value.interval_ms == null)
            value.interval_ms = try number(u64, bytes)
        else if (same(flag, "--wording") and value.wording == null)
            value.wording = .{ .bytes = bytes }
        else if (same(flag, "--policies-json") and value.policies == null)
            value.policies = try decode(t.Policies, a, bytes)
        else if (same(flag, "--route-json") and value.repository_route == null)
            value.repository_route = try decode(
                @typeInfo(@FieldType(t.Amendment, "repository_route")).optional.child,
                a,
                bytes,
            )
        else
            return error.InvalidArguments;
    }
    return directive(try wire.parse(t.Id, args[0]), .{ .amend = value });
}

fn method(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 2 and same(args[0], "show"))
        return .{ .method_show = try wire.parse(t.Id, args[1]) };
    if (args.len == 3 and same(args[0], "revert"))
        return directive(try wire.parse(t.Id, args[1]), .{ .revert = .{
            .expected_revision = try number(u64, args[2]),
        } });
    if (args.len == 4 and same(args[0], "adopt"))
        return directive(try wire.parse(t.Id, args[1]), .{ .adopt = .{
            .expected_revision = try number(u64, args[2]),
            .method = try decode(t.Method, a, args[3]),
        } });
    return error.InvalidArguments;
}
