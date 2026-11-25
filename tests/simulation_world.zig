const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const app = @import("../native/application.zig");
const github = @import("../app/github_contract.zig");
const external = @import("../native/github_external.zig");
const adapter = @import("../native/github_adapter.zig");
const http = @import("../native/http.zig");
const model = @import("../native/model_external.zig");
const model_contract = @import("../app/model_contract.zig");

pub const commits_max = 4096;
pub const repository_id: u64 = 123;

pub const Application = struct {
    pub const use_product_assets = true;
    const values = declarationsValue();
    pub const declarations: []const native.Declaration = &values;

    fn declarationsValue() [app.Application.declarations.len]native.Declaration {
        var result: [app.Application.declarations.len]native.Declaration = undefined;
        @memcpy(&result, app.Application.declarations);
        for (&result) |*declaration| {
            if (std.mem.eql(u8, declaration.identity, github.identity))
                declaration.capture.?.acquire = World.acquireGithub;
            if (std.mem.eql(u8, declaration.identity, model_contract.P.identity))
                declaration.capture.?.acquire = World.acquireModel;
        }
        return result;
    }
};

pub fn oid(value: u32) t.Oid {
    var bytes: t.Oid = @splat('0');
    var digits: [4]u8 = undefined;
    std.mem.writeInt(u32, &digits, value, .big);
    @memcpy(bytes[32..], &std.fmt.bytesToHex(digits, .lower));
    return bytes;
}

fn number(value: t.Oid) ?u32 {
    for (value[0..32]) |byte| if (byte != '0') return null;
    var raw: [4]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, value[32..]) catch return null;
    return std.mem.readInt(u32, &raw, .big);
}

const GithubFault = enum {
    none,
    not_found,
    retry_after,
    retry_date,
    rate_reset,
    server,
    malformed,
    oversized,
    interrupted,
    unknown,
    not_sent,
};
const ModelFault = enum { none, malformed, refusal, server, garbage, unknown, not_sent };

pub const Calls = struct { github: u64 = 0, model: u64 = 0, faults: u64 = 0 };

pub const World = struct {
    prng: std.Random.DefaultPrng,
    wall_ms: *const i64,
    calm: bool = false,
    parents: [commits_max]u32 = @splat(0),
    created: u32 = 1,
    tip: u32 = 1,
    calls: Calls = .{},

    pub fn init(seed: u64, wall_ms: *const i64) World {
        return .{ .prng = .init(seed ^ 0x9e3779b97f4a7c15), .wall_ms = wall_ms };
    }

    fn random(self: *World) std.Random {
        return self.prng.random();
    }

    fn chance(self: *World, percent: u8) bool {
        return self.random().uintLessThan(u8, 100) < percent;
    }

    fn commit(self: *World, parent: u32) ?u32 {
        if (self.created + 1 >= commits_max) return null;
        self.created += 1;
        self.parents[self.created] = parent;
        return self.created;
    }

    pub fn evolve(self: *World) void {
        const roll = self.random().uintLessThan(u8, 100);
        if (roll < 40) {
            for (0..self.random().intRangeAtMost(u8, 1, 4)) |_|
                self.tip = self.commit(self.tip) orelse return;
        } else if (roll < 45) {
            if (self.parents[self.tip] != 0) self.tip = self.parents[self.tip];
        } else if (roll < 50) {
            const base = if (self.parents[self.tip] != 0) self.parents[self.tip] else self.tip;
            self.tip = self.commit(base) orelse return;
        }
    }

    pub fn divergeFrom(self: *World, observed: t.Oid) void {
        const seen = number(observed) orelse return;
        if (seen == 0 or seen >= commits_max) return;
        self.tip = self.commit(self.parents[seen]) orelse return;
    }

    fn ancestor(self: *const World, older: u32, newer: u32) bool {
        var cursor = newer;
        for (0..commits_max) |_| {
            if (cursor == older) return true;
            if (cursor == 0) return false;
            cursor = self.parents[cursor];
        }
        return false;
    }

    fn mergeBase(self: *const World, left: u32, right: u32) u32 {
        var cursor = left;
        for (0..commits_max) |_| {
            if (cursor == 0 or self.ancestor(cursor, right)) return cursor;
            cursor = self.parents[cursor];
        }
        return 0;
    }

    fn githubFault(self: *World) GithubFault {
        if (self.calm or !self.chance(18)) return .none;
        const faults = std.enums.values(GithubFault)[1..];
        return faults[self.random().uintLessThan(usize, faults.len)];
    }

    fn modelFault(self: *World) ModelFault {
        if (self.calm or !self.chance(20)) return .none;
        const faults = std.enums.values(ModelFault)[1..];
        return faults[self.random().uintLessThan(usize, faults.len)];
    }

    pub fn acquireGithub(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *World = @ptrCast(@alignCast(ctx.environment orelse return error.NoWorld));
        self.calls.github += 1;
        var request = try c.decodeOwned(github.Request, ctx.allocator, bytes);
        defer request.deinit();
        if (request.value.phase == .reference and !self.calm) self.evolve();
        const fault = self.githubFault();
        if (fault != .none) self.calls.faults += 1;
        switch (fault) {
            .unknown => return .{ .unknown = error.SimulatedInterruption },
            .not_sent => return .{ .definitely_not_sent = error.SimulatedRefusal },
            else => {},
        }
        var prepared = try adapter.prepare(ctx.allocator, request.value);
        defer prepared.deinit();
        if (fault == .oversized or fault == .interrupted) {
            return .{ .captured = try c.encodeOwned(external.Capture, ctx.allocator, .{
                .refused = .{ .request_digest = prepared.request_digest, .refused = .{
                    .status = 200,
                    .refusal = if (fault == .oversized) .body_capacity else .body_interrupted,
                } },
            }) };
        }
        const body = try self.githubBody(ctx.allocator, request.value, fault);
        defer ctx.allocator.free(body);
        const head_bytes = try self.githubHead(ctx.allocator, fault);
        defer ctx.allocator.free(head_bytes);
        const head = try std.http.Client.Response.Head.parse(head_bytes);
        var reader = std.Io.Reader.fixed(body);
        var captured = try http.captureResponse(ctx.allocator, head, &reader, .{}, "unused");
        defer captured.deinit();
        return .{ .captured = try external.captureBytes(
            ctx.allocator,
            prepared,
            captured,
            self.wall_ms.*,
        ) };
    }

    fn githubHead(self: *World, a: std.mem.Allocator, fault: GithubFault) ![]u8 {
        const status = switch (fault) {
            .not_found => "404 Not Found",
            .retry_after, .retry_date => "429 Too Many Requests",
            .rate_reset => "403 Forbidden",
            .server => "503 Service Unavailable",
            else => "200 OK",
        };
        const extra = switch (fault) {
            .retry_after => try std.fmt.allocPrint(
                a,
                "Retry-After: {d}\r\n",
                .{self.random().intRangeAtMost(u32, 1, 7200)},
            ),
            .retry_date => try a.dupe(u8, "Retry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n"),
            .rate_reset => try std.fmt.allocPrint(
                a,
                "X-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: {d}\r\n",
                .{@divFloor(self.wall_ms.*, 1000) + self.random().intRangeAtMost(i64, 1, 3600)},
            ),
            else => try a.dupe(u8, ""),
        };
        defer a.free(extra);
        return std.fmt.allocPrint(a, "HTTP/1.1 {s}\r\nDate: Sun, 15 Nov 2026 00:00:00 GMT\r\n" ++
            "Content-Type: application/json\r\n{s}\r\n", .{ status, extra });
    }

    fn githubBody(
        self: *World,
        a: std.mem.Allocator,
        request: github.Request,
        fault: GithubFault,
    ) ![]u8 {
        if (fault == .malformed) return a.dupe(u8, "{\"id\":");
        if (fault != .none) return a.dupe(u8, "{\"message\":\"unavailable\"}");
        return switch (request.phase) {
            .repository_before, .repository_after => std.fmt.allocPrint(
                a,
                "{{\"id\":{d}}}",
                .{repository_id},
            ),
            .reference => std.json.Stringify.valueAlloc(a, .{
                .ref = request.repository.ref.bytes,
                .object = .{ .type = "commit", .sha = @as([]const u8, &oid(self.tip)) },
            }, .{}),
            .page => |page| self.comparison(a, page),
        };
    }

    fn comparison(self: *World, a: std.mem.Allocator, page: github.Page) ![]u8 {
        const base = number(page.base) orelse 0;
        const tip = number(page.tip) orelse 0;
        const merge = self.mergeBase(base, tip);
        const Commit = struct { sha: []const u8, commit: struct { message: []const u8 } };
        var commits: std.ArrayList(Commit) = .empty;
        defer commits.deinit(a);
        var cursor = tip;
        for (0..100) |_| {
            if (cursor == merge or cursor == 0) break;
            try commits.insert(a, 0, .{
                .sha = try a.dupe(u8, &oid(cursor)),
                .commit = .{ .message = "simulated commit" },
            });
            cursor = self.parents[cursor];
        }
        defer for (commits.items) |item| a.free(item.sha);
        var behind: u64 = 0;
        cursor = base;
        for (0..commits_max) |_| {
            if (cursor == merge or cursor == 0) break;
            behind += 1;
            cursor = self.parents[cursor];
        }
        const ahead: u64 = commits.items.len;
        const status = if (behind == 0) "ahead" else if (ahead == 0) "behind" else "diverged";
        return std.json.Stringify.valueAlloc(a, .{
            .status = status,
            .base_commit = .{ .sha = @as([]const u8, &page.base) },
            .merge_base_commit = .{ .sha = @as([]const u8, &oid(merge)) },
            .ahead_by = ahead,
            .behind_by = behind,
            .total_commits = ahead,
            .commits = commits.items,
        }, .{});
    }

    pub fn acquireModel(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *World = @ptrCast(@alignCast(ctx.environment orelse return error.NoWorld));
        self.calls.model += 1;
        var prepared = try c.decodeOwned(model.Adapter.Prepared, ctx.allocator, bytes);
        defer prepared.deinit();
        const conversation = prepared.value.request.offered[1];
        const fault = self.modelFault();
        if (fault != .none) self.calls.faults += 1;
        switch (fault) {
            .unknown => return .{ .unknown = error.SimulatedInterruption },
            .not_sent => return .{ .definitely_not_sent = error.SimulatedRefusal },
            else => {},
        }
        const body = try self.modelBody(ctx.allocator, conversation, fault);
        defer ctx.allocator.free(body);
        return .{ .captured = try c.encodeOwned(model.Raw, ctx.allocator, .{
            .status = if (fault == .server) 500 else 200,
            .identity_encoding = true,
            .request_id = .{ .bytes = "simulated-request" },
            .body = .{ .bytes = body },
            .format = .json,
            .media_type = .{ .bytes = "application/json" },
        }) };
    }

    fn modelBody(self: *World, a: std.mem.Allocator, conversation: bool, fault: ModelFault) ![]u8 {
        if (fault == .garbage or fault == .server) return a.dupe(u8, "{\"error\":");
        if (fault == .refusal) return a.dupe(u8, "{\"id\":\"r\",\"status\":\"completed\"," ++
            "\"error\":null,\"output\":[{\"type\":\"message\",\"status\":\"completed\"," ++
            "\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}");
        const arguments = if (fault == .malformed)
            try a.dupe(u8, "{\"summary\":7,\"highlights\":[]}")
        else if (conversation)
            try self.converse(a)
        else
            try a.dupe(u8, "{\"summary\":\"Simulated digest\",\"highlights\":[]}");
        defer a.free(arguments);
        return std.json.Stringify.valueAlloc(a, .{
            .id = "simulated-response",
            .status = "completed",
            .@"error" = @as(?u8, null),
            .output = .{.{
                .type = "function_call",
                .status = "completed",
                .id = "fc-simulated",
                .call_id = "call-simulated",
                .name = if (conversation) "converse" else "summarize",
                .arguments = arguments,
            }},
            .usage = .{ .input_tokens = @as(u64, 20), .output_tokens = @as(u64, 10) },
        }, .{});
    }

    fn converse(self: *World, a: std.mem.Allocator) ![]u8 {
        return switch (self.random().uintLessThan(u8, 5)) {
            0 => a.dupe(u8, "{\"reply\":\"Nothing to change.\",\"proposals\":[]}"),
            1 => a.dupe(u8, "{\"reply\":\"Offered.\",\"proposals\":[" ++
                "{\"tag\":\"select_proposal\",\"value\":{\"index\":0}}]}"),
            2 => std.fmt.allocPrint(a, "{{\"reply\":\"Amend.\",\"proposals\":[" ++
                "{{\"tag\":\"propose_amend\",\"value\":{{\"interval_ms\":{d}," ++
                "\"wording\":\"Concise\",\"policies\":null,\"repository_route\":null}}}}]}}", .{
                self.random().intRangeAtMost(u64, 60_000, 3_600_000),
            }),
            3 => std.fmt.allocPrint(a, "{{\"reply\":\"New monitor.\",\"proposals\":[" ++
                "{{\"tag\":\"propose_genesis\",\"value\":{{\"interval_ms\":{d}," ++
                "\"wording\":\"Fresh\",\"policies\":{s}}}}}]}}", .{
                self.random().intRangeAtMost(u64, 60_000, 3_600_000),
                try std.json.Stringify.valueAlloc(a, t.Policies{}, .{}),
            }),
            else => a.dupe(u8, "{\"reply\":\"Two.\",\"proposals\":[" ++
                "{\"tag\":\"select_proposal\",\"value\":{\"index\":0}}," ++
                "{\"tag\":\"select_proposal\",\"value\":{\"index\":1}}]}"),
        };
    }
};
