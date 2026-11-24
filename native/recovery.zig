const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const catalog = @import("catalog.zig");
const materialize = @import("materialize.zig");
const recovery_status = @import("recovery_status.zig");
const bounds = @import("../app/bounds.zig");

pub fn advance(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    clock_ms: i64,
    model: ?t.ModelBinding,
    page_limit: u32,
) !?t.Id {
    const position = obligation.eligible orelse return null;
    const record = index.records[position];
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
    const selected: recovery_status.Action = switch (decision) {
        .none => return null,
        .failed_fold => {
            if (!foldRetryReady(index, obligation, record.input.step, clock_ms))
                return error.FoldStepFailed;
            return try replace(
                service,
                a,
                record,
                obligation.task,
                clock_ms,
                model,
                page_limit,
                .failed,
            );
        },
        .replace => |reason| return try replace(
            service,
            a,
            record,
            obligation.task,
            clock_ms,
            model,
            page_limit,
            reason,
        ),
        .resume_captured => .{ .resume_captured = {} },
        .resume_parked => .{ .resume_parked = {} },
    };
    const resumed = try recovery_status.resumeSelected(
        service,
        a,
        record.task,
        saved.value.revision,
        selected,
        saved.value.current_occurrence,
    );
    if (resumed == .incompatible)
        return try replace(
            service,
            a,
            record,
            obligation.task,
            clock_ms,
            model,
            page_limit,
            .incompatible,
        );
    return null;
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
    service: anytype,
    a: std.mem.Allocator,
    old: idx.Record,
    target: t.Id,
    clock_ms: i64,
    model: ?t.ModelBinding,
    page_limit: u32,
    cause: @FieldType(t.Supersession, "cause"),
) !t.Id {
    const operation = try std.fmt.allocPrint(a, "replace:{s}", .{
        std.fmt.bytesToHex(old.task, .lower),
    });
    defer a.free(operation);
    const cancelled = try service.requestCancel(
        a,
        operation,
        old.task,
        "superseded application step",
    );
    const bytes = try c.encodeOwned(@TypeOf(cancelled.receipt), a, cancelled.receipt);
    defer a.free(bytes);
    var current = try catalog.rebuild(service, a, page_limit);
    defer current.deinit();
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
    var frozen = try materialize.replacement(a, &current, target, clock_ms, model, replacement);
    defer frozen.deinit();
    const admitted = try service.submit(
        a,
        frozen.value.envelope.operation.bytes,
        .{ .step = frozen.value },
    );
    return admitted.receipt.task;
}
