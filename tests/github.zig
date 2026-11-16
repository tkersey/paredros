const std = @import("std");
const github = @import("../native/github.zig");
const a = std.testing.allocator;
const binding: github.Binding = .{
    .repository_id = 123,
    .owner = "owner",
    .name = "repository",
    .ref = "refs/heads/main",
};
const repository: github.Response = .{
    .status = 200,
    .body = "{\"id\":123,\"full_name\":\"owner/repository\"}",
};
const Changes = struct {
    status: []const u8 = "ahead",
    base: u32 = 0,
    merge_base: u32 = 0,
    ahead: ?u64 = null,
    behind: u64 = 0,
};

fn oid(number: u32) !github.Oid {
    var bytes: github.Oid = undefined;
    _ = try std.fmt.bufPrint(&bytes, "{x:0>40}", .{number});
    return bytes;
}

fn reference(allocator: std.mem.Allocator, tip: u32) !github.Response {
    const tip_oid = try oid(tip);
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(allocator, .{
        .ref = binding.ref,
        .object = .{ .type = "commit", .sha = @as([]const u8, &tip_oid) },
    }, .{}) };
}

fn accumulator(allocator: std.mem.Allocator, tip: u32) !github.Accumulator {
    const ref = try reference(allocator, tip);
    defer allocator.free(ref.body);
    return github.Accumulator.init(allocator, binding, try oid(0), repository, ref);
}

fn page(
    allocator: std.mem.Allocator,
    start: u32,
    count: u32,
    total: u64,
    changes: Changes,
) !github.Response {
    const Record = struct { sha: []const u8, commit: struct { message: []const u8 } };
    const records = try allocator.alloc(Record, count);
    defer allocator.free(records);
    const ids = try allocator.alloc(github.Oid, count);
    defer allocator.free(ids);
    for (records, ids, 0..) |*record, *id, index| {
        id.* = try oid(start + @as(u32, @intCast(index)));
        record.* = .{ .sha = id, .commit = .{
            .message = "Untrusted commit text: <https://unexpected.invalid/> @everyone",
        } };
    }
    const base = try oid(changes.base);
    const merge_base = try oid(changes.merge_base);
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(allocator, .{
        .status = changes.status,
        .base_commit = .{ .sha = @as([]const u8, &base) },
        .merge_base_commit = .{ .sha = @as([]const u8, &merge_base) },
        .ahead_by = changes.ahead orelse total,
        .behind_by = changes.behind,
        .total_commits = total,
        .commits = records,
        .files = .{.{ .filename = "not-coverage-evidence" }},
    }, .{}) };
}

fn link(allocator: std.mem.Allocator, tip: u32, next: u64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "<https://api.github.com/repositories/123/compare/{s}...{s}" ++
            "?page={d}&per_page=100>; rel=\"next\"",
        .{ try oid(0), try oid(tip), next },
    );
}

test "github acquires more than 250 commits with frozen comparison and owned evidence" {
    var fixtures = std.heap.ArenaAllocator.init(a);
    defer fixtures.deinit();
    var scan = try accumulator(a, 301);
    defer scan.deinit();
    for (0..4) |index| {
        const start: u32 = @intCast(index * 100 + 1);
        var response = try page(fixtures.allocator(), start, if (index == 3) 1 else 100, 301, .{});
        if (index < 3) response.link = try link(fixtures.allocator(), 301, index + 2);
        try scan.appendPage(scan.nextRequest().?, response);
    }
    try std.testing.expect(scan.nextRequest() == null);
    var complete = try scan.finish(repository);
    defer complete.deinit();
    fixtures.deinit();
    fixtures = std.heap.ArenaAllocator.init(a);
    try std.testing.expectEqual(301, complete.commits.len);
    try std.testing.expectEqual(4, complete.pages.len);
    try std.testing.expectEqualSlices(u8, &try oid(301), &complete.tip);
    for (complete.commits, 1..) |commit, index| {
        try std.testing.expectEqualSlices(u8, &try oid(@intCast(index)), &commit.oid);
        try std.testing.expectEqualStrings(
            "Untrusted commit text: <https://unexpected.invalid/> @everyone",
            commit.untrusted_message,
        );
    }
    try std.testing.expect(std.mem.indexOf(u8, complete.pages[0].body, "files") != null);
    try std.testing.expectEqualStrings("2026-03-10", github.api_version);
}

test "github same sampled head completes only after both identity checks" {
    var scan = try accumulator(a, 0);
    defer scan.deinit();
    try std.testing.expect(scan.nextRequest() == null);
    var complete = try scan.finish(repository);
    defer complete.deinit();
    try std.testing.expectEqual(0, complete.commits.len);
    try std.testing.expectEqual(0, complete.pages.len);
    var reused = try accumulator(a, 0);
    defer reused.deinit();
    try std.testing.expectError(error.RepositoryIdentityMismatch, reused.finish(.{
        .status = 200,
        .body = "{\"id\":456}",
    }));
    try std.testing.expectError(error.AcquisitionFailed, reused.finish(repository));
}

test "github rejects provider cap mismatch despite a requested tip" {
    var scan = try accumulator(a, 10000);
    defer scan.deinit();
    const response = try page(a, 10000, 1, 10000, .{ .ahead = 18404 });
    defer a.free(response.body);
    try std.testing.expectError(
        error.IncompleteComparison,
        scan.appendPage(scan.nextRequest().?, response),
    );
    try std.testing.expectError(error.AcquisitionFailed, scan.finish(repository));
}

test "github later page failures and changing counts cannot publish partial batches" {
    for ([_]u16{ 403, 404, 429, 500, 304, 200 }) |status| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        var scan = try accumulator(a, 2);
        defer scan.deinit();
        var first = try page(fixtures.allocator(), 1, 1, 2, .{});
        first.link = try link(fixtures.allocator(), 2, 2);
        try scan.appendPage(scan.nextRequest().?, first);
        var second = try page(fixtures.allocator(), 2, 1, 3, .{});
        second.status = status;
        const expected = switch (status) {
            200 => error.InconsistentMetadata,
            304 => error.MissingRetainedResponse,
            else => error.UnsuccessfulResponse,
        };
        try std.testing.expectError(expected, scan.appendPage(scan.nextRequest().?, second));
        try std.testing.expectError(error.AcquisitionFailed, scan.finish(repository));
    }
}

test "github explicit interruption cannot turn retained pages into a complete batch" {
    var scan = try accumulator(a, 2);
    defer scan.deinit();
    const response = try page(a, 1, 1, 2, .{});
    defer a.free(response.body);
    try scan.appendPage(scan.nextRequest().?, response);
    scan.abort();
    try std.testing.expectError(error.AcquisitionFailed, scan.finish(repository));
}

test "github incomplete totals missing tip duplicate commit and base inclusion reject" {
    for (0..4) |scenario| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        var scan = try accumulator(a, 2);
        defer scan.deinit();
        if (scenario == 0 or scenario == 1) {
            const response = try page(fixtures.allocator(), 3, if (scenario == 0) 1 else 2, 2, .{});
            try scan.appendPage(scan.nextRequest().?, response);
            try std.testing.expectError(error.IncompleteComparison, scan.finish(repository));
        } else if (scenario == 2) {
            var first = try page(fixtures.allocator(), 1, 1, 2, .{});
            first.link = try link(fixtures.allocator(), 2, 2);
            try scan.appendPage(scan.nextRequest().?, first);
            const repeated = try page(fixtures.allocator(), 1, 1, 2, .{});
            try std.testing.expectError(
                error.DuplicateCommit,
                scan.appendPage(scan.nextRequest().?, repeated),
            );
        } else {
            const response = try page(fixtures.allocator(), 0, 2, 2, .{});
            try std.testing.expectError(
                error.BaseIncluded,
                scan.appendPage(scan.nextRequest().?, response),
            );
        }
    }
}

test "github divergence rewind and changed merge base remain incomplete" {
    const cases = [_]Changes{
        .{ .status = "behind" },
        .{ .status = "diverged" },
        .{ .base = 7 },
        .{ .merge_base = 7 },
        .{ .behind = 1 },
    };
    for (cases) |change| {
        var scan = try accumulator(a, 1);
        defer scan.deinit();
        const response = try page(a, 1, 1, 1, change);
        defer a.free(response.body);
        try std.testing.expectError(
            error.RewrittenHistory,
            scan.appendPage(scan.nextRequest().?, response),
        );
        try std.testing.expectError(error.AcquisitionFailed, scan.finish(repository));
    }
}

test "github pre and post identity binding reject name reuse" {
    const ref = try reference(a, 1);
    defer a.free(ref.body);
    const changed: github.Response = .{ .status = 200, .body = "{\"id\":456}" };
    try std.testing.expectError(
        error.RepositoryIdentityMismatch,
        github.Accumulator.init(a, binding, try oid(0), changed, ref),
    );
    var scan = try accumulator(a, 1);
    defer scan.deinit();
    const response = try page(a, 1, 1, 1, .{});
    defer a.free(response.body);
    try scan.appendPage(scan.nextRequest().?, response);
    try std.testing.expectError(error.RepositoryIdentityMismatch, scan.finish(changed));
}

test "github exact ref commit type full OID and retained response are required" {
    const good =
        \\{"ref":"refs/heads/main","object":{"type":"commit",
        \\"sha":"0123456789abcdef0123456789abcdef01234567"}}
    ;
    const parsed = try github.referenceOid(a, binding.ref, .{ .status = 200, .body = good });
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", &parsed);
    try std.testing.expectError(
        error.ReferenceMismatch,
        github.referenceOid(a, "refs/heads/main/child", .{ .status = 200, .body = good }),
    );
    try std.testing.expectError(
        error.UnsuccessfulResponse,
        github.referenceOid(a, binding.ref, .{ .status = 404, .body = "{}" }),
    );
    try std.testing.expectError(
        error.MissingRetainedResponse,
        github.referenceOid(a, binding.ref, .{ .status = 304, .body = good }),
    );
    try std.testing.expectError(error.UnsupportedObjectFormat, github.parseOid("abc123"));
    try std.testing.expectError(error.InvalidOid, github.parseOid(&@as([40]u8, @splat('z'))));
    for ([_][]const u8{
        "main",
        "refs/tags/v1",
        "refs/heads/",
        "refs/heads/a..b",
        "refs/heads/.hidden",
        "refs/heads/a.lock",
        "refs/heads/a/",
        "refs/heads/a//b",
        "refs/heads/a@{b",
        "refs/heads/a b",
        "refs/heads/a?b",
        "refs/heads/a.",
    }) |invalid| try std.testing.expectError(error.InvalidRef, github.validateRef(invalid));
    const path = try github.referencePath(a, "refs/heads/feature/é%#");
    defer a.free(path);
    try std.testing.expectEqualStrings("heads/feature/%C3%A9%25%23", path);
    try github.validateRef("refs/heads/foo./bar");
}

test "github pagination refuses new tip cross host wrong repository and wrong page" {
    const variants = [_][]const u8{
        "https://unexpected.invalid/repositories/123/compare/{s}...{s}?page=2&per_page=100",
        "https://api.github.com.evil/repositories/123/compare/{s}...{s}?page=2&per_page=100",
        "https://api.github.com/repositories/456/compare/{s}...{s}?page=2&per_page=100",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=3&per_page=100",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=2&per_page=250",
        "https://api.github.com/repositories/123/compare/{s}...{s}?page=2&per_page=100#ignored",
    };
    inline for (variants) |pattern| {
        var fixtures = std.heap.ArenaAllocator.init(a);
        defer fixtures.deinit();
        var scan = try accumulator(a, 2);
        defer scan.deinit();
        var response = try page(fixtures.allocator(), 1, 1, 2, .{});
        const url = try std.fmt.allocPrint(
            fixtures.allocator(),
            pattern,
            .{ try oid(0), try oid(2) },
        );
        response.link = try std.fmt.allocPrint(fixtures.allocator(), "<{s}>; rel=\"next\"", .{url});
        try std.testing.expectError(
            error.UnsafePagination,
            scan.appendPage(scan.nextRequest().?, response),
        );
    }
    var scan = try accumulator(a, 2);
    defer scan.deinit();
    var response = try page(a, 1, 1, 2, .{});
    defer a.free(response.body);
    response.link = try link(a, 3, 2);
    defer a.free(response.link.?);
    try std.testing.expectError(
        error.UnsafePagination,
        scan.appendPage(scan.nextRequest().?, response),
    );
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var scan = try accumulator(allocator, 1);
    defer scan.deinit();
    const response = try page(allocator, 1, 1, 1, .{});
    defer allocator.free(response.body);
    try scan.appendPage(scan.nextRequest().?, response);
    var complete = try scan.finish(repository);
    defer complete.deinit();
}

test "github partial allocations and transferred batch storage have one owner" {
    try std.testing.checkAllAllocationFailures(a, allocationPath, .{});
}

test "github malformed source JSON unsupported objects and unknown status are incomplete" {
    const wrong_object =
        \\{"ref":"refs/heads/main","object":{"type":"tag",
        \\"sha":"0123456789abcdef0123456789abcdef01234567"}}
    ;
    try std.testing.expectError(
        error.UnsupportedObjectType,
        github.referenceOid(a, binding.ref, .{ .status = 200, .body = wrong_object }),
    );
    try std.testing.expectError(
        error.UnsupportedObjectFormat,
        github.parseOid(&@as([64]u8, @splat('a'))),
    );
    for ([_][]const u8{ "identical", "unexpected-status" }) |status| {
        var scan = try accumulator(a, 1);
        defer scan.deinit();
        const response = try page(a, 1, 1, 1, .{ .status = status });
        defer a.free(response.body);
        try std.testing.expectError(
            error.IncompleteComparison,
            scan.appendPage(scan.nextRequest().?, response),
        );
    }
    var scan = try accumulator(a, 1);
    defer scan.deinit();
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        scan.appendPage(scan.nextRequest().?, .{ .status = 200, .body = "{" }),
    );
    try std.testing.expectError(error.AcquisitionFailed, scan.finish(repository));
}

test "github incomplete pagination and substituted request cannot finish" {
    for (0..4) |scenario| {
        var scan = try accumulator(a, 2);
        defer scan.deinit();
        var response = try page(a, 1, 1, 2, .{});
        defer a.free(response.body);
        const next = try link(a, 2, 2);
        defer a.free(next);
        const duplicate = try std.fmt.allocPrint(a, "{s}, {s}", .{ next, next });
        defer a.free(duplicate);
        response.link = if (scenario == 1) duplicate else next;
        if (scenario == 0) {
            try scan.appendPage(scan.nextRequest().?, response);
            try std.testing.expectError(error.IncompleteComparison, scan.finish(repository));
        } else if (scenario == 1) {
            try std.testing.expectError(
                error.InvalidPagination,
                scan.appendPage(scan.nextRequest().?, response),
            );
        } else if (scenario == 2) {
            try std.testing.expectError(
                error.ComparisonChanged,
                scan.appendPage("https://api.github.com/repos/other/repo", response),
            );
        } else {
            response.link = "<https://api.github.com/>; rel=\"\"";
            try std.testing.expectError(
                error.InvalidPagination,
                scan.appendPage(scan.nextRequest().?, response),
            );
        }
        try std.testing.expectError(error.AcquisitionFailed, scan.finish(repository));
    }
}
