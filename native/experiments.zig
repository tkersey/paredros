const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const e = @import("../app/experiment_contract.zig");
const idx = @import("index.zig");
const admission = @import("admission.zig");
const methods = @import("method_catalog.zig");

pub const Request = struct {
    campaign: t.Digest,
    attempt: u32,
    plan: e.Plan,
    live_model: bool,
};
pub const Attempt = struct {
    task: t.Id,
    number: u32,
    state: @FieldType(@import("retained.zig").Snapshot, "outcome"),
    accounting: t.Accounting,
    report: ?e.Report,
};
pub const Campaign = struct {
    identity: t.Digest,
    attempts: c.Vector(Attempt, null),
    accounting: t.Accounting,
    money_micros: ?u64 = null,
    efficacy: enum { not_established } = .not_established,
};

pub const OwnedCampaign = struct {
    arena: std.heap.ArenaAllocator,
    value: Campaign,

    pub fn deinit(self: *OwnedCampaign) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn admit(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    request: Request,
) !t.Id {
    if (!driver.attached or origin == .derived) return error.UnauthenticatedExperiment;
    const Materializer = struct {
        driver: @TypeOf(driver),
        value: Request,

        pub fn materialize(
            self: @This(),
            frame: std.mem.Allocator,
            requested: admission.Request,
        ) !t.Input {
            var index = try self.driver.rebuild(frame);
            defer index.deinit();
            try uniqueAttempt(&index, self.value.campaign, self.value.attempt);
            if (self.value.live_model) {
                const selected = self.driver.model orelse return error.ModelNotConfigured;
                if (self.value.plan != .compare or self.value.plan.compare.model == null or
                    !try equal(frame, t.ModelBinding, selected, self.value.plan.compare.model.?))
                    return error.ExperimentModelMismatch;
            }
            const evidence = try authenticatePlan(frame, &index, self.value.plan);
            const plan = try c.encodeOwned(e.Plan, frame, self.value.plan);
            if (plan.len > 1024 * 1024) return error.ExperimentPlanTooLarge;
            return .{ .experiment = .{
                .envelope = .{
                    .operation = .{ .bytes = requested.operation },
                    .stable_request = requested.digest,
                    .origin = requested.origin,
                },
                .campaign = self.value.campaign,
                .attempt = self.value.attempt,
                .plan = .{ .bytes = plan },
                .evidence = .{ .items = evidence },
                .live_model = self.value.live_model,
            } };
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = try admission.admit(driver.service, scratch, .{
        .operation = operation,
        .kind = .experiment,
        .target = null,
        .origin = origin,
        .digest = try admission.stableDigest(scratch, request),
    }, Materializer{ .driver = driver, .value = request });
    return result.receipt.task;
}

fn uniqueAttempt(index: *const idx.Index, campaign_id: t.Digest, number: u32) !void {
    for (index.records) |record| {
        if (record.input != .experiment) continue;
        const old = record.input.experiment;
        if (std.meta.eql(old.campaign, campaign_id) and old.attempt == number)
            return error.ExperimentAttemptConflict;
    }
}

fn equal(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const first = try c.encodeOwned(T, a, left);
    defer a.free(first);
    const second = try c.encodeOwned(T, a, right);
    defer a.free(second);
    return std.mem.eql(u8, first, second);
}

fn appendReference(
    a: std.mem.Allocator,
    index: *const idx.Index,
    references: *std.ArrayList(t.Reference),
    reference: t.Reference,
) !void {
    const record = index.record(reference.task) orelse return error.MissingExperimentEvidence;
    if (record.result_digest == null or !std.meta.eql(record.result_digest.?, reference.digest))
        return error.InvalidExperimentEvidence;
    for (references.items) |old| if (std.meta.eql(old, reference)) return;
    try references.append(a, reference);
}

pub fn authenticatePlan(
    a: std.mem.Allocator,
    index: *const idx.Index,
    plan: e.Plan,
) ![]const t.Reference {
    var references: std.ArrayList(t.Reference) = .empty;
    errdefer references.deinit(a);
    switch (plan) {
        .construct => |value| for (value.sources.items) |source| {
            for (source.provenance.items) |reference|
                try appendReference(a, index, &references, reference);
        },
        .compare => |value| {
            for (value.candidates.items) |candidate| {
                var source = try methods.source(
                    a,
                    index,
                    candidate.source.source,
                    candidate.source.source_digest,
                    candidate.source.contract_digest,
                );
                defer source.deinit();
                if (!try equal(a, t.RetainedMethodSource, candidate.source, source.value))
                    return error.MethodSourceMismatch;
                try appendReference(a, index, &references, candidate.source.source);
                for (candidate.construction_evidence.items) |reference|
                    try appendReference(a, index, &references, reference);
            }
            for (value.cases.items) |selected| {
                try authenticateCase(a, index, selected);
                try appendReference(a, index, &references, selected.input.step.predecessor);
                for (selected.input.step.batches.items) |batch|
                    try appendReference(a, index, &references, batch.reference);
            }
        },
    }
    return references.toOwnedSlice(a);
}

fn authenticateCase(a: std.mem.Allocator, index: *const idx.Index, selected: e.Case) !void {
    const step = selected.input.step;
    if (!try equal(a, t.Head, step.previous, selected.input.head))
        return error.ExperimentHeadMismatch;
    for (index.records) |record| {
        if (record.input != .step or !std.mem.eql(
            u8,
            record.input.step.envelope.operation.bytes,
            step.envelope.operation.bytes,
        )) continue;
        if (!try equal(a, t.Step, record.input.step, step)) return error.ExperimentInputMismatch;
        return;
    }
    return error.MissingRecordedExperimentCase;
}

pub fn campaign(a: std.mem.Allocator, index: *const idx.Index, id: t.Digest) !OwnedCampaign {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const value = try campaignValue(arena.allocator(), index, id);
    return .{ .arena = arena, .value = value };
}

fn campaignValue(a: std.mem.Allocator, index: *const idx.Index, id: t.Digest) !Campaign {
    var attempts: std.ArrayList(Attempt) = .empty;
    errdefer attempts.deinit(a);
    var totals: t.Accounting = .{};
    for (index.records) |record| {
        if (record.input != .experiment or
            !std.meta.eql(record.input.experiment.campaign, id)) continue;
        const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
        var report: ?e.Report = null;
        if (record.result != null and record.result.? == .experiment) {
            const decoded = try methods.report(a, index, .{
                .task = record.task,
                .digest = record.result_digest orelse return error.MissingExperimentReport,
            });
            report = decoded.value;
        }
        try addAccounting(&totals, snapshot.accounting);
        try attempts.append(a, .{
            .task = record.task,
            .number = record.input.experiment.attempt,
            .state = snapshot.outcome,
            .accounting = snapshot.accounting,
            .report = report,
        });
    }
    if (attempts.items.len == 0) return error.UnknownCampaign;
    std.mem.sort(Attempt, attempts.items, {}, struct {
        fn less(_: void, left: Attempt, right: Attempt) bool {
            return left.number < right.number;
        }
    }.less);
    for (attempts.items, 0..) |attempt, i| if (i > 0 and
        attempts.items[i - 1].number == attempt.number) return error.ExperimentAttemptConflict;
    return .{
        .identity = id,
        .attempts = .{ .items = try attempts.toOwnedSlice(a) },
        .accounting = totals,
    };
}

fn addAccounting(total: *t.Accounting, selected: t.Accounting) !void {
    inline for (@typeInfo(t.Accounting).@"struct".field_names) |name|
        @field(total, name) = try std.math.add(u64, @field(total, name), @field(selected, name));
}
