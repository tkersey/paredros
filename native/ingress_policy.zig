const std = @import("std");
const t = @import("application_types");
const transfer = @import("transfer.zig");

pub fn validate(index: anytype) !void {
    if (index.recovery_purpose == .transfer) return error.TransferredNamespace;
    if (transfer.importPending(index)) return error.ContinuityImportPending;
}

pub fn output(index: anytype) !void {
    try validate(index);
    if (index.import_hold) return error.ContinuityImportHeld;
}

pub fn directive(
    a: std.mem.Allocator,
    index: anytype,
    target: t.Id,
    body: t.DirectiveBody,
) !void {
    switch (body) {
        .audit, .recovery_hold, .recovery_release => return,
        else => {},
    }
    if (!try transfer.pendingControlsAdmitted(a, index, target))
        return error.ContinuityControlsPending;
}
