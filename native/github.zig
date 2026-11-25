const std = @import("std");

pub const api_version = "2026-03-10";
pub const api_origin = "https://api.github.com";
pub const Oid = [40]u8;
pub const Binding = struct {
    repository_id: u64,
    owner: []const u8,
    name: []const u8,
    ref: []const u8,
};
pub const Response = struct { status: u16, body: []const u8, link: ?[]const u8 = null };
pub const Commit = struct { oid: Oid, untrusted_message: []const u8 };
pub const Page = struct { request: []const u8, body: []const u8, link: ?[]const u8 };
pub const Metadata = struct {
    base: Oid,
    merge_base: Oid,
    ahead_by: u64,
    behind_by: u64,
    total_commits: u64,
};
pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    binding: Binding,
    base: Oid,
    tip: Oid,
    commits: []const Commit,
    pages: []const Page,
    repository_before: []const u8,
    reference: []const u8,
    repository_after: []const u8,

    pub fn deinit(self: *Batch) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseOid(bytes: []const u8) !Oid {
    if (bytes.len != 40) return error.UnsupportedObjectFormat;
    var result: Oid = undefined;
    for (bytes, &result) |byte, *out| {
        if (!std.ascii.isHex(byte)) return error.InvalidOid;
        out.* = std.ascii.toLower(byte);
    }
    return result;
}

pub fn validateRef(ref: []const u8) !void {
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, ref, prefix) or ref.len == prefix.len or
        !std.unicode.utf8ValidateSlice(ref)) return error.InvalidRef;
    if (std.mem.indexOf(u8, ref, "..") != null or
        std.mem.indexOf(u8, ref, "@{") != null or ref[ref.len - 1] == '.') return error.InvalidRef;
    for (ref) |byte| {
        if (byte <= ' ' or byte == 127 or std.mem.indexOfScalar(u8, "~^:?*[\\", byte) != null)
            return error.InvalidRef;
    }
    var parts = std.mem.splitScalar(u8, ref, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or
            std.mem.endsWith(u8, part, ".lock")) return error.InvalidRef;
    }
}

pub fn referencePath(a: std.mem.Allocator, ref: []const u8) ![]u8 {
    try validateRef(ref);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    const digits = "0123456789ABCDEF";
    for (ref[5..]) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~/", byte) != null) {
            try output.append(a, byte);
        } else {
            try output.appendSlice(a, &.{ '%', digits[byte >> 4], digits[byte & 15] });
        }
    }
    return output.toOwnedSlice(a);
}

pub fn validateRepository(a: std.mem.Allocator, id: u64, response: Response) !void {
    try successful(response);
    const parsed = try std.json.parseFromSlice(struct { id: u64 }, a, response.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (id == 0 or parsed.value.id != id) return error.RepositoryIdentityMismatch;
}

pub fn referenceOid(a: std.mem.Allocator, ref: []const u8, response: Response) !Oid {
    try validateRef(ref);
    try successful(response);
    const parsed = try std.json.parseFromSlice(struct {
        ref: []const u8,
        object: struct { type: []const u8, sha: []const u8 },
    }, a, response.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, ref, parsed.value.ref)) return error.ReferenceMismatch;
    if (!std.mem.eql(u8, parsed.value.object.type, "commit")) return error.UnsupportedObjectType;
    return parseOid(parsed.value.object.sha);
}

fn successful(response: Response) !void {
    if (response.status == 304) return error.MissingRetainedResponse;
    if (response.status != 200) return error.UnsuccessfulResponse;
}

const Comparison = struct {
    status: []const u8,
    base_commit: struct { sha: []const u8 },
    merge_base_commit: struct { sha: []const u8 },
    ahead_by: u64,
    behind_by: u64,
    total_commits: u64,
    commits: []const struct { sha: []const u8, commit: struct { message: []const u8 } },
};

pub const PageCursor = struct {
    binding: Binding,
    base: Oid,
    tip: Oid,
    ordinal: u64,
    metadata: ?Metadata,
    seen: []const Oid,

    pub fn validate(self: PageCursor, a: std.mem.Allocator) !void {
        var seen = try self.admitSeen(a);
        seen.deinit();
    }

    pub fn requestUrl(self: PageCursor, a: std.mem.Allocator, url: ?[]const u8) ![]u8 {
        try self.validate(a);
        if (url) |selected| {
            try validatePageUrl(a, self.binding, self.base, self.tip, self.ordinal, selected);
            return a.dupe(u8, selected);
        }
        if (self.ordinal != 1) return error.InvalidPageCursor;
        return comparisonUrl(a, self.binding, self.base, self.tip);
    }

    fn admitSeen(self: PageCursor, a: std.mem.Allocator) !std.AutoHashMap(Oid, void) {
        try validateBinding(self.binding);
        if (self.ordinal == 0 or !std.meta.eql(self.base, try parseOid(&self.base)) or
            !std.meta.eql(self.tip, try parseOid(&self.tip)) or
            std.meta.eql(self.base, self.tip)) return error.InvalidPageCursor;
        if (self.ordinal == 1) {
            if (self.metadata != null or self.seen.len != 0) return error.InvalidPageCursor;
        } else {
            const prior = self.metadata orelse return error.InvalidPageCursor;
            try validateMetadataBase(self.base, prior);
            if (self.seen.len == 0 or self.seen.len >= prior.total_commits or
                self.ordinal - 1 > self.seen.len or
                self.ordinal - 1 < (self.seen.len - 1) / 100 + 1)
                return error.InvalidPageCursor;
        }
        var seen = std.AutoHashMap(Oid, void).init(a);
        errdefer seen.deinit();
        for (self.seen) |oid| {
            if (!std.meta.eql(oid, try parseOid(&oid))) return error.InvalidPageCursor;
            if (std.meta.eql(oid, self.base)) return error.BaseIncluded;
            if ((try seen.getOrPut(oid)).found_existing) return error.DuplicateCommit;
        }
        return seen;
    }
};

pub const ParsedPage = struct {
    arena: std.heap.ArenaAllocator,
    metadata: Metadata,
    commits: []const Commit,
    next: ?[]const u8,
    count: usize,
    has_tip: bool,

    pub fn deinit(self: *ParsedPage) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn requireComplete(self: ParsedPage) !void {
        if (self.next != null) return error.IncompleteComparison;
        try validateComplete(self.metadata, self.count, self.has_tip);
    }
};

pub fn parsePage(
    a: std.mem.Allocator,
    cursor: PageCursor,
    request: []const u8,
    response: Response,
) !ParsedPage {
    var seen = try cursor.admitSeen(a);
    defer seen.deinit();
    try validatePageUrl(a, cursor.binding, cursor.base, cursor.tip, cursor.ordinal, request);
    try successful(response);
    const parsed = try std.json.parseFromSlice(Comparison, a, response.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const metadata = try validateMetadata(cursor, parsed.value);
    if (parsed.value.commits.len == 0 or parsed.value.commits.len > 100)
        return error.IncompleteComparison;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const commits = try owned.alloc(Commit, parsed.value.commits.len);
    for (parsed.value.commits, commits) |commit, *destination| {
        const oid = try parseOid(commit.sha);
        if (std.meta.eql(oid, cursor.base)) return error.BaseIncluded;
        if (!std.unicode.utf8ValidateSlice(commit.commit.message)) return error.InvalidMessage;
        if ((try seen.getOrPut(oid)).found_existing) return error.DuplicateCommit;
        destination.* = .{
            .oid = oid,
            .untrusted_message = try owned.dupe(u8, commit.commit.message),
        };
    }
    const next = try nextLink(response.link);
    if (seen.count() > metadata.total_commits or
        (next != null and seen.count() == metadata.total_commits))
        return error.IncompleteComparison;
    if (next) |url| try validatePageUrl(
        a,
        cursor.binding,
        cursor.base,
        cursor.tip,
        try std.math.add(u64, cursor.ordinal, 1),
        url,
    );
    const owned_next = if (next) |url| try owned.dupe(u8, url) else null;
    return .{
        .arena = arena,
        .metadata = metadata,
        .commits = commits,
        .next = owned_next,
        .count = seen.count(),
        .has_tip = seen.contains(cursor.tip),
    };
}

fn validateMetadata(cursor: PageCursor, comparison: Comparison) !Metadata {
    if (std.mem.eql(u8, comparison.status, "behind")) return error.BehindHistory;
    if (std.mem.eql(u8, comparison.status, "diverged")) return error.DivergedHistory;
    if (!std.mem.eql(u8, comparison.status, "ahead")) return error.IncompleteComparison;
    const metadata: Metadata = .{
        .base = try parseOid(comparison.base_commit.sha),
        .merge_base = try parseOid(comparison.merge_base_commit.sha),
        .ahead_by = comparison.ahead_by,
        .behind_by = comparison.behind_by,
        .total_commits = comparison.total_commits,
    };
    try validateMetadataBase(cursor.base, metadata);
    if (cursor.metadata) |prior| {
        if (!std.meta.eql(prior, metadata)) return error.InconsistentMetadata;
    }
    return metadata;
}

fn validateMetadataBase(base: Oid, metadata: Metadata) !void {
    if (!std.meta.eql(metadata.base, base) or !std.meta.eql(metadata.merge_base, base) or
        metadata.behind_by != 0) return error.RewrittenHistory;
    if (metadata.ahead_by != metadata.total_commits or metadata.total_commits == 0)
        return error.IncompleteComparison;
}

fn validateComplete(metadata: Metadata, count: usize, has_tip: bool) !void {
    if (count != metadata.total_commits or !has_tip) return error.IncompleteComparison;
}

pub const Accumulator = struct {
    arena: std.heap.ArenaAllocator,
    binding: Binding,
    base: Oid,
    tip: Oid,
    repository_before: []const u8,
    reference: []const u8,
    metadata: ?Metadata = null,
    commits: std.ArrayList(Commit) = .empty,
    pages: std.ArrayList(Page) = .empty,
    seen: std.AutoArrayHashMapUnmanaged(Oid, void) = .empty,
    expected: ?[]const u8,
    next_page: u64 = 1,
    state: enum { collecting, failed, finished } = .collecting,

    pub fn init(
        a: std.mem.Allocator,
        binding: Binding,
        base: Oid,
        repository: Response,
        reference: Response,
    ) !Accumulator {
        try validateBinding(binding);
        try validateRepository(a, binding.repository_id, repository);
        const tip = try referenceOid(a, binding.ref, reference);
        const canonical_base = try parseOid(&base);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const frozen: Binding = .{
            .repository_id = binding.repository_id,
            .owner = try owned.dupe(u8, binding.owner),
            .name = try owned.dupe(u8, binding.name),
            .ref = try owned.dupe(u8, binding.ref),
        };
        const before = try owned.dupe(u8, repository.body);
        const ref_body = try owned.dupe(u8, reference.body);
        const expected = if (std.mem.eql(u8, &canonical_base, &tip))
            null
        else
            try comparisonUrl(owned, binding, canonical_base, tip);
        return .{
            .arena = arena,
            .binding = frozen,
            .base = canonical_base,
            .tip = tip,
            .repository_before = before,
            .reference = ref_body,
            .expected = expected,
        };
    }

    pub fn deinit(self: *Accumulator) void {
        if (self.state != .finished) self.arena.deinit();
        self.* = undefined;
    }

    pub fn abort(self: *Accumulator) void {
        if (self.state == .collecting) self.state = .failed;
    }

    pub fn nextRequest(self: *const Accumulator) ?[]const u8 {
        return if (self.state == .collecting) self.expected else null;
    }

    pub fn appendPage(self: *Accumulator, request: []const u8, response: Response) !void {
        if (self.state != .collecting) return error.AcquisitionFailed;
        errdefer self.state = .failed;
        const expected = self.expected orelse return error.UnexpectedPage;
        if (!std.mem.eql(u8, request, expected)) return error.ComparisonChanged;
        var parsed = parsePage(self.arena.child_allocator, .{
            .binding = self.binding,
            .base = self.base,
            .tip = self.tip,
            .ordinal = self.next_page,
            .metadata = self.metadata,
            .seen = self.seen.keys(),
        }, request, response) catch |err| switch (err) {
            error.BehindHistory, error.DivergedHistory => return error.RewrittenHistory,
            else => return err,
        };
        defer parsed.deinit();
        const owned = self.arena.allocator();
        for (parsed.commits) |commit| {
            try self.seen.put(owned, commit.oid, {});
            try self.commits.append(owned, .{
                .oid = commit.oid,
                .untrusted_message = try owned.dupe(u8, commit.untrusted_message),
            });
        }
        try self.pages.append(owned, .{
            .request = try owned.dupe(u8, request),
            .body = try owned.dupe(u8, response.body),
            .link = if (response.link) |link| try owned.dupe(u8, link) else null,
        });
        self.metadata = parsed.metadata;
        self.expected = if (parsed.next) |url| try owned.dupe(u8, url) else null;
        self.next_page = try std.math.add(u64, self.next_page, 1);
    }

    pub fn finish(self: *Accumulator, repository_after: Response) !Batch {
        if (self.state != .collecting) return error.AcquisitionFailed;
        errdefer self.state = .failed;
        if (self.expected != null) return error.IncompleteComparison;
        try validateRepository(
            self.arena.child_allocator,
            self.binding.repository_id,
            repository_after,
        );
        if (!std.mem.eql(u8, &self.base, &self.tip)) {
            const metadata = self.metadata orelse return error.IncompleteComparison;
            try validateComplete(metadata, self.commits.items.len, self.seen.contains(self.tip));
        }
        const after = try self.arena.allocator().dupe(u8, repository_after.body);
        const result: Batch = .{
            .arena = self.arena,
            .binding = self.binding,
            .base = self.base,
            .tip = self.tip,
            .commits = self.commits.items,
            .pages = self.pages.items,
            .repository_before = self.repository_before,
            .reference = self.reference,
            .repository_after = after,
        };
        self.state = .finished;
        return result;
    }
};

pub fn validatePageUrl(
    a: std.mem.Allocator,
    binding: Binding,
    base: Oid,
    tip: Oid,
    ordinal: u64,
    url: []const u8,
) !void {
    if (ordinal == 0 or !std.mem.startsWith(u8, url, api_origin ++ "/"))
        return error.UnsafePagination;
    const relative = url[api_origin.len..];
    const query_at = std.mem.indexOfScalar(u8, relative, '?') orelse return error.UnsafePagination;
    const path = relative[0..query_at];
    const named = try std.fmt.allocPrint(a, "/repos/{s}/{s}/compare/{s}...{s}", .{
        binding.owner, binding.name, base, tip,
    });
    defer a.free(named);
    const numbered = try std.fmt.allocPrint(a, "/repositories/{d}/compare/{s}...{s}", .{
        binding.repository_id, base, tip,
    });
    defer a.free(numbered);
    if (!std.mem.eql(u8, path, named) and !std.mem.eql(u8, path, numbered))
        return error.UnsafePagination;
    try paginationQuery(relative[query_at + 1 ..], ordinal);
}

fn comparisonUrl(a: std.mem.Allocator, binding: Binding, base: Oid, tip: Oid) ![]u8 {
    return std.fmt.allocPrint(a, api_origin ++ "/repos/{s}/{s}/compare/{s}...{s}" ++
        "?per_page=100&page=1", .{ binding.owner, binding.name, base, tip });
}

pub fn validateBinding(binding: Binding) !void {
    try validateRef(binding.ref);
    if (binding.repository_id == 0) return error.RepositoryIdentityMismatch;
    for ([_][]const u8{ binding.owner, binding.name }) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.InvalidRepositoryRoute;
        for (component) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and
                std.mem.indexOfScalar(u8, "-._", byte) == null) return error.InvalidRepositoryRoute;
        }
    }
}

fn paginationQuery(query: []const u8, expected_page: u64) !void {
    var page: ?u64 = null;
    var per_page: ?u64 = null;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.UnsafePagination;
        const name = field[0..equals];
        const digits = field[equals + 1 ..];
        if (digits.len == 0) return error.UnsafePagination;
        for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.UnsafePagination;
        const value = std.fmt.parseInt(u64, digits, 10) catch
            return error.UnsafePagination;
        if (std.mem.eql(u8, name, "page") and page == null) {
            page = value;
        } else if (std.mem.eql(u8, name, "per_page") and per_page == null) {
            per_page = value;
        } else return error.UnsafePagination;
    }
    if (page != expected_page or per_page != 100) return error.UnsafePagination;
}

fn nextLink(header: ?[]const u8) !?[]const u8 {
    const value = header orelse return null;
    if (value.len == 0) return null;
    var next: ?[]const u8 = null;
    var links = std.mem.splitScalar(u8, value, ',');
    while (links.next()) |raw| {
        const link = std.mem.trim(u8, raw, " \t");
        if (link.len == 0 or link[0] != '<') return error.InvalidPagination;
        const end = std.mem.indexOfScalar(u8, link, '>') orelse return error.InvalidPagination;
        var parameters = std.mem.splitScalar(u8, link[end + 1 ..], ';');
        if (std.mem.trim(u8, parameters.next().?, " \t").len != 0)
            return error.InvalidPagination;
        var relation: ?[]const u8 = null;
        while (parameters.next()) |parameter| {
            const trimmed = std.mem.trim(u8, parameter, " \t");
            if (std.mem.startsWith(u8, trimmed, "rel=\"")) {
                if (relation != null or trimmed.len < 6 or trimmed[trimmed.len - 1] != '"')
                    return error.InvalidPagination;
                relation = trimmed[5 .. trimmed.len - 1];
            }
        }
        const rel = relation orelse return error.InvalidPagination;
        if (rel.len == 0) return error.InvalidPagination;
        var relations = std.mem.tokenizeAny(u8, rel, " \t");
        while (relations.next()) |kind| {
            if (std.mem.eql(u8, kind, "next")) {
                if (next != null) return error.InvalidPagination;
                next = link[1..end];
            }
        }
    }
    return next;
}
