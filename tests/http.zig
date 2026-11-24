const std = @import("std");
const http = @import("../native/http.zig");

fn config() http.Config {
    return .{
        .account = "github-test",
        .origin = "https://api.github.com",
        .token = "secret-never-retained",
    };
}

fn request() http.Request {
    return .{
        .method = .GET,
        .url = "https://api.github.com/repos/o/r",
        .headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
    };
}

fn response(bytes: []const u8) !std.http.Client.Response.Head {
    return std.http.Client.Response.Head.parse(bytes);
}

test "HTTP preparation freezes request bytes and excludes credential from identity" {
    const a = std.testing.allocator;
    var body = [_]u8{ '{', '}' };
    var original = request();
    original.method = .POST;
    original.body = &body;
    var one = try http.prepare(a, config(), original);
    defer one.deinit();
    var refreshed = config();
    refreshed.token = "rotated-secret-never-retained";
    var two = try http.prepare(a, refreshed, original);
    defer two.deinit();
    try std.testing.expectEqual(one.identity, two.identity);
    body[0] = '[';
    try std.testing.expectEqualStrings("{}", one.request.body);
    try std.testing.expectEqualStrings("accept", one.request.headers[0].name);
    original.url = "https://api.github.com/repos/other/repo";
    var changed = try http.prepare(a, refreshed, original);
    defer changed.deinit();
    try std.testing.expect(!std.meta.eql(one.identity, changed.identity));
}

test "HTTP identity normalizes header name case and order but binds credential account" {
    const a = std.testing.allocator;
    var one_request = request();
    one_request.headers = &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2026-03-10" },
    };
    var two_request = one_request;
    two_request.headers = &.{
        .{ .name = "x-github-api-version", .value = "2026-03-10" },
        .{ .name = "accept", .value = "application/json" },
    };
    var one = try http.prepare(a, config(), one_request);
    defer one.deinit();
    var two = try http.prepare(a, config(), two_request);
    defer two.deinit();
    try std.testing.expectEqual(one.identity, two.identity);
    var rebound = config();
    rebound.account = "another-account";
    var other = try http.prepare(a, rebound, one_request);
    defer other.deinit();
    try std.testing.expect(!std.meta.eql(one.identity, other.identity));
}

test "HTTP rejects cross origin userinfo fragment unsafe host and token newlines" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "http://api.github.com/x",    "https://user@api.github.com/x",
        "https://api.github.com/x#y", "https://api.github.com\\@evil.test/x",
        "https://%61pi.github.com/x", "https://[::1]/x",
        "https://api.github.com:0/x",
    }) |url| {
        var input = request();
        input.url = url;
        try std.testing.expectError(error.InvalidEndpoint, http.prepare(a, config(), input));
    }
    for ([_][]const u8{ "https://evil.test/x", "https://api.github.com:444/x" }) |url| {
        var input = request();
        input.url = url;
        try std.testing.expectError(error.CrossOrigin, http.prepare(a, config(), input));
    }
    var unsafe = config();
    unsafe.token = "credential\r\nInjected: value";
    try std.testing.expectError(error.InvalidConfiguration, http.prepare(a, unsafe, request()));
}

test "HTTP validates header allowlist injection duplicate values and configured limits" {
    const a = std.testing.allocator;
    var input = request();
    input.headers = &.{.{ .name = "Authorization", .value = "Bearer copied" }};
    try std.testing.expectError(error.UnsafeRequestHeader, http.prepare(a, config(), input));
    input.headers = &.{.{ .name = "Accept", .value = "application/json\nx: y" }};
    try std.testing.expectError(error.InvalidConfiguration, http.prepare(a, config(), input));
    input.headers = &.{ .{ .name = "accept", .value = "a" }, .{ .name = "Accept", .value = "b" } };
    try std.testing.expectError(error.DuplicateRequestHeader, http.prepare(a, config(), input));
    input = request();
    input.body = "x";
    try std.testing.expectError(error.UnexpectedRequestBody, http.prepare(a, config(), input));
    input.method = .POST;
    var bounded = config();
    bounded.limits.request_body_bytes_max = 1;
    input.body = "xx";
    try std.testing.expectError(error.RequestBodyCapacity, http.prepare(a, bounded, input));
    bounded = config();
    bounded.limits.request_header_bytes_max = 1;
    try std.testing.expectError(error.RequestHeaderCapacity, http.prepare(a, bounded, request()));
    bounded = config();
    bounded.limits.timeout_ms = 0;
    try std.testing.expectError(error.InvalidConfiguration, http.prepare(a, bounded, request()));
}

test "HTTP captures raw body selected metadata and preserves redirects without following" {
    const head = try response("HTTP/1.1 302 Found\r\nContent-Length: 4\r\n" ++
        "Date: Sun, 15 Nov 2026 00:00:00 GMT\r\nRetry-After: 60\r\n" ++
        "X-RateLimit-Remaining: 0\r\nLink: <https://evil.test/>; rel=next\r\n" ++
        "ETag: W/\"a\"\r\nX-GitHub-Request-Id: github-id\r\n" ++
        "X-Vendor-Req-Id: vendor-id\r\nContent-Type: application/json\r\n" ++
        "Authorization: Bearer must-not-retain\r\nSet-Cookie: secret=value\r\n\r\n");
    var reader = std.Io.Reader.fixed("test");
    var captured = try http.captureResponse(
        std.testing.allocator,
        head,
        &reader,
        .{},
        config().token,
    );
    defer captured.deinit();
    try std.testing.expectEqual(302, captured.status);
    try std.testing.expectEqualStrings("test", captured.body);
    try std.testing.expectEqualStrings("60", (try captured.header("retry-after")).?);
    try std.testing.expectEqualStrings("0", (try captured.header("x-ratelimit-remaining")).?);
    try std.testing.expectEqualStrings("github-id", (try captured.header("x-github-request-id")).?);
    try std.testing.expectEqual(null, try captured.header("x-vendor-req-id"));
    try std.testing.expectEqual(null, try captured.header("authorization"));
    try std.testing.expectEqual(null, try captured.header("set-cookie"));
    try std.testing.expect(captured.identity_encoding);
}

test "HTTP retains duplicate metadata without silently choosing an authoritative value" {
    const head = try response("HTTP/1.1 200 OK\r\nRetry-After: 1\r\nretry-after: 2\r\n\r\n");
    var reader = std.Io.Reader.fixed("");
    var captured = try http.captureResponse(
        std.testing.allocator,
        head,
        &reader,
        .{},
        config().token,
    );
    defer captured.deinit();
    try std.testing.expectEqual(2, captured.headers.len);
    try std.testing.expectError(error.DuplicateResponseHeader, captured.header("retry-after"));
}

test "HTTP rejects oversized declared streamed and truncated response bodies" {
    const a = std.testing.allocator;
    const head = try response("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n");
    var reader = std.Io.Reader.fixed("test");
    try std.testing.expectError(
        error.ResponseBodyCapacity,
        http.captureResponse(a, head, &reader, .{ .response_body_bytes_max = 3 }, config().token),
    );
    const streamed = try response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    reader = .fixed("test");
    try std.testing.expectError(
        error.ResponseBodyCapacity,
        http.captureResponse(
            a,
            streamed,
            &reader,
            .{ .response_body_bytes_max = 3 },
            config().token,
        ),
    );
    reader = .fixed("bad");
    try std.testing.expectError(
        error.TruncatedResponse,
        http.captureResponse(a, head, &reader, .{}, config().token),
    );
    reader = .fixed("test");
    try std.testing.expectError(
        error.ResponseHeaderCapacity,
        http.captureResponse(a, head, &reader, .{ .response_header_bytes_max = 3 }, config().token),
    );
}

test "HTTP credential echo in body or retained header is rejected without a false capture" {
    const a = std.testing.allocator;
    const plain = try response("HTTP/1.1 200 OK\r\n\r\n");
    var reader = std.Io.Reader.fixed(config().token);
    try std.testing.expectError(
        error.CredentialDisclosure,
        http.captureResponse(a, plain, &reader, .{}, config().token),
    );
    const echoed = try response("HTTP/1.1 200 OK\r\nX-Request-Id: secret-never-retained\r\n\r\n");
    reader = .fixed("ok");
    try std.testing.expectError(
        error.CredentialDisclosure,
        http.captureResponse(a, echoed, &reader, .{}, config().token),
    );
    var input = request();
    input.method = .POST;
    input.body = config().token;
    try std.testing.expectError(error.CredentialDisclosure, http.prepare(a, config(), input));
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var prepared = try http.prepare(a, config(), request());
    defer prepared.deinit();
    const head = try response("HTTP/1.1 200 OK\r\nDate: today\r\nContent-Length: 2\r\n\r\n");
    var reader = std.Io.Reader.fixed("{}");
    var captured = try http.captureResponse(a, head, &reader, .{}, config().token);
    defer captured.deinit();
    try std.testing.expectEqualStrings("{}", captured.body);
}

test "HTTP preparation and capture release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "HTTP execution refuses mutated request or configuration before any network activity" {
    var prepared = try http.prepare(std.testing.allocator, config(), request());
    defer prepared.deinit();
    prepared.request.url = "https://api.github.com/changed";
    const changed = http.execute(std.testing.allocator, std.testing.io, config(), &prepared);
    try std.testing.expectEqual(error.RequestChanged, changed.definitely_not_sent);
    var invalid = config();
    invalid.origin = "http://api.github.com";
    const rejected = http.execute(std.testing.allocator, std.testing.io, invalid, &prepared);
    try std.testing.expectEqual(error.InvalidEndpoint, rejected.definitely_not_sent);
}

test "HTTP 304 representation length is metadata and not an expected response body" {
    const head = try response("HTTP/1.1 304 Not Modified\r\n" ++
        "Content-Length: 9000000\r\nETag: \"same-representation\"\r\n\r\n");
    var reader = std.Io.Reader.fixed("");
    var captured = try http.captureResponse(
        std.testing.allocator,
        head,
        &reader,
        .{ .response_body_bytes_max = 10 },
        config().token,
    );
    defer captured.deinit();
    try std.testing.expectEqual(304, captured.status);
    try std.testing.expectEqual(0, captured.body.len);
    try std.testing.expectEqualStrings("9000000", (try captured.header("content-length")).?);
}

test "HTTP broken response reader is an error and not an empty success" {
    const head = try response("HTTP/1.1 200 OK\r\n\r\n");
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.ReadFailed, http.captureResponse(
        std.testing.allocator,
        head,
        &reader,
        .{},
        config().token,
    ));
}

test "HTTP unavailable concurrency is definitely unsent through offline failing I/O" {
    var prepared = try http.prepare(std.testing.allocator, config(), request());
    defer prepared.deinit();
    const outcome = http.execute(std.testing.allocator, .failing, config(), &prepared);
    try std.testing.expect(outcome == .definitely_not_sent);
}
