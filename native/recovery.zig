const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const catalog = @import("catalog.zig");
const materialize = @import("materialize.zig");
const recovery_status = @import("recovery_status.zig");

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
    const cause: ?@FieldType(t.Supersession, "cause") =
        if (!obligation.ordinaryDispatch() and !record.input.step.fold_only)
            .control
        else if (action == .replace)
            action.replace
        else
            null;
    if (record.input.step.fold_only and (status == .failed or status == .cancelled))
        return error.UnusableFoldAttempt;
    if (cause) |reason| return try replace(
        service,
        a,
        record,
        obligation.task,
        clock_ms,
        model,
        page_limit,
        reason,
    );
    const resumed = try recovery_status.resumeSelected(
        service,
        a,
        record.task,
        saved.value.revision,
        action,
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
