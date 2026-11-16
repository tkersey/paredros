const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const registry = native.registry;
const t = @import("application_types");
const contract = @import("../app/audit_contract.zig");
const slack = @import("slack.zig");
const transport = @import("http.zig");
const preparation = @import("delivery_prepare.zig");
const notification = @import("slack_external.zig");

pub const endpoint = "https://slack.com/api/conversations.history";
pub const Environment = notification.Environment;
pub const Capture = union(enum) {
    rejected: struct { request_digest: t.Digest, reason: t.Name },
    response: contract.CapturedPage,
};
const page_bytes_max = 2 * 1024 * 1024;

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
    var decoded = try c.decodeOwned(contract.Request, ctx.allocator, bytes);
    defer decoded.deinit();
    return c.encodeOwned(contract.Request, ctx.allocator, decoded.value);
}

fn sameDestination(left: t.Destination, right: t.Destination) bool {
    inline for (@typeInfo(t.Destination).@"struct".field_names) |name|
        if (!std.mem.eql(u8, @field(left, name).bytes, @field(right, name).bytes)) return false;
    return true;
}

fn initial(a: std.mem.Allocator, audit: t.Audit, bot: []const u8) !slack.HistoryAudit {
    if (audit.page_limit == 0) return error.InvalidAudit;
    try preparation.verifyStored(a, audit.delivery);
    var expected = try preparation.verify(
        a,
        audit.delivery.destination,
        audit.delivery.key,
        audit.delivery.payload,
        bot,
    );
    defer expected.deinit();
    var canary_wire: ?slack.Prepared = null;
    defer if (canary_wire) |*wire| wire.deinit();
    var canary: ?slack.Canary = null;
    if (audit.canary) |saved| {
        try preparation.verifyStored(a, saved.admitted);
        if (!sameDestination(saved.receipt.destination, audit.delivery.destination) or
            !sameDestination(saved.admitted.destination, audit.delivery.destination) or
            !std.meta.eql(saved.receipt.key, saved.admitted.key) or
            !std.meta.eql(saved.receipt.payload_digest, saved.admitted.payload.content_digest) or
            !std.mem.eql(u8, audit.oldest.bytes, saved.receipt.timestamp.bytes))
            return error.InvalidCanary;
        canary_wire = try preparation.verify(
            a,
            saved.admitted.destination,
            saved.admitted.key,
            saved.admitted.payload,
            bot,
        );
        canary = .{ .timestamp = saved.receipt.timestamp.bytes, .marker = canary_wire.?.marker };
    }
    return slack.HistoryAudit.init(
        a,
        expected.binding,
        expected.marker,
        audit.oldest.bytes,
        if (audit.latest) |latest| latest.bytes else null,
        canary,
        .{
            .pages = audit.page_limit,
            .messages = try std.math.mul(usize, audit.page_limit, 100),
            .page_bytes = page_bytes_max,
        },
    );
}

fn escape(a: std.mem.Allocator, value: []const u8) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(a);
    const alphabet = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') {
            try encoded.append(a, byte);
        } else try encoded.appendSlice(a, &.{ '%', alphabet[byte >> 4], alphabet[byte & 15] });
    }
    return encoded.toOwnedSlice(a);
}

fn target(a: std.mem.Allocator, request: slack.HistoryRequest) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const upper = if (request.latest) |latest|
        try std.fmt.allocPrint(scratch, "&latest={s}", .{try escape(scratch, latest)})
    else
        "";
    return std.fmt.allocPrint(a, endpoint ++
        "?team_id={s}&channel={s}&oldest={s}{s}&cursor={s}" ++
        "&inclusive=true&include_all_metadata=true&limit=100", .{
        try escape(scratch, request.team_id), try escape(scratch, request.channel),
        try escape(scratch, request.oldest),  upper,
        try escape(scratch, request.cursor),
    });
}

fn ingest(
    a: std.mem.Allocator,
    history: *slack.HistoryAudit,
    request: contract.Request,
    page: contract.CapturedPage,
) !void {
    if (!std.mem.eql(u8, history.binding.bot_id, page.bot_id.bytes))
        return error.InvalidCapture;
    const bytes = try c.encodeOwned(contract.Request, a, request);
    defer a.free(bytes);
    const url = try target(a, history.request());
    defer a.free(url);
    const evidence = page.evidence;
    if (!std.meta.eql(evidence.request_digest, preparation.hash(bytes)) or
        !std.meta.eql(evidence.body_digest, preparation.hash(evidence.body.bytes)) or
        !std.mem.eql(u8, evidence.target.bytes, url)) return error.InvalidCapture;
    if (!evidence.identity_encoding) {
        history.reason = .malformed;
        return;
    }
    try history.ingest(history.request(), .{
        .status = evidence.status,
        .body = evidence.body.bytes,
    });
}

fn replay(a: std.mem.Allocator, request: contract.Request, bot: []const u8) !slack.HistoryAudit {
    if (request.pages.items.len >= request.audit.page_limit) return error.InvalidAudit;
    var history = try initial(a, request.audit, bot);
    errdefer history.deinit();
    for (request.pages.items, 0..) |page, index| {
        if (history.complete or history.reason != null) return error.InvalidAudit;
        var prefix = request;
        prefix.pages.items = request.pages.items[0..index];
        try ingest(a, &history, prefix, page);
    }
    if (history.complete or history.reason != null) return error.InvalidAudit;
    return history;
}

pub fn requestTarget(a: std.mem.Allocator, request: contract.Request, bot: []const u8) ![]u8 {
    var history = try replay(a, request, bot);
    defer history.deinit();
    return target(a, history.request());
}

fn reject(a: std.mem.Allocator, bytes: []const u8, reason: []const u8) registry.Acquisition {
    const encoded = c.encodeOwned(Capture, a, .{ .rejected = .{
        .request_digest = preparation.hash(bytes),
        .reason = .{ .bytes = reason },
    } }) catch |err| return .{ .definitely_not_sent = err };
    return .{ .captured = encoded };
}

pub fn acquire(ctx: registry.Context, bytes: []const u8) !registry.Acquisition {
    ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
    var request = try c.decodeOwned(contract.Request, ctx.allocator, bytes);
    defer request.deinit();
    const env: *const Environment = @ptrCast(@alignCast(ctx.environment orelse
        return reject(ctx.allocator, bytes, "binding")));
    const destination = env.destination orelse return reject(ctx.allocator, bytes, "binding");
    if (!sameDestination(destination, request.value.audit.delivery.destination) or
        !std.mem.eql(u8, env.http.account, destination.account.bytes) or
        !std.mem.eql(u8, env.http.origin, "https://slack.com") or
        ctx.authority.revoked or !ctx.authority.disclosure)
        return reject(ctx.allocator, bytes, "binding");
    const url = requestTarget(ctx.allocator, request.value, env.bot_id) catch |err| {
        if (err == error.OutOfMemory) return .{ .definitely_not_sent = err };
        return reject(ctx.allocator, bytes, "invalid_audit");
    };
    defer ctx.allocator.free(url);
    var http = transport.prepare(ctx.allocator, env.http, .{
        .method = .GET,
        .url = url,
        .headers = &.{.{ .name = "User-Agent", .value = "paredros/0.0.1" }},
    }) catch |err| {
        if (err == error.OutOfMemory) return .{ .definitely_not_sent = err };
        return reject(ctx.allocator, bytes, "binding");
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
    bot: []const u8,
    owned: transport.Capture,
) registry.Acquisition {
    var captured = owned;
    defer captured.deinit();
    const encoded = captureBytes(
        ctx.allocator,
        bytes,
        bot,
        captured,
        std.Io.Clock.real.now(ctx.io).toMilliseconds(),
    ) catch |err|
        return .{ .unknown = err };
    return .{ .captured = encoded };
}

pub fn captureBytes(
    a: std.mem.Allocator,
    bytes: []const u8,
    bot: []const u8,
    captured: transport.Capture,
    captured_ms: i64,
) ![]u8 {
    var request = try c.decodeOwned(contract.Request, a, bytes);
    defer request.deinit();
    const url = try requestTarget(a, request.value, bot);
    defer a.free(url);
    const notification_bytes = try notification.captureBytes(a, bytes, bot, captured, captured_ms);
    defer a.free(notification_bytes);
    var decoded = try c.decodeOwned(notification.Capture, a, notification_bytes);
    defer decoded.deinit();
    var page: contract.CapturedPage = .{
        .bot_id = decoded.value.response.bot_id,
        .evidence = decoded.value.response.evidence,
    };
    page.evidence.target = .{ .bytes = url };
    return c.encodeOwned(Capture, a, .{ .response = page });
}

fn outcome(
    a: std.mem.Allocator,
    request: contract.Request,
    page: contract.CapturedPage,
) !contract.Reply {
    var history = try replay(a, request, page.bot_id.bytes);
    defer history.deinit();
    try ingest(a, &history, request, page);
    if (history.reason == null and !history.complete and history.pages_left == 0)
        history.reason = .budget;
    if (history.reason == null and !history.complete) return .{ .next = page };
    return .{ .done = switch (history.finding()) {
        .present => |ts| .{ .found = .{ .timestamp = .{ .bytes = try a.dupe(u8, ts) } } },
        .not_observed => .{ .not_observed = .{
            .oldest = request.audit.oldest,
            .latest = request.audit.latest orelse return error.InvalidAuditFinding,
            .canary = request.audit.canary.?.receipt,
        } },
        .inconclusive => |reason| .{ .inconclusive = .{ .bytes = @tagName(reason) } },
    } };
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
    const capture = try c.decodeOwned(Capture, a, captured_bytes);
    const reply: contract.Reply = switch (capture.value) {
        .rejected => |value| blk: {
            if (!std.meta.eql(value.request_digest, preparation.hash(expected)))
                return error.InvalidCapture;
            break :blk .{ .done = .{ .inconclusive = value.reason } };
        },
        .response => |page| try outcome(a, request.value, page),
    };
    return .{ .reply = try c.encodeOwned(contract.Reply, ctx.allocator, reply) };
}
