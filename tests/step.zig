const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const a = @import("../app/author.zig");
const step = @import("../app/step.zig");
const check = @import("../app/check.zig");
const policy = @import("../app/directive_policy.zig");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try emitStep(c), try c.schema(t.Failure));
    }
};

pub fn emitStep(c: protean.Context) !step.Function {
    return step.emit(c, try policy.emit(c), try reader(c), try renderer(c), &.{});
}

fn reader(c: protean.Context) !check.Function {
    const function = try c.author.function("simulated source phase", .{
        .input = try c.schema(check.Input),
    }, try c.schema(check.Result), &.{});
    const b = try c.author.body(function);
    const prior = try b.field(try b.parameter("input"), "previous");
    const none = try b.caseOf(prior, "none");
    const some = try b.caseOf(prior, "some");
    const baseline = try c.literal(check.Result, .{
        .kind = .baseline,
        .base = null,
        .tip = @splat('a'),
        .reason = null,
        .commits = .{ .items = &.{} },
        .evidence = .{ .items = &.{} },
    });
    const unchanged = try some.body().product(try c.schema(check.Result), .{
        .kind = try c.literal(@FieldType(check.Result, "kind"), .unchanged),
        .base = prior,
        .tip = prior,
        .reason = try c.literal(@FieldType(check.Result, "reason"), null),
        .commits = try c.literal(check.Commits, .{ .items = &.{} }),
        .evidence = try c.literal(check.Evidence, .{ .items = &.{} }),
    });
    try c.author.define(function, try b.ret(try b.match(prior, .{
        .none = try none.ret(baseline),
        .some = try some.ret(unchanged),
    })));
    return function;
}

fn renderer(c: protean.Context) !step.Render {
    const function = try c.author.function("simulated render phase", .{
        .input = try c.schema(step.RenderInput),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const head = try b.field(try b.parameter("input"), "head");
    try c.author.define(function, try b.ret(try b.update(head, .{
        .render_failure_streak = try b.constant(u32, 42),
    })));
    return function;
}

test "bounded step composes authored policy source publication and settlement" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("step diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = t.Step,
        .Result = t.StepResult,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
