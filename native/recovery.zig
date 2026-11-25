const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const materialize = @import("materialize.zig");
const recovery_status = @import("recovery_status.zig");
const bounds = @import("../app/bounds.zig");

pub fn advance(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    clock_ms: i64,
    model: ?t.ModelBinding,
) !?t.Id {
    const position = obligation.eligible orelse return null;
    const record = index.records[position];
    const service = driver.service;
    var saved = try service.task(a, record.task);
    defer saved.deinit();
    const status = try service.status(a, saved.value);
    const action = recovery_status.classify(
        status,
        saved.value.blocker,
        saved.value.current_occurrence,
        record.owner_snapshot orelse return error.MissingOwnerSnapshot,
    );
    const decision = recovery_status.decide(
        action,
        !obligation.ordinaryDispatch(),
        record.input.step.fold_only,
    );
    const cause: @FieldType(t.Supersession, "cause") = switch (decision) {
        .none => return null,
        .failed_fold => if (foldRetryReady(index, obligation, record.input.step, clock_ms))
            .failed
        else
            return error.FoldStepFailed,
        .replace => |reason| reason,
        .resume_captured, .resume_parked => blk: {
            const selected: recovery_status.Action = if (decision == .resume_captured)
                .{ .resume_captured = {} }
            else
                .{ .resume_parked = {} };
            const resumed = try recovery_status.resumeSelected(
                driver,
                a,
                record.task,
                saved.value.revision,
                selected,
                saved.value.current_occurrence,
            );
            if (resumed != .incompatible) return null;
            break :blk .incompatible;
        },
    };
    return try replace(driver, a, record, obligation.task, clock_ms, model, cause);
}

pub const fold_retry_max_ms: i64 = 3_600_000;

fn foldRetryReady(
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    failed: t.Step,
    clock_ms: i64,
) bool {
    var frozen = failed.previous.folded_directive_ordinal;
    for (failed.directives.items) |fact| frozen = @max(frozen, fact.value.ordinal);
    for (obligation.directives) |position|
        if (index.records[position].input.directive.ordinal > frozen) return true;
    const shift: u6 = @intCast(@min(failed.attempt, 6));
    const delay = @min(bounds.phase_retry_ms << shift, fold_retry_max_ms);
    return clock_ms >= failed.clock_ms +| delay or clock_ms < failed.clock_ms;
}

fn replace(
    driver: anytype,
    a: std.mem.Allocator,
    old: idx.Record,
    target: t.Id,
    clock_ms: i64,
    model: ?t.ModelBinding,
    cause: @FieldType(t.Supersession, "cause"),
) !t.Id {
    const operation = try std.fmt.allocPrint(a, "replace:{s}", .{
        std.fmt.bytesToHex(old.task, .lower),
    });
    defer a.free(operation);
    const cancelled = try driver.requestCancel(
        a,
        operation,
        old.task,
        "superseded application step",
    );
    const bytes = try c.encodeOwned(@TypeOf(cancelled.receipt), a, cancelled.receipt);
    defer a.free(bytes);
    var indexed = try driver.view(a);
    defer indexed.deinit();
    const current = &indexed.index;
    const obligation = current.obligation(target) orelse return error.UnknownObligation;
    const position = obligation.eligible orelse return error.StaleSupersession;
    if (!std.meta.eql(current.records[position].task, old.task)) return error.StaleSupersession;
    const replacement: t.Supersession = .{
        .input = .{ .task = old.task, .digest = old.input_digest },
        .attempt = old.input.step.attempt,
        .cancellation = .{
            .task = old.task,
            .operation = .{ .bytes = operation },
            .bytes = .{ .bytes = bytes },
        },
        .cause = cause,
        .phase = try @import("phase.zig").attempted(old),
    };
    var frozen = try materialize.replacement(a, current, target, clock_ms, model, replacement);
    defer frozen.deinit();
    const admitted = try driver.submit(
        a,
        frozen.value.envelope.operation.bytes,
        .{ .step = frozen.value },
    );
    return admitted.receipt.task;
}
