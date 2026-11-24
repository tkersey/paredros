const std = @import("std");
const t = @import("application_types");
const transfer = @import("transfer.zig");

pub fn validate(index: anytype) !void {
    if (index.transferred()) return error.TransferredNamespace;
    if (transfer.importPending(index)) return error.ContinuityImportPending;
}

pub fn directive(a: std.mem.Allocator, index: anytype, target: t.Id) !void {
    if (!try transfer.pendingControlsAdmitted(a, index, target))
        return error.ContinuityControlsPending;
}
