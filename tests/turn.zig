const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const turn = @import("../app/turn.zig");
const model = @import("../app/model.zig");
const m = @import("../app/model_contract.zig");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const function = try turn.emit(c, try model.emit(c), .{try m.P.declare(c)});
        return c.author.module(function, try c.schema(t.Failure));
    }
};

test "conversation turn admits only the checked model effect" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("turn diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = t.Turn,
        .Result = t.TurnResult,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(1, compiled.program.effects.len);
    try std.testing.expectEqualStrings(m.P.identity, compiled.program.effects[0].identity);
}
