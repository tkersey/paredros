const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const check = @import("../app/check.zig");
const t = @import("application_types");
const g = @import("../app/github_contract.zig");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try check.emit(c), try c.schema(t.Failure));
    }
};

test "GitHub check uses one declared page read with authored frozen pagination" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("check diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = check.Input,
        .Result = check.Result,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(1, compiled.program.effects.len);
    try std.testing.expectEqualStrings(g.identity, compiled.program.effects[0].identity);
}
