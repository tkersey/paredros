const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const chain = @import("../app/directive_chain.zig");
const policy = @import("../app/directive_policy.zig");

pub const Types = struct {
    pub const application_id = "paredros.directive-policy.witness";
    pub const application_version = "1.0.0";
    pub const Input = chain.Input;
    pub const Output = chain.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.directive-policy.input.v1";
    pub const output_schema_id = "paredros.directive-policy.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.directive-policy.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try chain.emit(c, try policy.emit(c)), try c.schema(t.Failure));
    }
};

test "directive policy composes complete authored control and evidence handling without effects" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("directive policy diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = Types.Input,
        .Result = Types.Output,
        .Failure = Types.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
