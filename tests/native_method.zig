const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const m = @import("../app/method_contract.zig");
const mc = @import("../app/model_contract.zig");
const external = @import("../native/method_external.zig");
const model_external = @import("../native/model_external.zig");
const SourceApplication = @import("method.zig").Application;
const Types = struct {
    pub const application_id = "paredros.method.witness";
    pub const application_version = "1.0.0";
    pub const Input = m.MethodInput;
    pub const Output = m.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.method.input.v1";
    pub const output_schema_id = "paredros.method.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.method.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Application = struct {
    pub const declarations: []const native.Declaration = &.{
        external.declaration(),
        external.codecDeclaration(),
        modelDeclaration(),
    };
    fn modelDeclaration() native.Declaration {
        var result = model_external.declaration();
        result.capture.?.acquire = Scenario.acquire;
        return result;
    }
    pub const emit = SourceApplication.emit;
};
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);
const Session = native.Session(Types);
const a = std.testing.allocator;

fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn literal(
    comptime T: type,
    b: *horos.source.Builder,
    value: T,
) !u64 {
    return b.literal(.{
        .schema = try c.schema(T, b),
        .bytes = try c.encodeOwned(T, b.allocator(), value),
    });
}

pub const GuestOptions = struct {
    ports: u32 = 0,
    wrong_output: bool = false,
    wrong_port: bool = false,
    context: []const u8 = "retained method context",
    output_state: ?[]const u8 = null,
    summary: mc.Summary = .{
        .summary = .{ .bytes = "Retained method" },
        .highlights = .{ .items = &.{} },
    },
};

fn guest(allocator: std.mem.Allocator, ports: u32, wrong_output: bool) ![]u8 {
    return guestSource(allocator, .{ .ports = ports, .wrong_output = wrong_output });
}

pub fn guestSource(allocator: std.mem.Allocator, options: GuestOptions) ![]u8 {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const input_schema = try c.schema(m.GuestInput, &b);
    const output_schema = try c.schema(m.GuestOutput, &b);
    const unit = try b.scalar(void);
    const response = try c.schema(m.CompletionReply, &b);
    const effect: ?u64 = if (options.ports == 0) null else try b.effect(.{
        .identity = m.completion_identity,
        .payload = if (options.wrong_port) unit else try c.schema(m.CompletionRequest, &b),
        .result = response,
        .external = false,
    });
    const entry = try b.declare(
        &.{input_schema},
        if (options.wrong_output) unit else output_schema,
        if (effect) |id| &.{id} else &.{},
        &.{},
    );
    const result = if (options.wrong_output)
        try literal(void, &b, {})
    else
        try guestOutput(&b, entry, output_schema, options);
    const payload_value = if (options.wrong_port)
        try literal(void, &b, {})
    else
        try literal(m.CompletionRequest, &b, .{ .context = .{ .bytes = options.context } });
    var term = try b.pure(result);
    for (0..options.ports) |_| term = try b.bind(
        try b.variable(response),
        try b.term(.{ .perform = .{
            .effect = effect.?,
            .payload = payload_value,
        } }),
        term,
    );
    try b.define(entry, term);
    return native.source_records.encode(allocator, b.module(entry, unit));
}

fn guestOutput(
    b: *horos.source.Builder,
    entry: u64,
    output_schema: u64,
    options: GuestOptions,
) !u64 {
    const state = if (options.output_state) |value|
        try literal(m.State, b, .{ .bytes = value })
    else
        try b.primitive(
            try c.schema(m.State, b),
            .field,
            &.{try b.reference(b.parameter(entry, 0))},
            1,
        );
    const summary = try literal(mc.Summary, b, options.summary);
    return b.primitive(output_schema, .product, &.{ summary, state }, 0);
}

fn input(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: []const u8,
) !m.MethodInput {
    return .{
        .retained = .{
            .source = .{ .task = @splat(1), .digest = hash(bytes) },
            .source_digest = hash(bytes),
            .contract_digest = try external.contractDigest(allocator),
            .bytes = .{ .bytes = bytes },
        },
        .guest = .{
            .batches = .{ .items = &.{} },
            .state = .{ .bytes = state },
        },
        .input_bytes_max = 65536,
        .model = null,
        .initiating_input = @splat(2),
    };
}

const Scenario = struct {
    calls: std.atomic.Value(u32) = .init(0),
    unknown: bool = false,
    context: []const u8 = "retained method context",
    fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *Scenario = @ptrCast(@alignCast(ctx.environment.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        var prepared = try c.decodeOwned(
            model_external.Adapter.Prepared,
            ctx.allocator,
            bytes,
        );
        defer prepared.deinit();
        try std.testing.expectEqualStrings(
            self.context,
            prepared.value.request.invocation.messages.items[1].content.bytes,
        );
        if (self.unknown) return .{ .unknown = error.TestUnknown };
        const body = "{\"id\":\"method-response\",\"status\":\"completed\",\"error\":null," ++
            "\"output\":[{\"type\":\"function_call\",\"status\":\"completed\",\"id\":\"fc\"," ++
            "\"call_id\":\"call\",\"name\":\"summarize\",\"arguments\":\"{\\\"summary\\\":" ++
            "\\\"Checked completion\\\",\\\"highlights\\\":[]}\"}]," ++
            "\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}";
        return .{ .captured = try c.encodeOwned(
            model_external.Raw,
            ctx.allocator,
            .{
                .status = 200,
                .identity_encoding = true,
                .request_id = .{ .bytes = "method-request" },
                .body = .{ .bytes = body },
                .format = .json,
                .media_type = .{ .bytes = "application/json" },
            },
        ) };
    }
};

pub fn configure(fixture: anytype) !mc.Binding {
    const allocator = fixture.arena.allocator();
    fixture.profile.authority.inference = true;
    const catalog = try model_external.emptyCatalog(allocator);
    const policy: mc.P.AdaptivePolicy = .{
        .schema = .{ .bytes = mc.P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://fixture.test/v1/responses" },
        .audience = .{ .bytes = "fixture" },
        .profiles = .{ .items = &.{.{
            .id = .{ .bytes = "selected" },
            .model = .{ .bytes = "fixture-model" },
            .reasoning_mode = .standard,
            .reasoning_context = .current_turn,
            .efforts = .{ .items = &.{.medium} },
            .effort_update = false,
            .explicit_cache = false,
            .additional_tools = false,
            .cache_diagnostics = false,
            .opaque_family = .{ .bytes = "fixture" },
            .max_output_tokens = 4096,
            .request_bytes = 1024 * 1024,
            .response_bytes = 2 * 1024 * 1024,
            .timeout_ms = 1000,
        }} },
        .catalog = .{ .digest = hash(catalog), .bytes = catalog.len },
        .core_tools = .{ true, true },
        .permitted_tools = .{ true, true },
    };
    var config = native.json.object();
    try native.json.put(
        allocator,
        &config,
        "adaptive",
        try native.values.toJson(mc.P.AdaptivePolicy, allocator, policy),
    );
    try native.json.put(
        allocator,
        &config,
        "responses",
        try native.values.toJson(
            c.ResponsesContract,
            allocator,
            .{ .route = .api_key_json, .binding = null },
        ),
    );
    fixture.profile.bytes = try native.json.canonical(allocator, config);
    fixture.profile.resources = try allocator.dupe([]const u8, &.{catalog});
    return (try model_external.binding(
        allocator,
        fixture.profile.bytes,
        "selected",
        .medium,
    )).value;
}

fn drive(
    fixture: anytype,
    session: *Session,
    id: t.Id,
    stop_model: ?*Scenario,
) !bool {
    const allocator = fixture.arena.allocator();
    for (0..20000) |_| {
        const completed = try session.collect(allocator, false);
        if (stop_model) |scenario| {
            if (completed != .none and scenario.calls.load(.acquire) != 0) return false;
        }
        var status = try fixture.service.?.task(allocator, id);
        defer status.deinit();
        if (status.value.terminal()) return true;
        _ = try session.advance(allocator);
        if (session.busy()) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    var status = try fixture.service.?.task(allocator, id);
    defer status.deinit();
    std.debug.print(
        "method status {s} {s} blocker={any}\n",
        .{
            @tagName(status.value.outcome_kind),
            @tagName(status.value.schedule),
            status.value.blocker,
        },
    );
    return error.MethodDidNotComplete;
}

fn submit(
    fixture: anytype,
    session: *Session,
    operation: []const u8,
    selected: m.MethodInput,
) !m.Result {
    const admitted = try fixture.service.?.submit(fixture.arena.allocator(), operation, selected);
    try std.testing.expect(try drive(fixture, session, admitted.receipt.task, null));
    return fixture.output(admitted.receipt.task);
}

const BoundedApplication = struct {
    pub const declarations = Application.declarations;

    pub fn emit(ctx: protean.Context) !horos.source.Module {
        const method = @import("../app/method.zig");
        const ops = try method.declare(ctx);
        const completion = try @import("../app/model.zig").emit(ctx);
        const invocation = try mc.P.declare(ctx);
        const function = try method.emitBounded(
            ctx,
            ops,
            completion,
            .{ invocation, ops.workspace, ops.codec },
            2,
        );
        return ctx.author.module(function, try ctx.schema(t.Failure));
    }
};

fn yieldingSource(allocator: std.mem.Allocator) ![]u8 {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const incoming = try c.schema(m.GuestInput, &b);
    const outgoing = try c.schema(m.GuestOutput, &b);
    const entry = try b.declare(&.{incoming}, outgoing, &.{}, &.{});
    const again = try b.term(.{ .call = .{
        .function = entry,
        .arguments = &.{try b.reference(b.parameter(entry, 0))},
    } });
    try b.define(entry, try b.term(.{ .yield_then = again }));
    return native.source_records.encode(allocator, b.module(entry, try b.scalar(void)));
}

test "native retained method bounded conductor cancels a yielding candidate" {
    var fixture: @import("native_fixture.zig").Fixture(Types, BoundedApplication) = .{};
    defer fixture.deinit();
    try fixture.initWithGrants(&.{ m.workspace_identity, m.codec_identity });
    var session = try Session.init(&fixture.service.?);
    defer session.deinit() catch @panic("bounded method session left busy");
    const allocator = fixture.arena.allocator();
    const result = try submit(
        &fixture,
        &session,
        "bounded",
        try input(allocator, try yieldingSource(allocator), ""),
    );
    try std.testing.expectEqualStrings("MethodAdvanceLimit", result.outcome.fault.bytes);
    try std.testing.expect(!result.model_consumed);
}

test "native retained method re-admits source without model admission and runs changed input" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.initWithGrants(&.{ m.workspace_identity, m.codec_identity });
    var session = try Session.init(&fixture.service.?);
    defer session.deinit() catch @panic("method session left busy");
    const allocator = fixture.arena.allocator();
    const source = try guest(allocator, 0, false);
    const first = try submit(
        &fixture,
        &session,
        "first",
        try input(allocator, source, "first"),
    );
    const large_state = try allocator.alloc(u8, 16 * 1024);
    @memset(large_state, 'x');
    const changed = try submit(
        &fixture,
        &session,
        "changed",
        try input(allocator, source, large_state),
    );
    try std.testing.expect(!first.model_consumed and !changed.model_consumed);
    try std.testing.expect(first.outcome == .success);
    try std.testing.expect(changed.outcome == .success);
    try std.testing.expectEqualStrings("first", first.outcome.success.state.bytes);
    try std.testing.expectEqualStrings(large_state, changed.outcome.success.state.bytes);
}

test "native retained method rejects wrong output malformed source and exact input overflow" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.initWithGrants(&.{ m.workspace_identity, m.codec_identity });
    var session = try Session.init(&fixture.service.?);
    defer session.deinit() catch @panic("method session left busy");
    const allocator = fixture.arena.allocator();
    const wrong = try submit(
        &fixture,
        &session,
        "wrong",
        try input(allocator, try guest(allocator, 0, true), ""),
    );
    try std.testing.expect(wrong.outcome == .fault and !wrong.model_consumed);
    const port_source = try guestSource(allocator, .{ .ports = 1, .wrong_port = true });
    const port = try submit(
        &fixture,
        &session,
        "wrong-port",
        try input(allocator, port_source, ""),
    );
    try std.testing.expectEqualStrings("InvalidMethodSchema", port.outcome.fault.bytes);
    try std.testing.expect(!port.model_consumed);
    const malformed = try submit(
        &fixture,
        &session,
        "malformed",
        try input(allocator, "{not a source}", ""),
    );
    try std.testing.expect(malformed.outcome == .fault and !malformed.model_consumed);
    var small = try input(
        allocator,
        try guest(allocator, 0, false),
        "state",
    );
    const encoded = try c.encodeOwned(m.GuestInput, allocator, small.guest);
    small.input_bytes_max = encoded.len;
    const exact = try submit(&fixture, &session, "exact-bound", small);
    try std.testing.expect(exact.outcome == .success);
    small.input_bytes_max -= 1;
    const bound = try submit(&fixture, &session, "bound", small);
    try std.testing.expectEqualStrings("MethodInputBound", bound.outcome.fault.bytes);
}

test "native retained method second completion port is cancelled after one checked call" {
    var scenario: Scenario = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture);
    try fixture.initWithGrants(&.{
        m.workspace_identity,
        m.codec_identity,
        mc.P.identity,
    });
    var session = try Session.init(&fixture.service.?);
    defer session.deinit() catch @panic("method session left busy");
    const allocator = fixture.arena.allocator();
    var selected = try input(
        allocator,
        try guest(allocator, 2, false),
        "state",
    );
    selected.model = binding;
    const result = try submit(&fixture, &session, "twice", selected);
    try std.testing.expect(result.model_consumed);
    try std.testing.expectEqualStrings(
        "MethodCompletionLimit",
        result.outcome.fault.bytes,
    );
    try std.testing.expectEqual(1, scenario.calls.load(.acquire));
}

test "native retained method captured completion survives owner restart" {
    var scenario: Scenario = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture);
    try fixture.initWithGrants(&.{
        m.workspace_identity,
        m.codec_identity,
        mc.P.identity,
    });
    var session = try Session.init(&fixture.service.?);
    var attached = true;
    defer if (attached) session.deinit() catch @panic("method session left busy");
    const allocator = fixture.arena.allocator();
    const large_context = try allocator.alloc(u8, 60 * 1024);
    @memset(large_context, 'x');
    scenario.context = large_context;
    var selected = try input(
        allocator,
        try guestSource(allocator, .{ .ports = 1, .context = large_context }),
        "retained state",
    );
    selected.model = binding;
    const admitted = try fixture.service.?.submit(allocator, "restart", selected);
    try std.testing.expect(!try drive(
        &fixture,
        &session,
        admitted.receipt.task,
        &scenario,
    ));
    try session.deinit();
    attached = false;
    try fixture.close();
    try fixture.open();
    var saved = try fixture.service.?.task(allocator, admitted.receipt.task);
    defer saved.deinit();
    _ = try fixture.service.?.resumeTask(
        allocator,
        "resume",
        admitted.receipt.task,
        saved.value.revision,
    );
    session = try Session.init(&fixture.service.?);
    attached = true;
    try std.testing.expect(try drive(&fixture, &session, admitted.receipt.task, null));
    const result = try fixture.output(admitted.receipt.task);
    try std.testing.expect(result.model_consumed);
    try std.testing.expectEqualStrings(
        "retained state",
        result.outcome.success.state.bytes,
    );
    try std.testing.expectEqual(1, scenario.calls.load(.acquire));
}

test "native retained method unknown completion remains blocked without fallback" {
    var scenario: Scenario = .{ .unknown = true };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture);
    try fixture.initWithGrants(&.{
        m.workspace_identity,
        m.codec_identity,
        mc.P.identity,
    });
    var session = try Session.init(&fixture.service.?);
    defer session.deinit() catch @panic("method session left busy");
    const allocator = fixture.arena.allocator();
    var selected = try input(
        allocator,
        try guest(allocator, 1, false),
        "state",
    );
    selected.model = binding;
    const admitted = try fixture.service.?.submit(allocator, "unknown", selected);
    try std.testing.expect(!try drive(
        &fixture,
        &session,
        admitted.receipt.task,
        &scenario,
    ));
    for (0..3) |_| _ = try session.tick(allocator);
    var saved = try fixture.service.?.task(allocator, admitted.receipt.task);
    defer saved.deinit();
    try std.testing.expect(!saved.value.terminal());
    try std.testing.expect(saved.value.blocker != null);
    try std.testing.expect(!session.busy());
    try std.testing.expectEqual(1, scenario.calls.load(.acquire));
}
