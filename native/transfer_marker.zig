const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const admission = @import("admission.zig");

pub fn inspect(a: std.mem.Allocator, index: anytype) !?usize {
    var found: ?usize = null;
    for (index.records, 0..) |item, position| {
        if (item.input != .transfer) continue;
        if (item.input.transfer.envelope.origin != .local) return error.TransferLocalOnly;
        if (item.result) |output| {
            if (output != .transfer) return error.TransferMarkerMismatch;
            const before = try c.encodeOwned(t.TransferMarker, a, item.input.transfer);
            defer a.free(before);
            const after = try c.encodeOwned(t.TransferMarker, a, output.transfer);
            defer a.free(after);
            if (!std.mem.eql(u8, before, after)) return error.TransferMarkerMismatch;
        }
        if (found != null) return error.DuplicateTransferMarker;
        found = position;
    }
    return found;
}

pub fn admit(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    request_digest: t.Digest,
) !t.Id {
    if (!driver.attached) return error.DriverDetached;
    if (origin != .local) return error.TransferLocalOnly;
    const request: admission.Request = .{
        .operation = operation,
        .kind = .transfer,
        .target = null,
        .origin = origin,
        .digest = request_digest,
    };
    const result = try admission.admit(driver, a, request, Marker(@TypeOf(driver)){
        .driver = driver,
    });
    return result.receipt.task;
}

fn Marker(comptime Driver: type) type {
    return struct {
        driver: Driver,

        pub fn materialize(
            self: @This(),
            a: std.mem.Allocator,
            request: admission.Request,
        ) !t.Input {
            var indexed = try self.driver.view(a);
            defer indexed.deinit();
            const index = &indexed.index;
            if (index.transferred()) return error.TransferredNamespace;
            if (@import("transfer.zig").importPending(index))
                return error.ContinuityImportPending;
            return .{ .transfer = .{ .envelope = .{
                .operation = .{ .bytes = request.operation },
                .stable_request = request.digest,
                .origin = request.origin,
            } } };
        }
    };
}
