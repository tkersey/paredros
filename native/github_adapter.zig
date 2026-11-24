const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const contract = @import("../app/github_contract.zig");
const github = @import("github.zig");
const transport = @import("http.zig");
const projected_headers = .{
    .{ "provider_date", "date" },
    .{ "request_id", "x-github-request-id" },
    .{ "link", "link" },
    .{ "etag", "etag" },
    .{ "retry_after", "retry-after" },
    .{ "rate_remaining", "x-ratelimit-remaining" },
    .{ "rate_reset", "x-ratelimit-reset" },
    .{ "media_type", "content-type" },
    .{ "content_encoding", "content-encoding" },
};
const RawHeader = std.meta.Elem(@FieldType(@FieldType(t.ReadEvidence, "headers"), "items"));

pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    url: []const u8,
    request_digest: t.Digest,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Interpreted = c.Decoded(contract.Reply);
pub const Observation = union(enum) {
    local: contract.Failure,
    refused: struct { request_digest: t.Digest, refused: transport.Refused },
    response: t.ReadEvidence,
};

pub fn classify(
    a: std.mem.Allocator,
    request: contract.Request,
    observation: Observation,
) !Interpreted {
    const reason = switch (observation) {
        .response => |evidence| return interpret(a, request, evidence),
        .local => |reason| reason,
        .refused => |refused| refused: {
            var prepared = try prepare(a, request);
            defer prepared.deinit();
            if (!std.meta.eql(prepared.request_digest, refused.request_digest))
                return error.InvalidCapture;
            break :refused refusal(request, refused.refused.refusal);
        },
    };
    return .{
        .arena = std.heap.ArenaAllocator.init(a),
        .value = .{ .rejected = .{ .reason = reason, .evidence = null } },
    };
}

pub fn refusal(request: contract.Request, refused: transport.Refusal) contract.Failure {
    return switch (refused) {
        .body_capacity => if (request.phase == .page) .incomplete else .malformed,
        .body_interrupted, .local_resources => .unavailable,
        .head_capacity,
        .head_malformed,
        .body_malformed,
        .body_unexpected,
        .credential_echo,
        .unrepresentable,
        => .malformed,
    };
}

pub fn prepare(a: std.mem.Allocator, request: contract.Request) !Prepared {
    const bound = binding(request.repository);
    try github.validateBinding(bound);
    if (request.repository.account.bytes.len == 0) return error.InvalidAccount;
    const bytes = try c.encodeOwned(contract.Request, a, request);
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const url = switch (request.phase) {
        .repository_before, .repository_after => try std.fmt.allocPrint(
            owned,
            github.api_origin ++ "/repos/{s}/{s}",
            .{ bound.owner, bound.name },
        ),
        .reference => reference: {
            const path = try github.referencePath(a, bound.ref);
            defer a.free(path);
            break :reference try std.fmt.allocPrint(
                owned,
                github.api_origin ++ "/repos/{s}/{s}/git/ref/{s}",
                .{ bound.owner, bound.name, path },
            );
        },
        .page => |page| try cursor(request.repository, page).requestUrl(
            owned,
            if (page.url) |url| url.bytes else null,
        ),
    };
    return .{ .arena = arena, .url = url, .request_digest = digest(bytes) };
}

pub fn interpret(
    a: std.mem.Allocator,
    request: contract.Request,
    evidence: t.ReadEvidence,
) !Interpreted {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const retained = try ownEvidence(arena.allocator(), evidence);
    const value = interpretChecked(a, arena.allocator(), request, retained) catch |err| failure: {
        if (err == error.OutOfMemory or err == error.Capacity) return err;
        break :failure contract.Reply{ .rejected = .{
            .reason = rejection(err, retained),
            .evidence = retained,
        } };
    };
    return .{ .arena = arena, .value = value };
}

fn interpretChecked(
    a: std.mem.Allocator,
    owned: std.mem.Allocator,
    request: contract.Request,
    evidence: t.ReadEvidence,
) !contract.Reply {
    var prepared = try prepare(a, request);
    defer prepared.deinit();
    try validateEvidence(prepared, evidence);
    const response: github.Response = .{
        .status = evidence.status,
        .body = evidence.body.bytes,
        .link = if (evidence.link) |link| link.bytes else null,
    };
    switch (request.phase) {
        .repository_before, .repository_after => {
            try github.validateRepository(a, request.repository.id, response);
            return .{ .repository = evidence };
        },
        .reference => return .{ .reference = .{
            .tip = try github.referenceOid(a, request.repository.ref.bytes, response),
            .evidence = evidence,
        } },
        .page => |page| {
            var parsed = try github.parsePage(
                a,
                cursor(request.repository, page),
                prepared.url,
                response,
            );
            defer parsed.deinit();
            if (parsed.next == null) try parsed.requireComplete();
            const commits = try owned.alloc(t.Commit, parsed.commits.len);
            for (parsed.commits, commits) |commit, *destination| destination.* = .{
                .oid = commit.oid,
                .message = .{ .bytes = try owned.dupe(u8, commit.untrusted_message) },
            };
            return .{ .page = .{
                .metadata = .{
                    .base = parsed.metadata.base,
                    .merge_base = parsed.metadata.merge_base,
                    .ahead_by = parsed.metadata.ahead_by,
                    .behind_by = parsed.metadata.behind_by,
                    .total_commits = parsed.metadata.total_commits,
                },
                .commits = .{ .items = commits },
                .next = if (parsed.next) |url| .{ .bytes = try owned.dupe(u8, url) } else null,
                .evidence = evidence,
            } };
        },
    }
}

fn binding(repository: t.Repository) github.Binding {
    return .{
        .repository_id = repository.id,
        .owner = repository.owner.bytes,
        .name = repository.name.bytes,
        .ref = repository.ref.bytes,
    };
}

fn cursor(repository: t.Repository, page: contract.Page) github.PageCursor {
    return .{
        .binding = binding(repository),
        .base = page.base,
        .tip = page.tip,
        .ordinal = page.ordinal,
        .metadata = if (page.metadata) |metadata| .{
            .base = metadata.base,
            .merge_base = metadata.merge_base,
            .ahead_by = metadata.ahead_by,
            .behind_by = metadata.behind_by,
            .total_commits = metadata.total_commits,
        } else null,
        .seen = page.seen.items,
    };
}

fn digest(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn validateEvidence(prepared: Prepared, evidence: t.ReadEvidence) !void {
    if (!std.meta.eql(prepared.request_digest, evidence.request_digest))
        return error.RequestDigestMismatch;
    if (!std.meta.eql(digest(evidence.body.bytes), evidence.body_digest))
        return error.BodyDigestMismatch;
    if (!std.mem.eql(u8, prepared.url, evidence.target.bytes)) return error.EvidenceTargetMismatch;
    if (evidence.status < 100 or evidence.status > 599) return error.InvalidStatus;
    if (!evidence.identity_encoding) return error.UnsupportedEncoding;
    if (evidence.content_encoding) |encoding| {
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, encoding.bytes, " \t"), "identity"))
            return error.UnsupportedEncoding;
    }
    inline for (projected_headers) |field| {
        if (@field(evidence, field[0])) |value| try header(@TypeOf(value), value);
    }
    try validateRawHeaders(evidence);
}

fn header(comptime T: type, value: T) !void {
    if (T.max_length) |maximum| if (value.bytes.len > maximum) return error.InvalidHeader;
    if (!std.unicode.utf8ValidateSlice(value.bytes)) return error.InvalidHeader;
    for (value.bytes) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f)
        return error.InvalidHeader;
}

fn ownEvidence(a: std.mem.Allocator, evidence: t.ReadEvidence) !t.ReadEvidence {
    var owned = evidence;
    owned.target.bytes = try a.dupe(u8, evidence.target.bytes);
    owned.body.bytes = try a.dupe(u8, evidence.body.bytes);
    inline for (projected_headers) |field| {
        if (@field(evidence, field[0])) |value| {
            var copy = value;
            copy.bytes = try a.dupe(u8, value.bytes);
            @field(owned, field[0]) = copy;
        }
    }
    const headers = try a.alloc(RawHeader, evidence.headers.items.len);
    for (evidence.headers.items, headers) |original, *copy| copy.* = .{
        .name = .{ .bytes = try a.dupe(u8, original.name.bytes) },
        .value = .{ .bytes = try a.dupe(u8, original.value.bytes) },
    };
    owned.headers.items = headers;
    return owned;
}

fn validateRawHeaders(evidence: t.ReadEvidence) !void {
    if (evidence.headers.items.len == 0) return;
    for (evidence.headers.items, 0..) |item, index| {
        if (!safeHeader(item.name.bytes)) return error.InvalidHeader;
        try header(@TypeOf(item.value), item.value);
        for (evidence.headers.items[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(prior.name.bytes, item.name.bytes))
                return error.DuplicateHeader;
        }
    }
    inline for (projected_headers) |field| {
        const raw = rawHeader(evidence, field[1]) orelse
            if (comptime std.mem.eql(u8, field[0], "request_id"))
                rawHeader(evidence, "x-request-id")
            else
                null;
        if (raw) |bytes| {
            const projected = @field(evidence, field[0]) orelse
                return error.InvalidHeaderProjection;
            if (!std.mem.eql(u8, projected.bytes, bytes)) return error.InvalidHeaderProjection;
        } else if (@field(evidence, field[0]) != null) return error.InvalidHeaderProjection;
    }
}

fn rawHeader(evidence: t.ReadEvidence, name: []const u8) ?[]const u8 {
    for (evidence.headers.items) |item| {
        if (std.ascii.eqlIgnoreCase(item.name.bytes, name)) return item.value.bytes;
    }
    return null;
}

fn safeHeader(name: []const u8) bool {
    inline for (projected_headers) |field| {
        if (std.ascii.eqlIgnoreCase(name, field[1])) return true;
    }
    for ([_][]const u8{
        "x-ratelimit-limit",
        "x-ratelimit-used",
        "x-ratelimit-resource",
        "x-request-id",
        "content-length",
    }) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    }
    return false;
}

fn rejection(err: anyerror, evidence: t.ReadEvidence) contract.Failure {
    return switch (err) {
        error.UnsuccessfulResponse => switch (evidence.status) {
            429 => .rate_limit,
            403 => if (evidence.retry_after != null or remainingZero(evidence))
                .rate_limit
            else
                .permission,
            401 => .permission,
            else => .unavailable,
        },
        error.RepositoryIdentityMismatch,
        error.ReferenceMismatch,
        error.InvalidRepositoryRoute,
        error.InvalidRef,
        error.InvalidAccount,
        error.EvidenceTargetMismatch,
        error.UnsafePagination,
        => .binding,
        error.UnsupportedObjectFormat, error.UnsupportedObjectType => .unsupported_object,
        error.BehindHistory => .behind,
        error.DivergedHistory => .diverged,
        error.MissingRetainedResponse => .unretained,
        error.IncompleteComparison,
        error.InconsistentMetadata,
        error.RewrittenHistory,
        error.BaseIncluded,
        error.DuplicateCommit,
        error.InvalidPagination,
        => .incomplete,
        else => .malformed,
    };
}

fn remainingZero(evidence: t.ReadEvidence) bool {
    const remaining = evidence.rate_remaining orelse return false;
    return std.mem.eql(u8, remaining.bytes, "0");
}
