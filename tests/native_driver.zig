const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const app = @import("../native/application.zig");
const t = @import("application_types");
const fixture_values = @import("contracts.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};
const Fixture = @import("native_fixture.zig").Fixture(app.Types, Application);

const Clock = struct {
    now_ms: i64 = 200,

    fn now(context: *anyopaque) !i64 {
        const self: *Clock = @ptrCast(@alignCast(context));
        return self.now_ms;
    }
};

fn finish(fixture: *Fixture, task_id: t.Id) !void {
    const a = fixture.arena.allocator();
    var input = (try fixture.service.?.applicationValue(a, task_id, .input)).?;
    defer input.deinit();
    var decoded = try c.decodeOwned(t.Input, a, input.bytes);
    defer decoded.deinit();
    const operation = switch (decoded.value) {
        inline else => |value| value.envelope.operation.bytes,
    };
    try std.testing.expectEqualDeep(task_id, try fixture.execute(operation, decoded.value));
}

test "native driver admits controls once and reconstructs its pause fence after reopen" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const initial = fixture_values.genesis();
    const target = try fixture.execute(initial.envelope.operation.bytes, .{ .genesis = initial });
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    const control = try driver.directive(a, "driver-pause", origin, target, .{ .pause = {} });
    var before = try driver.rebuild(a);
    try std.testing.expectEqual(t.Mode.active, before.head(before.obligation(target).?).mode);
    try std.testing.expect(!before.obligation(target).?.ordinaryDispatch());
    before.deinit();
    const phase = (try driver.nextStep(a, target)).?;
    try finish(&fixture, phase);
    var after = try driver.rebuild(a);
    try std.testing.expectEqual(t.Mode.paused, after.head(after.obligation(target).?).mode);
    try std.testing.expectEqual(1, after.head(after.obligation(target).?).folded_directive_ordinal);
    after.deinit();
    try std.testing.expectEqualDeep(
        control,
        try driver.directive(a, "driver-pause", origin, target, .{ .pause = {} }),
    );
    try std.testing.expectError(
        error.OperationConflict,
        driver.directive(a, "driver-pause", origin, target, .{ .@"resume" = {} }),
    );
    driver.detach();
    try fixture.close();
    try fixture.open();
    driver.service = &fixture.service.?;
    try driver.attach(a);
    defer driver.detach();
    var reopened = try driver.rebuild(a);
    defer reopened.deinit();
    try std.testing.expectEqual(t.Mode.paused, reopened.head(reopened.obligation(target).?).mode);
    try std.testing.expectEqual(@as(?t.Id, null), try driver.nextStep(a, target));
    try std.testing.expectEqualDeep(
        control,
        try driver.directive(a, "driver-pause", origin, target, .{ .pause = {} }),
    );
}

test {
    _ = @import("application.zig").NativeTests(native);
}

test "native driver replaces a fenced live step with a receipt bound fold" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const initial = fixture_values.genesis();
    const target = try fixture.execute(initial.envelope.operation.bytes, .{ .genesis = initial });
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    const old = (try driver.nextStep(a, target)).?;
    _ = try driver.directive(
        a,
        "pause-live-step",
        .{ .local = .{ .uid = 501 } },
        target,
        .{ .pause = {} },
    );
    const replacement = (try driver.nextStep(a, target)).?;
    try std.testing.expect(!std.meta.eql(old, replacement));
    var before = try driver.rebuild(a);
    const successor = before.record(replacement).?.input.step;
    try std.testing.expect(successor.fold_only);
    try std.testing.expectEqual(1, successor.attempt);
    try std.testing.expectEqualDeep(old, successor.supersession.?.input.task);
    try std.testing.expectEqualDeep(
        before.record(old).?.input.step.predecessor,
        successor.predecessor,
    );
    before.deinit();
    try finish(&fixture, replacement);
    var after = try driver.rebuild(a);
    defer after.deinit();
    try std.testing.expect(after.record(old).?.superseded);
    try std.testing.expectEqual(t.Mode.paused, after.head(after.obligation(target).?).mode);
    try std.testing.expectEqual(0, after.head(after.obligation(target).?).check_failure_streak);
    try std.testing.expectEqual(0, after.head(after.obligation(target).?).accounting.known_calls);
}

test "native driver freezes turn context on first admission and rejects changed replay" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    const spec = fixture_values.specification();
    const target = try driver.genesis(a, "driver-new", origin, spec);
    try finish(&fixture, target);
    const request: @import("../native/commands.zig").TurnRequest = .{
        .target = target,
        .text = .{ .bytes = "yes" },
    };
    const turn = try driver.turn(a, "driver-turn", origin, request);
    try finish(&fixture, turn);
    _ = try driver.directive(a, "driver-context-pause", origin, target, .{ .pause = {} });
    const fold = (try driver.nextStep(a, target)).?;
    try finish(&fixture, fold);
    try std.testing.expectEqualDeep(turn, try driver.turn(a, "driver-turn", origin, request));
    var changed = request;
    changed.text.bytes = "different";
    try std.testing.expectError(
        error.OperationConflict,
        driver.turn(a, "driver-turn", origin, changed),
    );
    var index = try driver.rebuild(a);
    defer index.deinit();
    const record = index.record(turn).?;
    try std.testing.expectEqual(1, record.input.turn.ordinal);
    try std.testing.expectEqual(1, record.input.turn.context_references.items.len);
    try std.testing.expectEqualDeep(target, record.input.turn.context_references.items[0].task);
    try std.testing.expectEqual(0, record.result.?.turn.proposals.items.len);
    try std.testing.expectEqual(t.Mode.paused, index.head(index.obligation(target).?).mode);
}

fn cancelTurn(fixture: *Fixture, id: t.Id, operation: []const u8) !void {
    const a = fixture.arena.allocator();
    _ = try fixture.service.?.requestCancel(a, operation, id, "test interrupted turn");
    for (0..4096) |_| {
        var task = try fixture.service.?.task(a, id);
        defer task.deinit();
        if (task.value.terminal()) return;
        switch (try fixture.service.?.pump(a)) {
            .work => |work| {
                try fixture.service.?.notSent(a, work);
                return error.UnexpectedExternalWork;
            },
            else => {},
        }
    }
    return error.CancellationDidNotComplete;
}

test "native driver bounds turn replacement and preserves its original context through restart" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    const initial = try driver.turn(a, "turn-cancelled", .{ .local = .{ .uid = 501 } }, .{
        .text = .{ .bytes = "inspect" },
    });
    try cancelTurn(&fixture, initial, "test-cancel-initial");
    const first = try driver.recoverTurns(a, 8);
    try std.testing.expectEqual(1, first.len);
    try std.testing.expectEqual(0, (try driver.recoverTurns(a, 8)).len);
    try cancelTurn(&fixture, first[0], "test-cancel-replacement");
    const final = try driver.recoverTurns(a, 8);
    try std.testing.expectEqual(1, final.len);
    driver.detach();
    try fixture.close();
    try fixture.open();
    driver.service = &fixture.service.?;
    try driver.attach(a);
    try std.testing.expectEqual(0, (try driver.recoverTurns(a, 8)).len);
    try finish(&fixture, final[0]);
    var index = try driver.rebuild(a);
    defer index.deinit();
    const before = index.record(initial).?;
    const after = index.record(final[0]).?;
    try std.testing.expect(before.superseded);
    try std.testing.expect(index.record(first[0]).?.superseded);
    try std.testing.expect(!after.superseded);
    try std.testing.expectEqual(2, after.input.turn.attempt);
    try std.testing.expectEqualStrings(
        before.input.turn.context.bytes,
        after.input.turn.context.bytes,
    );
    try std.testing.expectEqualDeep(
        before.input.turn.context_references,
        after.input.turn.context_references,
    );
    try std.testing.expectEqualDeep(
        before.input.turn.envelope.stable_request,
        after.input.turn.envelope.stable_request,
    );
    try std.testing.expect(
        std.mem.find(u8, after.result.?.turn.reply.bytes, "could not complete") != null,
    );
    try std.testing.expectEqual(0, (try driver.recoverTurns(a, 8)).len);
}

test "native driver replaces parked incompatible folds and retains pending controls" {
    for ([_]enum { runtime, profile }{ .runtime, .profile }) |binding| {
        var fixture: Fixture = .{};
        defer fixture.deinit();
        try fixture.init();
        const a = fixture.arena.allocator();
        const initial = fixture_values.genesis();
        const target = try fixture.execute(
            initial.envelope.operation.bytes,
            .{ .genesis = initial },
        );
        var clock: Clock = .{};
        var driver: Driver = .{
            .service = &fixture.service.?,
            .clock = .{ .context = &clock, .now = Clock.now },
        };
        try driver.attach(a);
        defer driver.detach();
        const directive = try driver.directive(
            a,
            "upgrade-pause",
            .{ .local = .{ .uid = 501 } },
            target,
            .{ .pause = {} },
        );
        const ordinary = (try driver.nextStep(a, target)).?;
        const old = (try driver.nextStep(a, target)).?;
        try std.testing.expect(!std.meta.eql(ordinary, old));
        var prepared = try driver.rebuild(a);
        try std.testing.expect(prepared.record(old).?.input.step.fold_only);
        prepared.deinit();
        driver.detach();
        try fixture.close();
        switch (binding) {
            .runtime => fixture.profile.runtime_identity = @splat(43),
            .profile => fixture.profile.bytes = "changed-native-test-profile",
        }
        try fixture.open();
        driver.service = &fixture.service.?;
        try driver.attach(a);
        var parked = try fixture.service.?.task(a, old);
        defer parked.deinit();
        try std.testing.expectEqual(.parked, try fixture.service.?.status(a, parked.value));
        try std.testing.expect(parked.value.blocker == null);
        try std.testing.expectEqual(0, try driver.resumeRetained(a, 8));
        const replacement = (try driver.nextStep(a, target)).?;
        try std.testing.expect(!std.meta.eql(old, replacement));
        var before = try driver.rebuild(a);
        const successor = before.record(replacement).?.input.step;
        try std.testing.expect(successor.fold_only);
        try std.testing.expectEqual(.incompatible, successor.supersession.?.cause);
        try std.testing.expectEqualDeep(old, successor.supersession.?.input.task);
        try std.testing.expect(before.record(old).?.superseded);
        try std.testing.expect(before.record(directive) != null);
        before.deinit();
        try finish(&fixture, replacement);
        var after = try driver.rebuild(a);
        defer after.deinit();
        try std.testing.expectEqual(.paused, after.head(after.obligation(target).?).mode);
        try std.testing.expectEqual(
            1,
            after.head(after.obligation(target).?).folded_directive_ordinal,
        );
        try std.testing.expectEqual(@as(?t.Id, null), try driver.nextStep(a, target));
    }
}

test "native driver replaces a parked turn under changed runtime with frozen context" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    const old = try driver.turn(a, "upgrade-turn", .{ .local = .{ .uid = 501 } }, .{
        .text = .{ .bytes = "inspect the same retained evidence" },
    });
    driver.detach();
    try fixture.close();
    fixture.profile.runtime_identity = @splat(43);
    try fixture.open();
    driver.service = &fixture.service.?;
    try driver.attach(a);
    const replacements = try driver.recoverTurns(a, 8);
    try std.testing.expectEqual(1, replacements.len);
    const next = replacements[0];
    var index = try driver.rebuild(a);
    const original = index.record(old).?;
    const successor = index.record(next).?;
    try std.testing.expect(original.superseded);
    try std.testing.expectEqual(1, successor.input.turn.attempt);
    try std.testing.expectEqualDeep(old, successor.input.turn.replacement.?.input.task);
    try std.testing.expectEqualStrings(
        original.input.turn.context.bytes,
        successor.input.turn.context.bytes,
    );
    try std.testing.expectEqualDeep(
        original.input.turn.context_references,
        successor.input.turn.context_references,
    );
    index.deinit();
    try finish(&fixture, next);
    try std.testing.expectEqual(0, (try driver.recoverTurns(a, 8)).len);
}

fn expectTurnProgress(
    a: std.mem.Allocator,
    driver: *Driver,
    turn: t.Id,
    status: []const u8,
    replied: bool,
) !void {
    const config: @import("../native/configuration.zig").Config = .{
        .version = 1,
        .current_uid = 501,
        .namespace_path = "/tmp/unused-driver-test",
        .control_socket_path = "/tmp/unused-driver-test.sock",
        .repository = .{
            .account = "github",
            .id = 1,
            .owner = "owner",
            .name = "repo",
            .ref = "refs/heads/main",
        },
    };
    const control = @import("../native/control.zig");
    const request = try control.encode(a, .{
        .version = 1,
        .operation = null,
        .command = .{ .task_show = turn },
    });
    const bytes = try control.dispatch(a, driver, config, 501, request);
    const parsed = try native.json.parse(a, bytes, .{});
    const data = parsed.value.object.get("data").?;
    const shown = try native.json.text(data.object.get("task_status").?);
    try std.testing.expectEqualStrings(status, shown);
    try std.testing.expect(data.object.get("retry_pending") == null);
    try std.testing.expectEqual(replied, data.object.get("result").? != .null);
}

test "native driver continues every unfinished turn lineage until it replies" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    const old = try driver.turn(a, "pending-turn", .{ .local = .{ .uid = 501 } }, .{
        .text = .{ .bytes = "inspect the parked attempt" },
    });
    try expectTurnProgress(a, &driver, old, "queued", false);
    driver.detach();
    try fixture.close();
    fixture.profile.runtime_identity = @splat(44);
    try fixture.open();
    driver.service = &fixture.service.?;
    try driver.attach(a);
    try expectTurnProgress(a, &driver, old, "parked", false);
    var index = try driver.rebuild(a);
    defer index.deinit();
    const snapshot = index.record(old).?.owner_snapshot.?;
    const Blocker = enum {
        credential_unavailable,
        model_unavailable,
        incompatible_profile,
        observation_blocked,
        waiting_workspace,
    };
    const Case = struct { status: native.tasks.Status, blocker: ?Blocker, moves: bool };
    const cases = [_]Case{
        .{ .status = .blocked, .blocker = .credential_unavailable, .moves = true },
        .{ .status = .blocked, .blocker = .model_unavailable, .moves = true },
        .{ .status = .blocked, .blocker = .incompatible_profile, .moves = true },
        .{ .status = .blocked, .blocker = .observation_blocked, .moves = false },
        .{ .status = .blocked, .blocker = .waiting_workspace, .moves = false },
        .{ .status = .blocked, .blocker = null, .moves = false },
        .{ .status = .parked, .blocker = null, .moves = true },
        .{ .status = .failed, .blocker = null, .moves = true },
        .{ .status = .cancelled, .blocker = null, .moves = true },
        .{ .status = .unknown, .blocker = null, .moves = true },
        .{ .status = .running, .blocker = null, .moves = false },
        .{ .status = .waiting_input, .blocker = null, .moves = false },
    };
    const recovery_status = @import("../native/recovery_status.zig");
    for (cases) |case| {
        const action = recovery_status.classify(case.status, case.blocker, null, snapshot);
        try std.testing.expectEqual(case.moves, action != .stay);
    }
    const replacements = try driver.recoverTurns(a, 8);
    try std.testing.expectEqual(1, replacements.len);
    try expectTurnProgress(a, &driver, old, "queued", false);
    try finish(&fixture, replacements[0]);
    try expectTurnProgress(a, &driver, old, "completed", true);
}
