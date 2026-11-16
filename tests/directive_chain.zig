const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const chain = @import("../app/directive_chain.zig");
const mode = @import("../app/mode.zig");
const t = @import("application_types");

pub const Types = struct {
    pub const application_id = "paredros.directive-chain.witness";
    pub const application_version = "1.0.0";
    pub const Input = chain.Input;
    pub const Output = chain.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.directive-chain.input.v1";
    pub const output_schema_id = "paredros.directive-chain.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.directive-chain.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try chain.emit(c, try modePolicy(c)), try c.schema(t.Failure));
    }
};

fn modePolicy(c: protean.Context) !chain.Apply {
    const transition = try mode.emit(c);
    const function = try c.author.function("directive chain test policy", .{
        .input = try c.schema(chain.ApplyInput),
    }, try c.schema(chain.Applied), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const body = try b.field(try b.field(input, "directive"), "body");
    var allowed = try b.constant(bool, false);
    var selected = try c.literal(mode.Control, .pause);
    inline for (.{ "pause", "resume", "cancel", "transfer" }) |name| {
        const is_control = try b.equal(try b.variantTag(body), try b.variantTag(try c.literal(t.DirectiveBody, @unionInit(t.DirectiveBody, name, {}))));
        allowed = try b.select(is_control, try b.constant(bool, true), allowed);
        selected = try b.select(is_control, try c.literal(mode.Control, @field(mode.Control, name)), selected);
    }
    const next = try b.call(transition, .{ .input = try b.product(try c.schema(mode.Input), .{
        .head = head,
        .control = selected,
    }) });
    const outcome = try b.select(allowed, try c.literal(chain.Outcome, .{ .applied = {} }), try c.literal(chain.Outcome, .{ .rejected = .{ .bytes = "test_policy_refusal" } }));
    const result = try b.product(try c.schema(chain.Applied), .{
        .head = try b.select(allowed, next, head),
        .outcome = outcome,
        .gap = try c.literal(?t.Batch, null),
        .notice = try c.literal(?t.DeliveryIntent, null),
        .audit_request = try c.literal(?t.AuditRequest, null),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

test "directive chain authored fold compiles without external capabilities" {
    var diagnostic: horos.source.Diagnostic = .{};
    errdefer std.debug.print("directive chain diagnostic {any}\n", .{diagnostic});
    var compiled = try protean.compileObserved(std.testing.allocator, protean.system(.{
        .InitialArgs = Types.Input,
        .Result = Types.Output,
        .Failure = Types.Failure,
        .application = Application,
    }), .{ .horos_options = .{ .diagnostic = &diagnostic } });
    defer compiled.deinit();
    try std.testing.expectEqual(0, compiled.program.effects.len);
}
