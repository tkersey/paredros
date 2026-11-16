const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const experiment = @import("../app/experiment.zig");
const e = @import("../app/experiment_contract.zig");
const method = @import("../app/method.zig");
const model = @import("../app/model.zig");
const m = @import("../app/model_contract.zig");

pub const Types = struct {
    pub const application_id = "paredros.experiment.witness";
    pub const application_version = "1.0.0";
    pub const Input = t.Experiment;
    pub const Output = t.ExperimentResult;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.experiment.input.v1";
    pub const output_schema_id = "paredros.experiment.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.experiment.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const completion = try model.emit(c);
        const method_ops = try method.declare(c);
        const ops = try experiment.declare(c);
        const function = try experiment.emit(c, ops, method_ops, completion, .{
            try m.P.declare(c), method_ops.workspace, method_ops.codec, ops.codec, ops.clock,
        });
        return c.author.module(function, try c.schema(t.Failure));
    }
};

test "experiment composes actual render and bounded method without a write capability" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("experiment diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = Types.Input,
        .Result = Types.Output,
        .Failure = Types.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(5, compiled.program.effects.len);
    var clock = false;
    var codec = false;
    const known = [_][]const u8{
        m.P.identity,
        @import("../app/method_contract.zig").workspace_identity,
        @import("../app/method_contract.zig").codec_identity,
        e.codec_identity,
        e.clock_identity,
    };
    for (compiled.program.effects) |effect| {
        var recognized = false;
        for (known) |identity| {
            recognized = recognized or std.mem.eql(u8, effect.identity, identity);
        }
        try std.testing.expect(recognized);
        clock = clock or std.mem.eql(u8, effect.identity, e.clock_identity);
        codec = codec or std.mem.eql(u8, effect.identity, e.codec_identity);
    }
    try std.testing.expect(clock and codec);
}
