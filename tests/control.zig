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

test "control protocol freezes activation retry and acknowledges persisted restrictive controls" {
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
        const operation = try std.fmt.allocPrint(frame, "paged-control:{d}", .{position});
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
        const operation = try std.fmt.allocPrint(frame, "large:{s}:{d}", .{
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
        const name = try std.fmt.allocPrint(frame, "large-monitor:{d}", .{position});
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
            .delivery = try (try b.caseOf(input, "delivery")).fail(output, failure),
            .experiment = try (try b.caseOf(input, "experiment")).fail(output, failure),
            .continuity_member = try (try b.caseOf(input, "continuity_member")).fail(
                output,
                failure,
            ),
            .continuity_cut = try (try b.caseOf(input, "continuity_cut")).fail(output, failure),
            .restore = try (try b.caseOf(input, "restore")).fail(output, failure),
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
        .interval_ms = std.math.maxInt(u64),
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
