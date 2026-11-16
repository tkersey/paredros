const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const mode = @import("../app/mode.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try mode.emit(c), try c.schema(t.Failure));
    }
};

test "responsibility modes are checked authored computation without effects" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("mode diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = mode.Input,
        .Result = t.Head,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
