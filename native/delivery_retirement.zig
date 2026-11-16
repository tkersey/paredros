const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");
const target = @import("delivery_target.zig");
const slack = @import("../app/slack_contract.zig");

pub fn reconcile(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) !void {
    for (index.records) |record| {
        if (record.input != .delivery or record.result_digest != null or record.superseded)
            continue;
        const value = record.input.delivery;
        const resolved = target.resolve(index, value) orelse continue;
        if (!std.meta.eql(resolved, obligation.task) or !obsolete(index, obligation, value))
            continue;
        var saved = try service.task(a, record.task);
        defer saved.deinit();
        if (saved.value.terminal() or try service.status(a, saved.value) == .unknown) continue;
        const history = try service.notificationHistory(
            a,
            record.task,
            slack.notification_identity,
        );
        if (!history.transmissionExcluded()) continue;
        const operation = try std.fmt.allocPrint(a, "delivery-retire:{s}", .{
            std.fmt.bytesToHex(record.task, .lower),
        });
        defer a.free(operation);
        _ = try service.requestCancel(a, operation, record.task, "obsolete undispatched delivery");
        var current = try service.task(a, record.task);
        defer current.deinit();
        if (current.value.terminal()) continue;
        if (current.value.schedule == .parked) {
            _ = try @import("recovery_status.zig").resumeSelected(
                service,
                a,
                record.task,
                current.value.revision,
                .resume_parked,
                null,
            );
        } else try resumeOwner(service, a, record.task, current.value.revision);
    }
}

fn resumeOwner(service: anytype, a: std.mem.Allocator, task: t.Id, revision: u64) !void {
    const operation = try std.fmt.allocPrint(a, "delivery-retire-drive:{s}:{s}", .{
        std.fmt.bytesToHex(task, .lower),
        std.fmt.bytesToHex(service.owner_epoch, .lower),
    });
    defer a.free(operation);
    if (try service.operationLookup(a, operation)) |owned| {
        var receipt = owned;
        defer receipt.deinit();
        return;
    }
    _ = service.resumeTask(a, operation, task, revision) catch |err| switch (err) {
        error.IncompatibleProfile => return,
        else => return err,
    };
}

fn obsolete(index: *const idx.Index, obligation: *const idx.Obligation, value: t.Delivery) bool {
    if (value.key.purpose == .control or value.key.purpose == .turn) return false;
    if (obligation.effective_mode == .cancelled) return true;
    if (value.key.purpose != .question) return false;
    const head = index.head(obligation);
    const question = head.question orelse return true;
    return question.specification_revision != head.specification.revision or
        value.payload.logical.specification_revision != head.specification.revision or
        !std.meta.eql(question.prompt.key, value.key);
}
