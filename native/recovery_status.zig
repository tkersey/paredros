const std = @import("std");
const native = @import("protean_native");
const t = @import("application_types");
const retained = @import("retained.zig");
const idx = @import("index.zig");

pub const Action = union(enum) {
    stay: void,
    resume_captured: void,
    resume_parked: void,
    replace: @FieldType(t.Supersession, "cause"),
};
pub const Resume = enum { unchanged, resumed, incompatible };
pub const Decision = union(enum) {
    none: void,
    resume_captured: void,
    resume_parked: void,
    replace: @FieldType(t.Supersession, "cause"),
    unusable: void,
};
pub const Turn = struct {
    status: native.tasks.Status,
    action: Action,
    revision: u64,
    occurrence: ?t.Digest,
};

pub fn recoverableTurn(record: idx.Record) bool {
    return record.input == .turn and !record.superseded and record.result == null;
}

pub fn turn(service: anytype, a: std.mem.Allocator, record: idx.Record) !Turn {
    std.debug.assert(recoverableTurn(record));
    var saved = try service.task(a, record.task);
    defer saved.deinit();
    const status = try service.status(a, saved.value);
    return .{
        .status = status,
        .action = classify(
            status,
            saved.value.blocker,
            saved.value.current_occurrence,
            record.owner_snapshot orelse return error.MissingOwnerSnapshot,
        ),
        .revision = saved.value.revision,
        .occurrence = saved.value.current_occurrence,
    };
}

pub fn classify(
    status: native.tasks.Status,
    blocker: anytype,
    current_occurrence: ?t.Digest,
    snapshot: retained.Snapshot,
) Action {
    return switch (status) {
        .failed => .{ .replace = .failed },
        .cancelled => .{ .replace = .control },
        .unknown => .{ .replace = .unknown },
        .parked => .{ .resume_parked = {} },
        .blocked => blocked(blocker, current_occurrence, snapshot),
        else => .{ .stay = {} },
    };
}

pub fn decide(action: Action, fenced: bool, fold_only: bool) Decision {
    switch (action) {
        .resume_captured => return .{ .resume_captured = {} },
        .replace => |cause| if (fold_only and (cause == .failed or cause == .control))
            return .{ .unusable = {} },
        .stay, .resume_parked => {},
    }
    if (fenced and !fold_only) return .{ .replace = .control };
    return switch (action) {
        .stay => .{ .none = {} },
        .resume_parked => .{ .resume_parked = {} },
        .replace => |cause| .{ .replace = cause },
        .resume_captured => unreachable,
    };
}

fn blocked(
    blocker: anytype,
    current_occurrence: ?t.Digest,
    snapshot: retained.Snapshot,
) Action {
    const reason = blocker orelse return .{ .stay = {} };
    if (reason == .incompatible_profile) return .{ .replace = .incompatible };
    if (reason == .observation_blocked or reason == .waiting_workspace)
        return .{ .stay = {} };
    if (current_occurrence) |occurrence| {
        for (snapshot.attempts.items) |attempt| {
            if (!std.meta.eql(attempt.occurrence, occurrence)) continue;
            if (attempt.capture) |capture| if (capture.disposition == .complete)
                return .{ .resume_captured = {} };
        }
    }
    return .{ .replace = .rejected };
}

pub fn resumeSelected(
    service: anytype,
    a: std.mem.Allocator,
    task: t.Id,
    revision: u64,
    action: Action,
    current_occurrence: ?t.Digest,
) !Resume {
    const operation = switch (action) {
        .resume_captured => try std.fmt.allocPrint(a, "capture-resume:{s}:{s}", .{
            std.fmt.bytesToHex(task, .lower),
            std.fmt.bytesToHex(
                current_occurrence orelse return error.MissingCapturedOccurrence,
                .lower,
            ),
        }),
        .resume_parked => try std.fmt.allocPrint(a, "resume:{s}:{d}", .{
            std.fmt.bytesToHex(task, .lower), revision,
        }),
        else => return .unchanged,
    };
    defer a.free(operation);
    if (try service.operationLookup(a, operation)) |saved| {
        var receipt = saved;
        receipt.deinit();
        return .unchanged;
    }
    _ = service.resumeTask(a, operation, task, revision) catch |err| switch (err) {
        error.IncompatibleProfile => return .incompatible,
        else => return err,
    };
    return .resumed;
}
