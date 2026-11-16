const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const m = @import("../app/model_contract.zig");
const model = @import("../app/model.zig");
const external = @import("../native/model_external.zig");
const examples = @import("contracts.zig");
const a = std.testing.allocator;

const Types = struct {
    pub const application_id = "paredros.model.witness";
    pub const application_version = "1.0.0";
    pub const Input = m.Input;
    pub const Output = m.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.model.witness.input.v1";
    pub const output_schema_id = "paredros.model.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.model.witness.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Application = struct {
    pub const declarations: []const native.Declaration = &.{declaration()};
    fn declaration() native.Declaration {
        var result = external.declaration();
        result.capture.?.acquire = Scenario.acquire;
        return result;
    }
    pub fn emit(ctx: protean.Context) !horos.source.Module {
        return ctx.author.module(try model.emit(ctx), try ctx.schema(t.Failure));
    }
};
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);

fn hash(bytes: []const u8) t.Digest {
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn configure(fixture: *Fixture, plan: bool) !m.Binding {
    const allocator = fixture.arena.allocator();
    fixture.profile.authority.inference = true;
    const catalog = try external.emptyCatalog(allocator);
    const profile: protean.model_invocation.AdaptiveInferenceProfile = .{
        .id = .{ .bytes = "selected" },
        .model = .{ .bytes = "fixture-model" },
        .reasoning_mode = .standard,
        .reasoning_context = if (plan) .auto else .current_turn,
        .efforts = .{ .items = &.{.medium} },
        .effort_update = false,
        .explicit_cache = false,
        .additional_tools = plan,
        .cache_diagnostics = false,
        .opaque_family = .{ .bytes = "fixture" },
        .max_output_tokens = if (plan) null else 4096,
        .request_bytes = 1024 * 1024,
        .response_bytes = 2 * 1024 * 1024,
        .timeout_ms = 1000,
    };
    const policy: m.P.AdaptivePolicy = .{
        .schema = .{ .bytes = m.P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://fixture.test/v1/responses" },
        .audience = .{ .bytes = "fixture" },
        .profiles = .{ .items = &.{profile} },
        .catalog = .{ .digest = hash(catalog), .bytes = catalog.len },
        .core_tools = .{ true, true },
        .permitted_tools = .{ true, true },
    };
    var config = native.json.object();
    try native.json.put(
        allocator,
        &config,
        "adaptive",
        try native.values.toJson(m.P.AdaptivePolicy, allocator, policy),
    );
    const responses = try native.values.toJson(c.ResponsesContract, allocator, .{
        .route = if (plan) .chatgpt_plan_sse else .api_key_json,
        .binding = if (plan) @splat(1) else null,
    });
    try native.json.put(allocator, &config, "responses", responses);
    fixture.profile.bytes = try native.json.canonical(allocator, config);
    fixture.profile.resources = try allocator.dupe([]const u8, &.{catalog});
    const binding = try external.binding(allocator, fixture.profile.bytes, "selected", .medium);
    return binding.value;
}

const Case = enum {
    summary,
    conversation,
    malformed,
    unoffered,
    refusal,
    invalid_oid,
    invalid_hex,
    genesis,
};
const Scenario = struct {
    selected: Case = .summary,
    calls: u32 = 0,
    plan: bool = false,
    fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *Scenario = @ptrCast(@alignCast(ctx.environment.?));
        self.calls += 1;
        var prepared = try c.decodeOwned(external.Adapter.Prepared, ctx.allocator, bytes);
        defer prepared.deinit();
        const request = prepared.value.request;
        try std.testing.expectEqual(1, request.invocation.selection.maximum_calls);
        try std.testing.expectEqual(1, request.invocation.selection.minimum_calls);
        try std.testing.expect(!request.invocation.response_policy.store);
        try std.testing.expectEqual(self.plan, request.invocation.response_policy.stream);
        try std.testing.expectEqualStrings("fixture-model", request.invocation.model.bytes);
        try std.testing.expectEqualStrings(
            "frozen operator context",
            request.invocation.messages.items[1].content.bytes,
        );
        try std.testing.expectEqualSlices(bool, &.{ true, true }, &request.materialized);
        const conversation = self.selected == .conversation or self.selected == .genesis;
        try std.testing.expectEqualSlices(
            bool,
            &.{ !conversation, conversation },
            &request.offered,
        );
        const response_bytes = try self.response(ctx.allocator);
        defer ctx.allocator.free(response_bytes);
        return .{ .captured = try c.encodeOwned(external.Raw, ctx.allocator, .{
            .status = 200,
            .identity_encoding = true,
            .request_id = .{ .bytes = "captured-model-request" },
            .body = .{ .bytes = response_bytes },
            .format = if (self.plan) .sse else .json,
            .media_type = .{ .bytes = if (self.plan) "text/event-stream" else "application/json" },
        }) };
    }

    fn response(self: *Scenario, allocator: std.mem.Allocator) ![]u8 {
        const args = try self.arguments(allocator);
        defer allocator.free(args);
        const name = if (self.selected == .conversation or self.selected == .genesis or
            self.selected == .unoffered) "converse" else "summarize";
        const encoded = if (self.selected == .refusal)
            try allocator.dupe(u8, "{\"id\":\"response-1\"," ++
                "\"status\":\"completed\",\"error\":null," ++
                "\"output\":[{\"type\":\"message\"," ++
                "\"status\":\"completed\",\"role\":\"assistant\"," ++
                "\"content\":[{\"type\":\"refusal\",\"refusal\":\"cannot comply\"}]}]}")
        else
            try std.json.Stringify.valueAlloc(allocator, .{
                .id = "response-1",
                .status = "completed",
                .@"error" = @as(?u8, null),
                .output = .{.{
                    .type = "function_call",
                    .status = "completed",
                    .id = "fc-1",
                    .call_id = "call-1",
                    .name = name,
                    .arguments = args,
                }},
                .usage = .{ .input_tokens = @as(u64, 20), .output_tokens = @as(u64, 10) },
            }, .{});
        if (!self.plan) return encoded;
        defer allocator.free(encoded);
        return sse(allocator, encoded);
    }

    fn arguments(self: *Scenario, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.selected) {
            .malformed => allocator.dupe(u8, "{\"summary\":7,\"highlights\":[]}"),
            .unoffered => allocator.dupe(u8, "{\"reply\":\"unoffered\",\"proposals\":[]}"),
            .conversation => allocator.dupe(u8, "{\"reply\":\"proposed only\",\"proposals\":[" ++
                "{\"tag\":\"select_proposal\",\"value\":{\"index\":0}}," ++
                "{\"tag\":\"propose_amend\",\"value\":{\"interval_ms\":120000," ++
                "\"wording\":\"Concise\",\"policies\":null,\"repository_route\":null}}]}"),
            .genesis => std.fmt.allocPrint(allocator, "{{\"reply\":\"new monitor proposal\"," ++
                "\"proposals\":[{{\"tag\":\"propose_genesis\"," ++
                "\"value\":{{\"interval_ms\":120000," ++
                "\"wording\":\"concise\",\"policies\":{s}}}}}]}}", .{
                try std.json.Stringify.valueAlloc(allocator, t.Policies{}, .{}),
            }),
            else => std.json.Stringify.valueAlloc(allocator, .{
                .summary = "Frozen summary",
                .highlights = .{.{
                    .oid = if (self.selected == .invalid_oid)
                        "not-an-oid"
                    else if (self.selected == .invalid_hex)
                        "gggggggggggggggggggggggggggggggggggggggg"
                    else
                        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    .text = "Evidence-backed highlight",
                }},
            }, .{}),
        };
    }
};

fn modelInput(binding: m.Binding, phase: @FieldType(m.Input, "phase")) m.Input {
    return .{
        .binding = binding,
        .phase = phase,
        .context = .{ .bytes = "frozen operator context" },
        .initiating_input = @splat(7),
        .target = @splat(8),
        .expected_revision = 9,
        .proposal_offers = .{ .items = &.{.{ .directive = .pause }} },
        .genesis_template = null,
    };
}

fn complete(fixture: *Fixture, work: native.tasks.Work) !void {
    const allocator = fixture.arena.allocator();
    const task_id = std.fmt.bytesToHex(work.task, .lower);
    const acquired = try work.entry.declaration.capture.?.acquire(.{
        .allocator = allocator,
        .io = .failing,
        .authority = &fixture.profile.authority,
        .task_id = &task_id,
        .profile = work.profile,
        .environment = fixture.profile.environment,
    }, work.prepared orelse return error.MissingPrepared);
    if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
    defer allocator.free(acquired.captured);
    try fixture.service.?.completeWork(allocator, work, .{ .acquired = acquired.captured });
}

fn drive(fixture: *Fixture, task_id: t.Id, stop: bool) !bool {
    const allocator = fixture.arena.allocator();
    for (0..4096) |_| {
        var task = try fixture.service.?.task(allocator, task_id);
        defer task.deinit();
        if (task.value.terminal()) return true;
        switch (try fixture.service.?.pump(allocator)) {
            .work => |work| {
                try complete(fixture, work);
                if (stop) return false;
            },
            .idle, .waiting, .progressed => {},
        }
    }
    var last = try fixture.service.?.task(allocator, task_id);
    defer last.deinit();
    std.debug.print("model cut outcome={s} schedule={s} blocker={any} attempts={d}\n", .{
        @tagName(last.value.outcome_kind), @tagName(last.value.schedule),
        last.value.blocker,                last.value.inference_attempts,
    });
    return error.ModelDidNotComplete;
}

test "native model candidate capture replays after restart without a second inference" {
    var scenario: Scenario = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture, false);
    try fixture.initWithGrants(&.{m.P.identity});
    const allocator = fixture.arena.allocator();
    const admitted = try fixture.service.?.submit(
        allocator,
        "model",
        modelInput(binding, .summary),
    );
    const id = admitted.receipt.task;
    try std.testing.expect(!try drive(&fixture, id, true));
    try std.testing.expectEqual(1, scenario.calls);
    try fixture.close();
    try fixture.open();
    try std.testing.expectEqual(.idle, try fixture.service.?.pump(allocator));
    var saved = try fixture.service.?.task(allocator, id);
    defer saved.deinit();
    _ = try fixture.service.?.resumeTask(allocator, "resume", id, saved.value.revision);
    try std.testing.expect(try drive(&fixture, id, false));
    const result = try fixture.output(id);
    try std.testing.expectEqualStrings("Frozen summary", result.candidate.summary.summary.bytes);
    try std.testing.expectEqual(
        @as(t.Oid, @splat('a')),
        result.candidate.summary.highlights.items[0].oid,
    );
    try std.testing.expectEqual(20, result.usage.?.input_tokens.?);
    try std.testing.expectEqual(10, result.usage.?.output_tokens.?);
    try std.testing.expectEqual(1, scenario.calls);
}

test "native model candidate rejects malformed unoffered and refused responses" {
    const CaseExpected = struct { scenario: Case, failure: m.P.InterpretationFailure };
    const cases = [_]CaseExpected{
        .{ .scenario = .malformed, .failure = .invalid_arguments },
        .{ .scenario = .unoffered, .failure = .unoffered },
        .{ .scenario = .refusal, .failure = .refusal },
    };
    for (cases) |case| {
        var scenario: Scenario = .{ .selected = case.scenario };
        var fixture: Fixture = .{};
        defer fixture.deinit();
        fixture.profile.environment = &scenario;
        const binding = try configure(&fixture, false);
        try fixture.initWithGrants(&.{m.P.identity});
        const admitted = try fixture.service.?.submit(
            fixture.arena.allocator(),
            "model",
            modelInput(binding, .summary),
        );
        try std.testing.expect(try drive(&fixture, admitted.receipt.task, false));
        const result = try fixture.output(admitted.receipt.task);
        try std.testing.expectEqual(case.failure, result.candidate.rejected);
        try std.testing.expectEqual(1, scenario.calls);
    }
}

test "native model candidate binds suggestions to exact initiating input target and revision" {
    var scenario: Scenario = .{ .selected = .conversation, .plan = true };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture, true);
    try fixture.initWithGrants(&.{m.P.identity});
    const selected = modelInput(binding, .conversation);
    const admitted = try fixture.service.?.submit(fixture.arena.allocator(), "turn", selected);
    try std.testing.expect(try drive(&fixture, admitted.receipt.task, false));
    const result = try fixture.output(admitted.receipt.task);
    if (result.candidate == .rejected)
        std.debug.print(
            "model conversation rejected: {s}\n",
            .{@tagName(result.candidate.rejected)},
        );
    try std.testing.expect(result.candidate == .conversation);
    const conversation = result.candidate.conversation;
    try std.testing.expectEqualStrings("proposed only", conversation.reply.bytes);
    try std.testing.expectEqual(2, conversation.proposals.items.len);
    for (conversation.proposals.items) |proposal| {
        try std.testing.expectEqual(selected.initiating_input, proposal.initiating_input);
        try std.testing.expectEqual(selected.target, proposal.target);
        try std.testing.expectEqual(selected.expected_revision, proposal.expected_revision);
    }
    try std.testing.expect(conversation.proposals.items[0].body.directive == .pause);
    const amendment = conversation.proposals.items[1].body.directive.amend;
    try std.testing.expectEqual(9, amendment.expected_revision);
    try std.testing.expectEqual(120000, amendment.interval_ms.?);
    try std.testing.expectEqual(1, scenario.calls);
}

test "native model candidate new monitor preserves configured bindings and anchor" {
    var scenario: Scenario = .{ .selected = .genesis };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture, false);
    try fixture.initWithGrants(&.{m.P.identity});
    var selected = modelInput(binding, .conversation);
    selected.target = null;
    selected.expected_revision = null;
    selected.genesis_template = examples.specification();
    const admitted = try fixture.service.?.submit(fixture.arena.allocator(), "new", selected);
    try std.testing.expect(try drive(&fixture, admitted.receipt.task, false));
    const result = try fixture.output(admitted.receipt.task);
    const proposal = result.candidate.conversation.proposals.items[0];
    const genesis = proposal.body.genesis;
    try std.testing.expectEqualDeep(selected.genesis_template.?.repository, genesis.repository);
    try std.testing.expectEqualDeep(selected.genesis_template.?.destination, genesis.destination);
    try std.testing.expectEqual(selected.genesis_template.?.anchor_ms, genesis.anchor_ms);
    try std.testing.expectEqual(selected.genesis_template.?.revision, genesis.revision);
    try std.testing.expectEqual(120000, genesis.interval_ms);
    try std.testing.expectEqualStrings("concise", genesis.wording.bytes);
}

fn expectFailure(fixture: *Fixture, id: t.Id, expected: []const u8) !void {
    const outcome = try fixture.outcome(id);
    try std.testing.expectEqualStrings(
        "failed",
        try native.json.text(native.json.get(outcome, "type").?),
    );
    const failure = try native.values.fromJson(
        t.Failure,
        fixture.arena.allocator(),
        native.json.get(outcome, "value").?,
    );
    try std.testing.expectEqualStrings(expected, failure.code.bytes);
}

test "native model candidate invalid OID and unoffered proposal references cannot escape" {
    var scenario: Scenario = .{ .selected = .invalid_oid };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    const binding = try configure(&fixture, false);
    try fixture.initWithGrants(&.{m.P.identity});
    const allocator = fixture.arena.allocator();
    const invalid = try fixture.service.?.submit(
        allocator,
        "invalid-oid",
        modelInput(binding, .summary),
    );
    try std.testing.expect(try drive(&fixture, invalid.receipt.task, false));
    const rejected = try fixture.output(invalid.receipt.task);
    try std.testing.expectEqual(.invalid_arguments, rejected.candidate.rejected);
    try std.testing.expectEqual(20, rejected.usage.?.input_tokens.?);
    try std.testing.expectEqual(10, rejected.usage.?.output_tokens.?);
    try std.testing.expectEqual(1, scenario.calls);
    scenario.selected = .invalid_hex;
    const invalid_hex = try fixture.service.?.submit(
        allocator,
        "invalid-hex",
        modelInput(binding, .summary),
    );
    try std.testing.expect(try drive(&fixture, invalid_hex.receipt.task, false));
    const hex_result = try fixture.output(invalid_hex.receipt.task);
    try std.testing.expectEqual(.invalid_arguments, hex_result.candidate.rejected);
    try std.testing.expectEqual(2, scenario.calls);
    scenario.selected = .conversation;
    var missing = modelInput(binding, .conversation);
    missing.proposal_offers.items = &.{};
    const unoffered = try fixture.service.?.submit(allocator, "unoffered-proposal", missing);
    try std.testing.expect(try drive(&fixture, unoffered.receipt.task, false));
    try expectFailure(&fixture, unoffered.receipt.task, "model_proposal_offer");
    try std.testing.expectEqual(3, scenario.calls);
}

fn sse(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const finalized = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "response.output_item.done",
        .output_index = @as(u64, 0),
        .item = parsed.value.object.get("output").?.array.items[0],
    }, .{});
    defer allocator.free(finalized);
    const terminal = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "response.completed",
        .response = parsed.value,
    }, .{});
    defer allocator.free(terminal);
    return std.fmt.allocPrint(allocator, "event: response.output_item.done\ndata: {s}\n\n" ++
        "event: response.completed\ndata: {s}\n\n", .{ finalized, terminal });
}
