const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const m = @import("../app/model_contract.zig");
const model = @import("../app/model.zig");
const external = @import("../native/model_external.zig");
const retained = @import("../native/retained.zig");
const index = @import("../native/index.zig");
const examples = @import("contracts.zig");
const a = std.testing.allocator;

const Types = struct {
    pub const application_id = t.application_id;
    pub const application_version = "1.0.0";
    pub const Input = t.Input;
    pub const Output = u32;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = t.input_schema_id;
    pub const output_schema_id = "paredros.retained.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.retained.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Application = struct {
    pub fn emit(ctx: protean.Context) !horos.source.Module {
        const entry = try ctx.author.function("retain input", .{
            .input = try ctx.schema(t.Input),
        }, try ctx.schema(u32), &.{});
        const b = try ctx.author.body(entry);
        try ctx.author.define(entry, try b.ret(try b.constant(u32, 7)));
        return ctx.author.module(entry, try ctx.schema(t.Failure));
    }
};
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);

const FailureApplication = struct {
    pub fn emit(ctx: protean.Context) !horos.source.Module {
        const entry = try ctx.author.function("fail retained input", .{
            .input = try ctx.schema(t.Input),
        }, try ctx.schema(u32), &.{});
        const b = try ctx.author.body(entry);
        try ctx.author.define(entry, try b.fail(
            try ctx.schema(u32),
            try ctx.literal(t.Failure, .{ .code = .{ .bytes = "fixture_failure" } }),
        ));
        return ctx.author.module(entry, try ctx.schema(t.Failure));
    }
};
const FailureFixture = @import("native_fixture.zig").Fixture(Types, FailureApplication);

const Service = native.tasks.Service(Types);

fn Returned(comptime method: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(method)).@"fn".return_type.?).error_union.payload;
}

fn Param(comptime method: anytype, comptime position: usize) type {
    return @typeInfo(@TypeOf(method)).@"fn".param_types[position].?;
}

const Selection = Param(Service.applicationValue, 3);
const Skewed = struct {
    service: *Service,
    skew: ?Selection = null,

    pub fn task(self: Skewed, s: std.mem.Allocator, id: t.Id) !Returned(Service.task) {
        return self.service.task(s, id);
    }

    pub fn applicationValue(
        self: Skewed,
        s: std.mem.Allocator,
        id: t.Id,
        selection: Selection,
    ) !Returned(Service.applicationValue) {
        var value = (try self.service.applicationValue(s, id, selection)) orelse return null;
        if (self.skew != null and self.skew.? == selection) value.reference.bytes += 1;
        return value;
    }

    pub fn frozenInputs(
        self: Skewed,
        s: std.mem.Allocator,
        id: t.Id,
    ) !Returned(Service.frozenInputs) {
        return self.service.frozenInputs(s, id);
    }

    pub fn status(
        self: Skewed,
        s: std.mem.Allocator,
        value: Param(Service.status, 2),
    ) !Returned(Service.status) {
        return self.service.status(s, value);
    }

    pub fn attemptPage(
        self: Skewed,
        s: std.mem.Allocator,
        id: t.Id,
        revision: u64,
        after: Param(Service.attemptPage, 4),
        limit: u32,
    ) !Returned(Service.attemptPage) {
        return self.service.attemptPage(s, id, revision, after, limit);
    }

    pub fn attemptValue(
        self: Skewed,
        s: std.mem.Allocator,
        id: t.Id,
        revision: u64,
        attempt: Param(Service.attemptValue, 4),
        part: Param(Service.attemptValue, 5),
    ) !Returned(Service.attemptValue) {
        return self.service.attemptValue(s, id, revision, attempt, part);
    }
};

fn fact(snapshot: retained.OwnedSnapshot) t.Settlement {
    return .{
        .reference = snapshot.reference,
        .owner_snapshot = .{ .bytes = snapshot.bytes },
        .kind = .phase,
        .accounting = snapshot.value.accounting,
        .delivery = null,
    };
}

fn step(settlement: *const t.Settlement) t.Input {
    const genesis = examples.genesis();
    const head = @import("native_genesis.zig").expectedFresh(genesis);
    return .{ .step = .{
        .envelope = genesis.envelope,
        .obligation = @splat(1),
        .predecessor = .{ .task = @splat(1), .digest = @splat(2) },
        .previous = head,
        .sequence = 1,
        .attempt = 0,
        .supersession = null,
        .directives = .{ .items = &.{} },
        .facts = .{ .items = @as(*const [1]t.Settlement, @ptrCast(settlement)) },
        .batches = .{ .items = &.{} },
        .clock_ms = 100,
        .fold_only = true,
    } };
}

fn loadAllocation(
    allocator: std.mem.Allocator,
    service: *native.tasks.Service(Types),
    id: t.Id,
) !void {
    var saved = try retained.load(service, allocator, id, 1);
    defer saved.deinit();
}

fn decodeAllocation(allocator: std.mem.Allocator, frozen: retained.OwnedSnapshot) !void {
    var decoded = try retained.decodeFrozen(allocator, frozen.reference, frozen.bytes);
    defer decoded.deinit();
}

fn copyAllocation(allocator: std.mem.Allocator, evidence: retained.Evidence) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try retained.copyEvidence(arena.allocator(), evidence);
}

test "native retained snapshot freezes exact owner bytes and survives reopening" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const id = try fixture.execute("first", .{ .genesis = examples.genesis() });
    var saved = try retained.load(&fixture.service.?, a, id, 1);
    defer saved.deinit();
    try std.testing.expectEqual(.completed, saved.snapshot.value.outcome);
    try std.testing.expectEqualStrings(
        t.input_schema_id,
        saved.snapshot.value.input.schema_id.bytes,
    );
    try std.testing.expectEqual(
        saved.snapshot.value.evidence_bytes,
        saved.snapshot.value.accounting.retained_bytes,
    );
    try std.testing.expectEqual(0, saved.snapshot.value.accounting.known_calls);
    try std.testing.expectEqual(0, saved.snapshot.value.unknown_calls.items.len);
    try fixture.close();
    try fixture.open();
    var reopened = try retained.load(&fixture.service.?, a, id, 1);
    defer reopened.deinit();
    try std.testing.expectEqualSlices(u8, saved.snapshot.bytes, reopened.snapshot.bytes);
    try std.testing.checkAllAllocationFailures(a, loadAllocation, .{ &fixture.service.?, id });
    try std.testing.checkAllAllocationFailures(a, decodeAllocation, .{saved.snapshot});
}

test "native retained load refuses application references whose length disagrees with bytes" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const id = try fixture.execute("first", .{ .genesis = examples.genesis() });
    const service = &fixture.service.?;
    var saved = try retained.load(Skewed{ .service = service }, a, id, 1);
    defer saved.deinit();
    var input = (try service.applicationValue(a, id, .input)).?;
    defer input.deinit();
    try std.testing.expectEqual(input.reference.digest, saved.evidence.input.digest);
    try std.testing.expectEqualSlices(u8, input.bytes, saved.evidence.input.bytes);
    try std.testing.expect(saved.evidence.result != null);
    for ([_]Selection{ .input, .result }) |skew| try std.testing.expectError(
        error.DigestMismatch,
        retained.load(Skewed{ .service = service, .skew = skew }, a, id, 1),
    );
}

test "native retained snapshot counts terminal failures but excludes control cancellation" {
    var failed: FailureFixture = .{};
    defer failed.deinit();
    try failed.init();
    const failure = try failed.execute("failure", .{ .genesis = examples.genesis() });
    var failure_snapshot = try retained.load(&failed.service.?, a, failure, 1);
    defer failure_snapshot.deinit();
    try std.testing.expectEqual(.failed, failure_snapshot.snapshot.value.outcome);
    try std.testing.expectEqual(1, failure_snapshot.snapshot.value.accounting.failed_attempts);
    try std.testing.expectEqualStrings(
        t.failure_schema_id,
        failure_snapshot.snapshot.value.result.?.schema_id.bytes,
    );
    try failed.close();
    var cancelled: Fixture = .{};
    defer cancelled.deinit();
    try cancelled.init();
    const admission = try cancelled.service.?.submit(
        a,
        "cancelled",
        .{ .genesis = examples.genesis() },
    );
    _ = try cancelled.service.?.requestCancel(
        cancelled.arena.allocator(),
        "cancel",
        admission.receipt.task,
        "control",
    );
    _ = try cancelled.execute("cancelled", .{ .genesis = examples.genesis() });
    var cancellation = try retained.load(&cancelled.service.?, a, admission.receipt.task, 1);
    defer cancellation.deinit();
    try std.testing.expectEqual(.cancelled, cancellation.snapshot.value.outcome);
    try std.testing.expectEqual(0, cancellation.snapshot.value.accounting.failed_attempts);
}

test "native retained snapshot authenticates historical cuts from immutable admitted input" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const admitted = try fixture.service.?.submit(
        a,
        "original",
        .{ .genesis = examples.genesis() },
    );
    var before = try retained.load(&fixture.service.?, a, admitted.receipt.task, 1);
    defer before.deinit();
    const old_fact = fact(before.snapshot);
    const holder = try fixture.service.?.submit(a, "holder", step(&old_fact));
    var holder_input = (try fixture.service.?.applicationValue(a, holder.receipt.task, .input)).?;
    defer holder_input.deinit();
    _ = try fixture.execute("original", .{ .genesis = examples.genesis() });
    var after = try retained.load(&fixture.service.?, a, admitted.receipt.task, 1);
    defer after.deinit();
    try std.testing.expect(after.snapshot.reference.revision > before.snapshot.reference.revision);
    const custody: retained.Admission = .{
        .input = .{ .task = holder.receipt.task, .digest = holder_input.reference.digest },
        .fact_index = 0,
    };
    var historical = try retained.loadAdmitted(
        &fixture.service.?,
        a,
        custody,
        before.snapshot.reference,
    );
    defer historical.deinit();
    try std.testing.expectEqualSlices(u8, before.snapshot.bytes, historical.bytes);
    var late = fact(after.snapshot);
    late.previous_reference = historical.reference;
    late.previous_accounting = historical.value.accounting;
    try retained.verifySettlement(late, after.snapshot, historical);
    late.previous_accounting.retained_bytes += 1;
    try std.testing.expectError(
        error.InvalidPreviousSettlement,
        retained.verifySettlement(late, after.snapshot, historical),
    );
    try std.testing.expectError(
        error.WrongAdmission,
        retained.loadAdmitted(&fixture.service.?, a, custody, after.snapshot.reference),
    );
    var forged = custody;
    forged.input.digest[0] ^= 1;
    try std.testing.expectError(
        error.WrongAdmission,
        retained.loadAdmitted(&fixture.service.?, a, forged, before.snapshot.reference),
    );
}

test "native retained snapshot pages stable tasks and rejects self consistent forged accounting" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const first = try fixture.execute("first", .{ .genesis = examples.genesis() });
    _ = try fixture.execute("second", .{ .genesis = examples.genesis() });
    var page = try retained.loadPage(&fixture.service.?, a, null, 1, 1);
    defer page.deinit();
    try std.testing.expectEqual(1, page.snapshots.len);
    var second = try retained.loadPage(&fixture.service.?, a, page.next, 1, 1);
    defer second.deinit();
    try std.testing.expectEqual(1, second.snapshots.len);
    try std.testing.expect(!std.meta.eql(
        page.snapshots[0].snapshot.value.task,
        second.snapshots[0].snapshot.value.task,
    ));
    var saved = try retained.load(&fixture.service.?, a, first, 1);
    defer saved.deinit();
    var forged = saved.snapshot.value;
    forged.accounting.known_calls = 1;
    const bytes = try c.encodeOwned(retained.Snapshot, a, forged);
    defer a.free(bytes);
    var reference = saved.snapshot.reference;
    reference.digest = index.digest(bytes);
    try std.testing.expectError(
        error.AccountingMismatch,
        retained.decodeFrozen(a, reference, bytes),
    );
    try std.testing.expectError(
        error.DigestMismatch,
        retained.decodeFrozen(a, saved.snapshot.reference, bytes),
    );
    try std.testing.expectError(
        error.InvalidPageLimit,
        retained.load(&fixture.service.?, a, first, 0),
    );
}

test "native retained snapshot serialization stays constant across twelve admitted fact links" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const genesis = try fixture.execute("chain-root", .{ .genesis = examples.genesis() });
    var current = try retained.load(&fixture.service.?, a, genesis, 1);
    defer current.deinit();
    const snapshot_bytes = current.snapshot.bytes.len;
    var step_input_bytes: ?usize = null;
    for (0..12) |position| {
        const settlement = fact(current.snapshot);
        var next_input = step(&settlement);
        const predecessor: t.Reference = .{
            .task = current.snapshot.value.task,
            .digest = current.snapshot.value.result.?.reference.digest,
        };
        const operation = try std.fmt.allocPrint(
            fixture.arena.allocator(),
            "chain-{d:0>2}",
            .{position},
        );
        next_input.step.envelope.operation.bytes = operation;
        next_input.step.envelope.origin = .{ .derived = .{ .predecessor = predecessor } };
        next_input.step.predecessor = predecessor;
        next_input.step.sequence = position + 1;
        next_input.step.previous.sequence = position;
        const id = try fixture.execute(operation, next_input);
        var next = try retained.load(&fixture.service.?, a, id, 1);
        errdefer next.deinit();
        try std.testing.expectEqual(snapshot_bytes, next.snapshot.bytes.len);
        if (step_input_bytes) |expected| {
            try std.testing.expectEqual(expected, next.evidence.input.bytes.len);
        } else step_input_bytes = next.evidence.input.bytes.len;
        try std.testing.expect(!std.meta.eql(current.snapshot.reference, next.snapshot.reference));
        try std.testing.expectEqual(
            index.digest(next.evidence.input.bytes),
            next.snapshot.value.input.reference.digest,
        );
        const loaded_row = retained.row(next);
        try std.testing.expectEqualSlices(u8, next.evidence.input.bytes, loaded_row.input.bytes);
        current.deinit();
        current = next;
    }
}

test "native retained snapshot evidence copy owns raw bytes after the loaded source is released" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const id = try fixture.execute("copy", .{ .genesis = examples.genesis() });
    var copied_arena = std.heap.ArenaAllocator.init(a);
    defer copied_arena.deinit();
    var loaded = try retained.load(&fixture.service.?, a, id, 1);
    const input_digest = loaded.snapshot.value.input.reference.digest;
    const profile_digest = loaded.snapshot.value.profile.digest;
    const copied = retained.copyEvidence(copied_arena.allocator(), loaded.evidence) catch |err| {
        loaded.deinit();
        return err;
    };
    loaded.deinit();
    try std.testing.expectEqual(input_digest, index.digest(copied.input.bytes));
    try std.testing.expectEqual(profile_digest, index.digest(copied.profile_bytes));
    try std.testing.expectEqualStrings(t.input_schema_id, copied.input.schema_id);
    try std.testing.checkAllAllocationFailures(a, copyAllocation, .{copied});
}

const ModelTypes = struct {
    pub const application_id = "paredros.retained.model";
    pub const application_version = "1.0.0";
    pub const Input = m.Input;
    pub const Output = m.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.retained.model.input.v1";
    pub const output_schema_id = "paredros.retained.model.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.retained.model.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const ModelApplication = struct {
    pub const declarations: []const native.Declaration = &.{external.declaration()};
    pub fn emit(ctx: protean.Context) !horos.source.Module {
        return ctx.author.module(try model.emit(ctx), try ctx.schema(t.Failure));
    }
};
const ModelFixture = @import("native_fixture.zig").Fixture(ModelTypes, ModelApplication);

fn modelAllocation(
    allocator: std.mem.Allocator,
    service: *native.tasks.Service(ModelTypes),
    id: t.Id,
) !void {
    var saved = try retained.load(service, allocator, id, 1);
    defer saved.deinit();
}

fn configure(fixture: anytype, plan: bool) !m.Binding {
    const allocator = fixture.arena.allocator();
    fixture.profile.authority.inference = true;
    const catalog = try external.emptyCatalog(allocator);
    const profile: protean.model_invocation.AdaptiveInferenceProfile = .{
        .id = .{ .bytes = "selected" },
        .model = .{ .bytes = "fixture-model" },
        .reasoning_mode = .standard,
        .reasoning_context = if (plan) .auto else .current_turn,
        .efforts = .{ .items = &.{.medium} },
        .effort_update = false,
        .explicit_cache = false,
        .additional_tools = plan,
        .cache_diagnostics = false,
        .opaque_family = .{ .bytes = "fixture" },
        .max_output_tokens = if (plan) null else 4096,
        .request_bytes = 1024 * 1024,
        .response_bytes = 2 * 1024 * 1024,
        .timeout_ms = 1000,
    };
    const policy: m.P.AdaptivePolicy = .{
        .schema = .{ .bytes = m.P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://fixture.test/v1/responses" },
        .audience = .{ .bytes = "fixture" },
        .profiles = .{ .items = &.{profile} },
        .catalog = .{ .digest = index.digest(catalog), .bytes = catalog.len },
        .core_tools = .{ true, true },
        .permitted_tools = .{ true, true },
    };
    var config = native.json.object();
    try native.json.put(
        allocator,
        &config,
        "adaptive",
        try native.values.toJson(m.P.AdaptivePolicy, allocator, policy),
    );
    const response_contract = try native.values.toJson(c.ResponsesContract, allocator, .{
        .route = if (plan) .chatgpt_plan_sse else .api_key_json,
        .binding = if (plan) @splat(1) else null,
    });
    try native.json.put(allocator, &config, "responses", response_contract);
    fixture.profile.bytes = try native.json.canonical(allocator, config);
    fixture.profile.resources = try allocator.dupe([]const u8, &.{catalog});
    return (try external.binding(allocator, fixture.profile.bytes, "selected", .medium)).value;
}

fn modelInput(binding: m.Binding) m.Input {
    return .{
        .binding = binding,
        .phase = .summary,
        .context = .{ .bytes = "frozen" },
        .initiating_input = @splat(7),
        .target = null,
        .expected_revision = null,
        .proposal_offers = .{ .items = &.{} },
        .genesis_template = null,
    };
}

fn dispatch(fixture: anytype) !native.tasks.Work {
    for (0..4096) |_| switch (try fixture.service.?.pump(fixture.arena.allocator())) {
        .work => |work| return work,
        .idle, .waiting, .progressed => {},
    };
    return error.MissingModelWork;
}

fn capture(fixture: anytype, work: native.tasks.Work, plan: bool, usage: []const u8) !void {
    const allocator = fixture.arena.allocator();
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"response\",\"status\":\"completed\",\"error\":null," ++
            "\"output\":[],\"usage\":{s}}}",
        .{usage},
    );
    const body = if (plan) try std.fmt.allocPrint(
        allocator,
        "event: response.completed\ndata: {{\"type\":\"response.completed\"," ++
            "\"response\":{s}}}\n\n",
        .{json},
    ) else json;
    const bytes = try c.encodeOwned(external.Raw, allocator, .{
        .status = 200,
        .request_id = null,
        .identity_encoding = true,
        .body = .{ .bytes = body },
        .format = if (plan) .sse else .json,
        .media_type = .{ .bytes = if (plan) "text/event-stream" else "application/json" },
    });
    try fixture.service.?.completeWork(allocator, work, .{ .acquired = bytes });
}

fn settle(fixture: anytype, task: t.Id) !void {
    for (0..4096) |_| {
        var saved = try fixture.service.?.task(a, task);
        defer saved.deinit();
        if (saved.value.terminal()) return;
        switch (try fixture.service.?.pump(fixture.arena.allocator())) {
            .work => return error.UnexpectedExternalWork,
            .idle, .waiting, .progressed => {},
        }
    }
    return error.ModelDidNotFinish;
}

test "native retained snapshot counts capture usage before projection with unknown IDs" {
    for ([_]bool{ false, true }) |plan| {
        var fixture: ModelFixture = .{};
        defer fixture.deinit();
        const binding = try configure(&fixture, plan);
        try fixture.initWithGrants(&.{m.P.identity});
        const admitted = try fixture.service.?.submit(a, "model", modelInput(binding));
        const id = admitted.receipt.task;
        const work = try dispatch(&fixture);
        var pending = try retained.load(&fixture.service.?, a, id, 1);
        defer pending.deinit();
        try std.testing.expectEqual(1, pending.snapshot.value.accounting.possible_charged_calls);
        try std.testing.expectEqual(1, pending.snapshot.value.unknown_calls.items.len);
        try std.testing.expectEqual(
            pending.snapshot.value.attempts.items[0].id,
            pending.snapshot.value.unknown_calls.items[0],
        );
        try capture(&fixture, work, plan, "{\"input_tokens\":20,\"output_tokens\":10}");
        var captured = try retained.load(&fixture.service.?, a, id, 1);
        defer captured.deinit();
        try std.testing.expectEqual(1, captured.snapshot.value.accounting.known_calls);
        try std.testing.expectEqual(20, captured.snapshot.value.accounting.known_input_tokens);
        try std.testing.expectEqual(10, captured.snapshot.value.accounting.known_output_tokens);
        try std.testing.expectEqual(0, captured.snapshot.value.unknown_calls.items.len);
        try std.testing.expectEqual(0, captured.snapshot.value.inference_output_tokens);
        try fixture.close();
        try fixture.open();
        var reopened = try retained.load(&fixture.service.?, a, id, 1);
        defer reopened.deinit();
        try std.testing.expectEqual(20, reopened.snapshot.value.accounting.known_input_tokens);
        var current = try fixture.service.?.task(a, id);
        defer current.deinit();
        _ = try fixture.service.?.resumeTask(a, "resume", id, current.value.revision);
        try settle(&fixture, id);
        var settled = try retained.load(&fixture.service.?, a, id, 1);
        defer settled.deinit();
        try std.testing.expectEqual(10, settled.snapshot.value.inference_output_tokens);
        try std.testing.expectEqual(10, settled.snapshot.value.accounting.known_output_tokens);
        try std.testing.expectEqual(1, settled.snapshot.value.attempts.items.len);
        if (!plan) {
            try std.testing.checkAllAllocationFailures(
                a,
                modelAllocation,
                .{ &fixture.service.?, id },
            );
            try std.testing.checkAllAllocationFailures(a, decodeAllocation, .{settled.snapshot});
            try std.testing.checkAllAllocationFailures(a, copyAllocation, .{settled.evidence});
        }
    }
}

test "native retained snapshot keeps partial usage unknown and excludes definitely not sent" {
    var fixture: ModelFixture = .{};
    defer fixture.deinit();
    const binding = try configure(&fixture, false);
    try fixture.initWithGrants(&.{m.P.identity});
    const admitted = try fixture.service.?.submit(a, "partial", modelInput(binding));
    const work = try dispatch(&fixture);
    try capture(&fixture, work, false, "{\"input_tokens\":20}");
    var partial = try retained.load(&fixture.service.?, a, admitted.receipt.task, 1);
    defer partial.deinit();
    try std.testing.expectEqual(20, partial.snapshot.value.accounting.known_input_tokens);
    try std.testing.expectEqual(
        null,
        partial.snapshot.value.attempts.items[0].usage.?.output_tokens,
    );
    try std.testing.expectEqual(1, partial.snapshot.value.accounting.possible_charged_calls);
    try settle(&fixture, admitted.receipt.task);
    const second = try fixture.service.?.submit(a, "not-sent", modelInput(binding));
    try fixture.service.?.notSent(fixture.arena.allocator(), try dispatch(&fixture));
    var unsent = try retained.load(&fixture.service.?, a, second.receipt.task, 1);
    defer unsent.deinit();
    try std.testing.expectEqual(0, unsent.snapshot.value.accounting.known_calls);
    try std.testing.expectEqual(0, unsent.snapshot.value.accounting.possible_charged_calls);
    try std.testing.expectEqual(1, unsent.snapshot.value.attempts.items.len);
    _ = try fixture.service.?.resumeTask(
        fixture.arena.allocator(),
        "retry",
        second.receipt.task,
        unsent.snapshot.reference.revision,
    );
    try capture(&fixture, try dispatch(&fixture), false, "null");
    var retried = try retained.load(&fixture.service.?, a, second.receipt.task, 1);
    defer retried.deinit();
    try std.testing.expectEqual(2, retried.snapshot.value.attempts.items.len);
    try std.testing.expectEqual(1, retried.snapshot.value.accounting.known_calls);
    try std.testing.expectEqual(1, retried.snapshot.value.accounting.possible_charged_calls);
    try std.testing.expectEqual(1, retried.snapshot.value.unknown_calls.items.len);
    var combined = try retained.load(&fixture.service.?, a, second.receipt.task, 2);
    defer combined.deinit();
    try std.testing.expectEqualSlices(u8, retried.snapshot.bytes, combined.snapshot.bytes);
}

const UnsupportedUsageApplication = struct {
    pub const declarations: []const native.Declaration = &.{declaration()};

    fn declaration() native.Declaration {
        var selected = external.declaration();
        selected.capture.?.interpret = interpret;
        return selected;
    }

    fn interpret(
        ctx: native.registry.ProjectionContext,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) !native.registry.Projection {
        return .{
            .reply = try c.encodeOwned(m.P.AdaptiveResult, ctx.allocator, .{
                .result = .{ .unsupported_response = .unsupported_status },
                .replay = null,
                .replay_status = .unsupported,
                .usage = .{
                    .input_tokens = 20,
                    .output_tokens = 10,
                    .cached_input_tokens = null,
                    .cache_write_tokens = null,
                    .reasoning_tokens = null,
                },
            }),
            .output_tokens = 10,
        };
    }

    pub fn emit(ctx: protean.Context) !horos.source.Module {
        return ModelApplication.emit(ctx);
    }
};
const UnsupportedUsageFixture = @import("native_fixture.zig").Fixture(
    ModelTypes,
    UnsupportedUsageApplication,
);

test "native retained snapshot rejects projected usage absent from interpretable raw capture" {
    var fixture: UnsupportedUsageFixture = .{};
    defer fixture.deinit();
    const binding = try configure(&fixture, false);
    try fixture.initWithGrants(&.{m.P.identity});
    const admitted = try fixture.service.?.submit(a, "unsupported-usage", modelInput(binding));
    try capture(&fixture, try dispatch(&fixture), false, "null");
    var before = try retained.load(&fixture.service.?, a, admitted.receipt.task, 1);
    defer before.deinit();
    try std.testing.expectEqual(1, before.snapshot.value.accounting.possible_charged_calls);
    try settle(&fixture, admitted.receipt.task);
    try std.testing.expectError(
        error.UsageMismatch,
        retained.load(&fixture.service.?, a, admitted.receipt.task, 1),
    );
}
