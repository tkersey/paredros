const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const owner = @import("../native/slack_owner.zig");
const config = @import("../native/configuration.zig");
const prep = @import("../native/delivery_prepare.zig");
const evidence = @import("../native/interaction_evidence.zig");
const Driver = @import("../native/driver.zig").Driver(t);
const Consumer = @import("control.zig");
const Fixture = @import("native_fixture.zig").Fixture(t, @import("slack_owner.zig").Application);

fn configuration() config.Config {
    return .{
        .version = 1,
        .current_uid = 501,
        .namespace_path = "/unused-slack-owner",
        .control_socket_path = "/unused-slack-owner.sock",
        .repository = .{
            .account = "github",
            .id = 1,
            .owner = "owner",
            .name = "repo",
            .ref = "refs/heads/main",
        },
        .slack = .{
            .account = "slack",
            .app = "A1",
            .workspace = "T1",
            .operator = "U1",
            .channel = "D1",
            .bot_id = "B1",
        },
    };
}

const Clock = struct {
    now_ms: i64 = 1000,

    fn now(context: *anyopaque) !i64 {
        const self: *Clock = @ptrCast(@alignCast(context));
        return self.now_ms;
    }
};

fn event(a: std.mem.Allocator, envelope: []const u8, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .envelope_id = envelope,
        .type = "events_api",
        .payload = .{
            .api_app_id = "A1",
            .team_id = "T1",
            .type = "event_callback",
            .event_id = "stable-event",
            .event = .{
                .type = "message",
                .user = "U1",
                .channel = "D1",
                .channel_type = "im",
                .ts = "100.000001",
                .text = text,
            },
        },
    }, .{});
}

fn modified(
    a: std.mem.Allocator,
    bytes: []const u8,
    path: []const []const u8,
    value: std.json.Value,
) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    var cursor = &parsed.value;
    for (path[0 .. path.len - 1]) |key| cursor = cursor.object.getPtr(key).?;
    try cursor.object.put(parsed.arena.allocator(), path[path.len - 1], value);
    return std.json.Stringify.valueAlloc(a, parsed.value, .{});
}

fn genesis(name: []const u8) t.Genesis {
    var value = @import("contracts.zig").genesis();
    value.envelope.operation.bytes = name;
    value.specification.destination = configuration().slack.destination();
    return value;
}

fn stored(f: *Fixture, task: t.Id) !c.Decoded(t.Input) {
    const a = f.arena.allocator();
    var bytes = (try f.service.?.applicationValue(a, task, .input)).?;
    defer bytes.deinit();
    return c.decodeOwned(t.Input, a, bytes.bytes);
}

test "native Slack owner persists before return and replays frozen context after reopen" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const target = try f.execute("first", .{ .genesis = genesis("first") });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(a);
    const bytes = try event(a, "first-envelope", "pause?");
    const task = (try owner.admit(&driver, a, configuration(), bytes)).admitted;
    var first = try stored(&f, task);
    defer first.deinit();
    try std.testing.expectEqualDeep(target, first.value.turn.target.?);
    try std.testing.expect(first.value.turn.context_references.items.len > 0);
    var receipt = (try f.service.?.operationLookup(
        a,
        first.value.turn.envelope.operation.bytes,
    )).?;
    defer receipt.deinit();
    try std.testing.expectEqualDeep(task, receipt.value.task);
    driver.detach();
    try f.close();
    try f.open();
    driver.service = &f.service.?;
    try driver.attach(a);
    defer driver.detach();
    _ = try f.execute("second", .{ .genesis = genesis("second") });
    const retry = try event(a, "redelivered-envelope", "pause?");
    try std.testing.expectEqualDeep(task, (try owner.admit(
        &driver,
        a,
        configuration(),
        retry,
    )).admitted);
    var after = try stored(&f, task);
    defer after.deinit();
    try std.testing.expectEqualDeep(first.value, after.value);
    try std.testing.expectError(error.OperationConflict, owner.admit(
        &driver,
        a,
        configuration(),
        try event(a, "changed-envelope", "cancel?"),
    ));
}

test "native Slack owner ignores unauthenticated and unsupported messages without tasks" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(a);
    defer driver.detach();
    const bytes = try event(a, "ignored-envelope", "pause?");
    for ([_][]const u8{ "user", "channel", "bot_id", "subtype", "thread_ts" }) |field| {
        const forged = try modified(a, bytes, &.{ "payload", "event", field }, .{
            .string = "forged",
        });
        try std.testing.expect((try owner.admit(&driver, a, configuration(), forged)) == .ignored);
    }
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(0, index.records.len);
}

fn execute(f: *Fixture, input: t.Input) !t.Id {
    const a = f.arena.allocator();
    const operation = switch (input) {
        inline else => |value| value.envelope.operation.bytes,
    };
    const id = (try f.service.?.submit(a, operation, input)).receipt.task;
    for (0..16384) |_| {
        var task = try f.service.?.task(a, id);
        defer task.deinit();
        if (task.value.terminal()) {
            try std.testing.expectEqual(.completed, task.value.outcome_kind);
            return id;
        }
        switch (try f.service.?.pump(a)) {
            .work => |work| {
                try f.service.?.notSent(a, work);
                return error.UnexpectedExternalWork;
            },
            else => {},
        }
    }
    return error.TaskDidNotComplete;
}

fn proposal(f: *Fixture, driver: *Driver, target: t.Id) !t.Id {
    const a = f.arena.allocator();
    const turn: t.Turn = .{
        .envelope = .{
            .operation = .{ .bytes = "offered-pause" },
            .stable_request = @splat(42),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .destination = configuration().slack.destination(),
        .text = .{ .bytes = "Pause this obligation." },
        .context = .{ .bytes = "" },
        .context_references = .{ .items = &.{} },
        .attempt = 0,
        .model = @import("control.zig").consumerBinding(),
        .target = target,
        .expected_revision = 0,
        .proposal_offers = .{ .items = &.{.{ .directive = .pause }} },
    };
    const task = try execute(f, .{ .turn = turn });
    var index = try driver.rebuild(a);
    defer index.deinit();
    const record = index.record(task).?;
    try std.testing.expectEqual(1, record.result.?.turn.proposals.items.len);
    const intent = record.result.?.turn.delivery.?;
    try std.testing.expectEqual(1, intent.payload.buttons.items.len);
    return admitDelivery(f, intent, .{ .task = task, .digest = record.result_digest.? });
}

fn admitDelivery(f: *Fixture, intent: t.DeliveryIntent, producer: t.Reference) !t.Id {
    const a = f.arena.allocator();
    var delivery = try prep.materialize(a, intent, producer, @splat(8), "B1");
    defer delivery.deinit();
    return (try f.service.?.submit(a, delivery.value.envelope.operation.bytes, .{
        .delivery = delivery.value,
    })).receipt.task;
}

fn click(f: *Fixture, delivery: t.Id, envelope: []const u8, action_ts: []const u8) ![]const u8 {
    const a = f.arena.allocator();
    var input = try stored(f, delivery);
    defer input.deinit();
    const value = input.value.delivery;
    const button = value.payload.logical.buttons.items[0];
    var wire = try std.json.parseFromSlice(std.json.Value, a, value.payload.wire_json.bytes, .{});
    defer wire.deinit();
    return std.json.Stringify.valueAlloc(a, .{
        .envelope_id = envelope,
        .type = "interactive",
        .payload = .{
            .type = "block_actions",
            .api_app_id = "A1",
            .team = .{ .id = "T1" },
            .user = .{ .id = "U1" },
            .channel = .{ .id = "D1" },
            .container = .{
                .type = "message",
                .channel_id = "D1",
                .message_ts = "100.000003",
            },
            .message = .{
                .app_id = "A1",
                .bot_id = "B1",
                .team = "T1",
                .ts = "100.000003",
                .text = "Provider rendered text",
                .blocks = wire.value.object.get("blocks").?,
                .metadata = wire.value.object.get("metadata").?,
            },
            .actions = .{.{
                .type = "button",
                .block_id = button.block_id.bytes,
                .action_id = button.action_id.bytes,
                .value = button.value.bytes,
                .action_ts = action_ts,
            }},
        },
    }, .{});
}

fn boundReceipt(driver: *Driver, a: std.mem.Allocator, task: t.Id, delivery: t.Id) !void {
    var index = try driver.rebuild(a);
    defer index.deinit();
    const source = index.record(delivery).?;
    try std.testing.expect(source.result == null);
    try std.testing.expect(try evidence.knownTimestamp(a, source.*) == null);
    const fact = (try evidence.settlement(a, &index, index.record(task).?.*)).?;
    try std.testing.expectEqual(.bound_interaction, fact.receipt.?.basis);
    try std.testing.expectEqualStrings("100.000003", fact.receipt.?.timestamp.bytes);
    try std.testing.expectEqualDeep(task, fact.receipt.?.evidence.task);
}

test "native Slack owner binds unknown receipt proposal and persists exact confirmation" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const target = try execute(&f, .{ .genesis = genesis("proposal-target") });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(a);
    const delivery = try proposal(&f, &driver, target);
    const bytes = try click(&f, delivery, "proposal-click", "100.000004");
    const task = (try owner.admit(&driver, a, configuration(), bytes)).admitted;
    var input = try stored(&f, task);
    defer input.deinit();
    try std.testing.expectEqualDeep(target, input.value.directive.obligation);
    try std.testing.expect(input.value.directive.body == .pause);
    try boundReceipt(&driver, a, task, delivery);
    driver.detach();
    try f.close();
    try f.open();
    driver.service = &f.service.?;
    try driver.attach(a);
    defer driver.detach();
    const retry = try click(&f, delivery, "proposal-redelivery", "100.000004");
    try std.testing.expectEqualDeep(task, (try owner.admit(
        &driver,
        a,
        configuration(),
        retry,
    )).admitted);
    try boundReceipt(&driver, a, task, delivery);
    try tamperedRefusal(&f, &driver, delivery);
}

fn tamperedRefusal(f: *Fixture, driver: *Driver, delivery: t.Id) !void {
    const a = f.arena.allocator();
    const bytes = try click(f, delivery, "tampered-click", "100.000005");
    const forged = try modified(a, bytes, &.{ "payload", "message", "blocks" }, .null);
    const task = (try owner.admit(driver, a, configuration(), forged)).admitted;
    var input = try stored(f, task);
    defer input.deinit();
    try std.testing.expectEqualStrings(
        "UnknownOrUnboundProposal",
        input.value.turn.refusal.?.bytes,
    );
    try std.testing.expect(input.value.turn.envelope.ingress.?.interaction == null);
    try std.testing.expectEqualDeep(task, (try owner.admit(
        driver,
        a,
        configuration(),
        forged,
    )).admitted);
    _ = try execute(f, input.value);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(0, index.record(task).?.result.?.turn.proposals.items.len);
}

test "native Slack owner final target produces durable refusal on exact proposal click" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const target = try execute(&f, .{ .genesis = genesis("final-target") });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(a);
    defer driver.detach();
    const delivery = try proposal(&f, &driver, target);
    _ = try driver.directive(a, "cancel-target", .{ .local = .{ .uid = 501 } }, target, .cancel);
    _ = try advance(&f, &driver, target);
    const bytes = try click(&f, delivery, "final-click", "100.000004");
    const task = (try owner.admit(&driver, a, configuration(), bytes)).admitted;
    var input = try stored(&f, task);
    defer input.deinit();
    try std.testing.expectEqualStrings("FinalObligation", input.value.turn.refusal.?.bytes);
    try std.testing.expect(input.value.turn.envelope.ingress.?.interaction != null);
    try std.testing.expectEqualDeep(task, (try owner.admit(
        &driver,
        a,
        configuration(),
        try click(&f, delivery, "final-retry", "100.000004"),
    )).admitted);
    _ = try execute(&f, input.value);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(1, index.obligation(target).?.directives.len);
    try std.testing.expectEqual(.cancelled, index.head(index.obligation(target).?).mode);
    try std.testing.expectEqual(0, index.record(task).?.result.?.turn.proposals.items.len);
}

fn advance(f: *Fixture, driver: *Driver, target: t.Id) !t.Id {
    const task = (try driver.nextStep(f.arena.allocator(), target)).?;
    var input = try stored(f, task);
    defer input.deinit();
    try std.testing.expectEqualDeep(task, try execute(f, input.value));
    return task;
}

test "native Slack owner binds exact question answer with no original delivery receipt" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const target = try execute(&f, .{ .genesis = genesis("question-target") });
    var clock: Clock = .{};
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(a);
    defer driver.detach();
    _ = try advance(&f, &driver, target);
    clock.now_ms = 1_000_000;
    const publication = try advance(&f, &driver, target);
    var index = try driver.rebuild(a);
    const producer: t.Reference = .{
        .task = publication,
        .digest = index.record(publication).?.result_digest.?,
    };
    const question = index.head(index.obligation(target).?).question.?;
    const identity = question.identity;
    const delivery = try admitDelivery(&f, question.prompt, producer);
    index.deinit();
    const bytes = try click(&f, delivery, "answer-click", "100.000004");
    const task = (try owner.admit(&driver, a, configuration(), bytes)).admitted;
    var input = try stored(&f, task);
    defer input.deinit();
    try std.testing.expectEqualDeep(target, input.value.directive.obligation);
    try std.testing.expectEqualDeep(
        identity,
        input.value.directive.body.answer.question,
    );
    try std.testing.expectEqualStrings(
        "accept_gap",
        input.value.directive.body.answer.choice.bytes,
    );
    try boundReceipt(&driver, a, task, delivery);
}
