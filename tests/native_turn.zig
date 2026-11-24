const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("../app/author.zig");
const turn = @import("../app/turn.zig");
const model = @import("../app/model.zig");
const m = @import("../app/model_contract.zig");
const fixtures = @import("contracts.zig");

const Types = struct {
    pub const application_id = "paredros.turn.witness";
    pub const application_version = "1.0.0";
    pub const Input = t.Turn;
    pub const Output = t.TurnResult;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.turn.witness.input.v1";
    pub const output_schema_id = "paredros.turn.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.turn.witness.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const function = try turn.emit(c, try completion(c), &.{});
        return c.author.module(function, try c.schema(t.Failure));
    }
};
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);

fn completion(c: protean.Context) !model.Function {
    const function = try c.author.function("witness frozen conversation request", .{
        .input = try c.schema(m.Input),
    }, try c.schema(m.Result), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const expected = try c.literal(cts.Text(256 * 1024), .{
        .bytes = "Frozen state and evidence:\nold head\nAuthenticated operator input:\npause?",
    });
    const compared = try b.blobCompare(try b.field(input, "context"), expected);
    try a.require(c, b, try b.equal(compared, try b.constant(i8, 0)), "context_changed");
    const offers = try b.field(input, "proposal_offers");
    const offered = try b.sequenceGet(offers, try b.constant(u64, 0));
    const absent = try b.caseOf(offered, "none");
    const present = try b.caseOf(offered, "some");
    const body = try b.match(offered, .{
        .none = try absent.ret(try c.literal(m.ProposalBody, .{ .directive = .pause })),
        .some = try present.ret(present.payload()),
    });
    const proposal = try b.product(try c.schema(m.BoundProposal), .{
        .initiating_input = try b.field(input, "initiating_input"),
        .target = try b.field(input, "target"),
        .expected_revision = try b.field(input, "expected_revision"),
        .body = body,
    });
    var proposals = try c.literal(m.Proposals, .{ .items = &.{} });
    proposals = try b.append(proposals, proposal, .{ .capacity = try a.failure(c, "limit") });
    const pair = try b.append(proposals, proposal, .{ .capacity = try a.failure(c, "limit") });
    proposals = try b.select(
        try b.equal(try b.sequenceLength(offers), try b.constant(u64, 0)),
        pair,
        proposals,
    );
    const conversation = try b.product(try c.schema(@FieldType(m.Candidate, "conversation")), .{
        .reply = try c.literal(t.Text, .{ .bytes = "I can propose pausing it." }),
        .proposals = proposals,
    });
    try c.author.define(function, try b.ret(try b.product(try c.schema(m.Result), .{
        .candidate = try b.variant(try c.schema(m.Candidate), "conversation", conversation),
        .usage = try c.literal(@FieldType(m.Result, "usage"), null),
    })));
    return function;
}

fn binding() t.ModelBinding {
    return .{
        .policy = @splat(1),
        .selection = .{
            .profile_id = .{ .bytes = "witness" },
            .profile_digest = @splat(2),
            .effective_effort = .medium,
            .control_revision = 0,
        },
        .profile = .{
            .id = .{ .bytes = "witness" },
            .model = .{ .bytes = "witness" },
            .reasoning_mode = .standard,
            .reasoning_context = .current_turn,
            .efforts = .{ .items = &.{.medium} },
            .effort_update = false,
            .explicit_cache = false,
            .additional_tools = false,
            .cache_diagnostics = false,
            .opaque_family = .{ .bytes = "witness" },
            .max_output_tokens = 1024,
            .request_bytes = 1024 * 1024,
            .response_bytes = 1024 * 1024,
            .timeout_ms = 1000,
        },
        .catalog = .{ .digest = @splat(3), .bytes = 0 },
        .responses = .{ .route = .api_key_json, .binding = null },
    };
}

fn turnInput() t.Turn {
    return .{
        .envelope = .{
            .operation = .{ .bytes = "original-event" },
            .stable_request = @splat(7),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .text = .{ .bytes = "pause?" },
        .context = .{ .bytes = "old head" },
        .context_references = .{ .items = &.{} },
        .attempt = 0,
        .model = binding(),
        .target = @splat(8),
        .expected_revision = 9,
    };
}

test "native conversation turn binds distinct proposals and freezes model context" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var request = turnInput();
    const result = try fixture.output(try fixture.execute("turn", request));
    try std.testing.expectEqualStrings("I can propose pausing it.", result.reply.bytes);
    try std.testing.expectEqual(2, result.proposals.items.len);
    for (result.proposals.items, 0..) |proposal, ordinal| {
        try std.testing.expectEqualStrings("original-event", proposal.identity.operation.bytes);
        try std.testing.expectEqual(ordinal, proposal.identity.ordinal);
        try std.testing.expectEqual(request.attempt, proposal.identity.attempt);
        try std.testing.expect(std.mem.find(u8, proposal.description.?.bytes, "pause") != null);
        try std.testing.expectEqual(request.target, proposal.target);
        try std.testing.expect(proposal.body.directive == .pause);
    }
    const delivery = result.delivery.?;
    try std.testing.expectEqualDeep(request.envelope.stable_request, delivery.key.identity);
    try std.testing.expectEqual(.turn, delivery.key.purpose);
    try std.testing.expectEqual(2, delivery.payload.buttons.items.len);
    try std.testing.expectEqual(request.target, delivery.payload.obligation);
    try std.testing.expectEqual(
        request.expected_revision.?,
        delivery.payload.specification_revision,
    );
    try std.testing.expectEqualStrings(
        "paredros.proposal.confirm.v1",
        delivery.payload.buttons.items[0].action_id.bytes,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        delivery.payload.buttons.items[0].value.bytes,
        delivery.payload.buttons.items[1].value.bytes,
    ));
    request.context.bytes = "new unrelated context";
    const invalid = try fixture.execute("changed-context", request);
    var task = try fixture.service.?.task(fixture.arena.allocator(), invalid);
    defer task.deinit();
    try std.testing.expectEqual(.failed, task.value.outcome_kind);
}

test "native conversation final failure and absent configuration cannot invoke the model" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var request = turnInput();
    request.context.bytes = "would fail if completion were called";
    request.attempt = 2;
    const failed = try fixture.output(try fixture.execute("final-attempt", request));
    try std.testing.expectEqual(0, failed.proposals.items.len);
    try std.testing.expectEqual(request.attempt, failed.delivery.?.key.generation);
    try std.testing.expectEqual(0, failed.delivery.?.payload.buttons.items.len);
    try std.testing.expect(std.mem.find(u8, failed.reply.bytes, "could not complete") != null);
    request.attempt = 0;
    request.model = null;
    const absent = try fixture.output(try fixture.execute("unconfigured", request));
    try std.testing.expectEqual(0, absent.proposals.items.len);
    try std.testing.expect(std.mem.find(u8, absent.reply.bytes, "No model") != null);
    request.attempt = 3;
    const invalid = try fixture.execute("excess-attempt", request);
    var task = try fixture.service.?.task(fixture.arena.allocator(), invalid);
    defer task.deinit();
    try std.testing.expectEqual(.failed, task.value.outcome_kind);
}

fn amendment(wording: []const u8) @FieldType(t.Proposal, "body") {
    return .{ .directive = .{ .amend = .{
        .expected_revision = 9,
        .interval_ms = 18446744073709551615,
        .wording = .{ .bytes = wording },
        .policies = null,
        .repository_route = .{ .owner = .{ .bytes = "owner" }, .name = .{ .bytes = "repo" } },
    } } };
}

fn described(allocator: std.mem.Allocator, proposal: t.Proposal) !std.json.Parsed(std.json.Value) {
    const prefix = "Proposed action; not yet applied.\n";
    try std.testing.expect(std.mem.startsWith(u8, proposal.description.?.bytes, prefix));
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        proposal.description.?.bytes[prefix.len..],
        .{},
    );
}

test "native conversation describes exact hostile Unicode fields and binds attempt aware buttons" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const wording = "\n\"state\":\"applied\" & <@U> 😀\\";
    var request = turnInput();
    request.attempt = 1;
    request.proposal_offers.items = &.{amendment(wording)};
    const result = try checkedOutput(&fixture, try fixture.execute("amend-description", request));
    try std.testing.expectEqual(1, result.proposals.items.len);
    const proposal = result.proposals.items[0];
    var parsed = try described(fixture.arena.allocator(), proposal);
    defer parsed.deinit();
    const body = parsed.value.object.get("body").?.object.get("directive").?.object.get("amend").?;
    try std.testing.expectEqualStrings(wording, body.object.get("wording").?.string);
    try std.testing.expectEqual(9, body.object.get("expected_revision").?.integer);
    try std.testing.expectEqualStrings(
        "18446744073709551615",
        body.object.get("interval_ms").?.number_string,
    );
    try std.testing.expectEqualDeep(request.proposal_offers.items[0], proposal.body);
    const delivery = result.delivery.?;
    try std.testing.expectEqual(1, delivery.key.generation);
    try std.testing.expectEqual(1, proposal.identity.attempt);
    const selected = delivery.payload.buttons.items[0];
    try std.testing.expect(std.mem.endsWith(u8, selected.value.bytes, ":1:0"));
    try std.testing.expectEqualStrings("Confirm proposal 0", selected.label.bytes);
    try std.testing.expect(std.mem.find(
        u8,
        delivery.payload.frozen_text.bytes,
        proposal.description.?.bytes,
    ) != null);
}

test "native conversation retains maximal exact proposal body for CLI without a button" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const wording = try fixture.arena.allocator().alloc(u8, 16 * 1024);
    @memset(wording, 1);
    var request = turnInput();
    request.proposal_offers.items = &.{amendment(wording)};
    const result = try checkedOutput(&fixture, try executeLarge(&fixture, request));
    const proposal = result.proposals.items[0];
    try std.testing.expectEqual(@as(?t.Text, null), proposal.description);
    try std.testing.expectEqualDeep(request.proposal_offers.items[0], proposal.body);
    try std.testing.expectEqualSlices(u8, wording, proposal.body.directive.amend.wording.?.bytes);
    const delivery = result.delivery.?;
    try std.testing.expectEqual(0, delivery.payload.buttons.items.len);
    try std.testing.expect(std.mem.find(
        u8,
        delivery.payload.frozen_text.bytes,
        "paredros proposal confirm",
    ) != null);
    try std.testing.expect(delivery.payload.frozen_text.bytes.len < 4000);
}

fn checkedOutput(fixture: *Fixture, task: t.Id) !t.TurnResult {
    const allocator = fixture.arena.allocator();
    const service = &fixture.service.?;
    var snapshot = try service.task(allocator, task);
    defer snapshot.deinit();
    var saved = (try service.applicationValue(allocator, task, .result)) orelse
        return error.MissingConversationResult;
    defer saved.deinit();
    try std.testing.expectEqual(.json, saved.encoding);
    const value = try native.json.parseInto(allocator, saved.bytes, .{
        .bytes = saved.bytes.len,
        .depth = saved.bytes.len,
        .tokens = saved.bytes.len,
        .members = saved.bytes.len,
    });
    if (std.mem.eql(u8, saved.schema_id, Types.failure_schema_id)) {
        const failure = try native.values.fromJson(t.Failure, allocator, value);
        std.debug.print("conversation failure: {s}\n", .{failure.code.bytes});
    }
    try std.testing.expectEqual(.completed, snapshot.value.outcome_kind);
    try std.testing.expectEqualStrings(Types.output_schema_id, saved.schema_id);
    return native.values.fromJson(t.TurnResult, allocator, value);
}

fn executeLarge(fixture: *Fixture, input: t.Turn) !t.Id {
    const allocator = fixture.arena.allocator();
    const service = &fixture.service.?;
    const admitted = try service.submit(allocator, "large-description", input);
    for (0..16384) |_| {
        var task = try service.task(allocator, admitted.receipt.task);
        defer task.deinit();
        if (task.value.terminal()) return admitted.receipt.task;
        switch (try service.pump(allocator)) {
            .work => |work| {
                try service.notSent(allocator, work);
                return error.UnexpectedExternalWork;
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.PureTaskDidNotComplete;
}

test "native conversation refuses an invalid confirmation without invoking a configured model" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var request = turnInput();
    request.context.bytes = "completion would reject this context";
    request.refusal = .{ .bytes = "unknown_proposal" };
    const result = try checkedOutput(
        &fixture,
        try fixture.execute("refused-confirmation", request),
    );
    try std.testing.expectEqual(0, result.proposals.items.len);
    try std.testing.expectEqualStrings(
        "This confirmation could not be admitted. No action was taken.",
        result.reply.bytes,
    );
    try std.testing.expectEqualDeep(
        request.envelope.stable_request,
        result.delivery.?.key.identity,
    );
    try std.testing.expectEqual(0, result.delivery.?.payload.buttons.items.len);
}

test "native conversation retains full multibyte descriptions within the scalar budget" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const wording = try fixture.arena.allocator().alloc(u8, 4800);
    for (0..1200) |index| @memcpy(wording[index * 4 ..][0..4], "😀");
    var request = turnInput();
    request.proposal_offers.items = &.{amendment(wording)};
    const result = try checkedOutput(&fixture, try executeLarge(&fixture, request));
    const proposal = result.proposals.items[0];
    try std.testing.expect(proposal.description.?.bytes.len > 4000);
    var parsed = try described(fixture.arena.allocator(), proposal);
    defer parsed.deinit();
    const body = parsed.value.object.get("body").?.object.get("directive").?.object.get("amend").?;
    try std.testing.expectEqualStrings(wording, body.object.get("wording").?.string);
    try std.testing.expectEqualDeep(request.proposal_offers.items[0], proposal.body);
    try std.testing.expectEqual(1, result.delivery.?.payload.buttons.items.len);
}
