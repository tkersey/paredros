const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const a = @import("../app/author.zig");
const t = @import("application_types");
const recovery = @import("../app/phase_recovery.zig");
const publication = @import("../app/check_publish.zig");

pub const Input = union(enum) {
    recovery: recovery.Input,
    failure: recovery.FailureInput,
    rejection: recovery.RejectionInput,
    publication: publication.Input,
    step: t.Step,
};

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const recover = try recovery.emit(c);
        const fail = try recovery.failure(c);
        const reject = try recovery.rejection(c);
        const publish = try publication.emit(c);
        const step = try @import("step.zig").emitStep(c);
        const function = try c.author.function("phase recovery witness", .{
            .input = try c.schema(Input),
        }, try c.schema(t.Head), &.{});
        const b = try c.author.body(function);
        const input = try b.parameter("input");
        const recovered = try b.caseOf(input, "recovery");
        const failed = try b.caseOf(input, "failure");
        const rejected = try b.caseOf(input, "rejection");
        const published = try b.caseOf(input, "publication");
        const stepped = try b.caseOf(input, "step");
        const result = try b.match(input, .{
            .recovery = try recovered.ret(try recovered.body().call(
                recover,
                .{ .input = recovered.payload() },
            )),
            .failure = try failed.ret(try failed.body().call(fail, .{ .input = failed.payload() })),
            .rejection = try rejected.ret(try rejected.body().call(
                reject,
                .{ .input = rejected.payload() },
            )),
            .publication = try published.ret(try published.body().field(
                try published.body().call(publish, .{ .input = published.payload() }),
                "head",
            )),
            .step = try stepped.ret(try stepped.body().field(
                try stepped.body().call(step, .{ .input = stepped.payload() }),
                "head",
            )),
        });
        try c.author.define(function, try b.ret(result));
        return c.author.module(function, try c.schema(t.Failure));
    }
};

test "phase recovery policy and step integration compile as checked pure computation" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("phase recovery diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = Input,
        .Result = t.Head,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
