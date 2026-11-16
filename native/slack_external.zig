const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const registry = native.registry;
const t = @import("application_types");
const contract = @import("../app/slack_contract.zig");
const slack = @import("slack.zig");
const transport = @import("http.zig");
const preparation = @import("delivery_prepare.zig");

pub const endpoint = "https://slack.com/api/chat.postMessage";
pub const Environment = struct {
    destination: ?t.Destination,
    bot_id: []const u8,
    http: transport.Config,
};
pub const Capture = union(enum) {
    local_rejection: struct { request_digest: t.Digest, reason: enum { binding, payload } },
    response: struct { bot_id: t.Name, evidence: t.ReadEvidence },
};

pub fn declaration() native.Declaration {
    return .{
        .identity = contract.identity,
        .resource_role = "write",
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

pub const hash = preparation.hash;
pub const keyDigest = preparation.keyDigest;
pub const markerDigest = preparation.markerDigest;

pub fn preparedWire(
    a: std.mem.Allocator,
    request: contract.Request,
    bot_id: []const u8,
) !slack.Prepared {
    return preparation.verify(a, request.destination, request.key, request.payload, bot_id);
}

fn bound(left: t.Destination, right: t.Destination) bool {
    inline for (@typeInfo(t.Destination).@"struct".field_names) |name|
        if (!std.mem.eql(u8, @field(left, name).bytes, @field(right, name).bytes)) return false;
    return true;
}

fn reject(
    a: std.mem.Allocator,
    bytes: []const u8,
    reason: @FieldType(@FieldType(Capture, "local_rejection"), "reason"),
) registry.Acquisition {
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
    if (!std.mem.eql(u8, bytes, canonical))
        return .{ .definitely_not_sent = error.InvalidPrepared };
    const env: *const Environment = @ptrCast(@alignCast(ctx.environment orelse
        return reject(ctx.allocator, bytes, .binding)));
    const destination = env.destination orelse return reject(ctx.allocator, bytes, .binding);
    slack.validateBinding(preparation.binding(destination, env.bot_id)) catch
        return reject(ctx.allocator, bytes, .binding);
    if (!bound(destination, request.value.destination) or
        !std.mem.eql(u8, env.http.account, destination.account.bytes) or
        ctx.authority.revoked or !ctx.authority.disclosure)
        return reject(ctx.allocator, bytes, .binding);
    var wire = preparedWire(ctx.allocator, request.value, env.bot_id) catch |err| {
        if (err == error.OutOfMemory) return .{ .definitely_not_sent = err };
        return reject(ctx.allocator, bytes, .payload);
    };
    defer wire.deinit();
    var http = transport.prepare(ctx.allocator, env.http, .{
        .method = .POST,
        .url = endpoint,
        .body = wire.body,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
            .{ .name = "User-Agent", .value = "paredros/0.0.1" },
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
        .captured => |captured| retain(ctx, bytes, env.bot_id, captured),
    };
}

fn retain(
    ctx: registry.Context,
    bytes: []const u8,
    bot_id: []const u8,
    owned: transport.Capture,
) registry.Acquisition {
    var captured = owned;
    defer captured.deinit();
    const encoded = captureBytes(
        ctx.allocator,
        bytes,
        bot_id,
        captured,
        std.Io.Clock.real.now(ctx.io).toMilliseconds(),
    ) catch |err| return .{ .unknown = err };
    return .{ .captured = encoded };
}

fn projected(comptime T: type, captured: transport.Capture, name: []const u8) ?T {
    const value = (captured.header(name) catch return null) orelse return null;
    if (T.max_length) |limit| if (value.len > limit) return null;
    if (!std.unicode.utf8ValidateSlice(value)) return null;
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return null;
    return .{ .bytes = value };
}

pub fn captureBytes(
    a: std.mem.Allocator,
    request_bytes: []const u8,
    bot_id: []const u8,
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
    return c.encodeOwned(Capture, a, .{ .response = .{
        .bot_id = .{ .bytes = bot_id },
        .evidence = .{
            .request_digest = hash(request_bytes),
            .target = .{ .bytes = endpoint },
            .status = captured.status,
            .identity_encoding = captured.identity_encoding,
            .media_type = projected(t.Name, captured, "content-type"),
            .content_encoding = projected(t.Name, captured, "content-encoding"),
            .headers = .{ .items = headers },
            .body = .{ .bytes = captured.body },
            .body_digest = hash(captured.body),
            .captured_ms = captured_ms,
            .provider_date = projected(t.Timestamp, captured, "date"),
            .request_id = projected(t.Name, captured, "x-slack-req-id"),
            .link = null,
            .etag = null,
            .retry_after = projected(t.Name, captured, "retry-after"),
            .rate_remaining = null,
            .rate_reset = null,
        },
    } });
}

fn responseOutcome(
    a: std.mem.Allocator,
    request: contract.Request,
    captured: @FieldType(Capture, "response"),
) !contract.Reply {
    const evidence = captured.evidence;
    if (!evidence.identity_encoding) return .{ .indeterminate = .{ .bytes = "encoding" } };
    var wire = try preparedWire(a, request, captured.bot_id.bytes);
    defer wire.deinit();
    var result = try slack.interpretDelivery(
        a,
        wire.binding,
        wire.marker,
        .{ .status = evidence.status, .body = evidence.body.bytes },
        2 * 1024 * 1024,
    );
    defer result.deinit();
    return switch (result.outcome) {
        .indeterminate => .{ .indeterminate = .{ .bytes = "provider_indeterminate" } },
        .rejected => |rejected| .{ .rejected = .{
            .code = .{ .bytes = try a.dupe(u8, rejected.reason) },
            .retryable = rejected.retryable,
            .retry_after = evidence.retry_after,
        } },
        .confirmed => |confirmed| .{ .confirmed = .{
            .timestamp = .{ .bytes = try a.dupe(u8, confirmed.timestamp) },
            .metadata_observed = !confirmed.metadata_degraded,
            .rendering_fault = confirmed.rendering_fault,
        } },
    };
}

pub fn interpret(
    ctx: registry.ProjectionContext,
    request_bytes: []const u8,
    prepared_bytes: []const u8,
    captured_bytes: []const u8,
) !registry.Projection {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = try prepare(ctx, request_bytes);
    defer ctx.allocator.free(expected);
    if (!std.mem.eql(u8, expected, prepared_bytes)) return error.InvalidPrepared;
    const request = try c.decodeOwned(contract.Request, a, expected);
    const captured = try c.decodeOwned(Capture, a, captured_bytes);
    const reply: contract.Reply = switch (captured.value) {
        .local_rejection => |rejected| blk: {
            if (!std.meta.eql(rejected.request_digest, hash(expected))) return error.InvalidCapture;
            break :blk .{ .rejected = .{ .code = .{ .bytes = @tagName(rejected.reason) } } };
        },
        .response => |response| blk: {
            const evidence = response.evidence;
            if (!std.meta.eql(evidence.request_digest, hash(expected)) or
                !std.meta.eql(evidence.body_digest, hash(evidence.body.bytes)) or
                !std.mem.eql(u8, evidence.target.bytes, endpoint)) return error.InvalidCapture;
            break :blk try responseOutcome(a, request.value, response);
        },
    };
    return .{ .reply = try c.encodeOwned(contract.Reply, ctx.allocator, reply) };
}
