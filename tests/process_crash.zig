const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const github = @import("../native/github_external.zig");
const slack = @import("../native/slack_external.zig");
const notification = @import("../app/slack_contract.zig");
const model = @import("../native/model_external.zig");
const model_contract = @import("../app/model_contract.zig");
const contract = @import("../app/github_contract.zig");
const retained = @import("../native/retained.zig");
const Driver = @import("../native/driver.zig").Driver(t);
const examples = @import("contracts.zig");
const Phase = enum {
    control_admitted,
    replacement_admitted,
    read_dispatched,
    read_captured,
    write_admitted,
    write_dispatched,
    write_captured,
    write_consumed,
    write_completed,
    turn_admitted,
    model_dispatched,
    model_captured,
};
const Witness = struct {
    target: t.Id,
    subject: t.Id,
    predecessor: ?t.Id = null,
    input_digest: t.Digest,
};
var phase: Phase = undefined;
var verifying = false;
var witness: Witness = undefined;
var acquisitions: u32 = 0;
var now_ms: i64 = 100;

const Application = struct {
    pub const use_product_assets = true;
    const values = declarationsValue();
    pub const declarations: []const native.Declaration = &values;

    fn declarationsValue() [app.Application.declarations.len]native.Declaration {
        var result: [app.Application.declarations.len]native.Declaration = undefined;
        @memcpy(&result, app.Application.declarations);
        result[0].capture.?.acquire = acquire;
        result[0].capture.?.interpret = interpret;
        result[3].capture.?.acquire = acquireWrite;
        result[3].capture.?.interpret = interpretWrite;
        result[2].capture.?.acquire = acquireModel;
        result[2].capture.?.interpret = interpretModel;
        return result;
    }
};
const Fixture = @import("native_fixture.zig").Fixture(t, Application);

fn emit(value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try std.json.Stringify.value(value, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn stopAt(selected: Phase) !void {
    if (verifying or phase != selected) return;
    try emit(.{ .cut = @tagName(phase), .witness = witness });
    while (true) try std.testing.io.sleep(.fromSeconds(1), .awake); // tiger: event-loop
}

fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    var task: t.Id = undefined;
    _ = try std.fmt.hexToBytes(&task, ctx.task_id);
    if (verifying and std.meta.eql(task, witness.subject))
        return error.OriginalAcquisitionRepeated;
    acquisitions += 1;
    try emit(.{ .acquired = "github", .task = task });
    try stopAt(.read_dispatched);
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .captured = try c.encodeOwned(github.Capture, ctx.allocator, .{
        .local_rejection = .{ .request_digest = digest, .reason = .permission },
    }) };
}

fn interpret(
    ctx: native.registry.ProjectionContext,
    request: []const u8,
    prepared: []const u8,
    captured: []const u8,
) !native.registry.Projection {
    try stopAt(.read_captured);
    return github.interpret(ctx, request, prepared, captured);
}

fn clock(_: *anyopaque) !i64 {
    return now_ms;
}

fn acquireWrite(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    if (verifying and phase != .write_admitted) return error.OriginalWriteRepeated;
    var task: t.Id = undefined;
    _ = try std.fmt.hexToBytes(&task, ctx.task_id);
    var request = try c.decodeOwned(notification.Request, ctx.allocator, bytes);
    defer request.deinit();
    var wire = try slack.preparedWire(ctx.allocator, request.value, "B123");
    defer wire.deinit();
    acquisitions += 1;
    try emit(.{
        .acquired = "slack",
        .task = task,
        .key = request.value.key,
        .payload_digest = request.value.payload.content_digest,
    });
    try stopAt(.write_dispatched);
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .ok = true,
        .channel = request.value.destination.channel.bytes,
        .ts = "1730000000.000001",
        .message = .{ .text = "fixture accepted message", .metadata = @as(?u8, null) },
    }, .{});
    defer ctx.allocator.free(body);
    var capture: @import("../native/http.zig").Capture = .{
        .arena = .init(ctx.allocator),
        .status = 200,
        .headers = &.{},
        .identity_encoding = true,
        .body = body,
    };
    defer capture.deinit();
    return .{ .captured = try slack.captureBytes(ctx.allocator, bytes, "B123", capture, 100) };
}

fn interpretWrite(
    ctx: native.registry.ProjectionContext,
    request: []const u8,
    prepared: []const u8,
    captured: []const u8,
) !native.registry.Projection {
    try stopAt(.write_captured);
    return app.Application.declarations[3].capture.?.interpret(ctx, request, prepared, captured);
}

fn writes() bool {
    return phase == .write_admitted or phase == .write_dispatched or
        phase == .write_captured or phase == .write_consumed or phase == .write_completed;
}

fn models() bool {
    return phase == .turn_admitted or phase == .model_dispatched or phase == .model_captured;
}

fn acquireModel(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    var task: t.Id = undefined;
    _ = try std.fmt.hexToBytes(&task, ctx.task_id);
    if (verifying and phase != .turn_admitted and std.meta.eql(task, witness.subject))
        return error.OriginalModelRepeated;
    var prepared = try c.decodeOwned(model.Adapter.Prepared, ctx.allocator, bytes);
    defer prepared.deinit();
    try std.testing.expectEqual(1, prepared.value.request.invocation.selection.maximum_calls);
    acquisitions += 1;
    try emit(.{ .acquired = "model", .task = task });
    try stopAt(.model_dispatched);
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .id = "response-crash-fixture",
        .status = "completed",
        .@"error" = @as(?u8, null),
        .output = .{.{
            .type = "function_call",
            .status = "completed",
            .id = "fc-crash-fixture",
            .call_id = "call-crash-fixture",
            .name = "converse",
            .arguments = "{\"reply\":\"Retained model reply\",\"proposals\":[]}",
        }},
        .usage = .{ .input_tokens = @as(u64, 20), .output_tokens = @as(u64, 10) },
    }, .{});
    defer ctx.allocator.free(body);
    return .{ .captured = try c.encodeOwned(model.Raw, ctx.allocator, .{
        .status = 200,
        .identity_encoding = true,
        .request_id = .{ .bytes = "request-crash-fixture" },
        .body = .{ .bytes = body },
        .format = .json,
        .media_type = .{ .bytes = "application/json" },
    }) };
}

fn interpretModel(
    ctx: native.registry.ProjectionContext,
    request: []const u8,
    prepared: []const u8,
    captured: []const u8,
) !native.registry.Projection {
    try stopAt(.model_captured);
    return model.declaration().capture.?.interpret(ctx, request, prepared, captured);
}

fn remember(driver: *Driver, target: t.Id, subject: t.Id, predecessor: ?t.Id) !void {
    var index = try driver.rebuild(std.testing.allocator);
    defer index.deinit();
    witness = .{
        .target = target,
        .subject = subject,
        .predecessor = predecessor,
        .input_digest = index.record(subject).?.input_digest,
    };
}

fn drive(f: *Fixture, session: *native.Session(t), task: t.Id) !void {
    const a = f.arena.allocator();
    const deadline = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() + 90_000;
    var cancelled = false;
    while (std.Io.Clock.awake.now(std.testing.io).toMilliseconds() < deadline) {
        if (phase == .write_consumed and !verifying) {
            _ = try session.collect(a, false);
            const history = try f.service.?.notificationHistory(a, task, app.notification_identity);
            if (!cancelled and history.captured != null and history.captured.?.reply != null) {
                _ = try f.service.?.requestCancel(a, "crash-consume-cancel", task, "stop");
                cancelled = true;
            }
        }
        _ = try session.tick(a);
        var state = try f.service.?.task(a, task);
        defer state.deinit();
        if (cancelled and !state.value.terminal() and state.value.current_occurrence == null)
            try stopAt(.write_consumed);
        if (state.value.terminal()) {
            try stopAt(.write_completed);
            return;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.CrashFixtureDidNotComplete;
}

fn createCut(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    const initial = examples.genesis();
    const target = try f.execute(initial.envelope.operation.bytes, .{ .genesis = initial });
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    if (writes()) return createWriteCut(f, driver, target);
    if (models()) return createModelCut(f, driver, target);
    if (phase == .control_admitted) {
        const pause = try driver.directive(a, "crash-pause", origin, target, .pause);
        try remember(driver, target, pause, null);
        return stopAt(.control_admitted);
    }
    const step = (try driver.nextStep(a, target)).?;
    if (phase == .replacement_admitted) {
        _ = try driver.directive(a, "crash-pause", origin, target, .pause);
        const replacement = (try driver.nextStep(a, target)).?;
        try remember(driver, target, replacement, step);
        return stopAt(.replacement_admitted);
    }
    try remember(driver, target, step, null);
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    try drive(f, &session, step);
    return error.CrashBoundaryNotReached;
}

fn createWriteCut(f: *Fixture, driver: *Driver, target: t.Id) !void {
    const deliveries = try driver.deliveries(f.arena.allocator(), target);
    try std.testing.expectEqual(1, deliveries.len);
    try remember(driver, target, deliveries[0], null);
    if (phase == .write_admitted) return stopAt(.write_admitted);
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    try drive(f, &session, witness.subject);
    return error.CrashBoundaryNotReached;
}

fn createModelCut(f: *Fixture, driver: *Driver, target: t.Id) !void {
    const turn = try driver.turn(
        f.arena.allocator(),
        "crash-turn",
        .{ .local = .{ .uid = 501 } },
        .{
            .target = target,
            .destination = examples.specification().destination,
            .text = .{ .bytes = "Keep the original conversation context." },
        },
    );
    try remember(driver, target, turn, null);
    if (phase == .turn_admitted) return stopAt(.turn_admitted);
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    try drive(f, &session, turn);
    return error.CrashBoundaryNotReached;
}

fn verifyControl(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    var index = try driver.rebuild(a);
    defer index.deinit();
    const obligation = index.obligation(witness.target).?;
    try std.testing.expect(!obligation.ordinaryDispatch());
    const repeated = try driver.directive(
        a,
        "crash-pause",
        .{ .local = .{ .uid = 501 } },
        witness.target,
        .pause,
    );
    if (phase == .control_admitted) try std.testing.expectEqualDeep(witness.subject, repeated);
    if (witness.predecessor) |old| {
        try std.testing.expect(index.record(old).?.superseded);
        try std.testing.expectEqualDeep(witness.subject, index.records[obligation.eligible.?].task);
    }
    const selected = try driver.nextStep(a, witness.target);
    const step = if (phase == .replacement_admitted) blk: {
        try std.testing.expect(selected == null);
        break :blk witness.subject;
    } else selected.?;
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    try drive(f, &session, step);
    var after = try driver.rebuild(a);
    defer after.deinit();
    try std.testing.expectEqual(.paused, after.head(after.obligation(witness.target).?).mode);
    try std.testing.expectEqual(0, acquisitions);
}

fn verifyRead(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    var saved = try retained.load(&f.service.?, a, witness.subject, 128);
    defer saved.deinit();
    try std.testing.expectEqual(1, saved.snapshot.value.attempts.items.len);
    const attempt = saved.snapshot.value.attempts.items[0];
    const captured = phase == .read_captured;
    try std.testing.expectEqual(captured, attempt.capture != null);
    const successor = try driver.nextStep(a, witness.target);
    if (captured) {
        try std.testing.expect(successor == null);
    } else {
        try std.testing.expect(successor != null);
        try std.testing.expect(!std.meta.eql(witness.subject, successor.?));
    }
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    try drive(f, &session, successor orelse witness.subject);
    var after = try driver.rebuild(a);
    defer after.deinit();
    const obligation = after.obligation(witness.target).?;
    try std.testing.expect(after.head(obligation).observed.tip == null);
    try std.testing.expectEqual(0, after.head(obligation).observed.sequence);
    try std.testing.expectEqual(1, after.head(obligation).check_failure_streak);
    if (captured) try std.testing.expectEqual(0, acquisitions);
    if (!captured) {
        try std.testing.expect(after.record(witness.subject).?.superseded);
        now_ms = after.head(obligation).source_not_before_ms;
        const next = (try driver.nextStep(a, witness.target)).?;
        try drive(f, &session, next);
        try std.testing.expectEqual(1, acquisitions);
    }
}

fn verifyWrite(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    var saved = try retained.load(&f.service.?, a, witness.subject, 128);
    defer saved.deinit();
    const sent = phase != .write_admitted;
    try std.testing.expectEqual(
        @as(usize, if (sent) 1 else 0),
        saved.snapshot.value.attempts.items.len,
    );
    if (sent) try std.testing.expectEqual(
        phase == .write_captured or phase == .write_consumed or phase == .write_completed,
        saved.snapshot.value.attempts.items[0].capture != null,
    );
    const before = try f.service.?.notificationHistory(
        a,
        witness.subject,
        app.notification_identity,
    );
    if (phase == .write_completed) {
        var state = try f.service.?.task(a, witness.subject);
        defer state.deinit();
        try std.testing.expect(state.value.terminal());
        try std.testing.expect(state.value.current_occurrence == null);
        try std.testing.expect(before.captured.?.reply != null);
    }
    try std.testing.expectEqual(!sent, before.transmissionExcluded());
    const repeated = try driver.deliveries(a, witness.target);
    try std.testing.expectEqual(1, repeated.len);
    try std.testing.expectEqualDeep(witness.subject, repeated[0]);
    if (phase == .write_consumed) return verifyConsumed(f, driver);
    const resumed = try driver.resumeRetained(a, 8);
    try std.testing.expectEqual(
        @as(u32, if (phase == .write_dispatched or phase == .write_completed) 0 else 1),
        resumed,
    );
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    if (phase == .write_dispatched) {
        for (0..8) |_| _ = try session.tick(a);
        var state = try f.service.?.task(a, witness.subject);
        defer state.deinit();
        try std.testing.expectEqual(.unknown, try f.service.?.status(a, state.value));
    } else {
        try drive(f, &session, witness.subject);
        const result = try f.output(witness.subject);
        try std.testing.expect(result == .delivery and result.delivery == .confirmed);
    }
    const after = try f.service.?.notificationHistory(
        a,
        witness.subject,
        app.notification_identity,
    );
    try std.testing.expectEqual(1, after.attempts);
    try std.testing.expect(!after.transmissionExcluded());
    try std.testing.expectEqual(@as(u32, if (phase == .write_admitted) 1 else 0), acquisitions);
    const again = try driver.deliveries(a, witness.target);
    try std.testing.expectEqual(1, again.len);
    try std.testing.expectEqualDeep(witness.subject, again[0]);
}

fn verifyConsumed(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    var state = try f.service.?.task(a, witness.subject);
    defer state.deinit();
    try std.testing.expect(!state.value.terminal());
    try std.testing.expect(state.value.current_occurrence == null);
    try std.testing.expect(state.value.cancellation != null);
    try std.testing.expect(!state.value.cancellation_applied);
    try std.testing.expectEqual(0, try driver.resumeRetained(a, 8));
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    for (0..8) |_| _ = try session.tick(a);
    const history = try f.service.?.notificationHistory(
        a,
        witness.subject,
        app.notification_identity,
    );
    try std.testing.expectEqual(1, history.attempts);
    try std.testing.expect(history.captured.?.reply != null);
    try std.testing.expect(!history.transmissionExcluded());
    try std.testing.expectEqual(0, acquisitions);
}

fn verifyModel(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    var original = try driver.rebuild(a);
    defer original.deinit();
    const previous = original.record(witness.subject).?.input.turn;
    const replacements = try driver.recoverTurns(a, 8);
    const unknown = phase == .model_dispatched;
    try std.testing.expectEqual(@as(usize, if (unknown) 1 else 0), replacements.len);
    const selected = if (unknown) replacements[0] else witness.subject;
    var session = try native.Session(t).init(&f.service.?);
    defer session.deinit() catch @panic("session left busy");
    try drive(f, &session, selected);
    const result = try f.output(selected);
    try std.testing.expect(result == .turn);
    try std.testing.expectEqualStrings("Retained model reply", result.turn.reply.bytes);
    try std.testing.expectEqual(0, result.turn.proposals.items.len);
    var after = try driver.rebuild(a);
    defer after.deinit();
    const current = after.record(selected).?.input.turn;
    try std.testing.expectEqualStrings(previous.text.bytes, current.text.bytes);
    try std.testing.expectEqualStrings(previous.context.bytes, current.context.bytes);
    try std.testing.expectEqualDeep(previous.context_references, current.context_references);
    try std.testing.expectEqualDeep(previous.proposal_offers, current.proposal_offers);
    var successful = try retained.load(&f.service.?, a, selected, 128);
    defer successful.deinit();
    try std.testing.expectEqual(1, successful.snapshot.value.accounting.known_calls);
    try std.testing.expectEqual(10, successful.snapshot.value.accounting.known_output_tokens);
    if (unknown) {
        try std.testing.expect(after.record(witness.subject).?.superseded);
        var lost = try retained.load(&f.service.?, a, witness.subject, 128);
        defer lost.deinit();
        try std.testing.expectEqual(1, lost.snapshot.value.accounting.possible_charged_calls);
        try std.testing.expectEqual(1, lost.snapshot.value.unknown_calls.items.len);
    }
    try std.testing.expectEqual(
        @as(u32, if (phase == .model_captured) 0 else 1),
        acquisitions,
    );
    try std.testing.expectEqual(0, (try driver.recoverTurns(a, 8)).len);
}

test "process crash owner fixture" {
    const env = std.testing.environ;
    const selected = env.getPosix("PAREDROS_CRASH_PHASE") orelse return error.InvalidArguments;
    phase = std.meta.stringToEnum(Phase, selected) orelse return error.InvalidArguments;
    const mode = env.getPosix("PAREDROS_CRASH_MODE") orelse return error.InvalidArguments;
    verifying = std.mem.eql(u8, mode, "verify");
    now_ms = if (verifying) 1000 else 100;
    if (!verifying and !std.mem.eql(u8, mode, "crash")) return error.InvalidArguments;
    const path = env.getPosix("PAREDROS_CRASH_PATH") orelse return error.InvalidArguments;
    var f: Fixture = .{};
    defer f.deinit();
    const binding = try @import("native_method.zig").configure(&f);
    try f.initWithGrants(&.{
        contract.identity,
        app.notification_identity,
        model_contract.P.identity,
    });
    try f.close();
    f.temporary.?.cleanup();
    f.temporary = null;
    f.path = path;
    try f.open();
    const a = f.arena.allocator();
    if (verifying) {
        const bytes = env.getPosix("PAREDROS_CRASH_WITNESS") orelse return error.InvalidArguments;
        witness = (try std.json.parseFromSlice(Witness, a, bytes, .{})).value;
    }
    var context: u8 = 0;
    var driver: Driver = .{ .service = &f.service.?, .clock = .{
        .context = &context,
        .now = clock,
    }, .model = binding };
    try driver.attach(a);
    defer driver.detach();
    if (!verifying) return createCut(&f, &driver);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqualDeep(
        witness.input_digest,
        index.record(witness.subject).?.input_digest,
    );
    if (models())
        try verifyModel(&f, &driver)
    else if (writes())
        try verifyWrite(&f, &driver)
    else if (phase == .control_admitted or phase == .replacement_admitted)
        try verifyControl(&f, &driver)
    else
        try verifyRead(&f, &driver);
    try emit(.{ .verified = selected, .acquisitions = acquisitions });
}
