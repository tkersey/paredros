const std = @import("std");
const protean = @import("protean");
const c = @import("protean_contracts");
const horos = @import("horos");
const native = @import("protean_native");
const t = @import("application_types");
const check = @import("../app/check.zig");
const github = @import("../app/github_contract.zig");
const external = @import("../native/github_external.zig");
const adapter = @import("../native/github_adapter.zig");
const http = @import("../native/http.zig");
const fixtures = @import("contracts.zig");

const Types = struct {
    pub const application_id = "paredros.github.witness";
    pub const application_version = "1.0.0";
    pub const Input = check.Input;
    pub const Output = check.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.github.witness.input.v1";
    pub const output_schema_id = "paredros.github.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.github.witness.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

const Application = struct {
    pub const declarations: []const native.Declaration = &.{declaration()};

    fn declaration() native.Declaration {
        var result = external.declaration();
        result.capture.?.acquire = Scenario.acquire;
        return result;
    }

    pub fn emit(ctx: protean.Context) !horos.source.Module {
        return ctx.author.module(try check.emit(ctx), try ctx.schema(t.Failure));
    }
};

const Fixture = @import("native_fixture.zig").Fixture(Types, Application);
const Phase = enum { repository_before, reference, page_one, page_two, repository_after };

fn oid(value: u32) t.Oid {
    var bytes: t.Oid = @splat('0');
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, value, .big);
    @memcpy(bytes[32..], &std.fmt.bytesToHex(number, .lower));
    return bytes;
}

fn sha(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn phase(request: github.Request) !Phase {
    return switch (request.phase) {
        .repository_before => .repository_before,
        .reference => .reference,
        .repository_after => .repository_after,
        .page => |page| switch (page.ordinal) {
            1 => .page_one,
            2 => .page_two,
            else => error.UnexpectedPage,
        },
    };
}

const Scenario = struct {
    reject_second: bool = false,
    calls: [5]u32 = @splat(0),
    order: [5]Phase = undefined,
    count: usize = 0,
    bodies: [5]?t.Digest = @splat(null),

    fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *Scenario = @ptrCast(@alignCast(ctx.environment orelse
            return error.MissingScenario));
        var request = try c.decodeOwned(github.Request, ctx.allocator, bytes);
        defer request.deinit();
        const selected = try phase(request.value);
        const index = @backingInt(selected);
        if (self.calls[index] != 0 or self.count >= self.order.len)
            return error.DuplicateAcquisition;
        self.calls[index] += 1;
        self.order[self.count] = selected;
        self.count += 1;
        try validateRequest(request.value, selected);
        var prepared = try adapter.prepare(ctx.allocator, request.value);
        defer prepared.deinit();
        const body = try self.responseBody(ctx.allocator, selected);
        defer ctx.allocator.free(body);
        self.bodies[index] = sha(body);
        const head_bytes = try self.headers(ctx.allocator, selected);
        defer ctx.allocator.free(head_bytes);
        const head = try std.http.Client.Response.Head.parse(head_bytes);
        var reader = std.Io.Reader.fixed(body);
        var captured = try http.captureResponse(
            ctx.allocator,
            head,
            &reader,
            .{},
            "fixture-credential-never-transmitted",
        );
        defer captured.deinit();
        return .{ .captured = try external.captureBytes(
            ctx.allocator,
            prepared,
            captured,
            @intCast(self.count * 100),
        ) };
    }

    fn responseBody(self: *Scenario, a: std.mem.Allocator, selected: Phase) ![]u8 {
        return switch (selected) {
            .repository_before, .repository_after => a.dupe(u8, "{\"id\":123}"),
            .reference => std.json.Stringify.valueAlloc(a, .{
                .ref = "refs/heads/main",
                .object = .{ .type = "commit", .sha = @as([]const u8, &oid(2)) },
            }, .{}),
            .page_one => comparison(a, 1),
            .page_two => if (self.reject_second)
                a.dupe(u8, "{\"message\":\"unavailable\"}")
            else
                comparison(a, 2),
        };
    }

    fn headers(self: *Scenario, a: std.mem.Allocator, selected: Phase) ![]u8 {
        const status = if (selected == .page_two and self.reject_second)
            "503 Unavailable"
        else
            "200 OK";
        const prefix = try std.fmt.allocPrint(a, "HTTP/1.1 {s}\r\n" ++
            "Date: Sun, 15 Nov 2026 00:00:00 GMT\r\nContent-Type: application/json\r\n", .{status});
        defer a.free(prefix);
        if (selected != .page_one) return std.fmt.allocPrint(a, "{s}\r\n", .{prefix});
        return std.fmt.allocPrint(a, "{s}Link: <https://api.github.com/repositories/123/compare/" ++
            "{s}...{s}?page=2&per_page=100>; rel=\"next\"\r\n\r\n", .{ prefix, oid(0), oid(2) });
    }
};

fn validateRequest(request: github.Request, selected: Phase) !void {
    try std.testing.expectEqualDeep(fixtures.specification().repository, request.repository);
    if (request.phase != .page) return;
    const page = request.phase.page;
    try std.testing.expectEqual(oid(0), page.base);
    try std.testing.expectEqual(oid(2), page.tip);
    if (selected == .page_one) {
        try std.testing.expectEqual(null, page.url);
        try std.testing.expectEqual(null, page.metadata);
        try std.testing.expectEqual(0, page.seen.items.len);
    } else {
        try std.testing.expect(page.url != null);
        try std.testing.expectEqual(2, page.metadata.?.total_commits);
        try std.testing.expectEqual(1, page.seen.items.len);
        try std.testing.expectEqual(oid(1), page.seen.items[0]);
    }
}

fn comparison(a: std.mem.Allocator, commit: u32) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .status = "ahead",
        .base_commit = .{ .sha = @as([]const u8, &oid(0)) },
        .merge_base_commit = .{ .sha = @as([]const u8, &oid(0)) },
        .ahead_by = @as(u64, 2),
        .behind_by = @as(u64, 0),
        .total_commits = @as(u64, 2),
        .commits = .{.{
            .sha = @as([]const u8, &oid(commit)),
            .commit = .{ .message = "untrusted commit message" },
        }},
    }, .{});
}

fn complete(fixture: *Fixture, work: native.tasks.Work) !void {
    const a = fixture.arena.allocator();
    try std.testing.expectEqualStrings(github.identity, work.entry.declaration.identity);
    const task_id = std.fmt.bytesToHex(work.task, .lower);
    const acquired = try work.entry.declaration.capture.?.acquire(.{
        .allocator = a,
        .io = .failing,
        .authority = &fixture.profile.authority,
        .task_id = &task_id,
        .profile = work.profile,
        .environment = fixture.profile.environment,
    }, work.prepared orelse return error.MissingPrepared);
    if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
    defer a.free(acquired.captured);
    try fixture.service.?.completeWork(a, work, .{ .acquired = acquired.captured });
}

fn drive(fixture: *Fixture, task_id: t.Id, stop_after: ?usize, scenario: *Scenario) !bool {
    const a = fixture.arena.allocator();
    for (0..4096) |_| {
        var task = try fixture.service.?.task(a, task_id);
        defer task.deinit();
        if (task.value.terminal()) return true;
        switch (try fixture.service.?.pump(a)) {
            .work => |work| {
                try complete(fixture, work);
                if (stop_after) |limit| if (scenario.count == limit) return false;
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.CheckDidNotComplete;
}

fn reopen(fixture: *Fixture, task_id: t.Id) !void {
    const a = fixture.arena.allocator();
    try fixture.close();
    try fixture.open();
    try std.testing.expectEqual(.idle, try fixture.service.?.pump(a));
    var task = try fixture.service.?.task(a, task_id);
    defer task.deinit();
    _ = try fixture.service.?.resumeTask(a, "resume-after-capture", task_id, task.value.revision);
}

fn expectEvidence(result: check.Result, scenario: Scenario, count: usize) !void {
    try std.testing.expectEqual(count, result.evidence.items.len);
    for (result.evidence.items, 0..) |evidence, index| {
        const selected = scenario.order[index];
        try std.testing.expectEqual(scenario.bodies[@backingInt(selected)].?, evidence.body_digest);
        try std.testing.expectEqual(@as(i64, @intCast((index + 1) * 100)), evidence.captured_ms);
        try std.testing.expect(evidence.headers.items.len >= 2);
        try std.testing.expectEqualStrings("https://api.github.com", evidence.target.bytes[0..22]);
    }
}

test "native GitHub multipage capture survives restart before interpretation without refetch" {
    var scenario: Scenario = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    try fixture.initWithGrants(&.{github.identity});
    const admitted = try fixture.service.?.submit(fixture.arena.allocator(), "check", .{
        .repository = fixtures.specification().repository,
        .previous = oid(0),
    });
    try std.testing.expect(!try drive(&fixture, admitted.receipt.task, 3, &scenario));
    try std.testing.expectEqual(1, scenario.calls[@backingInt(Phase.page_one)]);
    try std.testing.expectEqual(0, scenario.calls[@backingInt(Phase.page_two)]);
    try reopen(&fixture, admitted.receipt.task);
    try std.testing.expect(try drive(&fixture, admitted.receipt.task, null, &scenario));
    const result = try fixture.output(admitted.receipt.task);
    try std.testing.expectEqual(.complete, result.kind);
    try std.testing.expectEqual(null, result.reason);
    try std.testing.expectEqual(oid(0), result.base.?);
    try std.testing.expectEqual(oid(2), result.tip.?);
    try std.testing.expectEqual(2, result.commits.items.len);
    try std.testing.expectEqual(oid(1), result.commits.items[0].oid);
    try std.testing.expectEqual(oid(2), result.commits.items[1].oid);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1, 1, 1 }, &scenario.calls);
    try std.testing.expectEqualSlices(
        Phase,
        &.{ .repository_before, .reference, .page_one, .page_two, .repository_after },
        &scenario.order,
    );
    try expectEvidence(result, scenario, 5);
}

test "native GitHub later-page rejection retains earlier capture without complete coverage" {
    var scenario: Scenario = .{ .reject_second = true };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    try fixture.initWithGrants(&.{github.identity});
    const admitted = try fixture.service.?.submit(fixture.arena.allocator(), "rejected-check", .{
        .repository = fixtures.specification().repository,
        .previous = oid(0),
    });
    try std.testing.expect(try drive(&fixture, admitted.receipt.task, null, &scenario));
    const result = try fixture.output(admitted.receipt.task);
    try std.testing.expectEqual(.rejected, result.kind);
    try std.testing.expectEqual(github.Failure.unavailable, result.reason.?);
    try std.testing.expectEqual(oid(0), result.base.?);
    try std.testing.expectEqual(oid(2), result.tip.?);
    try std.testing.expectEqual(0, result.commits.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1, 1, 0 }, &scenario.calls);
    try expectEvidence(result, scenario, 4);
}
