const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const contract = @import("../app/slack_contract.zig");
const external = @import("../native/slack_external.zig");
const preparation = @import("../native/delivery_prepare.zig");
const fixtures = @import("contracts.zig");
const http = @import("../native/http.zig");
const a = std.testing.allocator;

const authority: native.registry.Authority = .{
    .principal = "test",
    .tenant = "test",
    .grants = &.{},
};
const destination: t.Destination = .{
    .account = .{ .bytes = "slack-test" },
    .app = .{ .bytes = "A1" },
    .workspace = .{ .bytes = "T1" },
    .operator = .{ .bytes = "U1" },
    .channel = .{ .bytes = "D1" },
};
var object_source: u8 = 0;

fn noObject(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: native.registry.ObjectReference,
    _: usize,
) ![]u8 {
    return error.UnexpectedObjectRead;
}

fn projection() native.registry.ProjectionContext {
    return .{
        .allocator = a,
        .task = @splat(1),
        .tenant = "test",
        .profile = "test",
        .objects = .{ .source = &object_source, .read_object = noObject },
    };
}

fn environment() external.Environment {
    return .{
        .destination = destination,
        .bot_id = "B1",
        .http = .{
            .account = "slack-test",
            .origin = "https://slack.com",
            .token = "secret-never-retained",
        },
    };
}

fn context(env: ?*external.Environment) native.Context {
    return .{
        .allocator = a,
        .io = .failing,
        .authority = &authority,
        .task_id = "test",
        .profile = "test",
        .environment = env,
    };
}

const producer: t.Reference = .{ .task = @splat(7), .digest = @splat(8) };
const evidence_digest: t.Digest = @splat(6);

const Fixture = struct {
    delivery: ?c.Decoded(t.Delivery) = null,
    request: contract.Request = undefined,

    fn init(self: *Fixture, controls: bool) !void {
        const buttons: []const t.Button = if (controls) &.{.{
            .block_id = .{ .bytes = "choice-1" },
            .action_id = .{ .bytes = "approve" },
            .value = .{ .bytes = "frozen-operation" },
            .label = .{ .bytes = "Approve <one> & two" },
        }} else &.{};
        self.delivery = try preparation.materialize(a, .{
            .destination = destination,
            .key = .{
                .lineage = @splat(1),
                .purpose = .digest,
                .identity = @splat(2),
                .generation = 1,
            },
            .payload = .{
                .obligation = @splat(3),
                .specification_revision = 1,
                .prior_sequence = 2,
                .through_sequence = 5,
                .frozen_text = .{ .bytes = "Untrusted <@U2> & https://example.test" },
                .coverage = .{ .sequence = 5, .epoch = 4, .tip = @splat('b') },
                .issue = 2,
                .buttons = .{ .items = buttons },
                .comparison = .{
                    .repository = fixtures.specification().repository,
                    .base = @splat('a'),
                    .tip = @splat('b'),
                },
                .prompt = null,
                .supersedes = null,
            },
        }, producer, evidence_digest, "B1");
        const delivery = self.delivery.?.value;
        self.request = .{
            .destination = delivery.destination,
            .key = delivery.key,
            .payload = delivery.payload,
        };
    }

    fn deinit(self: *Fixture) void {
        if (self.delivery) |*delivery| delivery.deinit();
    }
};

fn interpreted(input: contract.Request, captured: []const u8) !c.Decoded(contract.Reply) {
    const bytes = try c.encodeOwned(contract.Request, a, input);
    defer a.free(bytes);
    const result = try external.interpret(projection(), bytes, bytes, captured);
    defer a.free(result.reply);
    return c.decodeOwned(contract.Reply, a, result.reply);
}

fn capturedResponse(input: contract.Request, body: []const u8, status: u16) ![]u8 {
    const bytes = try c.encodeOwned(contract.Request, a, input);
    defer a.free(bytes);
    const headers = try std.fmt.allocPrint(
        a,
        "HTTP/1.1 {d} Test\r\nContent-Type: application/json\r\n" ++
            "Date: Sun, 15 Nov 2026 00:00:00 GMT\r\nX-Slack-Req-Id: captured-id\r\n" ++
            "Retry-After: 30\r\n\r\n",
        .{status},
    );
    defer a.free(headers);
    const head = try std.http.Client.Response.Head.parse(headers);
    var reader = std.Io.Reader.fixed(body);
    var response = try http.captureResponse(a, head, &reader, .{}, environment().http.token);
    defer response.deinit();
    return external.captureBytes(a, bytes, "B1", response, 1234);
}

fn expectRejection(input: contract.Request, env: ?*external.Environment, reason: []const u8) !void {
    const bytes = try c.encodeOwned(contract.Request, a, input);
    defer a.free(bytes);
    const result = try external.acquire(context(env), bytes);
    try std.testing.expect(result == .captured);
    defer a.free(result.captured);
    var decoded = try interpreted(input, result.captured);
    defer decoded.deinit();
    try std.testing.expectEqualStrings(reason, decoded.value.rejected.code.bytes);
    try std.testing.expect(!decoded.value.rejected.retryable);
    try std.testing.expect(std.mem.find(u8, result.captured, environment().http.token) == null);
}

test "Slack external declaration uses exact protected checked request and typed result" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(false);
    const declared = external.declaration();
    try std.testing.expectEqualStrings("agent.notification.slack.v1", declared.identity);
    try std.testing.expectEqualStrings("write", declared.resource_role);
    try std.testing.expect(declared.invoke == null and declared.capture != null);
    try std.testing.expectEqual(3, @typeInfo(contract.Request).@"struct".field_names.len);
    const bytes = try c.encodeOwned(contract.Request, a, fixture.request);
    defer a.free(bytes);
    const frozen = try external.prepare(projection(), bytes);
    defer a.free(frozen);
    try std.testing.expectEqualSlices(u8, bytes, frozen);
    const payload = try declared.payload_schema(a);
    defer a.free(payload);
    const reply = try declared.resume_schema(a);
    defer a.free(reply);
    try std.testing.expect(payload.len > 0 and reply.len > 0);
}

test "Slack external fixed wire reuses existing framing with escaped buttons and text" {
    for ([_]bool{ false, true }) |controls| {
        var fixture: Fixture = .{};
        defer fixture.deinit();
        try fixture.init(controls);
        var wire = try external.preparedWire(a, fixture.request, "B1");
        defer wire.deinit();
        try std.testing.expectEqualStrings(fixture.request.payload.wire_json.bytes, wire.body);
        try std.testing.expect(std.mem.find(u8, wire.body, "&lt;@U2&gt;") != null);
        try std.testing.expect(std.mem.find(u8, wire.body, "\"mrkdwn\":false") != null);
        try std.testing.expect(std.mem.find(u8, wire.body, "\"link_names\":false") != null);
    }
}

test "Slack external binding removal and every destination mismatch are permanent refusals" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(false);
    var env = environment();
    inline for (@typeInfo(t.Destination).@"struct".field_names) |name| {
        var input = fixture.request;
        @field(input.destination, name).bytes = "wrong-binding";
        try expectRejection(input, &env, "binding");
    }
    env.destination = null;
    try expectRejection(fixture.request, &env, "binding");
    try expectRejection(fixture.request, null, "binding");
    env = environment();
    env.http.account = "other-account";
    try expectRejection(fixture.request, &env, "binding");
    env = environment();
    env.http.origin = "https://evil.test";
    try expectRejection(fixture.request, &env, "binding");
}

test "Slack external authenticates key destination content marker and coverage before I/O" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(false);
    var env = environment();
    for (0..16) |index| {
        var input = fixture.request;
        switch (index) {
            0 => input.key.identity[0] ^= 1,
            1 => input.key.generation += 1,
            2 => input.payload.logical.prior_sequence += 1,
            3 => input.payload.logical.through_sequence += 1,
            4 => input.payload.logical.frozen_text.bytes = "replacement",
            5 => input.payload.marker_digest[0] ^= 1,
            6 => input.payload.content_digest[0] ^= 1,
            7 => input.payload.evidence_digest[0] ^= 1,
            8 => input.payload.logical.coverage.?.epoch += 1,
            9 => input.payload.logical.coverage.?.tip.?[0] = 'c',
            10 => input.payload.logical.obligation.?[0] ^= 1,
            11 => input.payload.wire_json.bytes = "{}",
            12 => input.payload.logical.issue += 1,
            13 => input.payload.logical.comparison.?.base[0] = 'c',
            14 => input.payload.logical.comparison.?.repository.owner.bytes = "other-owner",
            15 => input.payload.renderer_version += 1,
            else => unreachable,
        }
        try expectRejection(input, &env, "payload");
    }
}

test "Slack external refuses changed typed button value without resealing identical text" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(true);
    var changed = [_]t.Button{fixture.request.payload.logical.buttons.items[0]};
    changed[0].value.bytes = "different-operation";
    var input = fixture.request;
    input.payload.logical.buttons.items = &changed;
    try std.testing.expectEqualStrings(
        fixture.request.payload.logical.frozen_text.bytes,
        input.payload.logical.frozen_text.bytes,
    );
    try std.testing.expectEqualStrings(
        fixture.request.payload.wire_json.bytes,
        input.payload.wire_json.bytes,
    );
    var env = environment();
    try expectRejection(input, &env, "payload");
}

test "Slack external refuses resealed wire button that disagrees with immutable logical intent" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(true);
    var intent = preparation.projectIntent(fixture.delivery.?.value);
    var changed = [_]t.Button{intent.payload.buttons.items[0]};
    changed[0].value.bytes = "different-operation";
    intent.payload.buttons.items = &changed;
    var altered = try preparation.materialize(a, intent, producer, evidence_digest, "B1");
    defer altered.deinit();
    var input = fixture.request;
    input.payload = altered.value.payload;
    input.payload.logical = fixture.request.payload.logical;
    try std.testing.expectEqualDeep(fixture.request.payload.logical, input.payload.logical);
    try std.testing.expect(!std.mem.eql(
        u8,
        fixture.request.payload.wire_json.bytes,
        input.payload.wire_json.bytes,
    ));
    var env = environment();
    try expectRejection(input, &env, "payload");
}

test "Slack external total provider interpretation retains reviewed rejection distinctions" {
    const Case = struct {
        body: []const u8,
        status: u16 = 200,
        rejected: bool = false,
        retryable: bool = false,
    };
    const cases = [_]Case{
        .{ .body = "not JSON" },
        .{ .body = "{}" },
        .{ .body = "[]" },
        .{ .body = "{\"ok\":false,\"error\":\"internal_error\"}" },
        .{ .body = "{\"ok\":false,\"error\":\"fatal_error\"}" },
        .{ .body = "{\"ok\":false,\"error\":\"new_provider_error\"}" },
        .{ .body = "{\"ok\":false,\"error\":\"invalid_auth\"}", .status = 503 },
        .{ .body = "{\"ok\":false,\"error\":\"invalid_auth\"}", .rejected = true },
        .{ .body = "{\"ok\":false,\"error\":\"channel_not_found\"}", .rejected = true },
        .{
            .body = "{\"ok\":false,\"error\":\"ratelimited\"}",
            .status = 429,
            .rejected = true,
            .retryable = true,
        },
    };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(false);
    for (cases) |case| {
        const bytes = try capturedResponse(fixture.request, case.body, case.status);
        defer a.free(bytes);
        var result = try interpreted(fixture.request, bytes);
        defer result.deinit();
        if (case.rejected) {
            try std.testing.expectEqual(case.retryable, result.value.rejected.retryable);
            try std.testing.expectEqualStrings("30", result.value.rejected.retry_after.?.bytes);
        } else try std.testing.expect(result.value == .indeterminate);
    }
}

fn confirmedBody(input: contract.Request, metadata: bool, truncated: bool) ![]u8 {
    var wire = try std.json.parseFromSlice(std.json.Value, a, input.payload.wire_json.bytes, .{});
    defer wire.deinit();
    const selected: std.json.Value = if (metadata) wire.value.object.get("metadata").? else .null;
    return std.json.Stringify.valueAlloc(a, .{
        .ok = true,
        .channel = "D1",
        .ts = "1730000000.000001",
        .message = .{
            .metadata = selected,
            .text = "provider rewrite",
        },
        .response_metadata = .{ .warnings = if (truncated)
            @as([]const []const u8, &.{"message_truncated"})
        else
            &.{} },
    }, .{});
}

test "Slack external confirms rewritten response and dropped metadata without resend" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(true);
    for ([_]bool{ false, true }) |metadata| {
        const body = try confirmedBody(fixture.request, metadata, !metadata);
        defer a.free(body);
        const bytes = try capturedResponse(fixture.request, body, 200);
        defer a.free(bytes);
        var result = try interpreted(fixture.request, bytes);
        defer result.deinit();
        try std.testing.expectEqualStrings(
            "1730000000.000001",
            result.value.confirmed.timestamp.bytes,
        );
        try std.testing.expectEqual(metadata, result.value.confirmed.metadata_observed);
        try std.testing.expectEqual(!metadata, result.value.confirmed.rendering_fault);
        var again = try interpreted(fixture.request, bytes);
        defer again.deinit();
        try std.testing.expectEqualDeep(result.value, again.value);
    }
}

test "Slack external raw capture retains body safe headers provenance and no credential" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(false);
    const body = "{\"ok\":false,\"error\":\"invalid_auth\"}";
    const bytes = try capturedResponse(fixture.request, body, 200);
    defer a.free(bytes);
    var captured = try c.decodeOwned(external.Capture, a, bytes);
    defer captured.deinit();
    const evidence = captured.value.response.evidence;
    try std.testing.expectEqualStrings(body, evidence.body.bytes);
    try std.testing.expectEqualStrings("captured-id", evidence.request_id.?.bytes);
    try std.testing.expectEqualStrings("30", evidence.retry_after.?.bytes);
    try std.testing.expectEqual(4, evidence.headers.items.len);
    try std.testing.expectEqual(1234, evidence.captured_ms);
    try std.testing.expectEqual(external.hash(body), evidence.body_digest);
    try std.testing.expectEqualStrings(external.endpoint, evidence.target.bytes);
    try std.testing.expect(std.mem.find(u8, bytes, environment().http.token) == null);
}

test "Slack external rejects capture substitution and body target or request corruption" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init(false);
    const bytes = try capturedResponse(fixture.request, "{}", 200);
    defer a.free(bytes);
    for (0..3) |index| {
        var decoded = try c.decodeOwned(external.Capture, a, bytes);
        defer decoded.deinit();
        switch (index) {
            0 => decoded.value.response.evidence.request_digest[0] ^= 1,
            1 => decoded.value.response.evidence.body_digest[0] ^= 1,
            2 => decoded.value.response.evidence.target.bytes = "https://evil.test",
            else => unreachable,
        }
        const corrupt = try c.encodeOwned(external.Capture, a, decoded.value);
        defer a.free(corrupt);
        try std.testing.expectError(error.InvalidCapture, interpreted(fixture.request, corrupt));
    }
}
