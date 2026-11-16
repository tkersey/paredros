const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const step = @import("../app/step.zig");
const check = @import("../app/check.zig");

pub const Application = struct {
    pub fn emit(context: protean.Context) !horos.source.Module {
        const genesis = try @import("../app/genesis.zig").emit(context);
        const turn = try @import("../app/turn.zig").emit(
            context,
            try @import("control.zig").completion(context),
            &.{},
        );
        const advance = try step.emit(
            context,
            try @import("../app/directive_policy.zig").emit(context),
            try reader(context),
            try renderer(context),
            &.{},
        );
        const function = try context.author.function("Slack owner consumer application", .{
            .input = try context.schema(t.Input),
        }, try context.schema(t.Output), &.{});
        const b = try context.author.body(function);
        const input = try b.parameter("input");
        const initial = try b.caseOf(input, "genesis");
        const converse = try b.caseOf(input, "turn");
        const directive = try b.caseOf(input, "directive");
        const next = try b.caseOf(input, "step");
        const output = try context.schema(t.Output);
        const failure = try context.literal(t.Failure, .{
            .code = .{ .bytes = "unsupported_slack_owner_test" },
        });
        const result = try b.match(input, .{
            .genesis = try initial.ret(try initial.body().variant(
                output,
                "genesis",
                try initial.body().call(genesis, .{ .input = initial.payload() }),
            )),
            .turn = try converse.ret(try converse.body().variant(
                output,
                "turn",
                try converse.body().call(turn, .{ .input = converse.payload() }),
            )),
            .step = try next.ret(try next.body().variant(
                output,
                "step",
                try next.body().call(advance, .{ .input = next.payload() }),
            )),
            .directive = try directive.ret(try directive.body().variant(
                output,
                "directive",
                directive.payload(),
            )),
            .delivery = try (try b.caseOf(input, "delivery")).fail(output, failure),
            .audit = try (try b.caseOf(input, "audit")).fail(output, failure),
            .experiment = try (try b.caseOf(input, "experiment")).fail(output, failure),
            .continuity_member = try (try b.caseOf(input, "continuity_member")).fail(
                output,
                failure,
            ),
            .continuity_cut = try (try b.caseOf(input, "continuity_cut")).fail(output, failure),
            .restore = try (try b.caseOf(input, "restore")).fail(output, failure),
            .lineage_audit = try (try b.caseOf(input, "lineage_audit")).fail(output, failure),
        });
        try context.author.define(function, try b.ret(result));
        return context.author.module(function, try context.schema(t.Failure));
    }
};

fn reader(context: protean.Context) !check.Function {
    const function = try context.author.function("Slack owner simulated source gap", .{
        .input = try context.schema(check.Input),
    }, try context.schema(check.Result), &.{});
    const b = try context.author.body(function);
    const prior = try b.field(try b.parameter("input"), "previous");
    const none = try b.caseOf(prior, "none");
    const some = try b.caseOf(prior, "some");
    const baseline = try context.literal(check.Result, .{
        .kind = .baseline,
        .base = null,
        .tip = @splat('a'),
        .reason = null,
        .commits = .{ .items = &.{} },
        .evidence = .{ .items = &.{} },
    });
    const gap = try some.body().product(try context.schema(check.Result), .{
        .kind = try context.literal(@FieldType(check.Result, "kind"), .rejected),
        .base = prior,
        .tip = try context.literal(?t.Oid, @splat('b')),
        .reason = try context.literal(@FieldType(check.Result, "reason"), .diverged),
        .commits = try context.literal(check.Commits, .{ .items = &.{} }),
        .evidence = try context.literal(check.Evidence, .{ .items = &.{} }),
    });
    try context.author.define(function, try b.ret(try b.match(prior, .{
        .none = try none.ret(baseline),
        .some = try some.ret(gap),
    })));
    return function;
}

fn renderer(context: protean.Context) !step.Render {
    const function = try context.author.function("Slack owner identity render", .{
        .input = try context.schema(step.RenderInput),
    }, try context.schema(t.Head), &.{});
    const b = try context.author.body(function);
    try context.author.define(function, try b.ret(try b.field(try b.parameter("input"), "head")));
    return function;
}

test "Slack owner source composes checked turns local cancellation and source questions" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("Slack owner source diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = t.Input,
        .Result = t.Output,
        .Failure = t.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
