const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const audit = @import("../app/audit.zig");
const contract = @import("../app/audit_contract.zig");
const external = @import("../native/slack_audit_external.zig");
const preparation = @import("../native/delivery_prepare.zig");
const http = @import("../native/http.zig");
const a = std.testing.allocator;
const destination: t.Destination = .{
    .account = .{ .bytes = "slack-test" },
    .app = .{ .bytes = "A1" },
    .workspace = .{ .bytes = "T1" },
    .operator = .{ .bytes = "U1" },
    .channel = .{ .bytes = "D1" },
};
const producer: t.Reference = .{ .task = @splat(1), .digest = @splat(2) };

fn delivery(allocator: std.mem.Allocator, identity: u8) !c.Decoded(t.Delivery) {
    return preparation.materialize(allocator, .{
        .destination = destination,
        .key = .{
            .lineage = @splat(3),
            .purpose = .activation,
            .identity = @splat(identity),
            .generation = 1,
        },
        .payload = .{
            .obligation = null,
            .specification_revision = 1,
            .prior_sequence = 0,
            .through_sequence = 0,
            .frozen_text = .{ .bytes = "Frozen notice" },
            .prompt = null,
            .supersedes = null,
        },
    }, producer, @splat(4), "B1");
}

fn input(allocator: std.mem.Allocator, canary: bool) !c.Decoded(t.Audit) {
    var selected = try delivery(allocator, 5);
    defer selected.deinit();
    var prior = try delivery(allocator, 6);
    defer prior.deinit();
    const bytes = try c.encodeOwned(t.Audit, allocator, .{
        .envelope = .{
            .operation = .{ .bytes = "audit" },
            .stable_request = @splat(7),
            .origin = .{ .derived = .{ .predecessor = producer } },
        },
        .delivery = selected.value,
        .ordinal = 1,
        .oldest = .{ .bytes = "100.000001" },
        .latest = .{ .bytes = "200.000001" },
        .page_limit = 4,
        .canary = if (canary) .{
            .receipt = .{
                .key = prior.value.key,
                .destination = destination,
                .timestamp = .{ .bytes = "100.000001" },
                .payload_digest = prior.value.payload.content_digest,
                .evidence = producer,
                .basis = .captured_response,
            },
            .admitted = prior.value,
        } else null,
    });
    defer allocator.free(bytes);
    return c.decodeOwned(t.Audit, allocator, bytes);
}

fn body(
    allocator: std.mem.Allocator,
    value: ?t.Delivery,
    timestamp: []const u8,
    cursor: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var messages: std.ArrayList(std.json.Value) = .empty;
    if (value) |selected| {
        const wire = try std.json.parseFromSlice(
            std.json.Value,
            scratch,
            selected.payload.wire_json.bytes,
            .{},
        );
        const encoded = try std.json.Stringify.valueAlloc(scratch, .{
            .type = "message",
            .app_id = "A1",
            .bot_id = "B1",
            .team = "T1",
            .ts = timestamp,
            .metadata = wire.value.object.get("metadata").?,
        }, .{});
        const message = try std.json.parseFromSlice(std.json.Value, scratch, encoded, .{});
        try messages.append(scratch, message.value);
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = true,
        .messages = messages.items,
        .has_more = false,
        .response_metadata = .{ .next_cursor = cursor },
    }, .{});
}

fn capture(
    allocator: std.mem.Allocator,
    request: contract.Request,
    response: []const u8,
    status: u16,
) ![]u8 {
    const bytes = try c.encodeOwned(contract.Request, allocator, request);
    defer allocator.free(bytes);
    const headers = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} Test\r\n" ++
        "Content-Type: application/json\r\nDate: Mon, 16 Nov 2026 00:00:00 GMT\r\n" ++
        "X-Slack-Req-Id: audit-page\r\nRetry-After: 30\r\n\r\n", .{status});
    defer allocator.free(headers);
    const head = try std.http.Client.Response.Head.parse(headers);
    var reader = std.Io.Reader.fixed(response);
    var retained = try http.captureResponse(allocator, head, &reader, .{}, "secret-never-retained");
    defer retained.deinit();
    return external.captureBytes(allocator, bytes, "B1", retained, 1234);
}

var source: u8 = 0;
fn noObject(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: native.registry.ObjectReference,
    _: usize,
) ![]u8 {
    return error.UnexpectedObjectRead;
}

fn interpret(request: contract.Request, captured: []const u8) !c.Decoded(contract.Reply) {
    const bytes = try c.encodeOwned(contract.Request, a, request);
    defer a.free(bytes);
    const result = try external.interpret(.{
        .allocator = a,
        .task = @splat(1),
        .tenant = "test",
        .profile = "test",
        .objects = .{ .source = &source, .read_object = noObject },
    }, bytes, bytes, captured);
    defer a.free(result.reply);
    return c.decodeOwned(contract.Reply, a, result.reply);
}

test "native Slack audit moving window omits invented upper timestamp and retains positive match" {
    var frozen = try input(a, false);
    defer frozen.deinit();
    frozen.value.latest = null;
    const request: contract.Request = .{ .audit = frozen.value, .pages = .{ .items = &.{} } };
    const url = try external.requestTarget(a, request, "B1");
    defer a.free(url);
    try std.testing.expect(std.mem.find(u8, url, "latest=") == null);
    try std.testing.expect(std.mem.find(u8, url, "oldest=100.000001") != null);
    const timestamp = "9007199254740993.000001";
    const response = try body(a, frozen.value.delivery, timestamp, "");
    defer a.free(response);
    const bytes = try capture(a, request, response, 200);
    defer a.free(bytes);
    var result = try interpret(request, bytes);
    defer result.deinit();
    try std.testing.expectEqualStrings(timestamp, result.value.done.found.timestamp.bytes);
}

test "native Slack audit moving absence and exhausted page budget preserve uncertainty" {
    var frozen = try input(a, true);
    defer frozen.deinit();
    frozen.value.latest = null;
    var request: contract.Request = .{ .audit = frozen.value, .pages = .{ .items = &.{} } };
    const canary = frozen.value.canary.?.admitted;
    const response = try body(a, canary, "100.000001", "");
    defer a.free(response);
    const bytes = try capture(a, request, response, 200);
    defer a.free(bytes);
    var result = try interpret(request, bytes);
    defer result.deinit();
    try std.testing.expectEqualStrings("moving_window", result.value.done.inconclusive.bytes);
    request.audit.page_limit = 1;
    const incomplete = try body(a, canary, "100.000001", "next");
    defer a.free(incomplete);
    const bounded = try capture(a, request, incomplete, 200);
    defer a.free(bounded);
    var exhausted = try interpret(request, bounded);
    defer exhausted.deinit();
    try std.testing.expectEqualStrings("budget", exhausted.value.done.inconclusive.bytes);
}

test "native Slack audit follows cursor despite short page and qualifies inclusive canary" {
    var frozen = try input(a, true);
    defer frozen.deinit();
    var request: contract.Request = .{ .audit = frozen.value, .pages = .{ .items = &.{} } };
    const first_body = try body(a, frozen.value.canary.?.admitted, "100.000001", "next + cursor");
    defer a.free(first_body);
    const first = try capture(a, request, first_body, 200);
    defer a.free(first);
    var reply = try interpret(request, first);
    defer reply.deinit();
    try std.testing.expect(reply.value == .next);
    const page = reply.value.next;
    try std.testing.expectEqualStrings(first_body, page.evidence.body.bytes);
    try std.testing.expectEqual(4, page.evidence.headers.items.len);
    try std.testing.expectEqualStrings("audit-page", page.evidence.request_id.?.bytes);
    request.pages.items = &.{page};
    const url = try external.requestTarget(a, request, "B1");
    defer a.free(url);
    try std.testing.expect(std.mem.find(u8, url, "cursor=next%20%2B%20cursor") != null);
    try std.testing.expect(
        std.mem.find(u8, url, "inclusive=true&include_all_metadata=true") != null,
    );
    const last_body = try body(a, null, "", "");
    defer a.free(last_body);
    const last = try capture(a, request, last_body, 200);
    defer a.free(last);
    var result = try interpret(request, last);
    defer result.deinit();
    try std.testing.expect(result.value.done == .not_observed);
    try std.testing.expectEqualDeep(
        frozen.value.canary.?.receipt,
        result.value.done.not_observed.canary,
    );
}

test "native Slack audit exact positive match works without canary and never trusts absence" {
    var frozen = try input(a, false);
    defer frozen.deinit();
    const request: contract.Request = .{ .audit = frozen.value, .pages = .{ .items = &.{} } };
    const present = try body(a, frozen.value.delivery, "150.000001", "");
    defer a.free(present);
    const captured = try capture(a, request, present, 200);
    defer a.free(captured);
    var result = try interpret(request, captured);
    defer result.deinit();
    try std.testing.expectEqualStrings("150.000001", result.value.done.found.timestamp.bytes);
    const empty = try body(a, null, "", "");
    defer a.free(empty);
    const negative = try capture(a, request, empty, 200);
    defer a.free(negative);
    var absence = try interpret(request, negative);
    defer absence.deinit();
    try std.testing.expectEqualStrings("no_canary", absence.value.done.inconclusive.bytes);
}

test "native Slack audit missing metadata access malformed pagination and budget remain held" {
    const Case = struct { body: []const u8, status: u16 = 200, reason: []const u8 };
    const cases = [_]Case{
        .{ .body = "not-json", .reason = "malformed" },
        .{ .body = "{}", .status = 403, .reason = "access" },
        .{ .body = "{\"ok\":false,\"error\":\"ratelimited\"}", .reason = "access" },
        .{ .body = "{\"ok\":true,\"messages\":[],\"has_more\":true," ++
            "\"response_metadata\":{\"next_cursor\":\"\"}}", .reason = "cursor" },
        .{ .body = "{\"ok\":true,\"messages\":[],\"has_more\":false," ++
            "\"response_metadata\":{\"next_cursor\":\"next\"}}", .reason = "budget" },
        .{ .body = "{\"ok\":true,\"messages\":[{\"type\":\"message\",\"ts\":\"150.0\"," ++
            "\"bot_id\":\"B1\",\"app_id\":\"A1\"}]," ++
            "\"response_metadata\":{\"next_cursor\":\"\"}}", .reason = "metadata" },
    };
    var frozen = try input(a, true);
    defer frozen.deinit();
    frozen.value.page_limit = 1;
    const request: contract.Request = .{ .audit = frozen.value, .pages = .{ .items = &.{} } };
    for (cases) |case| {
        const captured = try capture(a, request, case.body, case.status);
        defer a.free(captured);
        var result = try interpret(request, captured);
        defer result.deinit();
        try std.testing.expectEqualStrings(case.reason, result.value.done.inconclusive.bytes);
    }
}

test "native Slack audit rejects capture substitution and invalid canary provenance" {
    var frozen = try input(a, true);
    defer frozen.deinit();
    var request: contract.Request = .{ .audit = frozen.value, .pages = .{ .items = &.{} } };
    const response = try body(a, null, "", "");
    defer a.free(response);
    const captured = try capture(a, request, response, 200);
    defer a.free(captured);
    for (0..3) |index| {
        var decoded = try c.decodeOwned(external.Capture, a, captured);
        defer decoded.deinit();
        switch (index) {
            0 => decoded.value.response.evidence.request_digest[0] ^= 1,
            1 => decoded.value.response.evidence.body_digest[0] ^= 1,
            2 => decoded.value.response.evidence.target.bytes = external.endpoint,
            else => unreachable,
        }
        const corrupt = try c.encodeOwned(external.Capture, a, decoded.value);
        defer a.free(corrupt);
        try std.testing.expectError(error.InvalidCapture, interpret(request, corrupt));
    }
    request.audit.canary.?.receipt.payload_digest[0] ^= 1;
    try std.testing.expectError(error.InvalidCanary, external.requestTarget(a, request, "B1"));
}

const Types = struct {
    pub const application_id = "paredros.audit.witness";
    pub const application_version = "1.0.0";
    pub const Input = t.Audit;
    pub const Output = t.AuditResult;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.audit.witness.input.v1";
    pub const output_schema_id = "paredros.audit.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.audit.witness.answer.v1";
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
        return ctx.author.module(try audit.emit(ctx), try ctx.schema(t.Failure));
    }
};
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);
const Scenario = struct {
    calls: [2]u32 = .{ 0, 0 },
    fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *Scenario = @ptrCast(@alignCast(ctx.environment.?));
        var request = try c.decodeOwned(contract.Request, ctx.allocator, bytes);
        defer request.deinit();
        const index = request.value.pages.items.len;
        if (index >= self.calls.len or self.calls[index] != 0) return error.DuplicateAcquisition;
        self.calls[index] += 1;
        const response = if (index == 0)
            try body(ctx.allocator, request.value.audit.canary.?.admitted, "100.000001", "next")
        else
            try body(ctx.allocator, request.value.audit.delivery, "150.000001", "");
        defer ctx.allocator.free(response);
        return .{ .captured = try capture(ctx.allocator, request.value, response, 200) };
    }
};

fn complete(fixture: *Fixture, work: native.tasks.Work) !void {
    const allocator = fixture.arena.allocator();
    const task_id = std.fmt.bytesToHex(work.task, .lower);
    const acquired = try work.entry.declaration.capture.?.acquire(.{
        .allocator = allocator,
        .io = .failing,
        .authority = &fixture.profile.authority,
        .task_id = &task_id,
        .profile = work.profile,
        .environment = fixture.profile.environment,
    }, work.prepared orelse return error.MissingPrepared);
    if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
    defer allocator.free(acquired.captured);
    try fixture.service.?.completeWork(allocator, work, .{ .acquired = acquired.captured });
}

fn drive(fixture: *Fixture, task_id: t.Id, stop: bool) !bool {
    const allocator = fixture.arena.allocator();
    for (0..4096) |_| {
        var task = try fixture.service.?.task(allocator, task_id);
        defer task.deinit();
        if (task.value.terminal()) return true;
        switch (try fixture.service.?.pump(allocator)) {
            .work => |work| {
                try complete(fixture, work);
                if (stop) return false;
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.AuditDidNotComplete;
}

test "native Slack audit capture survives reopen before interpretation without reacquisition" {
    var scenario: Scenario = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    try fixture.initWithGrants(&.{contract.identity});
    var frozen = try input(a, true);
    defer frozen.deinit();
    const allocator = fixture.arena.allocator();
    const admitted = try fixture.service.?.submit(allocator, "audit", frozen.value);
    const id = admitted.receipt.task;
    try std.testing.expect(!try drive(&fixture, id, true));
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, &scenario.calls);
    try fixture.close();
    try fixture.open();
    try std.testing.expectEqual(.idle, try fixture.service.?.pump(allocator));
    var saved = try fixture.service.?.task(allocator, id);
    defer saved.deinit();
    _ = try fixture.service.?.resumeTask(allocator, "resume", id, saved.value.revision);
    try std.testing.expect(try drive(&fixture, id, false));
    const result = try fixture.output(id);
    try std.testing.expectEqualStrings("150.000001", result.found.timestamp.bytes);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1 }, &scenario.calls);
}

const lineage_contract = @import("../app/lineage_audit_contract.zig");
const LineageTypes = struct {
    pub const application_id = "paredros.lineage-audit.witness";
    pub const application_version = "1.0.0";
    pub const Input = t.LineageAudit;
    pub const Output = t.LineageAuditResult;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.lineage-audit.witness.input.v1";
    pub const output_schema_id = "paredros.lineage-audit.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.lineage-audit.witness.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const LineageApplication = struct {
    pub const declarations: []const native.Declaration = &.{declaration()};
    fn declaration() native.Declaration {
        var result = external.lineageDeclaration();
        result.capture.?.acquire = LineageScenario.acquire;
        return result;
    }
    pub fn emit(ctx: protean.Context) !horos.source.Module {
        return ctx.author.module(try audit.Lineage.emit(ctx), try ctx.schema(t.Failure));
    }
};
const LineageFixture = @import("native_fixture.zig").Fixture(LineageTypes, LineageApplication);
const LineageScenario = struct {
    responses: [2][]const u8,
    calls: [2]u32 = .{ 0, 0 },

    fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        const self: *LineageScenario = @ptrCast(@alignCast(ctx.environment.?));
        var request = try c.decodeOwned(lineage_contract.Request, ctx.allocator, bytes);
        defer request.deinit();
        const index = request.value.pages.items.len;
        if (index >= self.calls.len or self.calls[index] != 0) return error.DuplicateAcquisition;
        self.calls[index] += 1;
        return .{ .captured = try lineageCapture(
            ctx.allocator,
            request.value,
            self.responses[index],
        ) };
    }
};

fn lineageInput() t.LineageAudit {
    return .{
        .envelope = .{
            .operation = .{ .bytes = "lineage-audit" },
            .stable_request = @splat(7),
            .origin = .{ .derived = .{ .predecessor = producer } },
        },
        .obligation = @splat(8),
        .predecessor = producer,
        .lineage = @splat(3),
        .destination = destination,
        .oldest = .{ .bytes = "100.000001" },
        .latest = .{ .bytes = "200.000001" },
        .page_limit = 4,
    };
}

fn lineageBody(allocator: std.mem.Allocator, cursor: []const u8) ![]u8 {
    var original = try delivery(allocator, 9);
    defer original.deinit();
    var intent = preparation.projectIntent(original.value);
    intent.key.generation = 9;
    var future = try preparation.materialize(allocator, intent, producer, @splat(4), "B1");
    defer future.deinit();
    return body(allocator, future.value, "150.000001", cursor);
}

fn lineageCapture(
    allocator: std.mem.Allocator,
    request: lineage_contract.Request,
    response: []const u8,
) ![]u8 {
    const bytes = try c.encodeOwned(lineage_contract.Request, allocator, request);
    defer allocator.free(bytes);
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
        "Date: Mon, 16 Nov 2026 00:00:00 GMT\r\nX-Slack-Req-Id: lineage-page\r\n\r\n";
    const head = try std.http.Client.Response.Head.parse(headers);
    var reader = std.Io.Reader.fixed(response);
    var retained = try http.captureResponse(allocator, head, &reader, .{}, "secret-never-retained");
    defer retained.deinit();
    return external.lineageCaptureBytes(allocator, bytes, "B1", retained, 1234);
}

fn lineageInterpret(
    request: lineage_contract.Request,
    captured: []const u8,
) !c.Decoded(lineage_contract.Reply) {
    const bytes = try c.encodeOwned(lineage_contract.Request, a, request);
    defer a.free(bytes);
    const result = try external.lineageInterpret(.{
        .allocator = a,
        .task = @splat(1),
        .tenant = "test",
        .profile = "test",
        .objects = .{ .source = &source, .read_object = noObject },
    }, bytes, bytes, captured);
    defer a.free(result.reply);
    return c.decodeOwned(lineage_contract.Reply, a, result.reply);
}

fn completeLineage(fixture: *LineageFixture, work: native.tasks.Work) !void {
    const allocator = fixture.arena.allocator();
    const task_id = std.fmt.bytesToHex(work.task, .lower);
    const acquired = try work.entry.declaration.capture.?.acquire(.{
        .allocator = allocator,
        .io = .failing,
        .authority = &fixture.profile.authority,
        .task_id = &task_id,
        .profile = work.profile,
        .environment = fixture.profile.environment,
    }, work.prepared orelse return error.MissingPrepared);
    if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
    defer allocator.free(acquired.captured);
    try fixture.service.?.completeWork(allocator, work, .{ .acquired = acquired.captured });
}

fn driveLineage(fixture: *LineageFixture, task_id: t.Id) !void {
    const allocator = fixture.arena.allocator();
    for (0..4096) |_| {
        var task = try fixture.service.?.task(allocator, task_id);
        defer task.deinit();
        if (task.value.terminal()) return;
        switch (try fixture.service.?.pump(allocator)) {
            .work => |work| try completeLineage(fixture, work),
            .idle, .waiting, .progressed => {},
        }
    }
    return error.AuditDidNotComplete;
}

test "native Slack lineage audit completes authored read loop without a delivery anchor" {
    const first = try lineageBody(a, "next + cursor");
    defer a.free(first);
    const last = try body(a, null, "", "");
    defer a.free(last);
    var scenario: LineageScenario = .{ .responses = .{ first, last } };
    var fixture: LineageFixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &scenario;
    try fixture.initWithGrants(&.{lineage_contract.identity});
    const admitted = try horos.data.program_image.Admitted.decode(a, fixture.assets.image);
    defer admitted.deinit();
    try std.testing.expectEqual(1, admitted.program().effects.len);
    try std.testing.expectEqualStrings(
        lineage_contract.identity,
        admitted.program().effects[0].identity,
    );
    try std.testing.expectEqual(1, fixture.handlers.?.entries.len);
    try std.testing.expectEqualStrings(
        "read",
        fixture.handlers.?.entries[0].declaration.resource_role,
    );
    const submitted = try fixture.service.?.submit(
        fixture.arena.allocator(),
        "lineage-audit",
        lineageInput(),
    );
    try driveLineage(&fixture, submitted.receipt.task);
    try std.testing.expect((try fixture.output(submitted.receipt.task)) == .complete);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1 }, &scenario.calls);
}

fn rejectLineageSubstitutions(request: lineage_contract.Request, captured: []const u8) !void {
    for (0..4) |index| {
        var decoded = try c.decodeOwned(external.Capture, a, captured);
        defer decoded.deinit();
        switch (index) {
            0 => decoded.value.response.evidence.request_digest[0] ^= 1,
            1 => decoded.value.response.evidence.body_digest[0] ^= 1,
            2 => decoded.value.response.evidence.target.bytes = external.endpoint,
            3 => decoded.value.response.bot_id.bytes = "B2",
            else => unreachable,
        }
        var history = try external.replayLineage(a, request, "B1");
        defer history.deinit();
        try std.testing.expectError(error.InvalidCapture, external.ingestLineage(
            a,
            &history,
            request,
            decoded.value.response,
        ));
    }
}

test "native Slack lineage capture retains future marker and rejects forged replay" {
    const request: lineage_contract.Request = .{
        .audit = lineageInput(),
        .pages = .{ .items = &.{} },
    };
    const response = try lineageBody(a, "");
    defer a.free(response);
    const captured = try lineageCapture(a, request, response);
    defer a.free(captured);
    var reply = try lineageInterpret(request, captured);
    defer reply.deinit();
    try std.testing.expect(reply.value.done == .complete);
    var decoded = try c.decodeOwned(external.Capture, a, captured);
    defer decoded.deinit();
    var retained = request;
    retained.pages.items = &.{decoded.value.response};
    var history = try external.replayLineage(a, retained, "B1");
    defer history.deinit();
    try std.testing.expect(history.complete);
    try std.testing.expectEqual(1, history.observations.items.len);
    const observed = history.observations.items[0];
    try std.testing.expectEqualStrings("150.000001", observed.timestamp);
    const payload = observed.metadata.object.get("event_payload").?;
    try std.testing.expectEqualStrings("9", payload.object.get("generation").?.string);
    try std.testing.expectEqualStrings(
        "lineage-page",
        decoded.value.response.evidence.request_id.?.bytes,
    );
    try rejectLineageSubstitutions(request, captured);
    retained.audit.lineage[0] ^= 1;
    try std.testing.expectError(error.InvalidCapture, external.replayLineage(a, retained, "B1"));
    var changed = request;
    changed.audit.obligation[0] ^= 1;
    try std.testing.expectError(error.InvalidCapture, lineageInterpret(changed, captured));
}

const LegacyInput = union(enum) {
    genesis: t.Genesis,
    step: t.Step,
    directive: t.Directive,
    delivery: t.Delivery,
    audit: t.Audit,
    turn: t.Turn,
    experiment: t.Experiment,
    continuity_member: t.ContinuityMember,
    continuity_cut: t.ContinuityCut,
    restore: t.Restore,
};

test "native Slack audit legacy Input bytes preserve ordinal and payload decoding" {
    var frozen = try input(a, true);
    defer frozen.deinit();
    const bytes = try c.encodeOwned(LegacyInput, a, .{ .audit = frozen.value });
    defer a.free(bytes);
    var decoded = try c.decodeOwned(t.Input, a, bytes);
    defer decoded.deinit();
    try std.testing.expect(decoded.value == .audit);
    try std.testing.expectEqualDeep(frozen.value, decoded.value.audit);
    const current = try c.encodeOwned(t.Input, a, decoded.value);
    defer a.free(current);
    try std.testing.expectEqualSlices(u8, bytes, current);
}
