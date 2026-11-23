const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const control = @import("../native/control.zig");
const configuration = @import("../native/configuration.zig");
const cli = @import("../native/cli.zig");
const contracts = @import("contracts.zig");
const Fixture = @import("native_restore.zig").Fixture;
const Driver = @import("native_restore.zig").Driver;

fn config() configuration.Config {
    const specification = contracts.specification();
    const repository = specification.repository;
    const destination = specification.destination;
    return .{
        .version = 1,
        .current_uid = 501,
        .namespace_path = "/tmp/unused-recovery-control",
        .control_socket_path = "/tmp/unused-recovery-control.sock",
        .repository = .{
            .account = repository.account.bytes,
            .id = repository.id,
            .owner = repository.owner.bytes,
            .name = repository.name.bytes,
            .ref = repository.ref.bytes,
        },
        .slack = .{
            .account = destination.account.bytes,
            .app = destination.app.bytes,
            .workspace = destination.workspace.bytes,
            .operator = destination.operator.bytes,
            .channel = destination.channel.bytes,
            .bot_id = "B1",
        },
    };
}

const Clock = struct {
    fn now(_: *anyopaque) !i64 {
        return 1000;
    }
};

fn call(
    a: std.mem.Allocator,
    driver: *Driver,
    selected: configuration.Config,
    operation: ?[]const u8,
    command: @FieldType(control.Request, "command"),
) !native.json.Value {
    const request = try control.encode(a, .{
        .version = 1,
        .operation = if (operation) |value| .{ .bytes = value } else null,
        .command = command,
    });
    const response = try control.dispatch(a, driver, selected, 501, request);
    return (try native.json.parse(a, response, .{})).value;
}

fn taskId(value: native.json.Value) !t.Id {
    try std.testing.expectEqualStrings(
        "admitted",
        try native.json.text(value.object.get("status").?),
    );
    return cli.hex(t.Id, try native.json.text(value.object.get("data").?.object.get("task").?));
}

fn reject(value: native.json.Value, expected: []const u8) !void {
    try std.testing.expectEqualStrings(
        "rejected",
        try native.json.text(value.object.get("status").?),
    );
    try std.testing.expectEqualStrings(expected, try native.json.text(value.object.get("error").?));
}

fn count(a: std.mem.Allocator, driver: *Driver) !usize {
    var index = try driver.rebuild(a);
    defer index.deinit();
    return index.records.len;
}

fn distinctDirectiveIdentities(a: std.mem.Allocator, driver: *Driver, target: t.Id) !void {
    const local: t.Origin = .{ .local = .{ .uid = 501 } };
    const body: t.DirectiveBody = .{ .check = {} };
    const first = try driver.directive(a, "repeated-check-a", local, target, body);
    const second = try driver.directive(a, "repeated-check-b", local, target, body);
    try std.testing.expectEqualDeep(
        first,
        try driver.directive(a, "repeated-check-a", local, target, body),
    );
    var index = try driver.rebuild(a);
    defer index.deinit();
    const before = index.record(first).?.input.directive.envelope.stable_request;
    const after = index.record(second).?.input.directive.envelope.stable_request;
    try std.testing.expect(!std.meta.eql(before, after));
}

fn refusedReleases(
    a: std.mem.Allocator,
    driver: *Driver,
    target: t.Id,
    reference: t.InputReference,
) !void {
    const before = try count(a, driver);
    const release: @FieldType(control.Request, "command") = .{ .recovery_release = .{
        .recovery = reference,
        .exclusive_owner = true,
    } };
    var changed = config();
    changed.repository.id += 1;
    try reject(
        try call(a, driver, changed, "wrong-repository", release),
        "RecoveryResourceMismatch",
    );
    try std.testing.expectEqual(before, try count(a, driver));
    changed = config();
    changed.slack.channel = "D-other";
    try reject(
        try call(a, driver, changed, "wrong-destination", release),
        "RecoveryResourceMismatch",
    );
    try std.testing.expectEqual(before, try count(a, driver));
    const direct: @FieldType(control.Request, "command") = .{ .directive = .{
        .target = target,
        .body = .{ .recovery_release = .{ .recovery = reference, .exclusive_owner = true } },
    } };
    try reject(try call(a, driver, changed, "wrong-directive", direct), "RecoveryResourceMismatch");
    try std.testing.expectEqual(before, try count(a, driver));
    var nonexclusive = release;
    nonexclusive.recovery_release.exclusive_owner = false;
    try reject(
        try call(a, driver, config(), "not-exclusive", nonexclusive),
        "RestoreExclusiveOwnerRequired",
    );
    try std.testing.expectEqual(before, try count(a, driver));
}

test "native recovery control validates bindings before mutation and replays exact release" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const genesis = contracts.genesis();
    const target = try fixture.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    try distinctDirectiveIdentities(a, &driver, target);
    const marker = try taskId(try call(a, &driver, config(), "control-recovery", .{
        .recovery_begin = {},
    }));
    var index = try driver.rebuild(a);
    const reference = index.recovery.?;
    try std.testing.expectEqualDeep(marker, reference.task);
    try std.testing.expect(index.recovery_hold);
    index.deinit();
    try refusedReleases(a, &driver, target, reference);
    const command: @FieldType(control.Request, "command") = .{ .recovery_release = .{
        .recovery = reference,
        .exclusive_owner = true,
    } };
    const released = try taskId(try call(a, &driver, config(), "control-release", command));
    const before = try count(a, &driver);
    var changed = config();
    changed.repository.id += 1;
    changed.slack.channel = "D-other";
    const replay = try taskId(try call(a, &driver, changed, "control-release", command));
    try std.testing.expectEqualDeep(released, replay);
    try std.testing.expectEqual(before, try count(a, &driver));
    const status = try call(a, &driver, config(), null, .{ .recovery_status = {} });
    try std.testing.expectEqualStrings(
        "observed",
        try native.json.text(status.object.get("status").?),
    );
    const data = status.object.get("data").?.object;
    try std.testing.expect(!data.get("recovery_hold").?.bool);
    try std.testing.expect(!data.get("import_hold").?.bool);
    const saved = data.get("recovery").?.object;
    try std.testing.expectEqualDeep(reference.task, try cli.hex(
        t.Id,
        try native.json.text(saved.get("task").?),
    ));
    try std.testing.expectEqualDeep(reference.digest, try cli.hex(
        t.Digest,
        try native.json.text(saved.get("digest").?),
    ));
    try std.testing.expect(try cutSize(data) > 0);
}

const large_cut_directives = 1_400;

fn seedDirectives(fixture: *Fixture, target: t.Id) !void {
    var prior: ?t.InputReference = null;
    for (1..large_cut_directives + 1) |ordinal| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const operation = try std.fmt.allocPrint(a, "large-cut-directive:{d}", .{ordinal});
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
        const id = try fixture.execute(operation, input);
        const bytes = try c.encodeOwned(t.Input, a, input);
        prior = .{ .task = id, .digest = @import("../native/index.zig").digest(bytes) };
    }
}

fn cutSize(data: std.json.ObjectMap) !u64 {
    return std.fmt.parseInt(u64, try native.json.text(data.get("restore_cut_size").?), 10);
}

fn observedRecovery(a: std.mem.Allocator, driver: *Driver) !std.json.ObjectMap {
    const reply = try call(a, driver, config(), null, .{ .recovery_status = {} });
    const status = try native.json.text(reply.object.get("status").?);
    try std.testing.expectEqualStrings("observed", status);
    return reply.object.get("data").?.object;
}

fn cliRelease(a: std.mem.Allocator, driver: *Driver, recovery: std.json.ObjectMap) !t.Id {
    const request = try cli.request(a, &.{
        "recovery",
        "release",
        try native.json.text(recovery.get("task").?),
        try native.json.text(recovery.get("digest").?),
        "--exclusive-owner",
    }, "large-cut-release");
    const response = try control.dispatch(a, driver, config(), 501, request);
    return taskId((try native.json.parse(a, response, .{})).value);
}

test "native recovery status stays framed for a large cut and its boundary releases via CLI" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const genesis = contracts.genesis();
    const target = try fixture.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    try seedDirectives(&fixture, target);
    var clock: u8 = 0;
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    const marker = try taskId(try call(a, &driver, config(), "large-cut-begin", .{
        .recovery_begin = {},
    }));
    const held = try observedRecovery(a, &driver);
    try std.testing.expect(held.get("recovery_hold").?.bool);
    try std.testing.expect(try cutSize(held) > large_cut_directives);
    const recovery = held.get("recovery").?.object;
    try std.testing.expectEqualDeep(marker, try cli.hex(
        t.Id,
        try native.json.text(recovery.get("task").?),
    ));
    _ = try cliRelease(a, &driver, recovery);
    const released = try observedRecovery(a, &driver);
    try std.testing.expect(!released.get("recovery_hold").?.bool);
    try std.testing.expectEqualStrings(
        try native.json.text(held.get("restore_cut_digest").?),
        try native.json.text(released.get("restore_cut_digest").?),
    );
}
