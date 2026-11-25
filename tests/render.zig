const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const step = @import("../app/step.zig");
const render = @import("../app/render.zig");
const model = @import("../app/model.zig");
const method = @import("../app/method.zig");
const m = @import("../app/model_contract.zig");

pub const Types = struct {
    pub const application_id = "paredros.render.witness";
    pub const application_version = "1.0.0";
    pub const Input = step.RenderInput;
    pub const Output = t.Head;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.render.input.v1";
    pub const output_schema_id = "paredros.render.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.render.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const completion = try model.emit(c);
        const ops = try method.declare(c);
        const effects = .{ try m.P.declare(c), ops.workspace, ops.codec };
        const retained = try method.emit(c, ops, completion, effects);
        const function = try render.emit(c, completion, retained, effects);
        return c.author.module(function, try c.schema(t.Failure));
    }
};

test "render composes checked model and retained method capabilities" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("ordinary render diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = Types.Input,
        .Result = Types.Output,
        .Failure = Types.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(3, compiled.program.effects.len);
    try std.testing.expectEqualStrings(m.P.identity, compiled.program.effects[0].identity);
}
