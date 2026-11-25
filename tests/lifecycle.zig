const std = @import("std");
const t = @import("application_types");
const lifecycle = @import("../native/lifecycle.zig");
const continuity_control = @import("../native/continuity_control.zig");
const continuity_import = @import("../native/continuity_import.zig");

fn expectNames(comptime Table: type, comptime Code: type, comptime extra: []const u8) !void {
    const table = std.meta.fieldNames(Table);
    const code = std.meta.fieldNames(Code);
    try std.testing.expectEqual(code.len + 1, table.len);
    try std.testing.expectEqualStrings(extra, table[0]);
    for (code, table[1..]) |left, right| try std.testing.expectEqualStrings(left, right);
}

test "lifecycle tables name exactly the production lifecycle states" {
    try expectNames(
        lifecycle.Export,
        @FieldType(continuity_control.ExportProgress, "phase"),
        "idle",
    );
    try expectNames(lifecycle.Import, continuity_import.Phase, "absent");
    inline for (comptime std.enums.values(t.Mode)) |mode| {
        const final = mode == .cancelled or mode == .transferred;
        try std.testing.expectEqual(final, lifecycle.final(mode));
        try std.testing.expect(lifecycle.mode.rests(mode));
    }
}

test "lifecycle mode table folds every caller control from every state" {
    try std.testing.expectEqual(t.Mode.paused, lifecycle.fold(.active, .pause));
    try std.testing.expectEqual(t.Mode.active, lifecycle.fold(.paused, .@"resume"));
    try std.testing.expectEqual(t.Mode.cancelled, lifecycle.fold(.paused, .cancel));
    try std.testing.expectEqual(t.Mode.cancelled, lifecycle.fold(.cancelled, .@"resume"));
    try std.testing.expectEqual(t.Mode.transferred, lifecycle.fold(.transferred, .pause));
    try std.testing.expectEqual(t.Mode.active, lifecycle.fold(.active, .check));
}
