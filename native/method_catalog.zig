const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const e = @import("../app/experiment_contract.zig");
const idx = @import("index.zig");
const method = @import("method_external.zig");

pub fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn reportOf(record: idx.Record) !?t.ReportValue {
    switch (record.input) {
        .continuity_member => |input| return if (record.result != null) input.report else null,
        .experiment => |input| {
            const output = record.result orelse return null;
            const result = output.experiment;
            if (!std.meta.eql(input.campaign, result.campaign) or input.attempt != result.attempt)
                return error.InvalidExperiment;
            return .{ .plan = input.plan, .result = result };
        },
        else => return null,
    }
}

pub fn reportValue(index: *const idx.Index, reference: t.Reference) !t.ReportValue {
    const record = index.record(reference.task) orelse return error.MissingExperiment;
    if (record.result_digest == null or !std.meta.eql(record.result_digest.?, reference.digest))
        return error.InvalidExperiment;
    return try reportOf(record.*) orelse error.InvalidExperiment;
}

pub fn report(
    a: std.mem.Allocator,
    index: *const idx.Index,
    reference: t.Reference,
) !c.Decoded(e.Report) {
    const value = try reportValue(index, reference);
    var decoded = try c.decodeOwned(e.Report, a, value.result.report.bytes);
    errdefer decoded.deinit();
    const identity = decoded.value.identity;
    if (decoded.value.version != 1 or !std.meta.eql(value.result.campaign, identity.campaign) or
        value.result.attempt != identity.attempt or
        !std.meta.eql(hash(value.plan.bytes), identity.plan_digest))
        return error.InvalidExperimentReport;
    return decoded;
}

pub fn source(
    a: std.mem.Allocator,
    index: *const idx.Index,
    reference: t.Reference,
    digest: t.Digest,
    contract: t.Digest,
) !c.Decoded(t.RetainedMethodSource) {
    var registered = try report(a, index, reference);
    defer registered.deinit();
    if (registered.value.kind != .source_registration) return error.InvalidMethodSource;
    var found: ?e.RegisteredSource = null;
    for (registered.value.registered_sources.items) |entry| {
        if (!std.meta.eql(entry.source_digest, digest)) continue;
        if (found != null or !std.meta.eql(hash(entry.draft.bytes.bytes), digest) or
            !std.meta.eql(entry.draft.contract_digest, contract)) return error.InvalidMethodSource;
        found = entry;
    }
    const entry = found orelse return error.MissingMethodSource;
    const bytes = try c.encodeOwned(t.RetainedMethodSource, a, .{
        .source = reference,
        .source_digest = digest,
        .contract_digest = contract,
        .bytes = .{ .bytes = entry.draft.bytes.bytes },
    });
    defer a.free(bytes);
    return c.decodeOwned(t.RetainedMethodSource, a, bytes);
}

pub fn qualified(
    a: std.mem.Allocator,
    index: *const idx.Index,
    selected: @FieldType(t.Method, "retained"),
) !c.Decoded(t.RetainedMethodSource) {
    var comparison = try report(a, index, selected.report);
    defer comparison.deinit();
    const value = comparison.value;
    if (value.kind != .comparison or value.rejection != null or value.cases.items.len == 0 or
        !std.meta.eql(selected.applicability, value.identity.plan_digest))
        return error.InvalidMethodQualification;
    const local = index.record(selected.report.task).?.input == .experiment;
    var found: ?usize = null;
    for (value.candidates.items, 0..) |candidate, i| {
        if ((local and !std.meta.eql(candidate.source, selected.source)) or
            !std.meta.eql(candidate.source_digest, selected.source_digest) or
            !std.meta.eql(candidate.contract_digest, selected.contract_digest)) continue;
        if (found != null or candidate.disposition == .rejected or
            candidate.completed_runs != value.cases.items.len or
            candidate.passed_mechanical_rubric != value.cases.items.len)
            return error.InvalidMethodQualification;
        found = i;
    }
    try completeRuns(value, (found orelse return error.UnqualifiedMethod) + 1);
    return source(a, index, selected.source, selected.source_digest, selected.contract_digest);
}

fn completeRuns(value: e.Report, arm: usize) !void {
    var seen: [32]bool = @splat(false);
    var count: usize = 0;
    for (value.runs.items) |run| {
        if (run.arm != arm) continue;
        if (run.case_index >= value.cases.items.len or seen[run.case_index] or
            run.method_fault != null or !run.quality.required_present or
            !run.quality.forbidden_absent or !run.quality.within_output_bound or
            !run.quality.responsibility_preserved) return error.UnqualifiedMethod;
        seen[run.case_index] = true;
        count += 1;
    }
    if (count != value.cases.items.len) return error.UnqualifiedMethod;
}

pub fn adoption(a: std.mem.Allocator, index: *const idx.Index, selected: t.Method) !void {
    if (selected != .retained) return error.OrdinaryAdoption;
    if (!std.meta.eql(selected.retained.contract_digest, try method.contractDigest(a)))
        return error.IncompatibleMethodContract;
    if (selected.retained.state.bytes.len != 0 or selected.retained.consecutive_faults != 0)
        return error.InvalidInitialMethodState;
    var admitted = try qualified(a, index, selected.retained);
    defer admitted.deinit();
}
