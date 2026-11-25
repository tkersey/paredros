const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const revision = @import("../app/revision.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try revision.emit(c), try c.schema(t.Failure));
    }
};

test "specification revisions compile to checked effect free authored computation" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("revision diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = revision.Input,
        .Result = revision.Result,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
