const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const frame = @import("../app/render_frame.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const oid = try @import("../app/oid_text.zig").emit(c);
        return c.author.module(try frame.emit(c, oid), try c.schema(t.Failure));
    }
};

test "render frame authoring compiles without model or external effects" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("render frame diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = frame.Input,
        .Result = frame.Result,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
