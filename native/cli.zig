const std = @import("std");
const native = @import("protean_native");
const t = @import("application_types");
const control = @import("control.zig");
const Command = @FieldType(control.Request, "command");

pub const help =
    \\paredros --config PATH COMMAND
    \\  serve [--recover]                 Run the daemon
    \\  status [--after ID] [--limit N]    Inspect durable state
    \\  ask TEXT [--target ID]            Admit a conversation turn
    \\  monitor add [--wording TEXT] [--interval-ms N]
    \\  monitor list | show ID | check ID | pause ID | resume ID | cancel ID
    \\  monitor directives ID [--after ORDINAL] [--limit N]
    \\  monitor amend ID REVISION [--interval-ms N] [--wording TEXT]
    \\  messages ID [--after ORDINAL] [--limit N]  Read local updates
    \\  question answer ID QUESTION_DIGEST CHOICE
    \\  proposal show | confirm REQUEST_DIGEST:ATTEMPT:ORDINAL
    \\  task show ID                     Inspect admitted input and result
    \\  delivery show KEY_JSON | release ID KEY_JSON
    \\  method show ID | revert ID REVISION | adopt ID REVISION METHOD_JSON
    \\  experiment run CAMPAIGN ATTEMPT PLAN_JSON [--live] | show CAMPAIGN
    \\  namespace check | describe-build | licenses
    \\  recovery status | begin | release TASK DIGEST --exclusive-owner
    \\  transfer export NAME [--snapshot]
    \\  transfer import PATH [--bytes-max N]
    \\  request JSON | stdio              Machine-readable daemon access
    \\Mutations accept --operation ID. Success means admission, not remote completion.
;

pub fn defaultOperation(
    a: std.mem.Allocator,
    io: std.Io,
    namespace: []const u8,
    backup_directory: ?[]const u8,
    args: []const []const u8,
) ![]u8 {
    if (!same(args[0], "transfer") or snapshotExport(args)) {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        return a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
    }
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .namespace = namespace,
        .backup_directory = backup_directory,
        .arguments = args,
    }, .{});
    defer a.free(bytes);
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn callerPath(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidArguments;
    if (std.fs.path.isAbsolute(path)) return path;
    const current = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ current, path });
}

pub fn callerArguments(
    a: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) ![]const []const u8 {
    if (!same(args[0], "transfer")) return args;
    const resolved = try a.dupe([]const u8, args);
    var positional: usize = 0;
    var i: usize = 0;
    while (i < resolved.len) : (i += 1) {
        if (same(resolved[i], "--operation")) {
            i += 1;
            continue;
        }
        positional += 1;
        if (positional == 2 and !same(resolved[i], "import")) return args;
        if (positional == 3) {
            resolved[i] = try callerPath(a, io, resolved[i]);
            return resolved;
        }
    }
    return args;
}

fn snapshotExport(args: []const []const u8) bool {
    if (args.len < 3 or !same(args[1], "export")) return false;
    for (args[3..]) |arg| if (same(arg, "--snapshot")) return true;
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
    var filtered: std.ArrayList([]const u8) = .empty;
    var operation = generated_operation;
    var explicit = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--operation")) {
            if (explicit or i + 1 == args.len) return error.InvalidArguments;
            i += 1;
            operation = args[i];
            explicit = true;
        } else try filtered.append(scratch, args[i]);
    }
    const values = filtered.items;
    if (values.len == 2 and std.mem.eql(u8, values[0], "request")) {
        var parsed = try native.json.parse(scratch, values[1], .{});
        defer parsed.deinit();
        const decoded = try native.values.fromJson(control.Request, scratch, parsed.value);
        return control.encode(a, decoded);
    }
    const command = try parse(scratch, values);
    const mutation = switch (command) {
        .status,
        .monitor_show,
        .monitor_directives,
        .messages,
        .task_show,
        .delivery_show,
        .method_show,
        .proposal_show,
        .experiment_show,
        .recovery_status,
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
        return .{ .task_show = try hex(t.Id, args[2]) };
    if (same(name, "proposal")) return proposal(args[1..]);
    if (same(name, "experiment")) return experiment(a, args[1..]);
    if (same(name, "question") and args.len == 5 and same(args[1], "answer"))
        return directive(try hex(t.Id, args[2]), .{ .answer = .{
            .question = try hex(t.Digest, args[3]),
            .choice = .{ .bytes = args[4] },
        } });
    if (same(name, "delivery")) return delivery(a, args[1..]);
    if (same(name, "method")) return method(a, args[1..]);
    if (same(name, "recovery")) return recovery(args[1..]);
    if (same(name, "transfer")) return transfer(args[1..]);
    return error.InvalidArguments;
}

fn recovery(args: []const []const u8) !Command {
    if (args.len == 1 and same(args[0], "status")) return .recovery_status;
    if (args.len == 1 and same(args[0], "begin")) return .recovery_begin;
    if (args.len != 4 or !same(args[0], "release") or
        !same(args[3], "--exclusive-owner")) return error.InvalidArguments;
    return .{ .recovery_release = .{
        .recovery = .{ .task = try hex(t.Id, args[1]), .digest = try hex(t.Digest, args[2]) },
        .exclusive_owner = true,
    } };
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
    var importing: @import("continuity_control.zig").Import = .{ .path = .{ .bytes = args[1] } };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (same(args[i], "--bytes-max") and importing.bytes_max == null) {
            i += 1;
            if (i == args.len) return error.InvalidArguments;
            importing.bytes_max = try number(u64, args[i]);
        } else return error.InvalidArguments;
    }
    return .{ .transfer_import = importing };
}

fn proposal(args: []const []const u8) !Command {
    if (args.len != 2) return error.InvalidArguments;
    var parts = std.mem.splitScalar(u8, args[1], ':');
    const request_id = parts.next() orelse return error.InvalidIdentity;
    const attempt = parts.next() orelse return error.InvalidIdentity;
    const ordinal = parts.next() orelse return error.InvalidIdentity;
    if (parts.next() != null) return error.InvalidIdentity;
    const value: @import("commands.zig").ProposalSelector = .{ .identity = .{
        .request = try hex(t.Digest, request_id),
        .attempt = try number(u32, attempt),
        .ordinal = try number(u32, ordinal),
    } };
    if (same(args[0], "show")) return .{ .proposal_show = value };
    if (same(args[0], "confirm")) return .{ .proposal_confirm = value };
    return error.InvalidArguments;
}

fn experiment(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 2 and same(args[0], "show"))
        return .{ .experiment_show = try hex(t.Digest, args[1]) };
    if (args.len < 4 or args.len > 5 or !same(args[0], "run")) return error.InvalidArguments;
    const live = args.len == 5;
    if (live and !same(args[4], "--live")) return error.InvalidArguments;
    return .{ .experiment_run = .{
        .campaign = try hex(t.Digest, args[1]),
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

pub fn hex(comptime T: type, bytes: []const u8) !T {
    if (bytes.len != @sizeOf(T) * 2) return error.InvalidIdentity;
    var value: T = undefined;
    _ = std.fmt.hexToBytes(&value, bytes) catch return error.InvalidIdentity;
    return value;
}

fn number(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidNumber;
}

fn decode(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !T {
    const parsed = try native.json.parse(a, bytes, .{});
    return native.values.fromJson(T, a, parsed.value);
}

fn directive(target: t.Id, body: t.DirectiveBody) Command {
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
            value.after = try hex(t.Id, args[i + 1]);
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
    const target = try hex(t.Id, args[1]);
    if (same(args[0], "show")) return .{ .monitor_show = target };
    inline for (.{ "pause", "resume", "cancel", "check" }) |name| {
        if (same(args[0], name)) return directive(target, @unionInit(t.DirectiveBody, name, {}));
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
    return .{ .target = try hex(t.Id, args[0]), .after = cursor.after, .limit = cursor.limit };
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
        target = try hex(t.Id, args[2]);
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
    return directive(try hex(t.Id, args[0]), .{ .amend = value });
}

fn delivery(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 2 and same(args[0], "show"))
        return .{ .delivery_show = try decode(t.DeliveryKey, a, args[1]) };
    if (args.len != 3 or !same(args[0], "release")) return error.InvalidArguments;
    return directive(try hex(t.Id, args[1]), .{ .release = .{
        .key = try decode(t.DeliveryKey, a, args[2]),
    } });
}

fn method(a: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 2 and same(args[0], "show"))
        return .{ .method_show = try hex(t.Id, args[1]) };
    if (args.len == 3 and same(args[0], "revert"))
        return directive(try hex(t.Id, args[1]), .{ .revert = .{
            .expected_revision = try number(u64, args[2]),
        } });
    if (args.len == 4 and same(args[0], "adopt"))
        return directive(try hex(t.Id, args[1]), .{ .adopt = .{
            .expected_revision = try number(u64, args[2]),
            .method = try decode(t.Method, a, args[3]),
        } });
    return error.InvalidArguments;
}
