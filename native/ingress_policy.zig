const std = @import("std");
const t = @import("application_types");
const transfer = @import("transfer.zig");

pub fn validate(a: std.mem.Allocator, index: anytype, namespace: t.Digest) !void {
    if (index.recovery_purpose == .transfer) return error.TransferredNamespace;
    if (try transfer.importPending(a, index, namespace)) return error.ContinuityImportPending;
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
