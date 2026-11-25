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

test "native driver refuses a directive admitted behind a pending final directive" {
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
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    const cancel = try driver.directive(a, "pending-cancel", origin, target, .{ .cancel = {} });
    try std.testing.expectError(
        error.FinalObligation,
        driver.directive(a, "behind-cancel", origin, target, .{ .pause = {} }),
    );
    try std.testing.expectEqualDeep(
        cancel,
        try driver.directive(a, "pending-cancel", origin, target, .{ .cancel = {} }),
    );
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(1, index.obligation(target).?.directives.len);
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

const Flaky = struct {
    failures: u32,
    calls: u32 = 0,

    fn run(self: *Flaky) !bool {
        self.calls += 1;
        if (self.calls <= self.failures) return error.TransientRead;
        return true;
    }
};

test "native driver replaces a cancelled fold step and observes faults without fencing" {
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
    defer driver.faults.deinit();
    _ = (try driver.nextStep(a, target)).?;
    _ = try driver.directive(a, "pause-cancelled", .{ .local = .{ .uid = 501 } }, target, .{
        .pause = {},
    });
    const replacement = (try driver.nextStep(a, target)).?;
    try cancelTurn(&fixture, replacement, "cancel-fold");
    try std.testing.expect(try driver.advance(a, target, .step));
    var index = try driver.rebuild(a);
    const obligation = index.obligation(target).?;
    try std.testing.expectEqual(null, obligation.fault);
    const successor = index.records[obligation.eligible.?].input.step;
    try std.testing.expect(successor.fold_only);
    try std.testing.expectEqual(.control, successor.supersession.?.cause);
    index.deinit();
    var flaky: Flaky = .{ .failures = 2 };
    const key: @import("../native/driver.zig").Key = .{ .item = target, .work = .step };
    try std.testing.expectEqual(null, try driver.guarded(key, bool, Flaky.run, .{&flaky}));
    index = try driver.rebuild(a);
    try std.testing.expectEqualStrings("TransientRead", index.obligation(target).?.fault.?.reason);
    index.deinit();
    try std.testing.expectEqual(null, try driver.guarded(key, bool, Flaky.run, .{&flaky}));
    try std.testing.expectEqual(1, flaky.calls);
    clock.now_ms += 1_000;
    try std.testing.expectEqual(null, try driver.guarded(key, bool, Flaky.run, .{&flaky}));
    try std.testing.expectEqual(2, driver.faults.items.get(key).?.failures);
    clock.now_ms += 2_000;
    try std.testing.expectEqual(true, try driver.guarded(key, bool, Flaky.run, .{&flaky}));
    try std.testing.expectEqual(null, driver.faults.latest(target));
}

test "native driver recovers a captured step before a pause fence replaces it" {
    const decide = @import("../native/recovery_status.zig").decide;
    try std.testing.expectEqualDeep(
        @as(@TypeOf(decide(.{ .stay = {} }, false, false)), .{ .resume_captured = {} }),
        decide(.{ .resume_captured = {} }, true, false),
    );
    try std.testing.expectEqual(.control, decide(.{ .stay = {} }, true, false).replace);
    try std.testing.expectEqual(.control, decide(.{ .resume_parked = {} }, true, false).replace);
    try std.testing.expect(decide(.{ .stay = {} }, true, true) == .none);
    try std.testing.expect(decide(.{ .replace = .failed }, false, true) == .failed_fold);
    try std.testing.expectEqual(.control, decide(.{ .replace = .control }, true, true).replace);
    try std.testing.expectEqual(.unknown, decide(.{ .replace = .unknown }, true, true).replace);
    try std.testing.expectEqual(.rejected, decide(.{ .replace = .rejected }, false, false).replace);
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

const idx = @import("../native/index.zig");

fn expectMaintained(driver: *Driver, a: std.mem.Allocator) !void {
    var indexed = try driver.view(a);
    defer indexed.deinit();
    try idx.verifyAgainstRebuild(driver.service, a, &indexed.index, driver.page_limit);
}

test "native driver index matches rebuild across admissions results supersession restart" {
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
    try expectMaintained(&driver, a);
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    const old = (try driver.nextStep(a, target)).?;
    try expectMaintained(&driver, a);
    _ = try driver.directive(a, "maintained-pause", origin, target, .{ .pause = {} });
    try expectMaintained(&driver, a);
    const replacement = (try driver.nextStep(a, target)).?;
    try expectMaintained(&driver, a);
    try finish(&fixture, replacement);
    try expectMaintained(&driver, a);
    var indexed = try driver.view(a);
    try std.testing.expect(indexed.index.record(old).?.superseded);
    try std.testing.expectEqual(t.Mode.paused, indexed.index.head(
        indexed.index.obligation(target).?,
    ).mode);
    indexed.deinit();
    _ = try driver.directive(a, "maintained-resume", origin, target, .{ .@"resume" = {} });
    try finish(&fixture, (try driver.nextStep(a, target)).?);
    try expectMaintained(&driver, a);
    driver.detach();
    try fixture.close();
    try fixture.open();
    driver.service = &fixture.service.?;
    try driver.attach(a);
    defer driver.detach();
    try expectMaintained(&driver, a);
    const derivations = driver.index.?.counters.derivations;
    try expectMaintained(&driver, a);
    try std.testing.expectEqual(derivations, driver.index.?.counters.derivations);
}

test "native driver verification rejects a namespace change that bypasses the index" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const initial = fixture_values.genesis();
    _ = try fixture.execute(initial.envelope.operation.bytes, .{ .genesis = initial });
    var clock: Clock = .{};
    var driver: Driver = .{
        .service = &fixture.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    var other = fixture_values.genesis();
    other.envelope.operation = .{ .bytes = "bypassing-genesis" };
    other.lineage = @splat(9);
    _ = try fixture.execute(other.envelope.operation.bytes, .{ .genesis = other });
    try std.testing.expectError(error.IndexDivergence, driver.view(a));
}

test "native mutations of the task service flow through the driver" {
    const sources = .{
        "admission",  "application",        "catalog",               "cli",
        "commands",   "compatibility",      "configuration",         "continuation_recovery",
        "continuity", "continuity_control", "continuity_import",     "continuity_turn",
        "control",    "control_socket",     "conversation_recovery", "daemon",
        "dialogue",   "eligibility",        "experiment_external",   "experiments",
        "github",     "github_adapter",     "github_external",       "http",
        "index",      "ingress_policy",     "main",                  "materialize",
        "messages",   "method_catalog",     "method_external",       "model_external",
        "phase",      "recovery",           "recovery_status",       "render_measure",
        "retained",   "transfer",           "transfer_marker",       "wire",
    };
    const forbidden = [_][]const u8{
        "service.submit(",
        "service.requestCancel(",
        "service.resumeTask(",
        "admit(driver.service",
        "admit(self.service",
    };
    inline for (sources) |name| {
        const source = @embedFile("../native/" ++ name ++ ".zig");
        for (forbidden) |pattern| {
            if (std.mem.indexOf(u8, source, pattern) != null) {
                std.debug.print("{s}.zig bypasses the driver with {s}\n", .{ name, pattern });
                return error.UnindexedMutation;
            }
        }
    }
}

const Reads = struct { records: usize, probes: u64, loads: u64, derivations: u64 };

const Unused = struct {
    fn call(_: *anyopaque, _: std.mem.Allocator, _: *Driver, _: u32, _: []const u8) ![]const u8 {
        return error.UnexpectedControl;
    }
};

fn idleReads(history: u32) !Reads {
    const socket = @import("../native/control_socket.zig");
    const Daemon = @import("../native/daemon.zig").Daemon(app.Types);
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
    for (0..history) |n| {
        const operation = try std.fmt.allocPrint(a, "history-pause-{d}", .{n});
        _ = try driver.directive(a, operation, .{ .local = .{ .uid = 501 } }, target, .{
            .pause = {},
        });
    }
    try finish(&fixture, (try driver.nextStep(a, target)).?);
    driver.detach();
    const path = try std.fs.path.join(a, &.{
        std.testing.TmpDir.parent_dir_path, &fixture.temporary.?.sub_path, "control",
    });
    var server = try socket.Server.init(std.testing.allocator, path, .{
        .operator_uid = socket.currentUid(),
    });
    defer server.deinit();
    const handler: Daemon.Handler = .{ .context = &driver, .call = Unused.call };
    var daemon = try Daemon.init(a, &driver, &server, handler, .{});
    for (0..6) |_| _ = try daemon.poll(a, 0);
    const before = driver.index.?.counters;
    for (0..12) |_| try std.testing.expectEqual(.idle, try daemon.poll(a, 0));
    const after = driver.index.?.counters;
    const reads: Reads = .{
        .records = driver.index.?.current.records.len,
        .probes = after.probes - before.probes,
        .loads = after.loads - before.loads,
        .derivations = after.derivations - before.derivations,
    };
    daemon.beginStop(0);
    try std.testing.expectEqual(.stopped, try daemon.poll(a, 0));
    try daemon.deinit();
    return reads;
}

test "native daemon idle polls read a bounded number of tasks regardless of namespace size" {
    const small = try idleReads(1);
    const large = try idleReads(16);
    try std.testing.expect(large.records >= small.records + 15);
    try std.testing.expectEqual(small.probes, large.probes);
    try std.testing.expectEqual(0, small.loads);
    try std.testing.expectEqual(0, large.loads);
    try std.testing.expectEqual(0, large.derivations);
}
