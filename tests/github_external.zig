const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const contract = @import("../app/github_contract.zig");
const adapter = @import("../native/github_adapter.zig");
const external = @import("../native/github_external.zig");
const http = @import("../native/http.zig");
const fixture = @import("contracts.zig");

const authority: native.registry.Authority = .{
    .principal = "test",
    .tenant = "test",
    .grants = &.{},
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

fn projection(a: std.mem.Allocator) native.registry.ProjectionContext {
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
        .repository = fixture.specification().repository,
        .http = .{
            .account = "github-test",
            .origin = "https://api.github.com",
            .token = "secret-never-retained",
        },
    };
}

fn context(a: std.mem.Allocator, env: ?*external.Environment) native.Context {
    return .{
        .allocator = a,
        .io = .failing,
        .authority = &authority,
        .task_id = "test",
        .profile = "test",
        .environment = env,
    };
}

fn request() contract.Request {
    return .{
        .repository = fixture.specification().repository,
        .phase = .{ .repository_before = {} },
    };
}

fn expectRejected(
    a: std.mem.Allocator,
    input: contract.Request,
    env: ?*external.Environment,
) !void {
    const bytes = try c.encodeOwned(contract.Request, a, input);
    defer a.free(bytes);
    const captured = try external.declaration().capture.?.acquire(context(a, env), bytes);
    try std.testing.expect(captured == .captured);
    defer a.free(captured.captured);
    var decoded = try c.decodeOwned(external.Capture, a, captured.captured);
    defer decoded.deinit();
    try std.testing.expect(decoded.value == .local_rejection);
    try std.testing.expectEqual(contract.Failure.binding, decoded.value.local_rejection.reason);
    const interpreted = try external.interpret(projection(a), bytes, bytes, captured.captured);
    defer a.free(interpreted.reply);
    var reply = try c.decodeOwned(contract.Reply, a, interpreted.reply);
    defer reply.deinit();
    try std.testing.expectEqual(contract.Failure.binding, reply.value.rejected.reason);
    try std.testing.expectEqual(null, reply.value.rejected.evidence);
    try std.testing.expect(std.mem.find(u8, captured.captured, "secret-never-retained") == null);
}

test "GitHub external declaration freezes canonical contract request and schemas" {
    const a = std.testing.allocator;
    const declared = external.declaration();
    try std.testing.expectEqualStrings(contract.identity, declared.identity);
    try std.testing.expectEqualStrings("read", declared.resource_role);
    try std.testing.expect(declared.invoke == null and declared.capture != null);
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    const prepared = try declared.capture.?.prepare(projection(a), bytes);
    defer a.free(prepared);
    try std.testing.expectEqualSlices(u8, bytes, prepared);
    const payload = try declared.payload_schema(a);
    defer a.free(payload);
    const reply = try declared.resume_schema(a);
    defer a.free(reply);
    try std.testing.expect(payload.len > 0 and reply.len > 0);
    const dependencies = try declared.capture.?.dependencies(a, &.{});
    try std.testing.expectEqual(0, dependencies.len);
}

test "GitHub external binding admits an amended route but rejects identity account and ref" {
    const a = std.testing.allocator;
    var env = environment();
    var routed = request();
    routed.repository.owner.bytes = "renamed-owner";
    routed.repository.name.bytes = "renamed-name";
    const bytes = try c.encodeOwned(contract.Request, a, routed);
    defer a.free(bytes);
    const acquired = try external.declaration().capture.?.acquire(context(a, &env), bytes);
    try std.testing.expect(acquired == .definitely_not_sent);
    for (0..3) |changed| {
        var input = request();
        switch (changed) {
            0 => input.repository.id += 1,
            1 => input.repository.account.bytes = "other-account",
            2 => input.repository.ref.bytes = "refs/heads/other",
            else => unreachable,
        }
        try expectRejected(a, input, &env);
    }
    env.http.account = "different-credential-binding";
    try expectRejected(a, request(), &env);
    env = environment();
    env.http.origin = "https://evil.test";
    try expectRejected(a, request(), &env);
    try expectRejected(a, request(), null);
}

fn capturedRepository(a: std.mem.Allocator, input: contract.Request, body: []const u8) ![]u8 {
    var prepared = try adapter.prepare(a, input);
    defer prepared.deinit();
    const head = try std.http.Client.Response.Head.parse("HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\nDate: Sun, 15 Nov 2026 00:00:00 GMT\r\n" ++
        "X-GitHub-Request-Id: capture-id\r\nX-RateLimit-Limit: 5000\r\n" ++
        "X-RateLimit-Remaining: 4999\r\nX-RateLimit-Reset: 1800000000\r\n" ++
        "X-RateLimit-Used: 1\r\nX-RateLimit-Resource: core\r\nETag: \"version\"\r\n\r\n");
    var reader = std.Io.Reader.fixed(body);
    var captured = try http.captureResponse(a, head, &reader, .{}, environment().http.token);
    defer captured.deinit();
    return external.captureBytes(a, prepared, captured, 1234);
}

test "GitHub external interpretation preserves capture metadata and contract digest" {
    const a = std.testing.allocator;
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    const captured = try capturedRepository(a, request(), "{\"id\":123}");
    defer a.free(captured);
    const result = try external.interpret(projection(a), bytes, bytes, captured);
    defer a.free(result.reply);
    var decoded = try c.decodeOwned(contract.Reply, a, result.reply);
    defer decoded.deinit();
    try std.testing.expect(decoded.value == .repository);
    const evidence = decoded.value.repository;
    try std.testing.expectEqualStrings("{\"id\":123}", evidence.body.bytes);
    try std.testing.expectEqual(1234, evidence.captured_ms);
    try std.testing.expectEqual(9, evidence.headers.items.len);
    try std.testing.expectEqualStrings("capture-id", evidence.request_id.?.bytes);
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqual(digest, evidence.request_digest);
    const replay = try external.interpret(projection(a), bytes, bytes, captured);
    defer a.free(replay.reply);
    try std.testing.expectEqualSlices(u8, result.reply, replay.reply);
}

test "GitHub external malformed provider body produces retained typed rejection" {
    const a = std.testing.allocator;
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    const captured = try capturedRepository(a, request(), "not-json");
    defer a.free(captured);
    const result = try external.interpret(projection(a), bytes, bytes, captured);
    defer a.free(result.reply);
    var decoded = try c.decodeOwned(contract.Reply, a, result.reply);
    defer decoded.deinit();
    try std.testing.expect(decoded.value == .rejected);
    try std.testing.expectEqualStrings("not-json", decoded.value.rejected.evidence.?.body.bytes);
}

test "GitHub external refuses unrelated prepared bytes and local rejection provenance" {
    const a = std.testing.allocator;
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    var other = request();
    other.phase = .{ .repository_after = {} };
    const unrelated = try c.encodeOwned(contract.Request, a, other);
    defer a.free(unrelated);
    var env = environment();
    env.repository.id += 1;
    const captured = try external.acquire(context(a, &env), bytes);
    defer a.free(captured.captured);
    try std.testing.expectError(
        error.InvalidPrepared,
        external.interpret(projection(a), bytes, unrelated, captured.captured),
    );
    try std.testing.expectError(
        error.InvalidCapture,
        external.interpret(projection(a), unrelated, unrelated, captured.captured),
    );
}

test "GitHub external cancellation and unavailable concurrency remain definitely unsent" {
    const a = std.testing.allocator;
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    var env = environment();
    var cancelled: std.atomic.Value(bool) = .init(true);
    var ctx = context(a, &env);
    ctx.cancellation = &cancelled;
    const stopped = try external.acquire(ctx, bytes);
    try std.testing.expectEqual(error.Canceled, stopped.definitely_not_sent);
    ctx.cancellation = null;
    const unavailable = try external.acquire(ctx, bytes);
    try std.testing.expect(unavailable == .definitely_not_sent);
}

fn allocationProbe(a: std.mem.Allocator) !void {
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    const captured = try capturedRepository(a, request(), "{\"id\":123}");
    defer a.free(captured);
    const result = try external.interpret(projection(a), bytes, bytes, captured);
    defer a.free(result.reply);
}

test "GitHub external capture and projection release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "GitHub external preserves oversized raw header while rejecting its projection" {
    const a = std.testing.allocator;
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    const identifier: [200]u8 = @splat('r');
    const head_bytes = try std.fmt.allocPrint(
        a,
        "HTTP/1.1 200 OK\r\nX-GitHub-Request-Id: {s}\r\n\r\n",
        .{identifier},
    );
    defer a.free(head_bytes);
    const head = try std.http.Client.Response.Head.parse(head_bytes);
    var reader = std.Io.Reader.fixed("{\"id\":123}");
    var captured = try http.captureResponse(a, head, &reader, .{}, environment().http.token);
    defer captured.deinit();
    var prepared = try adapter.prepare(a, request());
    defer prepared.deinit();
    const saved = try external.captureBytes(a, prepared, captured, 20);
    defer a.free(saved);
    const result = try external.interpret(projection(a), bytes, bytes, saved);
    defer a.free(result.reply);
    var reply = try c.decodeOwned(contract.Reply, a, result.reply);
    defer reply.deinit();
    try std.testing.expectEqual(contract.Failure.malformed, reply.value.rejected.reason);
    const retained = reply.value.rejected.evidence.?;
    try std.testing.expectEqual(null, retained.request_id);
    try std.testing.expectEqualSlices(u8, &identifier, retained.headers.items[0].value.bytes);
}

test "GitHub external received refusal interprets as a typed rejection without evidence" {
    const a = std.testing.allocator;
    const bytes = try c.encodeOwned(contract.Request, a, request());
    defer a.free(bytes);
    var prepared = try adapter.prepare(a, request());
    defer prepared.deinit();
    const Case = struct { refusal: http.Refusal, reason: contract.Failure };
    for ([_]Case{
        .{ .refusal = .body_capacity, .reason = .malformed },
        .{ .refusal = .body_interrupted, .reason = .unavailable },
        .{ .refusal = .unrepresentable, .reason = .malformed },
    }) |case| {
        const captured = try c.encodeOwned(external.Capture, a, .{ .refused = .{
            .request_digest = prepared.request_digest,
            .refused = .{ .status = 200, .refusal = case.refusal },
        } });
        defer a.free(captured);
        const result = try external.interpret(projection(a), bytes, bytes, captured);
        defer a.free(result.reply);
        var reply = try c.decodeOwned(contract.Reply, a, result.reply);
        defer reply.deinit();
        try std.testing.expectEqual(case.reason, reply.value.rejected.reason);
        try std.testing.expectEqual(null, reply.value.rejected.evidence);
    }
}
