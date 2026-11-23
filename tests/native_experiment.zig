const std = @import("std");
const native = @import("protean_native");
const horos = @import("horos");
const c = @import("protean_contracts");
const t = @import("application_types");
const e = @import("../app/experiment_contract.zig");
const external = @import("../native/experiment_external.zig");
const method = @import("../app/method_contract.zig");
const method_external = @import("../native/method_external.zig");
const model_external = @import("../native/model_external.zig");
const model = @import("../app/model_contract.zig");
const retained = @import("../native/retained.zig");
const method_fixture = @import("native_method.zig");
const examples = @import("contracts.zig");
const source = @import("experiment.zig");
const Types = source.Types;
const Fixture = @import("native_fixture.zig").Fixture(Types, Application);
const Session = native.Session(Types);
const a = std.testing.allocator;

const Application = struct {
    pub const emit = source.Application.emit;
    pub const declarations: []const native.Declaration = &.{
        method_external.declaration(), method_external.codecDeclaration(), codecDeclaration(),
        external.clockDeclaration(),   modelDeclaration(),
    };

    fn codecDeclaration() native.Declaration {
        var declaration = external.declaration();
        declaration.invoke = Witness.codec;
        return declaration;
    }

    fn modelDeclaration() native.Declaration {
        var declaration = model_external.declaration();
        declaration.capture.?.acquire = Witness.unknown;
        return declaration;
    }
};

const Witness = struct {
    checkpoints: std.atomic.Value(u32) = .init(0),
    scripted_calls: std.atomic.Value(u32) = .init(0),
    live_calls: std.atomic.Value(u32) = .init(0),

    fn codec(ctx: native.Context, bytes: []const u8) ![]u8 {
        const self: *Witness = @ptrCast(@alignCast(ctx.environment.?));
        var request = try c.decodeOwned(e.CodecRequest, ctx.allocator, bytes);
        defer request.deinit();
        switch (request.value) {
            .checkpoint => _ = self.checkpoints.fetchAdd(1, .release),
            .scripted_completion => _ = self.scripted_calls.fetchAdd(1, .release),
            else => {},
        }
        return external.declaration().invoke.?(ctx, bytes);
    }

    fn unknown(ctx: native.Context, _: []const u8) !native.registry.Acquisition {
        const self: *Witness = @ptrCast(@alignCast(ctx.environment.?));
        _ = self.live_calls.fetchAdd(1, .release);
        return .{ .unknown = error.WithheldFixtureResponse };
    }
};

fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn literal(comptime T: type, b: *horos.source.Builder, selected: T) !u64 {
    return b.literal(.{
        .schema = try c.schema(T, b),
        .bytes = try c.encodeOwned(T, b.allocator(), selected),
    });
}

fn stateSource(allocator: std.mem.Allocator) ![]u8 {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const incoming = try c.schema(method.GuestInput, &b);
    const outgoing = try c.schema(method.GuestOutput, &b);
    const entry = try b.declare(&.{incoming}, outgoing, &.{}, &.{});
    const state = try b.primitive(
        try c.schema(method.State, &b),
        .field,
        &.{try b.reference(b.parameter(entry, 0))},
        1,
    );
    const length = try b.primitive(try b.scalar(u64), .blob_length, &.{state}, 0);
    const empty = try b.primitive(
        try b.scalar(bool),
        .equal,
        &.{ length, try literal(u64, &b, 0) },
        0,
    );
    const body: model.Summary = .{
        .summary = .{ .bytes = "Retained method" },
        .highlights = .{ .items = &.{} },
    };
    const first = try literal(method.GuestOutput, &b, .{
        .body = body,
        .state = .{ .bytes = "seed" },
    });
    const later = try literal(method.GuestOutput, &b, .{
        .body = body,
        .state = .{ .bytes = "carried" },
    });
    try b.define(entry, try b.term(.{ .conditional = .{
        .condition = empty,
        .when_true = try b.pure(first),
        .when_false = try b.pure(later),
    } }));
    return native.source_records.encode(allocator, b.module(entry, try b.scalar(void)));
}

fn candidate(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) !e.Candidate {
    return .{
        .name = .{ .bytes = name },
        .source = .{
            .source = .{ .task = @splat(70), .digest = hash(bytes) },
            .source_digest = hash(bytes),
            .contract_digest = try method_external.contractDigest(allocator),
            .bytes = .{ .bytes = bytes },
        },
        .construction_evidence = .{ .items = &.{} },
    };
}

fn oid(number: u32) t.Oid {
    var result: t.Oid = @splat('0');
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, number, .big);
    @memcpy(result[32..], &std.fmt.bytesToHex(bytes, .lower));
    return result;
}

fn selectedCase(
    allocator: std.mem.Allocator,
    name: []const u8,
    condition: e.Condition,
    trial: u32,
    first: u32,
) !e.Case {
    const commits = try allocator.alloc(t.Commit, 4);
    for (commits, 0..) |*commit, i| commit.* = .{
        .oid = oid(first + @as(u32, @intCast(i))),
        .message = .{ .bytes = try std.fmt.allocPrint(allocator, "Change {d}", .{first + i}) },
    };
    var head = @import("native_genesis.zig").expectedFresh(examples.genesis());
    head.obligation = .{ .task = @splat(1) };
    head.observed = .{ .sequence = 1, .epoch = 2, .tip = oid(first + 3) };
    head.told = .{ .sequence = 0, .epoch = 2, .tip = oid(0) };
    if (condition == .oversized) head.specification.policies.render_input_bytes = 1;
    const facts = try allocator.alloc(@FieldType(t.Step, "batches").Child, 1);
    facts[0] = .{
        .reference = .{ .task = @splat(@intCast(first)), .digest = @splat(@intCast(first)) },
        .value = .{
            .repository = head.specification.repository,
            .sequence = 1,
            .epoch = 2,
            .base = oid(0),
            .tip = oid(first + 3),
            .coverage = .complete,
            .commits = .{ .items = commits },
            .raw_evidence = .{ .items = &.{} },
            .acquired_ms = 100,
            .provider_date = null,
        },
    };
    return .{
        .name = .{ .bytes = name },
        .condition = condition,
        .trial = trial,
        .input = .{ .head = head, .step = .{
            .envelope = examples.genesis().envelope,
            .obligation = @splat(1),
            .predecessor = .{ .task = @splat(2), .digest = @splat(3) },
            .previous = head,
            .sequence = 1,
            .attempt = 0,
            .supersession = null,
            .directives = .{ .items = &.{} },
            .facts = .{ .items = &.{} },
            .batches = .{ .items = facts },
            .clock_ms = 200,
            .fold_only = false,
        } },
        .rubric = .{
            .required = .{ .items = &.{.{ .bytes = "Repository: owner/test" }} },
            .forbidden = .{ .items = &.{.{ .bytes = "UNSUPPORTED" }} },
        },
    };
}

fn plan(allocator: std.mem.Allocator) !e.ComparisonPlan {
    const candidates = try allocator.alloc(e.Candidate, 3);
    candidates[0] = try candidate(allocator, "stateful", try stateSource(allocator));
    candidates[1] = try candidate(allocator, "malformed", "{not source records}");
    candidates[2] = try candidate(allocator, "rubric failure", try method_fixture.guestSource(
        allocator,
        .{ .summary = .{
            .summary = .{ .bytes = "UNSUPPORTED" },
            .highlights = .{ .items = &.{} },
        } },
    ));
    const cases = try allocator.alloc(e.Case, 6);
    cases[0] = try selectedCase(allocator, "representative one", .recurrence, 1, 1);
    cases[1] = try selectedCase(allocator, "representative two", .recurrence, 2, 1);
    cases[2] = try selectedCase(allocator, "changed", .changed, 1, 5);
    cases[3] = try selectedCase(allocator, "large", .oversized, 1, 9);
    cases[4] = try selectedCase(allocator, "interruption", .interruption, 1, 13);
    cases[5] = try selectedCase(allocator, "withheld", .withheld, 1, 17);
    return .{
        .candidates = .{ .items = candidates },
        .cases = .{ .items = cases },
        .rule = .reject_mechanical_failures_else_inconclusive,
        .budget = .{
            .render_runs = 24,
            .child_advances = 18 * e.advances_per_render,
            .live_calls = 0,
        },
        .expected_recurrences = 100,
    };
}

fn input(
    allocator: std.mem.Allocator,
    selected: e.ComparisonPlan,
    attempt: u32,
    live: bool,
) !t.Experiment {
    return .{
        .envelope = .{
            .operation = .{ .bytes = "experiment" },
            .stable_request = @splat(9),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .campaign = @splat(10),
        .attempt = attempt,
        .plan = .{ .bytes = try c.encodeOwned(e.Plan, allocator, .{ .compare = selected }) },
        .evidence = .{ .items = &.{} },
        .live_model = live,
    };
}

const Stop = enum { checkpoint, live, scripted };

fn drive(fixture: *Fixture, session: *Session, task: t.Id, witness: ?*Witness, stop: Stop) !bool {
    const allocator = fixture.arena.allocator();
    for (0..50_000) |_| {
        const completed = try session.collect(allocator, false);
        if (witness) |observed| if (completed != .none) {
            const count = switch (stop) {
                .checkpoint => observed.checkpoints.load(.acquire),
                .live => observed.live_calls.load(.acquire),
                .scripted => observed.scripted_calls.load(.acquire),
            };
            if (count > 0) return false;
        };
        var status = try fixture.service.?.task(allocator, task);
        defer status.deinit();
        if (status.value.terminal()) return true;
        _ = try session.advance(allocator);
        if (session.busy()) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.ExperimentDidNotComplete;
}

fn verifyReport(report: e.Report) !void {
    try std.testing.expect(report.rejection == null);
    try std.testing.expectEqual(.scripted_v1, report.identity.mode);
    try std.testing.expectEqual(.not_established, report.efficacy);
    try std.testing.expectEqual(.ordinary_retained, report.decision);
    try std.testing.expectEqual(.required, report.owner_join);
    try std.testing.expectEqual(24, report.runs.items.len);
    try std.testing.expectEqual(.evidence_inconclusive, report.candidates.items[0].disposition);
    try std.testing.expectEqual(.rejected, report.candidates.items[1].disposition);
    try std.testing.expectEqual(.rejected, report.candidates.items[2].disposition);
    try std.testing.expectEqual(6, report.candidates.items[0].passed_mechanical_rubric);
    try std.testing.expectEqual(4, report.runs.items[1].state_bytes);
    try std.testing.expectEqual(7, report.runs.items[5].state_bytes);
    try std.testing.expectEqual(4, report.runs.items[17].state_bytes);
    try std.testing.expectEqual(7, report.runs.items[21].state_bytes);
    try std.testing.expect(report.runs.items[17].interruption_checkpoint);
    try std.testing.expect(report.runs.items[17].actual_process_recovery == null);
    try std.testing.expectEqual(.withheld, report.cases.items[5].condition);
    try std.testing.expect(report.trials.items[0].count == 2 and !report.trials.items[0].anecdote);
    try std.testing.expect(report.trials.items[1].anecdote);
    try std.testing.expect(report.campaign_totals.retained_bytes == null);
    try std.testing.expect(report.campaign_totals.possible_charged_calls == null);
    try std.testing.expect(report.candidates.items[0].construction.model_calls == null);
    try std.testing.expect(report.candidates.items[0].amortization_recurrences == null);
    for (report.runs.items) |run| {
        try std.testing.expect(run.quality.responsibility_preserved);
        try std.testing.expect(run.wall_elapsed_including_recovery_ms != null);
        if (run.condition == .oversized) try std.testing.expect(
            std.mem.indexOf(u8, run.output.bytes, "Large-batch fallback") != null,
        );
    }
}

fn registerSources(fixture: *Fixture, session: *Session, declared: *e.ComparisonPlan) !t.Reference {
    const allocator = fixture.arena.allocator();
    const drafts = try allocator.alloc(e.SourceDraft, declared.candidates.items.len);
    for (declared.candidates.items, drafts) |selected, *draft| draft.* = .{
        .name = selected.name,
        .bytes = .{ .bytes = selected.source.bytes.bytes },
        .contract_digest = selected.source.contract_digest,
        .provenance = selected.construction_evidence,
        .origin = .operator_supplied,
    };
    var request = try input(allocator, declared.*, 0, false);
    request.plan.bytes = try c.encodeOwned(e.Plan, allocator, .{ .construct = .{
        .sources = .{ .items = drafts },
    } });
    const task = try fixture.service.?.submit(allocator, "source-registration", request);
    try std.testing.expect(try drive(fixture, session, task.receipt.task, null, .checkpoint));
    const output = try fixture.output(task.receipt.task);
    var report = try c.decodeOwned(e.Report, allocator, output.report.bytes);
    defer report.deinit();
    try std.testing.expectEqual(.source_registration, report.value.kind);
    try std.testing.expectEqual(0, report.value.runs.items.len);
    var stored = (try fixture.service.?.applicationValue(allocator, task.receipt.task, .result)).?;
    defer stored.deinit();
    const reference: t.Reference = .{
        .task = task.receipt.task,
        .digest = stored.reference.digest,
    };
    const candidates = try allocator.alloc(e.Candidate, drafts.len);
    for (candidates, report.value.registered_sources.items) |*selected, registered| {
        try std.testing.expectEqual(.unqualified, registered.qualification);
        selected.* = .{
            .name = .{ .bytes = try allocator.dupe(u8, registered.draft.name.bytes) },
            .source = .{
                .source = reference,
                .source_digest = registered.source_digest,
                .contract_digest = registered.draft.contract_digest,
                .bytes = .{ .bytes = try allocator.dupe(u8, registered.draft.bytes.bytes) },
            },
            .construction_evidence = .{ .items = try allocator.dupe(t.Reference, &.{reference}) },
        };
    }
    declared.candidates.items = candidates;
    return reference;
}

test "native experiment compares all cases and retains unknown cost through interruption" {
    var witness: Witness = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &witness;
    const binding = try method_fixture.configure(&fixture);
    try fixture.initWithGrants(&.{
        method.workspace_identity, method.codec_identity, e.codec_identity, e.clock_identity,
        model.P.identity,
    });
    const allocator = fixture.arena.allocator();
    var session = try Session.init(&fixture.service.?);
    var attached = true;
    defer if (attached) session.deinit() catch @panic("experiment session left busy");
    var declared = try plan(allocator);
    const registered = try registerSources(&fixture, &session, &declared);
    const unknown = try unknownPrefix(&fixture, &session, &declared, binding, &witness);
    const selected = try input(allocator, declared, 2, false);
    const admitted = try fixture.service.?.submit(allocator, "offline-comparison", selected);
    try std.testing.expect(!try drive(
        &fixture,
        &session,
        admitted.receipt.task,
        &witness,
        .checkpoint,
    ));
    try session.park(allocator);
    try session.deinit();
    attached = false;
    try fixture.close();
    try fixture.open();
    var saved = try fixture.service.?.task(allocator, admitted.receipt.task);
    defer saved.deinit();
    _ = try fixture.service.?.resumeTask(
        allocator,
        "resume-comparison",
        admitted.receipt.task,
        saved.value.revision,
    );
    session = try Session.init(&fixture.service.?);
    attached = true;
    try std.testing.expect(try drive(&fixture, &session, admitted.receipt.task, null, .checkpoint));
    const output = try fixture.output(admitted.receipt.task);
    var report = try c.decodeOwned(e.Report, a, output.report.bytes);
    defer report.deinit();
    try verifyReport(report.value);
    try std.testing.expectEqualDeep(registered, report.value.candidates.items[0].source);
    try std.testing.expectEqual(2, report.value.identity.attempt);
    var old = try retained.load(&fixture.service.?, allocator, unknown, 128);
    defer old.deinit();
    try std.testing.expectEqual(1, old.snapshot.value.accounting.possible_charged_calls);
    try std.testing.expectEqual(1, witness.live_calls.load(.acquire));
    try std.testing.expectEqual(10, witness.scripted_calls.load(.acquire));
    try std.testing.expectEqual(4, witness.checkpoints.load(.acquire));
    try session.park(allocator);
}

fn rejectedPlan(
    allocator: std.mem.Allocator,
    selected: e.ComparisonPlan,
    live: bool,
    reason: []const u8,
) !void {
    var reply = try external.evaluate(a, .{ .prepare = try input(allocator, selected, 0, live) });
    defer reply.deinit();
    try std.testing.expect(reply.value == .terminal);
    var report = try c.decodeOwned(e.Report, a, reply.value.terminal.report.bytes);
    defer report.deinit();
    try std.testing.expectEqualStrings(reason, report.value.rejection.?.bytes);
    try std.testing.expectEqual(0, report.value.runs.items.len);
    try std.testing.expectEqual(.not_established, report.value.efficacy);
}

test "native experiment rejects missing conditions budgets and exposed withheld data" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try plan(allocator);
    var changed = original;
    changed.budget.render_runs = 23;
    try rejectedPlan(allocator, changed, false, "ExperimentWorkBudget");
    changed = original;
    changed.budget.child_advances -= 1;
    try rejectedPlan(allocator, changed, false, "ExperimentWorkBudget");
    changed = original;
    changed.budget.report_bytes = 1;
    try rejectedPlan(allocator, changed, false, "ExperimentReportBudget");
    changed = original;
    changed.cases.items = changed.cases.items[0..5];
    try rejectedPlan(allocator, changed, false, "MissingExperimentCondition");
    changed = original;
    const cases = try allocator.dupe(e.Case, original.cases.items);
    cases[5].input = cases[0].input;
    changed.cases.items = cases;
    try rejectedPlan(allocator, changed, false, "WithheldAlreadyExposed");
    changed = original;
    changed.budget.live_calls = 24;
    try rejectedPlan(allocator, changed, true, "ExperimentLiveBudget");
    changed = original;
    const unexercised = try allocator.dupe(e.Case, original.cases.items);
    unexercised[0].input.head.specification.policies.render_input_bytes = 1;
    unexercised[0].input.step.previous = unexercised[0].input.head;
    changed.cases.items = unexercised;
    try rejectedPlan(allocator, changed, false, "MethodNotExercised");
    try retainedReserve(allocator, original);
    try armDisagreement(allocator, original);
}

fn armDisagreement(allocator: std.mem.Allocator, original: e.ComparisonPlan) !void {
    var changed = original;
    const cases = try allocator.dupe(e.Case, original.cases.items);
    changed.cases.items = cases;
    cases[0].input.head.specification.policies.context_bytes = 64;
    cases[0].input.step.previous = cases[0].input.head;
    try rejectedPlan(allocator, changed, false, "ArmMeasuresDisagree");
    cases[0] = original.cases.items[0];
    const facts = try allocator.dupe(
        @FieldType(t.Step, "batches").Child,
        cases[0].input.step.batches.items,
    );
    const body = try allocator.alloc(u8, 4096);
    @memset(body, 'x');
    facts[0].value.raw_evidence = .{ .items = try allocator.dupe(t.ReadEvidence, &.{.{
        .request_digest = @splat(9),
        .target = .{ .bytes = "https://api.github.com/repositories/1/compare/a...b" },
        .status = 200,
        .body = .{ .bytes = body },
        .body_digest = @splat(8),
        .captured_ms = 100,
        .provider_date = null,
        .request_id = null,
        .link = null,
        .etag = null,
        .retry_after = null,
        .rate_remaining = null,
        .rate_reset = null,
    }}) };
    cases[0].input.step.batches.items = facts;
    cases[0].input.head.specification.policies.render_input_bytes = 2048;
    cases[0].input.step.previous = cases[0].input.head;
    try rejectedPlan(allocator, changed, false, "ArmMeasuresDisagree");
}

fn exactBound(allocator: std.mem.Allocator, selected: *e.Case) !void {
    const one: @FieldType(t.Step, "batches") = .{
        .items = selected.input.step.batches.items[0..1],
    };
    const encoded = try c.encodeOwned(@TypeOf(one), allocator, one);
    selected.input.head.specification.policies.render_input_bytes = encoded.len;
    selected.input.step.previous = selected.input.head;
}

fn retainedReserve(allocator: std.mem.Allocator, original: e.ComparisonPlan) !void {
    var changed = original;
    const cases = try allocator.dupe(e.Case, original.cases.items);
    changed.cases.items = cases;
    try exactBound(allocator, &cases[0]);
    try rejectedPlan(allocator, changed, false, "MethodNotExercised");
    cases[0] = original.cases.items[0];
    try exactBound(allocator, &cases[3]);
    var reply = try external.evaluate(a, .{ .prepare = try input(allocator, changed, 0, false) });
    defer reply.deinit();
    try std.testing.expect(reply.value == .prepared);
}

fn allocationProbe(allocator: std.mem.Allocator, selected: t.Experiment) !void {
    var result = try external.evaluate(allocator, .{ .prepare = selected });
    defer result.deinit();
    try std.testing.expect(result.value == .prepared);
}

test "native experiment codec owns admitted plan bytes and cleans allocation failures" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = try input(allocator, try plan(allocator), 0, false);
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{selected});
    const bytes = try a.dupe(u8, selected.plan.bytes);
    var independent = selected;
    independent.plan.bytes = bytes;
    var result = try external.evaluate(a, .{ .prepare = independent });
    defer result.deinit();
    a.free(bytes);
    try std.testing.expectEqualStrings(
        "stateful",
        result.value.prepared.plan.candidates.items[0].name.bytes,
    );
    try std.testing.expectEqual(6, result.value.prepared.plan.cases.items.len);
}

fn unknownPrefix(
    fixture: *Fixture,
    session: *Session,
    declared: *e.ComparisonPlan,
    binding: t.ModelBinding,
    witness: *Witness,
) !t.Id {
    const allocator = fixture.arena.allocator();
    declared.model = binding;
    declared.budget.live_calls = 24;
    const first = try fixture.service.?.submit(
        allocator,
        "unknown-comparison",
        try input(allocator, declared.*, 1, true),
    );
    try std.testing.expect(!try drive(fixture, session, first.receipt.task, witness, .live));
    var first_result = try fixture.service.?.applicationValue(
        allocator,
        first.receipt.task,
        .result,
    );
    defer if (first_result) |*result| result.deinit();
    try std.testing.expect(first_result == null);
    declared.budget.live_calls = 0;
    return first.receipt.task;
}

test "native experiment reaches scripted completion without a model grant" {
    var witness: Witness = .{};
    var fixture: Fixture = .{};
    defer fixture.deinit();
    fixture.profile.environment = &witness;
    try fixture.initWithGrants(&.{
        method.workspace_identity, method.codec_identity, e.codec_identity, e.clock_identity,
    });
    const allocator = fixture.arena.allocator();
    var declared = try plan(allocator);
    var session = try Session.init(&fixture.service.?);
    defer session.deinit() catch @panic("scripted experiment session left busy");
    _ = try registerSources(&fixture, &session, &declared);
    const selected = try fixture.service.?.submit(
        allocator,
        "scripted-comparison",
        try input(allocator, declared, 1, false),
    );
    try std.testing.expect(!try drive(
        &fixture,
        &session,
        selected.receipt.task,
        &witness,
        .scripted,
    ));
    try std.testing.expectEqual(1, witness.scripted_calls.load(.acquire));
    try std.testing.expectEqual(0, witness.live_calls.load(.acquire));
    try session.park(allocator);
}
