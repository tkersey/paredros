const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const t = @import("application_types");

const identity = "paredros.session.probe.v1";
const Types = struct {
    pub const application_id = "paredros.session.witness";
    pub const application_version = "1.0.0";
    pub const Input = u32;
    pub const Output = u32;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.session.input.v1";
    pub const output_schema_id = "paredros.session.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.session.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);

const Application = struct {
    pub const declarations = &.{native.leaf(u32, u32, .{
        .identity = identity,
        .resource_role = "probe",
    }, Probe.read)};

    pub fn emit(c: protean.Context) !horos.source.Module {
        const read = try c.external(identity, try c.schema(u32), try c.schema(u32), .read);
        const function = try c.author.function("read held session probe", .{
            .input = try c.schema(u32),
        }, try c.schema(u32), .{read});
        const b = try c.author.body(function);
        try c.author.define(function, try b.ret(try b.perform(read, try b.parameter("input"))));
        return c.author.module(function, try c.schema(t.Failure));
    }
};

const Probe = struct {
    started: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),

    fn read(ctx: native.Context, input: u32) !u32 {
        const self: *Probe = @ptrCast(@alignCast(ctx.environment orelse
            return error.MissingProbe));
        _ = self.calls.fetchAdd(1, .monotonic);
        self.started.store(true, .release);
        for (0..5000) |_| {
            if (self.release.load(.acquire)) return input;
            try std.Io.sleep(ctx.io, .fromMilliseconds(1), .awake);
        }
        return error.ProbeDeadline;
    }
};

fn parameters(a: std.mem.Allocator, task: t.Id) !native.json.Value {
    var value = native.json.object();
    try native.json.put(a, &value, "task_id", native.json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(task, .lower)),
    ));
    return value;
}

fn start(
    fixture: *Fixture,
    session: *native.Session(Types),
    probe: *Probe,
) !void {
    const a = fixture.arena.allocator();
    for (0..5000) |_| {
        _ = try session.tick(a);
        if (probe.started.load(.acquire)) {
            try std.testing.expect(session.busy());
            return;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.ProbeDidNotStart;
}

fn finish(fixture: *Fixture, session: *native.Session(Types), task: t.Id) !void {
    const a = fixture.arena.allocator();
    for (0..5000) |_| {
        _ = try session.tick(a);
        var status = try fixture.service.?.task(a, task);
        defer status.deinit();
        if (status.value.cancellation != null and !session.busy()) {
            if (status.value.terminal()) {
                try std.testing.expectEqual(.cancelled, status.value.outcome_kind);
            } else {
                try std.testing.expect(status.value.blocker != null);
                try std.testing.expect(status.value.current_occurrence != null);
            }
            return;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.ProbeDidNotFinish;
}

test "native public session serves two control clients while a worker is held" {
    var probe: Probe = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &probe;
    try fixture.initWithGrants(&.{identity});
    const a = fixture.arena.allocator();
    const service = &fixture.service.?;
    var session = try native.Session(Types).init(service);
    defer session.deinit() catch @panic("session left busy");
    defer probe.release.store(true, .release);
    var first: native.client.Client(Types) = .{ .service = service };
    var second: native.client.Client(Types) = .{ .service = service };
    const admitted = try service.submit(a, "held-probe", 37);
    try start(&fixture, &session, &probe);
    const began = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const params = try parameters(a, admitted.receipt.task);
    const status = try first.call(a, .@"task.status", params);
    try std.testing.expect(!native.json.get(status, "result_available").?.bool);
    var cancel = try parameters(a, admitted.receipt.task);
    try native.json.put(a, &cancel, "client_operation_id", native.json.string("second-cancels"));
    _ = try second.call(a, .@"task.cancel", cancel);
    _ = try first.call(a, .@"task.status", params);
    const ended = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    try std.testing.expect(ended - began < 1000);
    try std.testing.expect(session.busy());
    try std.testing.expect(!probe.release.load(.acquire));
    var receipt = (try service.operationLookup(a, "second-cancels")).?;
    defer receipt.deinit();
    try std.testing.expectEqual(admitted.receipt.task, receipt.value.task);
    try std.testing.expectEqual(.cancel, receipt.value.method);
    probe.release.store(true, .release);
    try finish(&fixture, &session, admitted.receipt.task);
    try std.testing.expectEqual(1, probe.calls.load(.acquire));
    try session.park(a);
}
