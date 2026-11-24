const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const cli = @import("../native/cli.zig");
const control = @import("../native/control.zig");
const config = @import("../native/configuration.zig");
const app = @import("../native/application.zig");
const Driver = @import("../native/driver.zig").Driver(t);
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};
const Fixture = @import("native_fixture.zig").Fixture(t, Application);
const a = std.testing.allocator;

fn configuration() config.Config {
    return .{
        .version = 1,
        .current_uid = 501,
        .namespace_path = "/tmp/unused-control-test",
        .control_socket_path = "/tmp/unused-control-test.sock",
        .repository = .{
            .account = "github",
            .id = 1,
            .owner = "owner",
            .name = "repo",
            .ref = "refs/heads/main",
        },
    };
}

const Clock = struct {
    now_ms: i64 = 200,
    fn now(context: *anyopaque) !i64 {
        const self: *Clock = @ptrCast(@alignCast(context));
        return self.now_ms;
    }
};

fn decode(frame: std.mem.Allocator, bytes: []const u8) !native.json.Value {
    return (try native.json.parse(frame, bytes, .{})).value;
}

fn dispatch(
    frame: std.mem.Allocator,
    driver: *Driver,
    request: []const u8,
    uid: u32,
) !native.json.Value {
    return decode(frame, try control.dispatch(frame, driver, configuration(), uid, request));
}

fn taskId(value: native.json.Value) !t.Id {
    try std.testing.expectEqualStrings(
        "admitted",
        try native.json.text(value.object.get("status").?),
    );
    return cli.hex(t.Id, try native.json.text(value.object.get("data").?.object.get("task").?));
}

fn finish(fixture: *Fixture, id: t.Id) !void {
    const frame = fixture.arena.allocator();
    var input = (try fixture.service.?.applicationValue(frame, id, .input)).?;
    defer input.deinit();
    var decoded = try c.decodeOwned(t.Input, frame, input.bytes);
    defer decoded.deinit();
    const operation = switch (decoded.value) {
        inline else => |value| value.envelope.operation.bytes,
    };
    try std.testing.expectEqualDeep(id, try fixture.execute(operation, decoded.value));
}

test "control CLI preserves exact revisions and rejects ambiguous arguments" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const id = "00112233445566778899aabbccddeeff";
    const wire = try cli.request(frame, &.{
        "monitor",     "amend",  id, "18446744073709551615", "--wording",
        "<& UTF8 λ>",
        "--operation", "unique",
    }, "unused");
    const value = try native.values.fromJson(control.Request, frame, try decode(frame, wire));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        value.command.directive.body.amend.expected_revision,
    );
    try std.testing.expectEqualStrings(
        "<& UTF8 λ>",
        value.command.directive.body.amend.wording.?.bytes,
    );
    try std.testing.expectEqualStrings("unique", value.operation.?.bytes);
    try std.testing.expectError(
        error.InvalidArguments,
        cli.request(frame, &.{ "monitor", "pause", id, "extra" }, "id"),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        cli.request(frame, &.{ "status", "--limit", "1", "--limit", "2" }, "id"),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        cli.request(frame, &.{ "status", "--operation", "a", "--operation", "b" }, "id"),
    );
    try std.testing.expectError(
        error.InvalidIdentity,
        cli.request(frame, &.{ "monitor", "show", "short" }, "id"),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        cli.request(frame, &.{ "transfer", "import", "/b/h.paredros", "--exclusive-owner" }, "id"),
    );
}

test "control CLI preserves the caller's directory for a relative import path" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const io = std.testing.io;
    const current = try std.process.currentPathAlloc(io, frame);
    const expected = try std.fs.path.join(frame, &.{ current, "backups/h.paredros" });
    const supplied: []const []const u8 = &.{
        "transfer", "--operation", "import", "import", "backups/h.paredros", "--bytes-max", "9",
    };
    const resolved = try cli.callerArguments(frame, io, supplied);
    try std.testing.expectEqualStrings(expected, resolved[2]);
    try std.testing.expectEqualStrings("backups/h.paredros", supplied[4]);
    const absolute: []const []const u8 = &.{ "transfer", "import", "/b/h.paredros" };
    try std.testing.expectEqualStrings(
        "/b/h.paredros",
        (try cli.callerArguments(frame, io, absolute))[2],
    );
    const exported: []const []const u8 = &.{ "transfer", "export", "relative" };
    try std.testing.expectEqualStrings(
        "relative",
        (try cli.callerArguments(frame, io, exported))[2],
    );
    const encoded = try cli.request(frame, resolved, "id");
    const parsed = try native.json.parse(frame, encoded, .{});
    const request = try native.values.fromJson(control.Request, frame, parsed.value);
    try std.testing.expectEqualStrings(expected, request.command.transfer_import.path.bytes);
    try std.testing.expectEqual(@as(?u64, 9), request.command.transfer_import.bytes_max);
    try std.testing.expectError(
        error.RelativeTransferPath,
        cli.request(frame, &.{ "transfer", "import", "h.paredros" }, "id"),
    );
}

test "control CLI preserves one import identity across leading options and path spellings" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const io = std.testing.io;
    const current = try std.process.currentPathAlloc(io, frame);
    const parent = std.fs.path.dirname(current).?;
    const leaf = std.fs.path.basename(current);
    const expected = try std.fs.path.join(frame, &.{ current, "h.paredros" });
    const spellings = [_][]const u8{
        "h.paredros",
        "./h.paredros",
        ".//h.paredros",
        try std.fmt.allocPrint(frame, "../{s}/h.paredros", .{leaf}),
        try std.fmt.allocPrint(frame, "{s}/./{s}/h.paredros", .{ parent, leaf }),
    };
    var operations: [spellings.len][]const u8 = undefined;
    for (spellings, &operations) |path, *operation| {
        const leading = try cli.callerArguments(
            frame,
            io,
            &.{ "--operation", "chosen", "transfer", "import", path },
        );
        const encoded = try cli.request(frame, leading, "unused");
        const request = try native.values.fromJson(
            control.Request,
            frame,
            try decode(frame, encoded),
        );
        try std.testing.expectEqualStrings(expected, request.command.transfer_import.path.bytes);
        try std.testing.expectEqualStrings("chosen", request.operation.?.bytes);
        const plain = try cli.callerArguments(frame, io, &.{ "transfer", "import", path });
        try std.testing.expectEqualStrings(expected, plain[2]);
        operation.* = try cli.defaultOperation(
            frame,
            io,
            "/ns",
            "/backup",
            (try cli.invocation(frame, plain)).command,
        );
        const split = try cli.callerArguments(
            frame,
            io,
            &.{ "transfer", "--operation", "chosen", "import", path },
        );
        try std.testing.expectEqualStrings(
            operation.*,
            try cli.defaultOperation(frame, io, "/ns", "/backup", (try cli.invocation(
                frame,
                split,
            )).command),
        );
    }
    for (operations[1..]) |operation| try std.testing.expectEqualStrings(operations[0], operation);
    try std.testing.expectEqualStrings(
        "ask",
        (try cli.invocation(frame, &.{ "--operation", "chosen", "ask", "hello" })).command[0],
    );
    try std.testing.expectError(
        error.InvalidArguments,
        cli.callerArguments(frame, io, &.{ "transfer", "import", "h", "--operation" }),
    );
}

test "control CLI repeats transfer identity but takes a new snapshot identity per run" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const io = std.testing.io;
    const snapshot: []const []const u8 = &.{ "transfer", "export", "nightly", "--snapshot" };
    const handoff: []const []const u8 = &.{ "transfer", "export", "handoff" };
    try std.testing.expect(!std.mem.eql(
        u8,
        try cli.defaultOperation(frame, io, "/ns", "/backup", snapshot),
        try cli.defaultOperation(frame, io, "/ns", "/backup", snapshot),
    ));
    try std.testing.expectEqualStrings(
        try cli.defaultOperation(frame, io, "/ns", "/backup", handoff),
        try cli.defaultOperation(frame, io, "/ns", "/backup", handoff),
    );
}

test "control protocol freezes monitor retry and acknowledges persisted restrictive controls" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    const request = try cli.request(frame, &.{ "monitor", "add" }, "monitor-one");
    const id = try taskId(try dispatch(frame, &driver, request, 501));
    clock.now_ms = 500;
    try std.testing.expectEqualDeep(id, try taskId(try dispatch(frame, &driver, request, 501)));
    try finish(&fixture, id);
    var index = try driver.rebuild(frame);
    try std.testing.expectEqual(200, index.head(index.obligation(id).?).specification.anchor_ms);
    index.deinit();
    const hex_id = std.fmt.bytesToHex(id, .lower);
    const pause = try cli.request(frame, &.{ "monitor", "pause", &hex_id }, "pause-one");
    const pause_id = try taskId(try dispatch(frame, &driver, pause, 501));
    var receipt = (try fixture.service.?.operationLookup(frame, "pause-one")).?;
    defer receipt.deinit();
    try std.testing.expectEqualDeep(pause_id, receipt.value.task);
    const system = try control.encode(frame, .{
        .version = 1,
        .operation = .{ .bytes = "caller-transfer" },
        .command = .{ .directive = .{ .target = id, .body = .{ .transfer = {} } } },
    });
    try expectRejected(try dispatch(frame, &driver, system, 501), "SystemDirective");
    const show = try cli.request(frame, &.{ "monitor", "show", &hex_id }, "unused");
    const response = try dispatch(frame, &driver, show, 501);
    const data = response.object.get("data").?;
    try std.testing.expectEqualStrings(
        "paused",
        try native.json.text(data.object.get("effective_mode").?),
    );
    const backlog = try native.values.fromJson(
        @import("../native/materialize.zig").Backlog,
        frame,
        data.object.get("backlog").?,
    );
    try std.testing.expectEqual(0, backlog.untold_batches);
    try std.testing.expect(backlog.oldest == null);
    try std.testing.expectEqual(1, data.object.get("pending_directives").?.array.items.len);
    try std.testing.expect(!data.object.get("ordinary_dispatch").?.bool);
    try std.testing.expect(data.object.get("reconciliation") == null);
    try std.testing.expect(data.object.get("reconciliation_evidence") == null);
    const denied = try dispatch(frame, &driver, pause, 502);
    try std.testing.expectEqualStrings(
        "PermissionDenied",
        try native.json.text(denied.object.get("error").?),
    );
    try fixture.close();
    try fixture.open();
    driver.service = &fixture.service.?;
    var reopened = try driver.rebuild(frame);
    defer reopened.deinit();
    try std.testing.expect(!reopened.obligation(id).?.ordinaryDispatch());
}

fn expectDirectivePages(
    frame: std.mem.Allocator,
    driver: *Driver,
    hex_id: []const u8,
    expected: []const t.Directive,
) !void {
    var count: usize = 0;
    var after: u64 = 0;
    while (count < expected.len) {
        const cursor = try std.fmt.allocPrint(frame, "{d}", .{after});
        const bytes = try cli.request(frame, &.{
            "monitor", "directives", hex_id, "--after", cursor, "--limit", "7",
        }, "unused");
        const request = try native.values.fromJson(
            control.Request,
            frame,
            try decode(frame, bytes),
        );
        try std.testing.expect(request.operation == null);
        const response = try dispatch(frame, driver, bytes, 501);
        const page = response.object.get("data").?;
        const items = page.object.get("pending_directives").?.array.items;
        try std.testing.expect(items.len > 0 and items.len <= 7);
        for (items) |item| {
            const actual = try native.values.fromJson(t.Directive, frame, item);
            try std.testing.expectEqualDeep(expected[count], actual);
            count += 1;
        }
        const next = try native.values.fromJson(
            ?u64,
            frame,
            page.object.get("pending_directives_next").?,
        );
        if (count == expected.len) {
            try std.testing.expect(next == null);
        } else {
            try std.testing.expect(next.? > after);
            after = next.?;
        }
    }
}

test "control pages pending directives with exact frozen contents" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    const id = try taskId(try dispatch(frame, &driver, try cli.request(
        frame,
        &.{ "monitor", "add" },
        "paged-monitor",
    ), 501));
    try finish(&fixture, id);
    const hex_id = std.fmt.bytesToHex(id, .lower);
    var expected: [35]t.Directive = undefined;
    for (&expected, 0..) |*value, position| {
        const operation = try std.fmt.allocPrint(frame, "paged-control-{d}", .{position});
        const verb = if (position % 2 == 0) "pause" else "resume";
        const request = try cli.request(frame, &.{ "monitor", verb, &hex_id }, operation);
        const task = try taskId(try dispatch(frame, &driver, request, 501));
        const input = (try fixture.service.?.applicationValue(frame, task, .input)).?;
        value.* = (try c.decodeOwned(t.Input, frame, input.bytes)).value.directive;
    }
    const shown = try dispatch(frame, &driver, try cli.request(
        frame,
        &.{ "monitor", "show", &hex_id },
        "unused",
    ), 501);
    const data = shown.object.get("data").?;
    try std.testing.expectEqual(16, data.object.get("pending_directives").?.array.items.len);
    try std.testing.expectEqual(35, try native.values.fromJson(
        u64,
        frame,
        data.object.get("pending_directives_total").?,
    ));
    try expectDirectivePages(frame, &driver, &hex_id, &expected);
    for ([_][]const u8{ "0", "65" }) |limit| {
        const request = try cli.request(frame, &.{
            "monitor", "directives", &hex_id, "--limit", limit,
        }, "unused");
        const response = try dispatch(frame, &driver, request, 501);
        try std.testing.expectEqualStrings(
            "InvalidPageLimit",
            try native.json.text(response.object.get("error").?),
        );
    }
    try std.testing.expectError(error.InvalidArguments, cli.request(frame, &.{
        "monitor", "directives", &hex_id, "--after", "0", "--after", "1",
    }, "unused"));
}

fn decodeFrame(frame: std.mem.Allocator, bytes: []const u8) !native.json.Value {
    return (try native.json.parse(frame, bytes, .{ .bytes = control.frame_bytes_max })).value;
}

fn admitLarge(
    frame: std.mem.Allocator,
    driver: *Driver,
    target: t.Id,
    wording: []const u8,
    count: usize,
) !void {
    for (0..count) |position| {
        const operation = try std.fmt.allocPrint(frame, "large-{s}-{d}", .{
            &std.fmt.bytesToHex(target, .lower),
            position,
        });
        _ = try taskId(try dispatch(frame, driver, try control.encode(frame, .{
            .version = 1,
            .operation = .{ .bytes = operation },
            .command = .{ .directive = .{ .target = target, .body = .{ .amend = .{
                .expected_revision = 0,
                .interval_ms = null,
                .wording = .{ .bytes = wording },
                .policies = null,
                .repository_route = null,
            } } } },
        }), 501));
    }
}

fn statusPage(frame: std.mem.Allocator, driver: *Driver, after: ?t.Id) !native.json.Value {
    const bytes = try control.dispatch(frame, driver, configuration(), 501, try control.encode(
        frame,
        .{ .version = 1, .operation = null, .command = .{ .status = .{
            .after = after,
            .limit = 16,
        } } },
    ));
    try std.testing.expect(bytes.len <= control.frame_bytes_max);
    const value = try decodeFrame(frame, bytes);
    try std.testing.expectEqualStrings(
        "observed",
        try native.json.text(value.object.get("status").?),
    );
    return value.object.get("data").?;
}

fn expectStatusPages(frame: std.mem.Allocator, driver: *Driver, expected: usize) !void {
    var seen: usize = 0;
    var after: ?t.Id = null;
    for (0..expected) |_| {
        const page = try statusPage(frame, driver, after);
        const items = page.object.get("obligations").?.array.items;
        try std.testing.expect(items.len > 0 and items.len < expected);
        for (items) |item| try std.testing.expectEqual(
            16,
            item.object.get("pending_directives").?.array.items.len,
        );
        seen += items.len;
        after = try native.values.fromJson(?t.Id, frame, page.object.get("next").?);
        if (after == null) break;
    }
    try std.testing.expectEqual(expected, seen);
}

test "control pages pending directives and status within one frame" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    const wording = try frame.alloc(u8, 16 * 1024);
    @memset(wording, 1);
    var ids: [3]t.Id = undefined;
    for (&ids, [_]usize{ 44, 16, 16 }, 0..) |*id, count, position| {
        const name = try std.fmt.allocPrint(frame, "large-monitor-{d}", .{position});
        id.* = try taskId(try dispatch(frame, &driver, try control.encode(frame, .{
            .version = 1,
            .operation = .{ .bytes = name },
            .command = .{ .monitor_add = .{ .wording = .{ .bytes = name }, .interval_ms = null } },
        }), 501));
        try finish(&fixture, id.*);
        try admitLarge(frame, &driver, id.*, wording, count);
    }
    try expectStatusPages(frame, &driver, ids.len);
    const hex_id = std.fmt.bytesToHex(ids[0], .lower);
    const request = try cli.request(frame, &.{
        "monitor", "directives", &hex_id, "--limit", "64",
    }, "unused");
    const bytes = try control.dispatch(frame, &driver, configuration(), 501, request);
    try std.testing.expect(bytes.len <= control.frame_bytes_max);
    const data = (try decodeFrame(frame, bytes)).object.get("data").?;
    const shown = data.object.get("pending_directives").?.array.items.len;
    try std.testing.expect(shown > 16 and shown < 44);
    try std.testing.expect(data.object.get("pending_directives_next").? != .null);
}

test "control reads messages without admission and rejects malformed pages" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    const id = try taskId(try dispatch(frame, &driver, try cli.request(
        frame,
        &.{ "monitor", "add" },
        "messages-monitor",
    ), 501));
    try finish(&fixture, id);
    const hex_id = std.fmt.bytesToHex(id, .lower);
    const wire = try cli.request(frame, &.{
        "messages", &hex_id, "--after", "3", "--limit", "5", "--operation", "ignored",
    }, "unused");
    const parsed = try native.values.fromJson(control.Request, frame, try decode(frame, wire));
    try std.testing.expect(parsed.operation == null);
    try std.testing.expectEqualDeep(id, parsed.command.messages.target);
    try std.testing.expectEqual(3, parsed.command.messages.after.?);
    try std.testing.expectEqual(5, parsed.command.messages.limit);
    var before = try driver.rebuild(frame);
    const records = before.records.len;
    before.deinit();
    const read = try cli.request(frame, &.{ "messages", &hex_id }, "unused");
    const bytes = try control.dispatch(frame, &driver, configuration(), 501, read);
    try std.testing.expect(bytes.len <= control.frame_bytes_max);
    try std.testing.expectEqualStrings(
        "observed",
        try native.json.text((try decodeFrame(frame, bytes)).object.get("status").?),
    );
    for ([_][]const u8{ "0", "65" }) |limit| {
        const request = try cli.request(frame, &.{
            "messages", &hex_id, "--limit", limit,
        }, "unused");
        const response = try dispatch(frame, &driver, request, 501);
        try std.testing.expectEqualStrings(
            "InvalidPageLimit",
            try native.json.text(response.object.get("error").?),
        );
    }
    var after = try driver.rebuild(frame);
    defer after.deinit();
    try std.testing.expectEqual(records, after.records.len);
    for ([_][]const []const u8{
        &.{ "messages", &hex_id, "--after", "1", "--after", "2" },
        &.{"messages"},
        &.{ "messages", "--after", "2", "--limit", "3" },
    }) |args| try std.testing.expectError(error.InvalidArguments, cli.request(frame, args, "id"));
}

test "control malformed and unsupported frames are rejected without admission" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    for ([_][]const u8{ "{", "{}", "{\"version\":1,\"version\":1}" }) |bytes| {
        const result = try dispatch(frame, &driver, bytes, 501);
        try std.testing.expectEqualStrings(
            "rejected",
            try native.json.text(result.object.get("status").?),
        );
    }
    const request = try control.encode(frame, .{
        .version = 2,
        .operation = null,
        .command = .{ .status = .{ .after = null, .limit = 16 } },
    });
    const result = try dispatch(frame, &driver, request, 501);
    try std.testing.expectEqualStrings(
        "UnsupportedProtocol",
        try native.json.text(result.object.get("error").?),
    );
    var index = try driver.rebuild(frame);
    defer index.deinit();
    try std.testing.expectEqual(0, index.records.len);
}

const protean = @import("protean");
const horos = @import("horos");
const authored = @import("../app/author.zig");
const model_contract = @import("../app/model_contract.zig");
const commands = @import("../native/commands.zig");
const ConsumerFixture = @import("native_fixture.zig").Fixture(t, ConsumerApplication);

pub const ConsumerApplication = struct {
    pub fn emit(context: protean.Context) !horos.source.Module {
        const genesis = try @import("../app/genesis.zig").emit(context);
        const turn = try @import("../app/turn.zig").emit(context, try completion(context), &.{});
        const function = try context.author.function("proposal consumer application", .{
            .input = try context.schema(t.Input),
        }, try context.schema(t.Output), &.{});
        const b = try context.author.body(function);
        const input = try b.parameter("input");
        const initial = try b.caseOf(input, "genesis");
        const converse = try b.caseOf(input, "turn");
        const directive = try b.caseOf(input, "directive");
        const output = try context.schema(t.Output);
        const failure = try context.literal(t.Failure, .{
            .code = .{ .bytes = "unsupported_consumer_test" },
        });
        const result = try b.match(input, .{
            .genesis = try initial.ret(try initial.body().variant(
                try context.schema(t.Output),
                "genesis",
                try initial.body().call(genesis, .{ .input = initial.payload() }),
            )),
            .turn = try converse.ret(try converse.body().variant(
                try context.schema(t.Output),
                "turn",
                try converse.body().call(turn, .{ .input = converse.payload() }),
            )),
            .directive = try directive.ret(try directive.body().variant(
                try context.schema(t.Output),
                "directive",
                directive.payload(),
            )),
            .step = try (try b.caseOf(input, "step")).fail(output, failure),
            .experiment = try (try b.caseOf(input, "experiment")).fail(output, failure),
            .continuity_member = try (try b.caseOf(input, "continuity_member")).fail(
                output,
                failure,
            ),
            .continuity_cut = try (try b.caseOf(input, "continuity_cut")).fail(output, failure),
            .transfer = try (try b.caseOf(input, "transfer")).fail(output, failure),
        });
        try context.author.define(function, try b.ret(result));
        return context.author.module(function, try context.schema(t.Failure));
    }
};

pub fn completion(context: protean.Context) !@import("../app/model.zig").Function {
    const function = try context.author.function("consumer frozen proposal", .{
        .input = try context.schema(model_contract.Input),
    }, try context.schema(model_contract.Result), &.{});
    const b = try context.author.body(function);
    const input = try b.parameter("input");
    const first = try b.sequenceGet(
        try b.field(input, "proposal_offers"),
        try b.constant(u64, 0),
    );
    const present = try b.caseOf(first, "some");
    const absent = try b.caseOf(first, "none");
    const body = try b.match(first, .{
        .some = try present.ret(present.payload()),
        .none = try absent.fail(
            try context.schema(model_contract.ProposalBody),
            try context.literal(t.Failure, .{ .code = .{ .bytes = "missing_offer" } }),
        ),
    });
    const proposal = try b.product(try context.schema(model_contract.BoundProposal), .{
        .initiating_input = try b.field(input, "initiating_input"),
        .target = try b.field(input, "target"),
        .expected_revision = try b.field(input, "expected_revision"),
        .body = body,
    });
    const proposals = try b.append(
        try context.literal(model_contract.Proposals, .{ .items = &.{} }),
        proposal,
        .{ .capacity = try authored.failure(context, "proposal_capacity") },
    );
    const conversation = try b.product(
        try context.schema(@FieldType(model_contract.Candidate, "conversation")),
        .{
            .reply = try context.literal(t.Text, .{ .bytes = "Review this proposal." }),
            .proposals = proposals,
        },
    );
    try context.author.define(function, try b.ret(try b.product(
        try context.schema(model_contract.Result),
        .{ .candidate = try b.variant(
            try context.schema(model_contract.Candidate),
            "conversation",
            conversation,
        ), .usage = try context.literal(@FieldType(model_contract.Result, "usage"), null) },
    )));
    return function;
}

fn consumerTurn(target: t.Id) t.Turn {
    return .{
        .envelope = .{
            .operation = .{ .bytes = "consumer-turn" },
            .stable_request = @splat(77),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .text = .{ .bytes = "Update every field exactly." },
        .context = .{ .bytes = "" },
        .context_references = .{ .items = &.{} },
        .attempt = 0,
        .model = consumerBinding(),
        .target = target,
        .expected_revision = 0,
        .proposal_offers = .{ .items = &.{} },
    };
}

fn consumerExecute(fixture: *ConsumerFixture, operation_id: []const u8, input: t.Input) !t.Id {
    const frame = fixture.arena.allocator();
    const service = &fixture.service.?;
    const admitted = try service.submit(frame, operation_id, input);
    for (0..16384) |_| {
        var snapshot = try service.task(frame, admitted.receipt.task);
        defer snapshot.deinit();
        if (snapshot.value.terminal()) {
            try std.testing.expectEqual(.completed, snapshot.value.outcome_kind);
            return admitted.receipt.task;
        }
        switch (try service.pump(frame)) {
            .work => |work| {
                try service.notSent(frame, work);
                return error.UnexpectedConsumerExternalWork;
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.ConsumerTaskDidNotComplete;
}

fn consumerCall(
    frame: std.mem.Allocator,
    driver: *Driver,
    verb: []const u8,
    token: []const u8,
) !native.json.Value {
    return consumerOperation(frame, driver, verb, token, "consumer-confirm");
}

fn consumerOperation(
    frame: std.mem.Allocator,
    driver: *Driver,
    verb: []const u8,
    token: []const u8,
    operation: []const u8,
) !native.json.Value {
    const request = try cli.request(frame, &.{ "proposal", verb, token }, operation);
    return decode(frame, try control.dispatch(frame, driver, configuration(), 501, request));
}

fn consumerConfirmed(
    fixture: *ConsumerFixture,
    driver: *Driver,
    token: []const u8,
    expected: t.Proposal,
) !void {
    const frame = fixture.arena.allocator();
    const id = try taskId(try consumerCall(frame, driver, "confirm", token));
    var saved = (try fixture.service.?.applicationValue(frame, id, .input)).?;
    defer saved.deinit();
    try std.testing.expectEqualStrings(t.input_schema_id, saved.schema_id);
    try std.testing.expectEqual(.contract, saved.encoding);
    var decoded = try c.decodeOwned(t.Input, frame, saved.bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected.target.?, decoded.value.directive.obligation);
    try std.testing.expectEqualDeep(expected.body.directive, decoded.value.directive.body);
    const retried = try taskId(try consumerCall(frame, driver, "confirm", token));
    try std.testing.expectEqualDeep(id, retried);
}

fn consumerPrinted(
    frame: std.mem.Allocator,
    driver: *Driver,
    turn_id: t.Id,
    token: []const u8,
) !void {
    const id = std.fmt.bytesToHex(turn_id, .lower);
    const request = try cli.request(frame, &.{ "task", "show", &id }, "unused");
    const path = "/etc/paredros/config.json";
    const bytes = try control.dispatchWithIndex(
        frame,
        driver,
        configuration(),
        501,
        request,
        null,
        null,
        path,
    );
    const data = (try decode(frame, bytes)).object.get("data").?;
    const items = data.object.get("confirmations").?.array.items;
    try std.testing.expectEqual(1, items.len);
    const identity = try native.json.text(items[0].object.get("identity").?);
    try std.testing.expectEqualStrings(token, identity);
    const expected = try std.fmt.allocPrint(frame, "paredros --config {s} proposal confirm {s}", .{
        path,
        token,
    });
    try std.testing.expectEqualStrings(
        expected,
        try native.json.text(items[0].object.get("command").?),
    );
}

test "control proposal consumer shows and confirms maximal retained body by authored zero ordinal" {
    var fixture: ConsumerFixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    const target = try consumerExecute(&fixture, "genesis", .{
        .genesis = @import("contracts.zig").genesis(),
    });
    const wording = try frame.alloc(u8, 16 * 1024);
    @memset(wording, 1);
    var input = consumerTurn(target);
    const offered: model_contract.ProposalBody = .{ .directive = .{ .amend = .{
        .expected_revision = 0,
        .interval_ms = config.interval_ms_max,
        .wording = .{ .bytes = wording },
        .policies = @import("contracts.zig").specification().policies,
        .repository_route = .{
            .owner = .{ .bytes = "exact<&owner" },
            .name = .{ .bytes = "exact😀repo" },
        },
    } } };
    input.proposal_offers.items = &.{offered};
    const turn_id = try consumerExecute(&fixture, "consumer-turn", .{ .turn = input });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &fixture.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(frame);
    defer driver.detach();
    const token = try consumerToken(&fixture, input);
    try consumerPrinted(frame, &driver, turn_id, token);
    const response = try consumerCall(frame, &driver, "show", token);
    try std.testing.expectEqualStrings(
        "observed",
        try native.json.text(response.object.get("status").?),
    );
    const shown = try native.values.fromJson(t.Proposal, frame, response.object.get("data").?);
    try std.testing.expectEqualDeep(offered, shown.body);
    try std.testing.expectEqualDeep(input.target, shown.target);
    try std.testing.expectEqual(0, shown.identity.ordinal);
    try std.testing.expectEqual(@as(?t.Text, null), shown.description);
    try consumerConfirmed(&fixture, &driver, token, shown);
    try consumerResolution(&driver, frame, turn_id, input, token);
}

test "control proposal consumer confirms each proposal once across operations" {
    var fixture: ConsumerFixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    const target = try consumerExecute(&fixture, "genesis", .{
        .genesis = @import("contracts.zig").genesis(),
    });
    var directive = consumerTurn(target);
    directive.proposal_offers.items = &.{.{ .directive = .check }};
    _ = try consumerExecute(&fixture, "directive-turn", .{ .turn = directive });
    var genesis = consumerTurn(target);
    genesis.envelope.operation.bytes = "genesis-turn";
    genesis.envelope.stable_request = @splat(78);
    genesis.target = null;
    genesis.expected_revision = null;
    genesis.proposal_offers.items = &.{.{ .genesis = @import("contracts.zig").specification() }};
    _ = try consumerExecute(&fixture, "genesis-turn", .{ .turn = genesis });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &fixture.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(frame);
    defer driver.detach();
    for ([_]t.Turn{ directive, genesis }) |offered| {
        const request = std.fmt.bytesToHex(offered.envelope.stable_request, .lower);
        const token = try std.fmt.allocPrint(frame, "{s}:0:0", .{&request});
        var tasks: [2]t.Id = undefined;
        for (&tasks, [_][]const u8{ "first", "again" }) |*task, name| {
            const operation = try std.fmt.allocPrint(frame, "{s}-{s}", .{ name, &request });
            task.* = try taskId(try consumerOperation(frame, &driver, "confirm", token, operation));
        }
        try std.testing.expectEqualDeep(tasks[0], tasks[1]);
    }
    driver.detach();
    for ([_]t.Turn{ directive, genesis }) |offered| {
        const request = std.fmt.bytesToHex(offered.envelope.stable_request, .lower);
        const token = try std.fmt.allocPrint(frame, "{s}:0:0", .{&request});
        const operation = try std.fmt.allocPrint(frame, "detached-{s}", .{&request});
        const refused = try consumerOperation(frame, &driver, "confirm", token, operation);
        try std.testing.expectEqualStrings(
            "UnauthenticatedRequest",
            try native.json.text(refused.object.get("error").?),
        );
    }
    var index = try driver.rebuild(frame);
    defer index.deinit();
    var geneses: usize = 0;
    var directives: usize = 0;
    for (index.records) |record| switch (record.input) {
        .genesis => geneses += 1,
        .directive => directives += 1,
        else => {},
    };
    try std.testing.expectEqual(2, geneses);
    try std.testing.expectEqual(1, directives);
}

fn consumerResolution(
    driver: *Driver,
    frame: std.mem.Allocator,
    turn_id: t.Id,
    input: t.Turn,
    token: []const u8,
) !void {
    var index = try driver.rebuild(frame);
    defer index.deinit();
    const selector: commands.ProposalSelector = .{ .identity = .{
        .request = input.envelope.stable_request,
        .attempt = 0,
        .ordinal = 0,
    } };
    const resolved = try commands.resolveProposal(&index, selector);
    try std.testing.expectEqualDeep(turn_id, resolved.turn.task);
    try std.testing.expectEqualDeep(
        resolved,
        try commands.resolveProposal(&index, .{ .retained = resolved }),
    );
    var stale = resolved;
    stale.turn.digest[0] ^= 1;
    try std.testing.expectError(
        error.UnknownProposal,
        commands.resolveProposal(&index, .{ .retained = stale }),
    );
    var missing = selector;
    missing.identity.ordinal = 1;
    try std.testing.expectError(error.UnknownProposal, commands.resolveProposal(&index, missing));
    missing = selector;
    missing.identity.attempt = 1;
    try std.testing.expectError(error.UnknownProposal, commands.resolveProposal(&index, missing));
    index.records[index.tasks.get(turn_id).?].superseded = true;
    try std.testing.expectError(error.UnknownProposal, commands.resolveProposal(&index, selector));
    const invalid = try std.fmt.allocPrint(frame, "{s}:extra", .{token});
    try std.testing.expectError(
        error.InvalidIdentity,
        cli.request(frame, &.{ "proposal", "show", invalid }, "unused"),
    );
}

pub fn consumerBinding() t.ModelBinding {
    return .{
        .policy = @splat(1),
        .selection = .{
            .profile_id = .{ .bytes = "witness" },
            .profile_digest = @splat(2),
            .effective_effort = .medium,
            .control_revision = 0,
        },
        .profile = .{
            .id = .{ .bytes = "witness" },
            .model = .{ .bytes = "witness" },
            .reasoning_mode = .standard,
            .reasoning_context = .current_turn,
            .efforts = .{ .items = &.{.medium} },
            .effort_update = false,
            .explicit_cache = false,
            .additional_tools = false,
            .cache_diagnostics = false,
            .opaque_family = .{ .bytes = "witness" },
            .max_output_tokens = 1024,
            .request_bytes = 1024 * 1024,
            .response_bytes = 1024 * 1024,
            .timeout_ms = 1000,
        },
        .catalog = .{ .digest = @splat(3), .bytes = 0 },
        .responses = .{ .route = .api_key_json, .binding = null },
    };
}

fn consumerToken(fixture: *ConsumerFixture, input: t.Turn) ![]const u8 {
    const identity = std.fmt.bytesToHex(input.envelope.stable_request, .lower);
    return std.fmt.allocPrint(fixture.arena.allocator(), "{s}:{d}:0", .{
        &identity,
        input.attempt,
    });
}

fn expectRejected(response: native.json.Value, expected: []const u8) !void {
    try std.testing.expectEqualStrings(
        "rejected",
        try native.json.text(response.object.get("status").?),
    );
    const actual = try native.json.text(response.object.get("error").?);
    try std.testing.expectEqualStrings(expected, actual);
}

test "control malformed and unsupported operation identities are refused without admission" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    const reserved = [_][]const u8{
        "turn-retry:00112233445566778899aabbccddeeff:1",
        "turn-replace:00112233445566778899aabbccddeeff",
        "transfer:00:00",
        "step:00:1:0",
        "continuity-genesis:00",
        "continuity-directive:00",
        "export-cut:00",
        "owner:chosen",
        ":",
    };
    for (reserved) |operation| {
        const asked = try control.encode(frame, .{
            .version = 1,
            .operation = .{ .bytes = operation },
            .command = .{ .ask = .{ .text = .{ .bytes = "hello" }, .target = null } },
        });
        try expectRejected(try dispatch(frame, &driver, asked, 501), "ReservedOperationId");
        for ([_][]const []const u8{
            &.{ "--operation", operation, "monitor", "add" },
            &.{ "transfer", "export", "handoff.paredros", "--operation", operation },
        }) |args| {
            const request = try cli.request(frame, args, "unused");
            try expectRejected(try dispatch(frame, &driver, request, 501), "ReservedOperationId");
        }
    }
    var index = try driver.rebuild(frame);
    try std.testing.expectEqual(0, index.records.len);
    index.deinit();
    const args: []const []const u8 = &.{ "--operation", "owner-chosen.1_A", "ask", "hi" };
    const chosen = try cli.request(frame, args, "x");
    _ = try taskId(try dispatch(frame, &driver, chosen, 501));
}

fn unboundedProposals(fixture: *ConsumerFixture, target: t.Id) ![2][]const u8 {
    const too_long = config.interval_ms_max + 1;
    var amend = consumerTurn(target);
    amend.proposal_offers.items = &.{.{ .directive = .{ .amend = .{
        .expected_revision = 0,
        .interval_ms = too_long,
        .wording = null,
        .policies = null,
        .repository_route = null,
    } } }};
    _ = try consumerExecute(fixture, "consumer-turn", .{ .turn = amend });
    var genesis = consumerTurn(target);
    genesis.envelope.operation.bytes = "genesis-turn";
    genesis.envelope.stable_request = @splat(78);
    genesis.target = null;
    genesis.expected_revision = null;
    var specification = @import("contracts.zig").specification();
    specification.interval_ms = too_long;
    genesis.proposal_offers.items = &.{.{ .genesis = specification }};
    _ = try consumerExecute(fixture, "genesis-turn", .{ .turn = genesis });
    return .{ try consumerToken(fixture, amend), try consumerToken(fixture, genesis) };
}

test "control malformed and unsupported intervals are refused without admission" {
    var fixture: ConsumerFixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    const target = try consumerExecute(&fixture, "genesis", .{
        .genesis = @import("contracts.zig").genesis(),
    });
    const tokens = try unboundedProposals(&fixture, target);
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &fixture.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(frame);
    defer driver.detach();
    var before = try driver.rebuild(frame);
    const admitted = before.records.len;
    before.deinit();
    const hex_id = std.fmt.bytesToHex(target, .lower);
    const longest = try std.fmt.allocPrint(frame, "{d}", .{config.interval_ms_max});
    const excess = try std.fmt.allocPrint(frame, "{d}", .{config.interval_ms_max + 1});
    const Refusal = struct { args: []const []const u8, error_name: []const u8 };
    for ([_]Refusal{
        .{
            .args = &.{ "monitor", "add", "--interval-ms", excess },
            .error_name = "IntervalTooLong",
        },
        .{ .args = &.{ "monitor", "add", "--interval-ms", "0" }, .error_name = "InvalidInterval" },
        .{
            .args = &.{ "monitor", "amend", &hex_id, "0", "--interval-ms", excess },
            .error_name = "IntervalTooLong",
        },
        .{
            .args = &.{ "monitor", "amend", &hex_id, "0", "--interval-ms", "0" },
            .error_name = "InvalidInterval",
        },
        .{
            .args = &.{ "proposal", "confirm", tokens[0] },
            .error_name = "IntervalTooLong",
        },
        .{
            .args = &.{ "proposal", "confirm", tokens[1] },
            .error_name = "IntervalTooLong",
        },
    }, 0..) |refusal, position| {
        const operation = try std.fmt.allocPrint(frame, "refused-{d}", .{position});
        const request = try cli.request(frame, refusal.args, operation);
        try expectRejected(try dispatch(frame, &driver, request, 501), refusal.error_name);
    }
    var after = try driver.rebuild(frame);
    try std.testing.expectEqual(admitted, after.records.len);
    after.deinit();
    for ([_][]const []const u8{
        &.{ "monitor", "add", "--interval-ms", longest },
        &.{ "monitor", "amend", &hex_id, "0", "--interval-ms", longest },
    }, 0..) |args, position| {
        const operation = try std.fmt.allocPrint(frame, "bounded-{d}", .{position});
        _ = try taskId(try dispatch(frame, &driver, try cli.request(frame, args, operation), 501));
    }
}

test "control task show reports an unconfirmable proposal instead of failing" {
    var fixture: ConsumerFixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    const target = try consumerExecute(&fixture, "genesis", .{
        .genesis = @import("contracts.zig").genesis(),
    });
    var input = consumerTurn(target);
    input.proposal_offers.items = &.{.{ .directive = .check }};
    const turn_id = try consumerExecute(&fixture, "consumer-turn", .{ .turn = input });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &fixture.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(frame);
    defer driver.detach();
    try consumerPrinted(frame, &driver, turn_id, try consumerToken(&fixture, input));
    var twin = input;
    twin.envelope.operation.bytes = "consumer-twin";
    _ = try consumerExecute(&fixture, "consumer-twin", .{ .turn = twin });
    const id = std.fmt.bytesToHex(turn_id, .lower);
    const request = try cli.request(frame, &.{ "task", "show", &id }, "unused");
    const shown = try dispatch(frame, &driver, request, 501);
    const status = try native.json.text(shown.object.get("status").?);
    try std.testing.expectEqualStrings("observed", status);
    const data = shown.object.get("data").?;
    try std.testing.expect(data.object.get("retry_pending") == null);
    const offered = data.object.get("confirmations").?.array.items;
    try std.testing.expectEqual(1, offered.len);
    try std.testing.expect(!offered[0].object.get("confirmable").?.bool);
    try std.testing.expectEqual(.null, std.meta.activeTag(offered[0].object.get("command").?));
}

fn widestStatus(frame: std.mem.Allocator, driver: *Driver, index: *const @import(
    "../native/index.zig",
).Index) ![]const u8 {
    const request = try control.encode(frame, .{
        .version = 1,
        .operation = null,
        .command = .{ .status = .{ .after = null, .limit = 1 } },
    });
    const settings = configuration();
    return control.dispatchWithIndex(frame, driver, settings, 501, request, null, index, null);
}

fn shownPending(page: native.json.Value) usize {
    const entry = page.object.get("obligations").?.array.items[0];
    return entry.object.get("pending_directives").?.array.items.len;
}

test "control pages pending status with the widest next cursor within one frame" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const frame = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(frame);
    defer driver.detach();
    const add = try cli.request(frame, &.{ "monitor", "add" }, "widest-monitor");
    const id = try taskId(try dispatch(frame, &driver, add, 501));
    try finish(&fixture, id);
    const hex_id = std.fmt.bytesToHex(id, .lower);
    for ([_][]const u8{ "pause", "resume" }) |verb| {
        const operation = try std.fmt.allocPrint(frame, "widest-{s}", .{verb});
        const control_request = try cli.request(frame, &.{ "monitor", verb, &hex_id }, operation);
        _ = try taskId(try dispatch(frame, &driver, control_request, 501));
    }
    var index = try driver.rebuild(frame);
    defer index.deinit();
    const head = &index.records[index.tasks.get(id).?].result.?.genesis;
    head.specification.wording.bytes = "a";
    const probe_bytes = try widestStatus(frame, &driver, &index);
    const probe = (try decodeFrame(frame, probe_bytes)).object.get("data").?;
    try std.testing.expectEqual(2, shownPending(probe));
    const next = try native.json.canonical(frame, probe.object.get("next").?);
    try std.testing.expect(next.len >= 50);
    const wording = try frame.alloc(u8, control.frame_bytes_max + 2 - probe_bytes.len);
    @memset(wording, 'a');
    head.specification.wording.bytes = wording;
    const bytes = try widestStatus(frame, &driver, &index);
    try std.testing.expect(bytes.len <= control.frame_bytes_max);
    const value = try decodeFrame(frame, bytes);
    const disposition = try native.json.text(value.object.get("status").?);
    try std.testing.expectEqualStrings("observed", disposition);
    const shown = value.object.get("data").?;
    try std.testing.expectEqual(1, shownPending(shown));
    try std.testing.expectEqualDeep(
        @as(?t.Id, id),
        try native.values.fromJson(?t.Id, frame, shown.object.get("next").?),
    );
}
