const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const contract = @import("../app/github_contract.zig");
const adapter = @import("../native/github_adapter.zig");
const a = std.testing.allocator;
const RawHeader = std.meta.Elem(@FieldType(@FieldType(t.ReadEvidence, "headers"), "items"));
const repository: t.Repository = .{
    .account = .{ .bytes = "github-test" },
    .id = 123,
    .owner = .{ .bytes = "owner" },
    .name = .{ .bytes = "repository" },
    .ref = .{ .bytes = "refs/heads/main" },
};

fn oid(number: u32) !t.Oid {
    var bytes: t.Oid = undefined;
    _ = try std.fmt.bufPrint(&bytes, "{x:0>40}", .{number});
    return bytes;
}

fn initial(tip: u32) !contract.Request {
    return .{ .repository = repository, .phase = .{ .page = .{
        .base = try oid(0),
        .tip = try oid(tip),
        .ordinal = 1,
        .url = null,
        .metadata = null,
        .seen = .{ .items = &.{} },
    } } };
}

fn metadata(total: u64) !contract.Metadata {
    return .{
        .base = try oid(0),
        .merge_base = try oid(0),
        .ahead_by = total,
        .behind_by = 0,
        .total_commits = total,
    };
}

fn url(allocator: std.mem.Allocator, tip: u32, ordinal: u64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repositories/123/compare/{s}...{s}?page={d}&per_page=100",
        .{ try oid(0), try oid(tip), ordinal },
    );
}

const Page = struct {
    commits: []const u32,
    total: u64,
    ahead: ?u64 = null,
    status: []const u8 = "ahead",
    base: u32 = 0,
    merge_base: u32 = 0,
};

fn body(allocator: std.mem.Allocator, page: Page) ![]u8 {
    const Record = struct { sha: []const u8, commit: struct { message: []const u8 } };
    const records = try allocator.alloc(Record, page.commits.len);
    defer allocator.free(records);
    const ids = try allocator.alloc(t.Oid, page.commits.len);
    defer allocator.free(ids);
    for (records, ids, page.commits) |*record, *id, number| {
        id.* = try oid(number);
        record.* = .{ .sha = id, .commit = .{ .message = "Untrusted commit @everyone <url>" } };
    }
    const base = try oid(page.base);
    const merge_base = try oid(page.merge_base);
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = page.status,
        .base_commit = .{ .sha = @as([]const u8, &base) },
        .merge_base_commit = .{ .sha = @as([]const u8, &merge_base) },
        .ahead_by = page.ahead orelse page.total,
        .behind_by = @as(u64, 0),
        .total_commits = page.total,
        .commits = records,
    }, .{});
}

fn hash(bytes: []const u8) t.Digest {
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn requestDigest(allocator: std.mem.Allocator, request: contract.Request) !t.Digest {
    const bytes = try c.encodeOwned(contract.Request, allocator, request);
    defer allocator.free(bytes);
    return hash(bytes);
}

fn capture(
    allocator: std.mem.Allocator,
    request: contract.Request,
    status: u16,
    raw: []const u8,
    next: ?[]const u8,
) !t.ReadEvidence {
    var prepared = try adapter.prepare(allocator, request);
    defer prepared.deinit();
    return .{
        .request_digest = try requestDigest(allocator, request),
        .target = .{ .bytes = try allocator.dupe(u8, prepared.url) },
        .status = status,
        .body = .{ .bytes = raw },
        .body_digest = hash(raw),
        .captured_ms = 1000,
        .provider_date = .{ .bytes = "Sun, 15 Nov 2026 22:00:33 GMT" },
        .request_id = .{ .bytes = "request-123" },
        .link = if (next) |target| .{
            .bytes = try std.fmt.allocPrint(allocator, "<{s}>; rel=\"next\"", .{target}),
        } else null,
        .etag = .{ .bytes = "\"etag-1\"" },
        .retry_after = null,
        .rate_remaining = .{ .bytes = "4999" },
        .rate_reset = .{ .bytes = "1794781000" },
        .media_type = .{ .bytes = "application/json" },
    };
}

fn expectRejected(
    request: contract.Request,
    evidence: t.ReadEvidence,
    reason: contract.Failure,
) !void {
    var result = try adapter.interpret(a, request, evidence);
    defer result.deinit();
    try std.testing.expect(result.value == .rejected);
    try std.testing.expectEqual(reason, result.value.rejected.reason);
    const retained = result.value.rejected.evidence.?;
    try std.testing.expectEqualDeep(evidence, retained);
    const encoded = try c.encodeOwned(contract.Reply, a, result.value);
    defer a.free(encoded);
}

fn capturedHeaders(allocator: std.mem.Allocator, evidence: t.ReadEvidence) !t.ReadEvidence {
    var owned = evidence;
    var headers: std.ArrayList(RawHeader) = .empty;
    errdefer headers.deinit(allocator);
    inline for (.{
        .{ "provider_date", "date" },
        .{ "request_id", "x-github-request-id" },
        .{ "link", "link" },
        .{ "etag", "etag" },
        .{ "retry_after", "retry-after" },
        .{ "rate_remaining", "x-ratelimit-remaining" },
        .{ "rate_reset", "x-ratelimit-reset" },
        .{ "media_type", "content-type" },
        .{ "content_encoding", "content-encoding" },
    }) |pair| {
        if (@field(evidence, pair[0])) |value| try headers.append(allocator, .{
            .name = .{ .bytes = pair[1] },
            .value = .{ .bytes = value.bytes },
        });
    }
    owned.headers.items = try headers.toOwnedSlice(allocator);
    return owned;
}

test "github adapter prepares owned routes and canonical request identity for each phase" {
    const request: contract.Request = .{ .repository = repository, .phase = .repository_before };
    var prepared = try adapter.prepare(a, request);
    defer prepared.deinit();
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/owner/repository",
        prepared.url,
    );
    try std.testing.expectEqualSlices(u8, &try requestDigest(a, request), &prepared.request_digest);
    var after = request;
    after.phase = .repository_after;
    var final = try adapter.prepare(a, after);
    defer final.deinit();
    try std.testing.expectEqualStrings(prepared.url, final.url);
    try std.testing.expect(!std.meta.eql(prepared.request_digest, final.request_digest));
    var reference = request;
    reference.phase = .reference;
    reference.repository.ref.bytes = "refs/heads/feature/é%#";
    var selected = try adapter.prepare(a, reference);
    defer selected.deinit();
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/owner/repository/git/ref/heads/feature/%C3%A9%25%23",
        selected.url,
    );
    var page = try adapter.prepare(a, try initial(2));
    defer page.deinit();
    try std.testing.expect(std.mem.endsWith(u8, page.url, "?per_page=100&page=1"));
}

test "github adapter checks repository identity both times and exact ref commit object" {
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    for ([_]bool{ false, true }) |after| {
        const request: contract.Request = .{
            .repository = repository,
            .phase = if (after) .repository_after else .repository_before,
        };
        const good = try capture(scratch, request, 200, "{\"id\":123}", null);
        var reply = try adapter.interpret(a, request, good);
        defer reply.deinit();
        try std.testing.expect(reply.value == .repository);
        try expectRejected(
            request,
            try capture(scratch, request, 200, "{\"id\":456}", null),
            .binding,
        );
    }
    const request: contract.Request = .{ .repository = repository, .phase = .reference };
    const tip = try oid(3);
    const raw = try std.json.Stringify.valueAlloc(scratch, .{
        .ref = repository.ref.bytes,
        .object = .{ .type = "commit", .sha = @as([]const u8, &tip) },
    }, .{});
    const good = try capture(scratch, request, 200, raw, null);
    var reply = try adapter.interpret(a, request, good);
    defer reply.deinit();
    try std.testing.expectEqualDeep(tip, reply.value.reference.tip);
    var changed = request;
    changed.repository.ref.bytes = "refs/heads/main/other";
    try expectRejected(changed, try capture(scratch, changed, 200, raw, null), .binding);
    const tag = try std.json.Stringify.valueAlloc(scratch, .{
        .ref = repository.ref.bytes,
        .object = .{ .type = "tag", .sha = @as([]const u8, &tip) },
    }, .{});
    try expectRejected(request, try capture(scratch, request, 200, tag, null), .unsupported_object);
}

test "github adapter each page owns raw evidence and final page proves complete coverage" {
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    const request = try initial(3);
    const raw = try body(scratch, .{ .commits = &.{ 1, 2 }, .total = 3 });
    const expected_raw = try a.dupe(u8, raw);
    defer a.free(expected_raw);
    const evidence = try capturedHeaders(
        scratch,
        try capture(scratch, request, 200, raw, try url(scratch, 3, 2)),
    );
    var first = try adapter.interpret(a, request, evidence);
    defer first.deinit();
    try std.testing.expect(first.value == .page);
    var second_request = request;
    second_request.phase.page.ordinal = 2;
    second_request.phase.page.url = first.value.page.next;
    second_request.phase.page.metadata = first.value.page.metadata;
    second_request.phase.page.seen.items = &.{ try oid(1), try oid(2) };
    const last_raw = try body(scratch, .{ .commits = &.{3}, .total = 3 });
    const last = try capture(scratch, second_request, 200, last_raw, null);
    var second = try adapter.interpret(a, second_request, last);
    defer second.deinit();
    try std.testing.expect(second.value == .page);
    try std.testing.expect(second.value.page.next == null);
    try std.testing.expectEqual(3, second.value.page.metadata.total_commits);
    try std.testing.expectEqualDeep(try oid(3), second.value.page.commits.items[0].oid);
    fixtures.deinit();
    fixtures = std.heap.ArenaAllocator.init(a);
    try std.testing.expectEqualStrings(expected_raw, first.value.page.evidence.body.bytes);
    try std.testing.expectEqualStrings(
        "date",
        first.value.page.evidence.headers.items[0].name.bytes,
    );
    try std.testing.expectEqualStrings(
        "Untrusted commit @everyone <url>",
        first.value.page.commits.items[0].message.bytes,
    );
    try std.testing.expectEqualStrings(
        "request-123",
        second.value.page.evidence.request_id.?.bytes,
    );
}

fn continuation(
    allocator: std.mem.Allocator,
    tip: u32,
    total: u64,
    seen: []const t.Oid,
) !contract.Request {
    var request = try initial(tip);
    request.phase.page.ordinal = 2;
    request.phase.page.url = .{ .bytes = try url(allocator, tip, 2) };
    request.phase.page.metadata = try metadata(total);
    request.phase.page.seen.items = seen;
    return request;
}

test "github adapter rejects resetting pagination state or supplying invalid prior coverage" {
    const Mutation = enum { ordinal, metadata, seen, skipped, url, duplicate, base, merge_base };
    for (std.enums.values(Mutation)) |mutation| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        var request = try continuation(fixtures.allocator(), 3, 3, &.{try oid(1)});
        const page = &request.phase.page;
        switch (mutation) {
            .ordinal => page.ordinal = 1,
            .metadata => page.metadata = null,
            .seen => page.seen.items = &.{},
            .skipped => page.ordinal = 3,
            .url => page.url = null,
            .duplicate => page.seen.items = &.{ try oid(1), try oid(1) },
            .base => page.seen.items = &.{try oid(0)},
            .merge_base => page.metadata.?.merge_base = try oid(7),
        }
        const expected = switch (mutation) {
            .duplicate => error.DuplicateCommit,
            .base => error.BaseIncluded,
            .merge_base => error.RewrittenHistory,
            else => error.InvalidPageCursor,
        };
        try std.testing.expectError(expected, adapter.prepare(a, request));
    }
}

test "github adapter freezes metadata and rejects duplicate OIDs within or across pages" {
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    const request = try continuation(scratch, 2, 2, &.{try oid(1)});
    const changed = try body(scratch, .{ .commits = &.{2}, .total = 3 });
    try expectRejected(request, try capture(scratch, request, 200, changed, null), .incomplete);
    const repeated = try body(scratch, .{ .commits = &.{1}, .total = 2 });
    try expectRejected(request, try capture(scratch, request, 200, repeated, null), .incomplete);
    const first = try initial(2);
    const duplicate = try body(scratch, .{ .commits = &.{ 1, 1 }, .total = 2 });
    try expectRejected(first, try capture(scratch, first, 200, duplicate, null), .incomplete);
}

test "github adapter final pages require exact total requested tip and uncapped metadata" {
    const cases = [_]Page{
        .{ .commits = &.{1}, .total = 2 },
        .{ .commits = &.{ 1, 3 }, .total = 2 },
        .{ .commits = &.{ 1, 2 }, .total = 1 },
        .{ .commits = &.{2}, .total = 10000, .ahead = 18404 },
        .{ .commits = &.{ 0, 2 }, .total = 2 },
        .{ .commits = &.{}, .total = 2 },
        .{ .commits = &.{2}, .total = 1, .merge_base = 7 },
    };
    for (cases) |page| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        const scratch = fixtures.allocator();
        const request = try initial(2);
        const raw = try body(scratch, page);
        try expectRejected(request, try capture(scratch, request, 200, raw, null), .incomplete);
    }
    for ([_][]const u8{ "behind", "diverged" }) |status| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        const scratch = fixtures.allocator();
        const request = try initial(2);
        const raw = try body(scratch, .{ .commits = &.{2}, .total = 1, .status = status });
        try expectRejected(
            request,
            try capture(scratch, request, 200, raw, null),
            if (std.mem.eql(u8, status, "behind")) .behind else .diverged,
        );
    }
}

test "github adapter checks current and next URLs against exact service route and page" {
    const variants = [_][]const u8{
        "https://other.invalid/repositories/123/compare/{s}...{s}?page=2&per_page=100",
        "https://api.github.com.evil/repositories/123/compare/{s}...{s}?page=2&per_page=100",
        "https://api.github.com/repositories/456/compare/{s}...{s}?page=2&per_page=100",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=3&per_page=100",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=+2&per_page=100",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=2&per_page=100#x",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=2&per_page=250",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=2&per_page=100&page=2",
    };
    inline for (variants) |pattern| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        const scratch = fixtures.allocator();
        const unsafe = try std.fmt.allocPrint(scratch, pattern, .{ try oid(0), try oid(2) });
        var current = try continuation(scratch, 2, 2, &.{try oid(1)});
        current.phase.page.url = .{ .bytes = unsafe };
        try std.testing.expectError(error.UnsafePagination, adapter.prepare(a, current));
        const request = try initial(2);
        const raw = try body(scratch, .{ .commits = &.{1}, .total = 2 });
        try expectRejected(request, try capture(scratch, request, 200, raw, unsafe), .binding);
    }
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    var changed = try continuation(fixtures.allocator(), 2, 2, &.{try oid(1)});
    changed.phase.page.url = .{ .bytes = try url(fixtures.allocator(), 3, 2) };
    try std.testing.expectError(error.UnsafePagination, adapter.prepare(a, changed));
}

test "github adapter rejects changed request body target and content encoding evidence" {
    const Mutation = enum { request, body_digest, body, target, encoding, encoding_header };
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    const request = try initial(1);
    const raw = try body(scratch, .{ .commits = &.{1}, .total = 1 });
    const good = try capture(scratch, request, 200, raw, null);
    for (std.enums.values(Mutation)) |mutation| {
        var changed = good;
        switch (mutation) {
            .request => changed.request_digest[0] ^= 1,
            .body_digest => changed.body_digest[0] ^= 1,
            .body => changed.body.bytes = "changed bytes",
            .target => changed.target.bytes = "https://other.invalid/",
            .encoding => changed.identity_encoding = false,
            .encoding_header => changed.content_encoding = .{ .bytes = "gzip" },
        }
        try expectRejected(request, changed, if (mutation == .target) .binding else .malformed);
    }
}

test "github adapter typed rejections retain exact raw responses and safe metadata" {
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    const request: contract.Request = .{ .repository = repository, .phase = .repository_before };
    for ([_]u16{ 401, 403, 429, 500, 304, 200 }) |status| {
        const reason: contract.Failure = switch (status) {
            401, 403 => .permission,
            429 => .rate_limit,
            304 => .incomplete,
            200 => .malformed,
            else => .unavailable,
        };
        const evidence = try capture(scratch, request, status, "<untrusted>not JSON\xff", null);
        try expectRejected(request, evidence, reason);
    }
    var limited = try capture(scratch, request, 403, "{\"message\":\"rate limited\"}", null);
    limited.rate_remaining = .{ .bytes = "0" };
    try expectRejected(request, limited, .rate_limit);
    limited.rate_remaining = .{ .bytes = "10" };
    limited.retry_after = .{ .bytes = "60" };
    try expectRejected(request, limited, .rate_limit);
    limited.request_id = .{ .bytes = "unsafe\r\nheader" };
    try expectRejected(request, limited, .malformed);
}

test "github adapter retains invalid raw header bytes and refuses projection ambiguity" {
    const Mutation = enum { duplicate, overlong, unreadable, changed, missing, unsafe };
    for (std.enums.values(Mutation)) |mutation| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        const scratch = fixtures.allocator();
        const request: contract.Request = .{
            .repository = repository,
            .phase = .repository_before,
        };
        var evidence = try capturedHeaders(
            scratch,
            try capture(scratch, request, 200, "{\"id\":123}", null),
        );
        const headers = try scratch.dupe(RawHeader, evidence.headers.items);
        evidence.headers.items = headers;
        switch (mutation) {
            .duplicate => {
                headers[0].name.bytes = "X-GitHub-Request-Id";
                evidence.provider_date = null;
                evidence.request_id = null;
            },
            .overlong => {
                const oversized = try scratch.alloc(u8, 129);
                @memset(oversized, 'x');
                headers[1].value.bytes = oversized;
                evidence.request_id = null;
            },
            .unreadable => {
                headers[1].value.bytes = "\xff";
                evidence.request_id = null;
            },
            .changed => evidence.etag = .{ .bytes = "changed" },
            .missing => evidence.headers.items = headers[1..],
            .unsafe => headers[0].name.bytes = "x-unselected",
        }
        try expectRejected(request, evidence, .malformed);
    }
}

test "github adapter request ID projections prefer GitHub then the generic fallback" {
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    const request: contract.Request = .{ .repository = repository, .phase = .repository_before };
    var evidence = try capturedHeaders(
        scratch,
        try capture(scratch, request, 200, "{\"id\":123}", null),
    );
    const headers = try scratch.alloc(RawHeader, evidence.headers.items.len + 1);
    @memcpy(headers[0..evidence.headers.items.len], evidence.headers.items);
    headers[headers.len - 1] = .{
        .name = .{ .bytes = "X-Request-Id" },
        .value = .{ .bytes = "fallback-456" },
    };
    evidence.headers.items = headers;
    var preferred = try adapter.interpret(a, request, evidence);
    defer preferred.deinit();
    try std.testing.expect(preferred.value == .repository);
    try std.testing.expectEqualStrings(
        "request-123",
        preferred.value.repository.request_id.?.bytes,
    );
    headers[1].name.bytes = "x-ratelimit-used";
    evidence.request_id = .{ .bytes = "fallback-456" };
    var fallback = try adapter.interpret(a, request, evidence);
    defer fallback.deinit();
    try std.testing.expect(fallback.value == .repository);
    try std.testing.expectEqualStrings(
        "fallback-456",
        fallback.value.repository.request_id.?.bytes,
    );
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var fixtures = std.heap.ArenaAllocator.init(allocator);
    defer fixtures.deinit();
    const scratch = fixtures.allocator();
    const request = try initial(1);
    const raw = try body(scratch, .{ .commits = &.{1}, .total = 1 });
    const evidence = try capturedHeaders(scratch, try capture(scratch, request, 200, raw, null));
    var prepared = try adapter.prepare(allocator, request);
    defer prepared.deinit();
    var result = try adapter.interpret(allocator, request, evidence);
    defer result.deinit();
    try std.testing.expect(result.value == .page);
    var invalid = evidence;
    invalid.body_digest[0] ^= 1;
    var rejected = try adapter.interpret(allocator, request, invalid);
    defer rejected.deinit();
    try std.testing.expect(rejected.value == .rejected);
}

test "github adapter releases partial preparation interpretation and rejected capture allocations" {
    try std.testing.checkAllAllocationFailures(a, allocationPath, .{});
}
