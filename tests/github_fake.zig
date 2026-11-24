const std = @import("std");
const Native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const github = @import("../app/github_contract.zig");
const external = @import("../native/github_external.zig");
const adapter = @import("../native/github_adapter.zig");
const http = @import("../native/http.zig");

pub const Application = struct {
    pub const use_product_assets = true;
    const declaration_values = declarationsValue();
    pub const declarations: []const Native.Declaration = &declaration_values;

    fn declarationsValue() [app.Application.declarations.len]Native.Declaration {
        var result: [app.Application.declarations.len]Native.Declaration = undefined;
        @memcpy(&result, app.Application.declarations);
        for (&result) |*declaration| {
            if (std.mem.eql(u8, declaration.identity, github.identity))
                declaration.capture.?.acquire = Source.acquire;
        }
        return result;
    }
};

pub fn oid(value: u32) t.Oid {
    var bytes: t.Oid = @splat('0');
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, value, .big);
    @memcpy(bytes[32..], &std.fmt.bytesToHex(number, .lower));
    return bytes;
}

pub const Source = struct {
    tip: u32 = 1,
    ahead: bool = false,

    fn acquire(ctx: Native.Context, bytes: []const u8) !Native.registry.Acquisition {
        const self: *Source = @ptrCast(@alignCast(ctx.environment orelse
            return error.MissingSource));
        var request = try c.decodeOwned(github.Request, ctx.allocator, bytes);
        defer request.deinit();
        var prepared = try adapter.prepare(ctx.allocator, request.value);
        defer prepared.deinit();
        const reply = try self.response(ctx.allocator, request.value);
        defer ctx.allocator.free(reply);
        const head = try std.http.Client.Response.Head.parse("HTTP/1.1 200 OK\r\n" ++
            "Date: Sun, 15 Nov 2026 00:00:00 GMT\r\nContent-Type: application/json\r\n\r\n");
        var reader = std.Io.Reader.fixed(reply);
        var captured = try http.captureResponse(ctx.allocator, head, &reader, .{}, "unused");
        defer captured.deinit();
        return .{ .captured = try external.captureBytes(ctx.allocator, prepared, captured, 100) };
    }

    fn response(self: *const Source, a: std.mem.Allocator, request: github.Request) ![]u8 {
        return switch (request.phase) {
            .repository_before, .repository_after => a.dupe(u8, "{\"id\":123}"),
            .reference => std.json.Stringify.valueAlloc(a, .{
                .ref = "refs/heads/main",
                .object = .{ .type = "commit", .sha = @as([]const u8, &oid(self.tip)) },
            }, .{}),
            .page => std.json.Stringify.valueAlloc(a, .{
                .status = if (self.ahead) "ahead" else "diverged",
                .base_commit = .{ .sha = @as([]const u8, &oid(1)) },
                .merge_base_commit = .{ .sha = @as([]const u8, &oid(if (self.ahead) 1 else 0)) },
                .ahead_by = @as(u64, 1),
                .behind_by = @as(u64, if (self.ahead) 0 else 1),
                .total_commits = @as(u64, 1),
                .commits = .{.{
                    .sha = @as([]const u8, &oid(self.tip)),
                    .commit = .{ .message = if (self.ahead) "new commit" else "rewritten history" },
                }},
            }, .{}),
        };
    }
};

pub const Clock = struct {
    now_ms: i64 = 200,

    pub fn now(context: *anyopaque) !i64 {
        const self: *Clock = @ptrCast(@alignCast(context));
        return self.now_ms;
    }
};

pub fn drive(f: anytype, task: t.Id) !void {
    const a = f.arena.allocator();
    for (0..4096) |_| {
        var saved = try f.service.?.task(a, task);
        defer saved.deinit();
        if (saved.value.terminal()) return;
        switch (try f.service.?.pump(a)) {
            .work => |work| {
                const id = std.fmt.bytesToHex(work.task, .lower);
                const acquired = try work.entry.declaration.capture.?.acquire(.{
                    .allocator = a,
                    .io = .failing,
                    .authority = &f.profile.authority,
                    .task_id = &id,
                    .profile = work.profile,
                    .environment = f.profile.environment,
                }, work.prepared orelse return error.MissingPrepared);
                if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
                try f.service.?.completeWork(a, work, .{ .acquired = acquired.captured });
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.TaskDidNotComplete;
}

pub fn settle(f: anytype, driver: anytype, target: t.Id) !void {
    const a = f.arena.allocator();
    for (0..16) |_| {
        try drive(f, (try driver.nextStep(a, target)) orelse return);
    }
    return error.StepsDidNotSettle;
}
