const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const genesis = @import("../app/genesis.zig");
const t = @import("application_types");

const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        errdefer std.log.err("genesis authoring: {s}", .{
            c.author.lastDiagnostic().renderAlloc(c.builder.allocator()) catch "unavailable",
        });
        const entry = try genesis.emit(c);
        const initial = try horos.authoring.interop.schemaId(c.author, try c.schema(t.Genesis));
        const result = try horos.authoring.interop.schemaId(c.author, try c.schema(t.Head));
        const failure = try horos.authoring.interop.schemaId(c.author, try c.schema(t.Failure));
        const module = try c.author.module(entry, try c.schema(t.Failure));
        const function = module.functions[@intCast(module.entry)];
        try std.testing.expectEqual(1, function.parameters.len);
        try std.testing.expectEqual(initial, module.variables[@intCast(function.parameters[0])]);
        try std.testing.expectEqual(result, function.result);
        try std.testing.expectEqual(failure, module.failure);
        return module;
    }
};

test "genesis is a checked authored computation with no external effects" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("genesis diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = t.Genesis,
        .Result = t.Head,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
