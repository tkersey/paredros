const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");

pub fn rebuild(service: anytype, a: std.mem.Allocator, page_limit: u32) !idx.Index {
    if (page_limit == 0) return error.InvalidPageLimit;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var rows: std.ArrayList(idx.Row) = .empty;
    var cancellations: std.ArrayList(idx.Cancellation) = .empty;
    var after: ?t.Id = null;
    while (true) {
        const page = try retained.loadPage(service, scratch, after, page_limit, page_limit);
        for (page.snapshots) |loaded| {
            const row = retained.row(loaded);
            try rows.append(scratch, row);
            const decoded = try c.decodeOwned(t.Input, scratch, row.input.bytes);
            if (decoded.value == .step) if (decoded.value.step.supersession) |replacement| {
                const receipt = try idx.readCancellation(service, scratch, replacement.cancellation);
                try cancellations.append(scratch, receipt.value);
            };
            if (decoded.value == .turn) if (decoded.value.turn.replacement) |replacement| {
                const receipt = try idx.readCancellation(service, scratch, replacement.cancellation);
                try cancellations.append(scratch, receipt.value);
            };
        }
        const next = page.next orelse break;
        if (after) |previous| if (std.mem.order(u8, &previous, &next) != .lt)
            return error.InvalidTaskOrder;
        after = next;
    }
    return idx.Index.init(native, a, rows.items, cancellations.items);
}
