const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const e = @import("../app/experiment_contract.zig");
const idx = @import("../native/index.zig");
const catalog = @import("../native/method_catalog.zig");
const method = @import("../native/method_external.zig");
const experiments = @import("../native/experiments.zig");
const retained = @import("../native/retained.zig");
const a = std.testing.allocator;

fn emptyReport() e.Report {
    return .{
        .kind = .source_registration,
        .identity = .{
            .campaign = @splat(1),
            .attempt = 0,
            .plan_digest = catalog.hash("source plan"),
            .mode = .source_registration,
        },
        .rejection = null,
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
    };
}

fn record(frame: std.mem.Allocator, id: u8, plan: []const u8, value: e.Report) !idx.Record {
    const input: t.Input = .{ .experiment = .{
        .envelope = .{
            .operation = .{ .bytes = "experiment" },
            .stable_request = @splat(id),
            .origin = .{ .local = .{ .uid = 501 } },
        },
        .campaign = value.identity.campaign,
        .attempt = value.identity.attempt,
        .plan = .{ .bytes = plan },
        .evidence = .{ .items = &.{} },
        .live_model = false,
    } };
    const output: t.Output = .{ .experiment = .{
        .campaign = value.identity.campaign,
        .attempt = value.identity.attempt,
        .report = .{ .bytes = try c.encodeOwned(e.Report, frame, value) },
        .accounting = .{},
    } };
    return .{
        .task = @splat(id),
        .revision = 4,
        .input_digest = catalog.hash(try c.encodeOwned(t.Input, frame, input)),
        .result_digest = catalog.hash(try c.encodeOwned(t.Output, frame, output)),
        .input = input,
        .result = output,
    };
}

const Fixture = struct {
    index: idx.Index,
    selected: @FieldType(t.Method, "retained"),

    fn init() !Fixture {
        var index: idx.Index = .{
            .arena = .init(a),
            .records = undefined,
            .obligations = &.{},
            .tasks = .empty,
        };
        errdefer index.deinit();
        const frame = index.arena.allocator();
        const contract = try method.contractDigest(frame);
        const sources = try frame.alloc(e.RegisteredSource, 1);
        sources[0] = .{
            .draft = .{
                .name = .{ .bytes = "candidate" },
                .bytes = .{ .bytes = "retained source bytes" },
                .contract_digest = contract,
                .provenance = .{ .items = &.{} },
                .origin = .operator_supplied,
            },
            .source_digest = catalog.hash("retained source bytes"),
            .qualification = .unqualified,
        };
        var source_report = emptyReport();
        source_report.registered_sources.items = sources;
        index.records = try frame.alloc(idx.Record, 2);
        index.records[0] = try record(frame, 2, "source plan", source_report);
        try index.tasks.put(frame, index.records[0].task, 0);
        const source_ref = index.reference(0);
        const qualified_report = try comparison(frame, source_ref, sources[0]);
        index.records[1] = try record(frame, 3, "comparison plan", qualified_report);
        try index.tasks.put(frame, index.records[1].task, 1);
        return .{ .index = index, .selected = .{
            .source = source_ref,
            .source_digest = sources[0].source_digest,
            .contract_digest = contract,
            .report = index.reference(1),
            .applicability = qualified_report.identity.plan_digest,
            .state = .{ .bytes = "" },
            .consecutive_faults = 0,
        } };
    }
};

fn comparison(
    frame: std.mem.Allocator,
    source_ref: t.Reference,
    source: e.RegisteredSource,
) !e.Report {
    var value = emptyReport();
    value.kind = .comparison;
    value.identity = .{
        .campaign = @splat(1),
        .attempt = 1,
        .plan_digest = catalog.hash("comparison plan"),
        .mode = .scripted_v1,
    };
    const cases = try frame.alloc(e.CaseEvidence, 1);
    cases[0] = .{
        .name = .{ .bytes = "withheld" },
        .condition = .withheld,
        .trial = 1,
        .input_digest = @splat(9),
        .rubric = .{ .required = .{ .items = &.{} }, .forbidden = .{ .items = &.{} } },
    };
    value.cases.items = cases;
    const candidates = try frame.alloc(e.CandidateEvidence, 1);
    candidates[0] = .{
        .name = source.draft.name,
        .source = source_ref,
        .source_digest = source.source_digest,
        .contract_digest = source.draft.contract_digest,
        .construction_evidence = .{ .items = &.{} },
        .source_bytes = source.draft.bytes.bytes.len,
        .disposition = .evidence_inconclusive,
        .completed_runs = 1,
        .passed_mechanical_rubric = 1,
        .cold_wall_ms = null,
        .recurring_wall = .{},
    };
    value.candidates.items = candidates;
    const runs = try frame.alloc(e.Run, 1);
    runs[0] = .{
        .case_index = 0,
        .arm = 1,
        .trial = 1,
        .condition = .withheld,
        .output = .{ .bytes = "inert output" },
        .output_digest = catalog.hash("inert output"),
        .method_fault = null,
        .quality = .{
            .required_present = true,
            .forbidden_absent = true,
            .within_output_bound = true,
            .responsibility_preserved = true,
        },
        .state_bytes = 0,
        .wall_elapsed_including_recovery_ms = null,
        .interruption_checkpoint = false,
    };
    value.runs.items = runs;
    return value;
}

test "method catalog binds retained bytes to registration and independent qualification" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    try catalog.adoption(a, &fixture.index, .{ .retained = fixture.selected });
    var source = try catalog.qualified(a, &fixture.index, fixture.selected);
    defer source.deinit();
    try std.testing.expectEqualStrings("retained source bytes", source.value.bytes.bytes);
    var wrong = fixture.selected;
    wrong.source_digest[0] ^= 1;
    try std.testing.expectError(
        error.UnqualifiedMethod,
        catalog.qualified(a, &fixture.index, wrong),
    );
    wrong = fixture.selected;
    wrong.report.digest[0] ^= 1;
    try std.testing.expectError(
        error.InvalidExperiment,
        catalog.qualified(a, &fixture.index, wrong),
    );
    wrong = fixture.selected;
    wrong.applicability[0] ^= 1;
    try std.testing.expectError(
        error.InvalidMethodQualification,
        catalog.qualified(a, &fixture.index, wrong),
    );
    wrong = fixture.selected;
    wrong.state.bytes = "unqualified cache";
    try std.testing.expectError(
        error.InvalidInitialMethodState,
        catalog.adoption(a, &fixture.index, .{ .retained = wrong }),
    );
}

test "method catalog rejects absent runs despite a claimed qualification count" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    const frame = fixture.index.arena.allocator();
    var decoded = try catalog.report(frame, &fixture.index, fixture.selected.report);
    defer decoded.deinit();
    decoded.value.runs.items = &.{};
    fixture.index.records[1] = try record(frame, 3, "comparison plan", decoded.value);
    fixture.selected.report = fixture.index.reference(1);
    try std.testing.expectError(
        error.UnqualifiedMethod,
        catalog.qualified(a, &fixture.index, fixture.selected),
    );
}

test "method catalog preserves returned source after releasing the retained index" {
    var fixture = try Fixture.init();
    var source = try catalog.qualified(a, &fixture.index, fixture.selected);
    defer source.deinit();
    fixture.index.deinit();
    try std.testing.expectEqualStrings("retained source bytes", source.value.bytes.bytes);
}

fn owned(record_value: idx.Record, accounting: t.Accounting) retained.Snapshot {
    const value: retained.Value = .{
        .schema_id = .{ .bytes = "experiment" },
        .encoding = .contract,
        .reference = .{ .digest = record_value.input_digest, .bytes = 0 },
    };
    return .{
        .task = record_value.task,
        .revision = record_value.revision,
        .event_cut = record_value.revision,
        .outcome = .completed,
        .input = value,
        .result = value,
        .profile = .{ .digest = @splat(0), .bytes = 0 },
        .inference_attempts = 0,
        .inference_request_bytes = 0,
        .inference_output_tokens = 0,
        .evidence_bytes = 0,
        .attempts = .{ .items = &.{} },
        .unknown_calls = .{ .items = &.{} },
        .accounting = accounting,
    };
}

test "method catalog campaign totals and settled accounting share owner snapshot values" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    fixture.index.records[0].owner_snapshot = owned(fixture.index.records[0], .{
        .known_calls = 2,
        .known_input_tokens = 30,
        .known_output_tokens = 7,
        .retained_bytes = 11,
    });
    fixture.index.records[1].owner_snapshot = owned(fixture.index.records[1], .{
        .known_calls = 1,
        .known_input_tokens = 5,
        .possible_charged_calls = 1,
        .failed_attempts = 1,
    });
    var observed = try experiments.campaign(a, &fixture.index, @splat(1));
    defer observed.deinit();
    const totals: t.Accounting = .{
        .known_calls = 3,
        .known_input_tokens = 35,
        .known_output_tokens = 7,
        .retained_bytes = 11,
        .possible_charged_calls = 1,
        .failed_attempts = 1,
    };
    try std.testing.expectEqualDeep(totals, observed.value.accounting);
    try std.testing.expectEqual(2, observed.value.attempts.items.len);
    for (observed.value.attempts.items, fixture.index.records) |attempt, row| {
        try std.testing.expectEqualDeep(
            experiments.measurements(totals),
            attempt.report.?.campaign_totals,
        );
        const result = (try experiments.settled(row)).?;
        try std.testing.expectEqualDeep(attempt.accounting, result.accounting);
    }
    try std.testing.expectEqual(3, experiments.measurements(totals).model_calls.?);
    try std.testing.expectEqual(1, experiments.measurements(totals).possible_charged_calls.?);
}
