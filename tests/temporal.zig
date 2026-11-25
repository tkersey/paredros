const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const temporal = @import("../app/temporal.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try temporal.emit(c), try c.schema(t.Failure));
    }
};

test "temporal next anchor is authored with checked arithmetic and no external effect" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("temporal diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = temporal.Input,
        .Result = i64,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
