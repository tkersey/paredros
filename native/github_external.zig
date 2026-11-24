const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const registry = native.registry;
const t = @import("application_types");
const contract = @import("../app/github_contract.zig");
const adapter = @import("github_adapter.zig");
const transport = @import("http.zig");

pub const Environment = struct { repository: t.Repository, http: transport.Config };
pub const Capture = union(enum) {
    local_rejection: struct { request_digest: t.Digest, reason: contract.Failure },
    response: t.ReadEvidence,
};

pub fn declaration() native.Declaration {
    return .{
        .identity = contract.identity,
        .resource_role = "read",
        .kind = .leaf,
        .background = true,
        .payload_schema = requestSchema,
        .resume_schema = replySchema,
        .capture = .{
            .dependencies = registry.opaqueProjection,
            .prepare = prepare,
            .acquire = acquire,
            .interpret = interpret,
        },
    };
}

fn requestSchema(a: std.mem.Allocator) ![]u8 {
    return native.values.schemaBytes(contract.Request, a);
}

fn replySchema(a: std.mem.Allocator) ![]u8 {
    return native.values.schemaBytes(contract.Reply, a);
}

pub fn prepare(ctx: registry.ProjectionContext, bytes: []const u8) ![]u8 {
    var request = try c.decodeOwned(contract.Request, ctx.allocator, bytes);
    defer request.deinit();
    return c.encodeOwned(contract.Request, ctx.allocator, request.value);
}

fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn bound(configured: t.Repository, requested: t.Repository) bool {
    return configured.id == requested.id and
        std.mem.eql(u8, configured.account.bytes, requested.account.bytes) and
        std.mem.eql(u8, configured.ref.bytes, requested.ref.bytes);
}

fn reject(a: std.mem.Allocator, bytes: []const u8, reason: contract.Failure) registry.Acquisition {
    const captured = c.encodeOwned(Capture, a, .{ .local_rejection = .{
        .request_digest = hash(bytes),
        .reason = reason,
    } }) catch |err| return .{ .definitely_not_sent = err };
    return .{ .captured = captured };
}

pub fn acquire(ctx: registry.Context, bytes: []const u8) !registry.Acquisition {
    ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
    var request = c.decodeOwned(contract.Request, ctx.allocator, bytes) catch |err|
        return .{ .definitely_not_sent = err };
    defer request.deinit();
    const canonical = c.encodeOwned(contract.Request, ctx.allocator, request.value) catch |err|
        return .{ .definitely_not_sent = err };
    defer ctx.allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return .{
        .definitely_not_sent = error.InvalidPrepared,
    };
    const env: *const Environment = @ptrCast(@alignCast(ctx.environment orelse
        return reject(ctx.allocator, bytes, .binding)));
    if (!bound(env.repository, request.value.repository) or
        !std.mem.eql(u8, env.http.account, env.repository.account.bytes) or
        ctx.authority.revoked or !ctx.authority.disclosure)
        return reject(ctx.allocator, bytes, .binding);
    var prepared = adapter.prepare(ctx.allocator, request.value) catch |err| {
        if (err == error.OutOfMemory) return .{ .definitely_not_sent = err };
        return reject(ctx.allocator, bytes, switch (err) {
            error.InvalidRef,
            error.InvalidRepositoryRoute,
            error.InvalidAccount,
            error.RepositoryIdentityMismatch,
            error.UnsafePagination,
            => .binding,
            else => .malformed,
        });
    };
    defer prepared.deinit();
    var http = transport.prepare(ctx.allocator, env.http, .{
        .method = .GET,
        .url = prepared.url,
        .headers = &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "User-Agent", .value = "paredros/0.0.1" },
            .{ .name = "X-GitHub-Api-Version", .value = "2026-03-10" },
        },
    }) catch |err| {
        if (err == error.OutOfMemory) return .{ .definitely_not_sent = err };
        return reject(ctx.allocator, bytes, .binding);
    };
    defer http.deinit();
    ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
    return switch (transport.execute(ctx.allocator, ctx.io, env.http, &http)) {
        .definitely_not_sent => |err| .{ .definitely_not_sent = err },
        .unknown => |err| .{ .unknown = err },
        .captured => |captured| capture(ctx, prepared, captured),
    };
}

fn projected(comptime T: type, captured: transport.Capture, name: []const u8) ?T {
    const value = (captured.header(name) catch return null) orelse return null;
    if (T.max_length) |limit| if (value.len > limit) return null;
    if (!std.unicode.utf8ValidateSlice(value)) return null;
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return null;
    return .{ .bytes = value };
}

fn capture(
    ctx: registry.Context,
    request: adapter.Prepared,
    owned: transport.Capture,
) registry.Acquisition {
    var captured = owned;
    defer captured.deinit();
    const captured_ms = std.Io.Clock.real.now(ctx.io).toMilliseconds();
    const bytes = captureBytes(ctx.allocator, request, captured, captured_ms) catch |err|
        return .{ .unknown = err };
    return .{ .captured = bytes };
}

pub fn captureBytes(
    a: std.mem.Allocator,
    request: adapter.Prepared,
    captured: transport.Capture,
    captured_ms: i64,
) ![]u8 {
    const Header = @FieldType(t.ReadEvidence, "headers").Child;
    const headers = try a.alloc(Header, captured.headers.len);
    defer a.free(headers);
    for (headers, captured.headers) |*dest, source| dest.* = .{
        .name = .{ .bytes = source.name },
        .value = .{ .bytes = source.value },
    };
    const github_id = captured.header("x-github-request-id") catch null;
    return c.encodeOwned(Capture, a, .{ .response = .{
        .request_digest = request.request_digest,
        .target = .{ .bytes = request.url },
        .status = captured.status,
        .identity_encoding = captured.identity_encoding,
        .media_type = projected(t.Name, captured, "content-type"),
        .content_encoding = projected(t.Name, captured, "content-encoding"),
        .headers = .{ .items = headers },
        .body = .{ .bytes = captured.body },
        .body_digest = hash(captured.body),
        .captured_ms = captured_ms,
        .provider_date = projected(t.Timestamp, captured, "date"),
        .request_id = projected(t.Name, captured, if (github_id != null)
            "x-github-request-id"
        else
            "x-request-id"),
        .link = projected(c.Utf8, captured, "link"),
        .etag = projected(c.Utf8, captured, "etag"),
        .retry_after = projected(t.Name, captured, "retry-after"),
        .rate_remaining = projected(t.Name, captured, "x-ratelimit-remaining"),
        .rate_reset = projected(t.Name, captured, "x-ratelimit-reset"),
    } });
}

pub fn interpret(
    ctx: registry.ProjectionContext,
    request_bytes: []const u8,
    prepared_bytes: []const u8,
    captured_bytes: []const u8,
) !registry.Projection {
    const expected = try prepare(ctx, request_bytes);
    defer ctx.allocator.free(expected);
    if (!std.mem.eql(u8, expected, prepared_bytes)) return error.InvalidPrepared;
    var request = try c.decodeOwned(contract.Request, ctx.allocator, expected);
    defer request.deinit();
    var captured = try c.decodeOwned(Capture, ctx.allocator, captured_bytes);
    defer captured.deinit();
    switch (captured.value) {
        .local_rejection => |rejected| {
            if (!std.meta.eql(rejected.request_digest, hash(expected))) return error.InvalidCapture;
            return .{ .reply = try c.encodeOwned(contract.Reply, ctx.allocator, .{
                .rejected = .{ .reason = rejected.reason, .evidence = null },
            }) };
        },
        .response => |evidence| {
            var reply = try adapter.interpret(ctx.allocator, request.value, evidence);
            defer reply.deinit();
            return .{ .reply = try c.encodeOwned(contract.Reply, ctx.allocator, reply.value) };
        },
    }
}
