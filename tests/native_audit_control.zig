const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const audit = @import("../native/audit_control.zig");
const eligibility = @import("../native/eligibility.zig");
const Driver = @import("../native/driver.zig").Driver(t);
const Fixture = @import("native_fixture.zig").Fixture(t, @import("slack_owner.zig").Application);

const Clock = struct {
    fn now(_: *anyopaque) !i64 {
        return 1000;
    }
};

fn stored(f: *Fixture, task: t.Id) !c.Decoded(t.Input) {
    const a = f.arena.allocator();
    var value = (try f.service.?.applicationValue(a, task, .input)).?;
    defer value.deinit();
    return c.decodeOwned(t.Input, a, value.bytes);
}

fn finish(f: *Fixture, task: t.Id) !void {
    var input = try stored(f, task);
    defer input.deinit();
    const name = switch (input.value) {
        inline else => |value| value.envelope.operation.bytes,
    };
    try std.testing.expectEqualDeep(task, try f.execute(name, input.value));
}

fn allowed(driver: *Driver, a: std.mem.Allocator, task: t.Id, capability: []const u8) !bool {
    var index = try driver.rebuild(a);
    defer index.deinit();
    return eligibility.permits(a, &index, .{
        .task = task,
        .identity = @splat(1),
        .kind = .acquisition,
        .capability = capability,
    }, -9_999_999);
}

fn finalDelivery(f: *Fixture, driver: *Driver) !t.DeliveryKey {
    const a = f.arena.allocator();
    const genesis = @import("contracts.zig").genesis();
    const target = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    const deliveries = try driver.deliveries(a, target);
    try std.testing.expectEqual(1, deliveries.len);
    var input = try stored(f, deliveries[0]);
    defer input.deinit();
    const key = input.value.delivery.key;
    _ = try driver.directive(a, "final-cancel", .{ .local = .{ .uid = 501 } }, target, .cancel);
    try finish(f, (try driver.nextStep(a, target)).?);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(.cancelled, index.head(index.obligation(target).?).mode);
    return key;
}

test "native audit control persists final recovery audit and permits only history after reopen" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    var clock: u8 = 0;
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &clock,
        .now = Clock.now,
    } };
    try driver.attach(a);
    const key = try finalDelivery(&f, &driver);
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    _ = try @import("../native/restore.zig").begin(&driver, a, "audit-recovery", origin);
    const task = try audit.request(&driver, a, "manual-final-audit", origin, key);
    var admitted = try stored(&f, task);
    defer admitted.deinit();
    try std.testing.expect(admitted.value.audit.latest == null);
    try std.testing.expectEqualDeep(key, admitted.value.audit.delivery.key);
    try std.testing.expect(try allowed(
        &driver,
        a,
        task,
        @import("../app/audit_contract.zig").identity,
    ));
    try std.testing.expect(!try allowed(
        &driver,
        a,
        task,
        @import("../app/slack_contract.zig").notification_identity,
    ));
    driver.detach();
    try f.close();
    try f.open();
    driver.service = &f.service.?;
    try driver.attach(a);
    defer driver.detach();
    try std.testing.expectEqualDeep(task, try audit.request(
        &driver,
        a,
        "manual-final-audit",
        origin,
        key,
    ));
    try std.testing.expect(try allowed(
        &driver,
        a,
        task,
        @import("../app/audit_contract.zig").identity,
    ));
    var reopened = try driver.rebuild(a);
    defer reopened.deinit();
    try std.testing.expect(reopened.recovery_hold);
}
