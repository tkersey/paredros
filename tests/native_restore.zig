const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const contracts = @import("contracts.zig");
const chain = @import("../app/directive_chain.zig");
const policy = @import("directive_policy.zig");
const PolicyFixture = @import("native_fixture.zig").Fixture(policy.Types, policy.Application);
const restore = @import("../native/restore.zig");
const app = @import("../native/application.zig");
pub const Driver = @import("../native/driver.zig").Driver(app.Types);
pub const Fixture = @import("product_fixture.zig").Fixture;

const origin: t.Origin = .{ .local = .{ .uid = 501 } };
const boundary: t.InputReference = .{ .task = @splat(7), .digest = @splat(8) };

fn directive(id: u8, previous: ?t.InputReference, body: t.DirectiveBody) t.DirectiveFact {
    return .{
        .reference = .{ .task = @splat(id), .digest = @splat(id + 10) },
        .value = .{
            .envelope = .{
                .operation = .{ .bytes = "restore-policy" },
                .stable_request = @splat(id),
                .origin = origin,
            },
            .obligation = @splat(1),
            .ordinal = id,
            .predecessor = previous,
            .body = body,
        },
    };
}

fn policyInput(head: t.Head, facts: []const t.DirectiveFact) chain.Input {
    return .{ .obligation = @splat(1), .head = head, .directives = .{ .items = facts } };
}

test "native restore policy preserves desired modes and never releases uncertain digest" {
    var f: PolicyFixture = .{};
    defer f.deinit();
    try f.init();
    var head = @import("native_genesis.zig").expectedFresh(contracts.genesis());
    head.obligation = .{ .task = @splat(1) };
    head.digest = .{ .delivery = head.activation.?, .hold = .none, .not_before_ms = 0 };
    const hold = directive(1, null, .{ .recovery_hold = .{ .recovery = boundary } });
    const released = directive(2, hold.reference, .{ .recovery_release = .{
        .recovery = boundary,
        .exclusive_owner = true,
    } });
    const held = try f.output(try f.execute("restore-hold", policyInput(head, &.{hold})));
    try std.testing.expectEqual(.paused, held.head.mode);
    try std.testing.expectEqual(head.desired_mode, held.head.desired_mode);
    try std.testing.expect(held.head.recovery_hold);
    try std.testing.expectEqualDeep(boundary, held.head.recovery_boundary.?);
    try std.testing.expectEqual(.uncertain_transmission, held.head.digest.?.hold);
    const done = try f.output(try f.execute(
        "restore-release",
        policyInput(held.head, &.{released}),
    ));
    try std.testing.expectEqual(.active, done.head.mode);
    try std.testing.expect(!done.head.recovery_hold);
    try std.testing.expect(done.head.recovery_boundary == null);
    try std.testing.expectEqual(.uncertain_transmission, done.head.digest.?.hold);
    head.mode = .paused;
    head.desired_mode = .paused;
    const paused = try f.output(try f.execute(
        "restore-paused",
        policyInput(head, &.{ hold, released }),
    ));
    try std.testing.expectEqual(.paused, paused.head.mode);
    head.mode = .cancelled;
    head.desired_mode = .cancelled;
    const final = try f.output(try f.execute("restore-final", policyInput(head, &.{hold})));
    try std.testing.expectEqual(.cancelled, final.head.mode);
    try std.testing.expect(final.dispositions.items[0].outcome == .rejected);
}

test "native restore policy rejects wrong boundary nonexclusive and remote release" {
    var f: PolicyFixture = .{};
    defer f.deinit();
    try f.init();
    var head = @import("native_genesis.zig").expectedFresh(contracts.genesis());
    head.obligation = .{ .task = @splat(1) };
    head.mode = .paused;
    head.recovery_hold = true;
    head.recovery_boundary = boundary;
    const release_body: t.DirectiveBody = .{ .recovery_release = .{
        .recovery = boundary,
        .exclusive_owner = true,
    } };
    const candidate = directive(1, null, release_body);
    var cases = [_]t.DirectiveFact{ candidate, candidate, candidate };
    cases[0].value.body.recovery_release.recovery.digest = @splat(99);
    cases[1].value.body.recovery_release.exclusive_owner = false;
    cases[2].value.envelope.origin = .{ .derived = .{
        .predecessor = .{ .task = @splat(3), .digest = @splat(4) },
    } };
    for (cases, [_][]const u8{ "wrong-boundary", "nonexclusive", "remote-release" }) |fact, name| {
        const value = try f.output(try f.execute(name, policyInput(head, &.{fact})));
        try std.testing.expect(value.dispositions.items[0].outcome == .rejected);
        try std.testing.expect(value.head.recovery_hold);
        try std.testing.expectEqualDeep(boundary, value.head.recovery_boundary.?);
    }
}

const Clock = struct {
    fn now(_: *anyopaque) !i64 {
        return 1000;
    }
};

const Interrupted = struct {
    service: @FieldType(Driver, "service"),
    attached: bool = true,
    driver: *Driver,

    pub fn rebuild(self: *@This(), a: std.mem.Allocator) !@import("../native/index.zig").Index {
        return self.driver.rebuild(a);
    }

    pub fn directive(
        _: *@This(),
        _: std.mem.Allocator,
        _: []const u8,
        _: t.Origin,
        _: t.Id,
        _: t.DirectiveBody,
    ) !t.Id {
        return error.InterruptedHoldAdmission;
    }
};

fn finish(fixture: *Fixture, task: t.Id) !void {
    const a = fixture.arena.allocator();
    var bytes = (try fixture.service.?.applicationValue(a, task, .input)).?;
    defer bytes.deinit();
    var input = try c.decodeOwned(t.Input, a, bytes.bytes);
    defer input.deinit();
    const operation = switch (input.value) {
        inline else => |value| value.envelope.operation.bytes,
    };
    try std.testing.expectEqualDeep(task, try fixture.execute(operation, input.value));
}

fn verifyReleasedEligibility(index: *@import("../native/index.zig").Index, target: t.Id) !void {
    const gate = @import("../native/restore_eligibility.zig");
    const preparation = @import("../native/delivery_prepare.zig");
    const obligation = index.obligation(target).?;
    const producer = index.reference(obligation.chain[obligation.chain.len - 1]);
    const a = index.arena.allocator();
    var intent = index.head(obligation).activation.?;
    var old = try preparation.materialize(a, intent, producer, @splat(0), "B1");
    defer old.deinit();
    try std.testing.expect(!gate.allows(index, old.value));
    intent.key.generation += 1;
    var generation = try preparation.materialize(a, intent, producer, @splat(0), "B1");
    defer generation.deinit();
    try std.testing.expect(!gate.allows(index, generation.value));
    intent.key.purpose = .digest;
    intent.key.identity = index.record(producer.task).?.input.step.envelope.stable_request;
    intent.key.generation = 0;
    intent.payload.obligation = target;
    intent.payload.prior_sequence = 0;
    intent.payload.through_sequence = 1;
    intent.payload.coverage = .{ .sequence = 1, .epoch = 0, .tip = @splat('a') };
    var fresh = try preparation.materialize(a, intent, producer, @splat(0), "B1");
    defer fresh.deinit();
    try std.testing.expect(gate.allows(index, fresh.value));
    index.recovery_hold = true;
    try std.testing.expect(!gate.allows(index, fresh.value));
}

test "native restore begin survives reopen and release folds held obligations once" {
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
    var interrupted: Interrupted = .{ .service = driver.service, .driver = &driver };
    try std.testing.expectError(
        error.InterruptedHoldAdmission,
        restore.begin(&interrupted, a, "known-rollback", origin),
    );
    var before = try driver.rebuild(a);
    const reference = before.recovery.?;
    const task = reference.task;
    try std.testing.expect(before.recovery_hold);
    try std.testing.expectEqual(0, before.obligation(target).?.directives.len);
    before.deinit();
    driver.detach();
    try fixture.close();
    try fixture.open();
    driver.service = &fixture.service.?;
    try driver.attach(a);
    defer driver.detach();
    try std.testing.expectEqualDeep(task, try restore.begin(&driver, a, "known-rollback", origin));
    try std.testing.expectError(
        error.RestoreExclusiveOwnerRequired,
        restore.release(&driver, a, "release-recovery", origin, reference, false),
    );
    const released = try restore.release(&driver, a, "release-recovery", origin, reference, true);
    try std.testing.expectEqualDeep(
        released,
        try restore.release(&driver, a, "release-recovery", origin, reference, true),
    );
    const fold = (try driver.nextStep(a, target)).?;
    try finish(&fixture, fold);
    var after = try driver.rebuild(a);
    defer after.deinit();
    try std.testing.expect(!after.recovery_hold);
    try std.testing.expectEqual(2, after.obligation(target).?.directives.len);
    try std.testing.expect(!after.head(after.obligation(target).?).recovery_hold);
    try std.testing.expectEqual(.active, after.head(after.obligation(target).?).mode);
    try std.testing.expect(after.restore_cut.len > 0);
    try verifyReleasedEligibility(&after, target);
}

test "native restore beginTransfer binds export request and cannot reopen source" {
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
    const task = try restore.beginTransfer(&driver, a, "transfer-source", origin, @splat(11));
    try std.testing.expectEqualDeep(
        task,
        try restore.beginTransfer(&driver, a, "transfer-source", origin, @splat(11)),
    );
    try std.testing.expectError(
        error.OperationConflict,
        restore.beginTransfer(&driver, a, "transfer-source", origin, @splat(12)),
    );
    try std.testing.expectError(
        error.RestoreTransferPermanent,
        restore.begin(&driver, a, "rollback-after-transfer", origin),
    );
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(t.RestorePurpose.transfer, index.recovery_purpose.?);
    try std.testing.expect(index.recovery_hold);
    try std.testing.expectEqual(1, index.obligation(target).?.directives.len);
    try std.testing.expectError(
        error.RestoreTransferPermanent,
        restore.release(&driver, a, "release-transfer", origin, index.recovery.?, true),
    );
    try std.testing.expectError(
        error.RestoreTransferPermanent,
        driver.directive(a, "release-transfer-head", origin, target, .{ .recovery_release = .{
            .recovery = index.recovery.?,
            .exclusive_owner = true,
        } }),
    );
}
