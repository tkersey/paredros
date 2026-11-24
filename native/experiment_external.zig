const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const e = @import("../app/experiment_contract.zig");
const m = @import("../app/model_contract.zig");
const method = @import("../app/method_contract.zig");
const step = @import("../app/step.zig");
const measure = @import("render_measure.zig");

pub const OwnedReply = struct {
    arena: std.heap.ArenaAllocator,
    value: e.CodecReply,

    pub fn deinit(self: *OwnedReply) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn declaration() native.Declaration {
    return .{
        .identity = e.codec_identity,
        .resource_role = "frozen",
        .kind = .leaf,
        .payload_schema = requestSchema,
        .resume_schema = replySchema,
        .invoke = invokeBytes,
        .recovery = .{
            .identity = "paredros.experiment.codec.recovery.v1",
            .version = 1,
            .rederive = rederive,
        },
    };
}

fn requestSchema(a: std.mem.Allocator) ![]u8 {
    return native.values.schemaBytes(e.CodecRequest, a);
}

fn replySchema(a: std.mem.Allocator) ![]u8 {
    return native.values.schemaBytes(e.CodecReply, a);
}

pub fn clockDeclaration() native.Declaration {
    return native.leaf(e.Stamp, i64, .{
        .identity = e.clock_identity,
        .resource_role = "measurement",
    }, stamp);
}

fn stamp(ctx: native.Context, _: e.Stamp) !i64 {
    return std.math.cast(i64, std.Io.Clock.boot.now(ctx.io).toMilliseconds()) orelse
        error.ClockRange;
}

fn invokeBytes(ctx: native.Context, bytes: []const u8) ![]u8 {
    var result = try evaluateBytes(ctx.allocator, bytes);
    defer result.deinit();
    return c.encodeOwned(e.CodecReply, ctx.allocator, result.value);
}

fn rederive(
    ctx: native.registry.RederivationContext,
    _: native.registry.RecoveryInput,
    bytes: []const u8,
    _: ?[]const u8,
) !native.registry.RederivationFinding {
    try ctx.checkCancellation();
    var result = try evaluateBytes(ctx.allocator, bytes);
    defer result.deinit();
    return .{ .result = try c.encodeOwned(e.CodecReply, ctx.allocator, result.value) };
}

pub fn evaluate(a: std.mem.Allocator, request: e.CodecRequest) !OwnedReply {
    const bytes = try c.encodeOwned(e.CodecRequest, a, request);
    defer a.free(bytes);
    return evaluateBytes(a, bytes);
}

fn evaluateBytes(a: std.mem.Allocator, bytes: []const u8) !OwnedReply {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const decoded = try c.decodeOwned(e.CodecRequest, arena.allocator(), bytes);
    const result = try value(arena.allocator(), decoded.value);
    return .{ .arena = arena, .value = result };
}

fn value(a: std.mem.Allocator, request: e.CodecRequest) !e.CodecReply {
    return switch (request) {
        .prepare => |input| prepare(a, input) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .terminal = try rejected(a, input, @errorName(err)) };
        },
        .run_input => |input| .{ .run_input = try runInput(a, input) },
        .observe => |input| .{ .observed = try observe(a, input) },
        .finish => |input| .{ .finished = try finish(a, input.identity, input.plan, input.runs) },
        .scripted_completion => .{ .scripted_completion = .{
            .candidate = .{ .summary = .{
                .summary = .{ .bytes = "Scripted comparison reply; no live model inference." },
                .highlights = .{ .items = &.{} },
            } },
            .usage = null,
        } },
        .checkpoint => .{ .checkpoint = {} },
    };
}

fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn digest(a: std.mem.Allocator, comptime T: type, input: T) !t.Digest {
    const bytes = try c.encodeOwned(T, a, input);
    defer a.free(bytes);
    return hash(bytes);
}

fn identity(input: t.Experiment) e.Identity {
    return .{
        .campaign = input.campaign,
        .attempt = input.attempt,
        .plan_digest = hash(input.plan.bytes),
        .mode = if (input.live_model) .live else .scripted_v1,
    };
}

fn prepare(a: std.mem.Allocator, input: t.Experiment) !e.CodecReply {
    if (input.envelope.version != 1 or input.plan.bytes.len > 1024 * 1024)
        return error.InvalidExperimentInput;
    const decoded = try c.decodeOwned(e.Plan, a, input.plan.bytes);
    const plan = switch (decoded.value) {
        .construct => |construction| return .{
            .terminal = try register(a, input, construction),
        },
        .compare => |comparison| comparison,
    };
    try validatePlan(a, plan, input.live_model);
    const states = try a.alloc(method.State, plan.candidates.items.len);
    @memset(states, .{ .bytes = "" });
    return .{ .prepared = .{
        .identity = identity(input),
        .plan = plan,
        .states = .{ .items = states },
        .model = if (input.live_model) plan.model.? else scriptedBinding(),
    } };
}

fn register(
    a: std.mem.Allocator,
    input: t.Experiment,
    plan: e.ConstructionPlan,
) !t.ExperimentResult {
    if (input.live_model or plan.version != 1 or plan.sources.items.len == 0 or
        plan.maximum_source_bytes > 960 * 1024) return error.InvalidSourceRegistration;
    const contract = try @import("method_external.zig").contractDigest(a);
    const registered = try a.alloc(e.RegisteredSource, plan.sources.items.len);
    var total: u64 = 0;
    for (plan.sources.items, registered, 0..) |draft, *result, i| {
        total += draft.bytes.bytes.len;
        if (total > plan.maximum_source_bytes or draft.name.bytes.len == 0 or
            draft.bytes.bytes.len == 0) return error.SourceRegistrationBound;
        if (!std.meta.eql(draft.contract_digest, contract)) return error.InvalidSourceContract;
        const source_digest = hash(draft.bytes.bytes);
        for (registered[0..i]) |prior| {
            if (std.mem.eql(u8, draft.name.bytes, prior.draft.name.bytes) or
                std.meta.eql(source_digest, prior.source_digest))
                return error.DuplicateRegisteredSource;
        }
        result.* = .{
            .draft = draft,
            .source_digest = source_digest,
            .qualification = .unqualified,
        };
    }
    var id = identity(input);
    id.mode = .source_registration;
    return encodeReport(a, .{
        .kind = .source_registration,
        .identity = id,
        .rejection = null,
        .rule = .reject_mechanical_failures_else_inconclusive,
        .budget = null,
        .expected_recurrences = null,
        .cases = .{ .items = &.{} },
        .candidates = .{ .items = &.{} },
        .registered_sources = .{ .items = registered },
        .trials = .{ .items = &.{} },
        .runs = .{ .items = &.{} },
        .ordinary_cold_wall_ms = null,
        .ordinary_recurring_wall = .{},
        .writes = .simulated,
        .decision = .ordinary_retained,
        .efficacy = .not_established,
        .owner_join = .required,
    }, 1024 * 1024);
}

fn validatePlan(a: std.mem.Allocator, plan: e.ComparisonPlan, live: bool) !void {
    if (plan.version != 1 or plan.candidates.items.len == 0 or plan.cases.items.len == 0)
        return error.EmptyExperimentPlan;
    const runs = (plan.candidates.items.len + 1) * plan.cases.items.len;
    const advances = plan.candidates.items.len * plan.cases.items.len * e.advances_per_render;
    if (runs > plan.budget.render_runs or advances > plan.budget.child_advances)
        return error.ExperimentWorkBudget;
    if (live and (plan.model == null or runs > plan.budget.live_calls))
        return error.ExperimentLiveBudget;
    if (!live and plan.budget.live_calls != 0) return error.ScriptedLiveBudget;
    const report_bound = 4096 + runs * 4608 + plan.cases.items.len * 2400 +
        plan.candidates.items.len * 2048;
    if (plan.budget.report_bytes < report_bound or plan.budget.report_bytes > 1024 * 1024)
        return error.ExperimentReportBudget;
    for (plan.candidates.items, 0..) |candidate, i| {
        if (candidate.name.bytes.len == 0 or candidate.source.bytes.bytes.len == 0)
            return error.EmptyCandidate;
        for (plan.candidates.items[0..i]) |prior| {
            if (std.mem.eql(u8, candidate.name.bytes, prior.name.bytes) or
                std.meta.eql(candidate.source.source_digest, prior.source.source_digest))
                return error.DuplicateCandidate;
        }
    }
    try validateCases(a, plan.cases.items);
}

fn validateCases(a: std.mem.Allocator, cases: []const e.Case) !void {
    var counts: [5]u32 = @splat(0);
    var withheld = false;
    var representative: ?t.Digest = null;
    for (cases, 0..) |selected, i| {
        try validateCase(a, selected);
        if (withheld and selected.condition != .withheld) return error.WithheldOrdering;
        withheld = withheld or selected.condition == .withheld;
        counts[@backingInt(selected.condition)] += 1;
        for (cases[0..i]) |prior| {
            if (std.mem.eql(u8, selected.name.bytes, prior.name.bytes) or
                (selected.condition == prior.condition and selected.trial == prior.trial))
                return error.DuplicateExperimentCase;
        }
        const batches = try digest(a, @FieldType(t.Step, "batches"), selected.input.step.batches);
        if (selected.condition == .recurrence and representative == null) representative = batches;
        if (selected.condition == .changed and representative != null and
            std.meta.eql(batches, representative.?)) return error.UnchangedChangedCase;
        if (selected.condition == .withheld) for (cases[0..i]) |prior| {
            if (prior.condition == .withheld) continue;
            const earlier = try digest(a, @FieldType(t.Step, "batches"), prior.input.step.batches);
            if (std.meta.eql(batches, earlier)) return error.WithheldAlreadyExposed;
        };
    }
    for (counts) |count| if (count == 0) return error.MissingExperimentCondition;
    if (counts[@backingInt(e.Condition.recurrence)] < 2 or cases[0].condition != .recurrence)
        return error.MissingRecurrence;
}

fn validateCase(a: std.mem.Allocator, selected: e.Case) !void {
    const input = selected.input;
    if (selected.name.bytes.len == 0 or selected.trial == 0 or
        input.head.method != .ordinary or
        input.head.method_disposition != null or input.step.batches.items.len == 0)
        return error.InvalidExperimentCase;
    const first = input.step.batches.items[0].value;
    if (input.head.observed.sequence <= input.head.told.sequence or
        first.coverage != .complete or first.commits.items.len == 0 or
        first.sequence != try std.math.add(u64, input.head.told.sequence, 1))
        return error.MethodNotExercised;
    const head_digest = try digest(a, t.Head, input.head);
    const previous_digest = try digest(a, t.Head, input.step.previous);
    if (!std.meta.eql(head_digest, previous_digest))
        return error.ExperimentHeadMismatch;
    if (selected.rubric.maximum_output_bytes > 4000) return error.InvalidRubric;
    for (selected.rubric.required.items) |text| if (text.bytes.len == 0)
        return error.EmptyRubricTerm;
    for (selected.rubric.forbidden.items) |text| if (text.bytes.len == 0)
        return error.EmptyRubricTerm;
    const oversized = try firstOversized(a, input);
    if (selected.condition == .oversized and !oversized) return error.OversizedCaseFits;
    if (selected.condition != .oversized and oversized) return error.MethodNotExercised;
}

fn firstOversized(a: std.mem.Allocator, input: step.RenderInput) !bool {
    const first = input.step.batches.items[0];
    const specification = input.head.specification;
    var ordinary = try measure.Prefix.init(.ordinary, specification, "");
    var retained = try measure.Prefix.init(.retained, specification, "");
    try ordinary.add(a, first);
    try retained.add(a, first);
    const baseline = try ordinary.oversized();
    const candidate = try retained.oversized();
    if (baseline != candidate) return error.ArmMeasuresDisagree;
    return baseline;
}

pub fn scriptedBinding() t.ModelBinding {
    return .{
        .policy = @splat(0),
        .selection = .{
            .profile_id = .{ .bytes = "scripted-v1" },
            .profile_digest = @splat(0),
            .effective_effort = .medium,
            .control_revision = 0,
        },
        .profile = .{
            .id = .{ .bytes = "scripted-v1" },
            .model = .{ .bytes = "scripted-v1" },
            .reasoning_mode = .standard,
            .reasoning_context = .current_turn,
            .efforts = .{ .items = &.{.medium} },
            .effort_update = false,
            .explicit_cache = false,
            .additional_tools = false,
            .cache_diagnostics = false,
            .opaque_family = .{ .bytes = "scripted-v1" },
            .max_output_tokens = 4096,
            .request_bytes = 1024 * 1024,
            .response_bytes = 2 * 1024 * 1024,
            .timeout_ms = 1000,
        },
        .catalog = .{ .digest = @splat(0), .bytes = 0 },
        .responses = .{},
    };
}

fn runInput(a: std.mem.Allocator, input: e.RunInput) !step.RenderInput {
    var result = input.selected.input;
    result.step.envelope = input.envelope;
    result.step.model = input.model;
    result.step.method_source = null;
    result.head.method = .{ .ordinary = {} };
    result.head.method_disposition = null;
    if (input.candidate) |candidate| {
        const prior = if (input.selected.condition == .interruption)
            method.State{ .bytes = "" }
        else
            input.state;
        result.step.method_source = candidate.source;
        result.head.method = .{ .retained = .{
            .source = candidate.source.source,
            .source_digest = candidate.source.source_digest,
            .contract_digest = candidate.source.contract_digest,
            .report = .{ .task = @splat(0), .digest = @splat(0) },
            .applicability = try digest(a, t.Specification, result.head.specification),
            .state = prior,
            .consecutive_faults = 0,
        } };
    }
    result.step.previous = result.head;
    return result;
}

fn preserved(a: std.mem.Allocator, before: t.Head, after: t.Head) !bool {
    var projected = after;
    projected.method = before.method;
    projected.method_disposition = before.method_disposition;
    projected.message = before.message;
    projected.told = before.told;
    projected.render_failure_streak = before.render_failure_streak;
    projected.render_not_before_ms = before.render_not_before_ms;
    return std.meta.eql(try digest(a, t.Head, before), try digest(a, t.Head, projected));
}

fn observe(a: std.mem.Allocator, input: e.Observation) !e.Observed {
    const text = if (input.output.message) |published| published.text.bytes else "";
    if (text.len > 4000) return error.RenderOutputBound;
    var quality: e.Quality = .{
        .required_present = true,
        .forbidden_absent = true,
        .within_output_bound = text.len <= input.selected.rubric.maximum_output_bytes,
        .responsibility_preserved = try preserved(a, input.input.head, input.output),
    };
    for (input.selected.rubric.required.items) |term|
        quality.required_present = quality.required_present and
            std.mem.indexOf(u8, text, term.bytes) != null;
    for (input.selected.rubric.forbidden.items) |term|
        quality.forbidden_absent = quality.forbidden_absent and
            std.mem.indexOf(u8, text, term.bytes) == null;
    const elapsed = @as(i128, input.ended_ms) - @as(i128, input.started_ms);
    const state = if (input.output.method == .retained)
        input.output.method.retained.state
    else
        method.State{ .bytes = "" };
    return .{
        .run = .{
            .case_index = input.case_index,
            .arm = input.arm,
            .trial = input.selected.trial,
            .condition = input.selected.condition,
            .output = .{ .bytes = try a.dupe(u8, text) },
            .output_digest = hash(text),
            .method_fault = if (input.output.method_disposition) |disposition|
                .{ .bytes = try a.dupe(u8, disposition.reason.bytes) }
            else
                null,
            .quality = quality,
            .state_bytes = @intCast(state.bytes.len),
            .wall_elapsed_including_recovery_ms = std.math.cast(u64, elapsed),
            .interruption_checkpoint = input.selected.condition == .interruption,
        },
        .state = .{ .bytes = try a.dupe(u8, state.bytes) },
    };
}

fn passed(run: e.Run) bool {
    const quality = run.quality;
    return run.method_fault == null and quality.required_present and quality.forbidden_absent and
        quality.within_output_bound and quality.responsibility_preserved;
}

fn spread(runs: e.Runs, arm: u32) e.Spread {
    var result: e.Spread = .{};
    for (runs.items) |run| {
        if (run.arm != arm or run.case_index == 0) continue;
        const elapsed = run.wall_elapsed_including_recovery_ms orelse continue;
        result.samples += 1;
        result.minimum_ms = if (result.minimum_ms) |prior| @min(prior, elapsed) else elapsed;
        result.maximum_ms = if (result.maximum_ms) |prior| @max(prior, elapsed) else elapsed;
    }
    return result;
}

fn cold(runs: e.Runs, arm: u32) ?u64 {
    for (runs.items) |run| if (run.arm == arm and run.case_index == 0)
        return run.wall_elapsed_including_recovery_ms;
    return null;
}

fn candidateEvidence(
    a: std.mem.Allocator,
    plan: e.ComparisonPlan,
    runs: e.Runs,
) ![]e.CandidateEvidence {
    const result = try a.alloc(e.CandidateEvidence, plan.candidates.items.len);
    for (plan.candidates.items, result, 0..) |candidate, *row, index| {
        const arm: u32 = @intCast(index + 1);
        var completed: u32 = 0;
        var passing: u32 = 0;
        for (runs.items) |run| if (run.arm == arm) {
            completed += 1;
            if (passed(run)) passing += 1;
        };
        row.* = .{
            .name = candidate.name,
            .source = candidate.source.source,
            .source_digest = candidate.source.source_digest,
            .contract_digest = candidate.source.contract_digest,
            .construction_evidence = candidate.construction_evidence,
            .source_bytes = candidate.source.bytes.bytes.len,
            .disposition = if (passing != completed) .rejected else .evidence_inconclusive,
            .completed_runs = completed,
            .passed_mechanical_rubric = passing,
            .cold_wall_ms = cold(runs, arm),
            .recurring_wall = spread(runs, arm),
        };
    }
    return result;
}

fn caseEvidence(a: std.mem.Allocator, plan: e.ComparisonPlan) ![]e.CaseEvidence {
    const result = try a.alloc(e.CaseEvidence, plan.cases.items.len);
    for (plan.cases.items, result) |selected, *row| row.* = .{
        .name = selected.name,
        .condition = selected.condition,
        .trial = selected.trial,
        .input_digest = try digest(a, step.RenderInput, selected.input),
        .rubric = selected.rubric,
    };
    return result;
}

fn trials(a: std.mem.Allocator, plan: e.ComparisonPlan, runs: e.Runs) ![]e.Trials {
    const result = try a.alloc(e.Trials, 5);
    for (result, 0..) |*row, i| {
        const condition: e.Condition = @fromBackingInt(@intCast(i));
        var count: u32 = 0;
        for (plan.cases.items) |selected| if (selected.condition == condition) {
            count += 1;
        };
        const candidates = try a.alloc(e.Spread, plan.candidates.items.len);
        for (candidates, 0..) |*candidate, index|
            candidate.* = conditionSpread(runs, @intCast(index + 1), condition);
        row.* = .{
            .condition = condition,
            .count = count,
            .anecdote = count == 1,
            .includes_cold_start = plan.cases.items[0].condition == condition,
            .ordinary_wall = conditionSpread(runs, 0, condition),
            .candidate_wall = .{ .items = candidates },
        };
    }
    return result;
}

fn conditionSpread(runs: e.Runs, arm: u32, condition: e.Condition) e.Spread {
    var result: e.Spread = .{};
    for (runs.items) |run| {
        if (run.arm != arm or run.condition != condition) continue;
        const elapsed = run.wall_elapsed_including_recovery_ms orelse continue;
        result.samples += 1;
        result.minimum_ms = if (result.minimum_ms) |prior| @min(prior, elapsed) else elapsed;
        result.maximum_ms = if (result.maximum_ms) |prior| @max(prior, elapsed) else elapsed;
    }
    return result;
}

fn finish(
    a: std.mem.Allocator,
    id: e.Identity,
    plan: e.ComparisonPlan,
    runs: e.Runs,
) !t.ExperimentResult {
    const expected = plan.cases.items.len * (plan.candidates.items.len + 1);
    if (runs.items.len != expected) return error.IncompleteExperimentRuns;
    for (runs.items, 0..) |run, i| {
        const case_index = i / (plan.candidates.items.len + 1);
        if (run.case_index != case_index or run.arm != i % (plan.candidates.items.len + 1) or
            run.condition != plan.cases.items[case_index].condition or
            run.trial != plan.cases.items[case_index].trial)
            return error.ExperimentRunOrdering;
    }
    return encodeReport(a, .{
        .kind = .comparison,
        .identity = id,
        .rejection = null,
        .rule = plan.rule,
        .budget = plan.budget,
        .expected_recurrences = plan.expected_recurrences,
        .cases = .{ .items = try caseEvidence(a, plan) },
        .candidates = .{ .items = try candidateEvidence(a, plan, runs) },
        .registered_sources = .{ .items = &.{} },
        .trials = .{ .items = try trials(a, plan, runs) },
        .runs = runs,
        .ordinary_cold_wall_ms = cold(runs, 0),
        .ordinary_recurring_wall = spread(runs, 0),
        .writes = .simulated,
        .decision = .ordinary_retained,
        .efficacy = .not_established,
        .owner_join = .required,
    }, plan.budget.report_bytes);
}

fn rejected(a: std.mem.Allocator, input: t.Experiment, reason: []const u8) !t.ExperimentResult {
    return encodeReport(a, .{
        .kind = .rejected_plan,
        .identity = identity(input),
        .rejection = .{ .bytes = reason },
        .rule = .reject_mechanical_failures_else_inconclusive,
        .budget = null,
        .expected_recurrences = null,
        .cases = .{ .items = &.{} },
        .candidates = .{ .items = &.{} },
        .registered_sources = .{ .items = &.{} },
        .trials = .{ .items = &.{} },
        .runs = .{ .items = &.{} },
        .ordinary_cold_wall_ms = null,
        .ordinary_recurring_wall = .{},
        .writes = .simulated,
        .decision = .ordinary_retained,
        .efficacy = .not_established,
        .owner_join = .required,
    }, 1024 * 1024);
}

fn encodeReport(a: std.mem.Allocator, report: e.Report, maximum: u32) !t.ExperimentResult {
    const bytes = try c.encodeOwned(e.Report, a, report);
    if (bytes.len > maximum or bytes.len > 1024 * 1024) return error.ExperimentReportBound;
    return .{
        .campaign = report.identity.campaign,
        .attempt = report.identity.attempt,
        .report = .{ .bytes = bytes },
        .accounting = .{},
    };
}
