const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const model = @import("../app/model.zig");
const m = @import("../app/model_contract.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try model.emit(c), try c.schema(t.Failure));
    }
};

test "configured model candidate uses the existing checked model construction" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("model diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = m.Input,
        .Result = m.Result,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(1, compiled.program.effects.len);
    try std.testing.expectEqualStrings(m.P.identity, compiled.program.effects[0].identity);
    try std.testing.expectEqual(2, m.P.declaration_count);
}
