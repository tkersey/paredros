const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const publish = @import("../app/check_publish.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try publish.emit(c), try c.schema(t.Failure));
    }
};

test "source publication compiles to checked pure authored computation" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("source publication diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = publish.Input,
        .Result = publish.Result,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
