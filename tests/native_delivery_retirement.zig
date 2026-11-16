const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const idx = @import("../native/index.zig");
const retirement = @import("../native/delivery_retirement.zig");
const outbound = @import("../native/outbound.zig");
const prep = @import("../native/delivery_prepare.zig");
const examples = @import("contracts.zig");
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};
const Fixture = @import("native_fixture.zig").Fixture(t, Application);
const target: t.Id = @splat(1);

fn subject(f: *Fixture, question: bool) !idx.Index {
    const a = f.arena.allocator();
    const initial = examples.genesis();
    var head = @import("native_genesis.zig").expectedFresh(initial);
    var intent = head.activation.?;
    intent.payload.obligation = target;
    if (question) intent.key.purpose = .question;
    const reference: t.Reference = .{ .task = target, .digest = @splat(2) };
    var prepared = try prep.materialize(a, intent, reference, @splat(3), "B1");
    defer prepared.deinit();
    const task = (try f.service.?.submit(a, prepared.value.envelope.operation.bytes, .{
        .delivery = prepared.value,
    })).receipt.task;
    head.activation = null;
    if (question) head.question = .{
        .identity = intent.key.identity,
        .condition = @splat(4),
        .specification_revision = head.specification.revision,
        .evidence = .current,
        .choices = .{ .items = &.{} },
        .prompt = intent,
    };
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    const records = try scratch.alloc(idx.Record, 2);
    records[0] = .{
        .task = target,
        .revision = 1,
        .input_digest = @splat(1),
        .result_digest = reference.digest,
        .input = .{ .genesis = initial },
        .result = .{ .genesis = head },
        .selected = true,
    };
    const bytes = try c.encodeOwned(t.Input, scratch, .{ .delivery = prepared.value });
    records[1] = .{
        .task = task,
        .revision = 1,
        .input_digest = idx.digest(bytes),
        .result_digest = null,
        .input = (try c.decodeOwned(t.Input, scratch, bytes)).value,
        .result = null,
    };
    const obligations = try scratch.alloc(idx.Obligation, 1);
    obligations[0] = .{
        .task = target,
        .chain = try scratch.dupe(usize, &.{0}),
        .directives = &.{},
        .eligible = null,
        .folded_mode = .active,
        .effective_mode = .active,
        .recovery_hold = false,
    };
    var index: idx.Index = .{
        .arena = arena,
        .records = records,
        .obligations = obligations,
        .tasks = .empty,
    };
    for (records, 0..) |record, position| try index.tasks.put(scratch, record.task, position);
    return index;
}

fn requested(f: *Fixture, index: *const idx.Index) !bool {
    var saved = try f.service.?.task(f.arena.allocator(), index.records[1].task);
    defer saved.deinit();
    return saved.value.cancellation != null;
}

fn revision(f: *Fixture, task: t.Id) !u64 {
    var saved = try f.service.?.task(f.arena.allocator(), task);
    defer saved.deinit();
    return saved.value.revision;
}

fn reconcile(f: *Fixture, index: *const idx.Index) !void {
    try retirement.reconcile(&f.service.?, f.arena.allocator(), index, &index.obligations[0]);
}

fn finish(f: *Fixture, task: t.Id) !void {
    const a = f.arena.allocator();
    for (0..4096) |_| {
        var saved = try f.service.?.task(a, task);
        defer saved.deinit();
        if (saved.value.terminal()) return;
        switch (try f.service.?.pump(a)) {
            .work => return error.UnexpectedExternalWork,
            else => {},
        }
    }
    return error.TaskDidNotFinish;
}

fn dispatch(f: *Fixture) !native.tasks.Work {
    for (0..4096) |_| switch (try f.service.?.pump(f.arena.allocator())) {
        .work => |work| return work,
        else => {},
    };
    return error.MissingNotification;
}

test "native delivery retirement cancels admitted output and replays one operation after reopen" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    var index = try subject(&f, false);
    defer index.deinit();
    index.obligations[0].effective_mode = .cancelled;
    try std.testing.expectEqual(0, (try outbound.admitDeliveries(
        &f.service.?,
        a,
        &index,
        target,
        100,
    )).len);
    try std.testing.expect(try requested(&f, &index));
    const task = index.records[1].task;
    const operation = try std.fmt.allocPrint(a, "delivery-retire:{s}", .{
        std.fmt.bytesToHex(task, .lower),
    });
    var first = (try f.service.?.operationLookup(a, operation)).?;
    defer first.deinit();
    const first_revision = try revision(&f, task);
    try reconcile(&f, &index);
    try std.testing.expectEqual(first_revision, try revision(&f, task));
    try f.close();
    try f.open();
    try reconcile(&f, &index);
    var repeated = (try f.service.?.operationLookup(a, operation)).?;
    defer repeated.deinit();
    try std.testing.expectEqualDeep(first.value, repeated.value);
    const reopened_revision = try revision(&f, task);
    try reconcile(&f, &index);
    try std.testing.expectEqual(reopened_revision, try revision(&f, task));
    try finish(&f, task);
    var state = try f.service.?.task(a, task);
    defer state.deinit();
    try std.testing.expectEqual(.cancelled, try f.service.?.status(a, state.value));
    try std.testing.expect((try f.service.?.notificationHistory(
        a,
        task,
        app.notification_identity,
    )).transmissionExcluded());
}

test "native delivery retirement closes replaced and revision obsolete question prompts" {
    for (0..3) |change| {
        var f: Fixture = .{};
        defer f.deinit();
        try f.init();
        var index = try subject(&f, true);
        defer index.deinit();
        try reconcile(&f, &index);
        try std.testing.expect(!try requested(&f, &index));
        const head = &index.records[0].result.?.genesis;
        switch (change) {
            0 => head.question = null,
            1 => head.question.?.prompt.key.identity = @splat(9),
            else => head.specification.revision += 1,
        }
        try reconcile(&f, &index);
        try std.testing.expect(try requested(&f, &index));
        try finish(&f, index.records[1].task);
        var saved = try f.service.?.task(f.arena.allocator(), index.records[1].task);
        defer saved.deinit();
        try std.testing.expectEqual(
            .cancelled,
            try f.service.?.status(f.arena.allocator(), saved.value),
        );
    }
}

test "native delivery retirement preserves pause recovery holds and delayed intents across resume" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    var index = try subject(&f, true);
    defer index.deinit();
    index.obligations[0].effective_mode = .paused;
    index.obligations[0].recovery_hold = true;
    index.recovery_hold = true;
    try reconcile(&f, &index);
    try std.testing.expect(!try requested(&f, &index));
    index.records[1].input.delivery.key.purpose = .digest;
    index.records[0].result.?.genesis.digest = .{
        .delivery = prep.projectIntent(index.records[1].input.delivery),
        .hold = .none,
        .not_before_ms = std.math.maxInt(i64),
    };
    try reconcile(&f, &index);
    index.obligations[0].effective_mode = .active;
    index.obligations[0].recovery_hold = false;
    index.recovery_hold = false;
    try reconcile(&f, &index);
    try std.testing.expect(!try requested(&f, &index));
}

fn capture(f: *Fixture, value: t.Delivery, work: native.tasks.Work) !void {
    const a = f.arena.allocator();
    const request = try c.encodeOwned(@import("../app/slack_contract.zig").Request, a, .{
        .destination = value.destination,
        .key = value.key,
        .payload = value.payload,
    });
    const body = try std.json.Stringify.valueAlloc(a, .{
        .ok = true,
        .channel = value.destination.channel.bytes,
        .ts = "100.000001",
        .message = .{ .text = "accepted", .metadata = @as(?u8, null) },
    }, .{});
    const response: @import("../native/http.zig").Capture = .{
        .arena = .init(a),
        .status = 200,
        .headers = &.{},
        .identity_encoding = true,
        .body = body,
    };
    const bytes = try @import("../native/slack_external.zig").captureBytes(
        a,
        request,
        "B1",
        response,
        100,
    );
    try f.service.?.completeWork(a, work, .{ .acquired = bytes });
}

test "native delivery retirement preserves dispatched unknown captured and confirmed outcomes" {
    for ([_]bool{ false, true }) |captured| {
        var f: Fixture = .{};
        defer f.deinit();
        try f.initWithGrants(&.{app.notification_identity});
        const a = f.arena.allocator();
        var index = try subject(&f, false);
        defer index.deinit();
        const task = index.records[1].task;
        const work = try dispatch(&f);
        index.obligations[0].effective_mode = .cancelled;
        try reconcile(&f, &index);
        try std.testing.expect(!try requested(&f, &index));
        if (captured) {
            try capture(&f, index.records[1].input.delivery, work);
        } else try f.service.?.unknown(a, work);
        try reconcile(&f, &index);
        try std.testing.expect(!try requested(&f, &index));
        const history = try f.service.?.notificationHistory(a, task, app.notification_identity);
        try std.testing.expectEqual(1, history.attempts);
        try std.testing.expect(!history.transmissionExcluded());
        if (captured) {
            try finish(&f, task);
            try reconcile(&f, &index);
            const output = try f.output(task);
            try std.testing.expect(output == .delivery and output.delivery == .confirmed);
        } else {
            var saved = try f.service.?.task(a, task);
            defer saved.deinit();
            try std.testing.expectEqual(.unknown, try f.service.?.status(a, saved.value));
        }
        try std.testing.expect(!try requested(&f, &index));
    }
}
