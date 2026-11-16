const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const method = @import("../app/method.zig");
const m = @import("../app/method_contract.zig");
const model = @import("../app/model.zig");
const model_contract = @import("../app/model_contract.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const completion = try model.emit(c);
        const invocation = try model_contract.P.declare(c);
        const ops = try method.declare(c);
        const function = try method.emit(
            c,
            ops,
            completion,
            .{ invocation, ops.workspace, ops.codec },
        );
        return c.author.module(function, try c.schema(t.Failure));
    }
};

test "retained method owns workspace and one caller checked model effect" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("method diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(
        std.testing.allocator,
        protean.system(.{
            .InitialArgs = m.MethodInput,
            .Result = m.Result,
            .Failure = t.Failure,
            .application = Application,
        }),
        .{ .horos_options = .{ .diagnostic = &diagnostic } },
    );
    defer compiled.deinit();
    try std.testing.expectEqual(3, compiled.program.effects.len);
    try std.testing.expectEqualStrings(
        model_contract.P.identity,
        compiled.program.effects[0].identity,
    );
    try std.testing.expectEqualStrings(
        m.workspace_identity,
        compiled.program.effects[1].identity,
    );
    try std.testing.expectEqualStrings(
        m.codec_identity,
        compiled.program.effects[2].identity,
    );
}
