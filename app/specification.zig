const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const bounds = @import("bounds.zig");

pub const Function = a.Function(struct { specification: t.Specification }, ?t.Name);

pub fn emit(c: protean.Context) !Function {
    const function = try c.author.function("validate specification bounds", .{
        .specification = try c.schema(t.Specification),
    }, try c.schema(?t.Name), &.{});
    const b = try c.author.body(function);
    const specification = try b.parameter("specification");
    const policies = try b.field(specification, "policies");
    var result = try b.select(
        try b.less(try half(c, b, policies), try prelude(c, b, specification)),
        try c.literal(?t.Name, .{ .bytes = "invalid_wording" }),
        try c.literal(?t.Name, null),
    );
    inline for (@typeInfo(t.Policies).@"struct".field_names) |name| {
        const bound = @field(bounds.policies, name);
        result = try outside(c, b, @FieldType(t.Policies, name), try b.field(policies, name), .{
            .min = bound.min,
            .max = bound.max,
            .reason = "invalid_policy_" ++ name,
        }, result);
    }
    result = try outside(c, b, i64, try b.field(specification, "anchor_ms"), .{
        .min = 0,
        .max = bounds.instant_ms_max,
        .reason = "invalid_anchor",
    }, result);
    result = try outside(c, b, u64, try b.field(specification, "interval_ms"), .{
        .min = bounds.interval.min,
        .max = bounds.interval.max,
        .reason = "invalid_interval",
    }, result);
    try c.author.define(function, try b.ret(result));
    return function;
}

fn half(c: protean.Context, b: anytype, policies: a.Value(t.Policies)) !a.Value(u64) {
    var limit = try b.constant(u64, bounds.policies.context_bytes.max);
    inline for (.{ "render_input_bytes", "context_bytes" }) |name| {
        const value = try b.field(policies, name);
        limit = try b.select(try b.less(value, limit), value, limit);
    }
    const failed = try a.failure(c, "render_limit");
    return b.checked(.divide, limit, try b.constant(u64, 2), .{
        .overflow = failed,
        .division_by_zero = failed,
    });
}

fn prelude(
    c: protean.Context,
    b: anytype,
    specification: a.Value(t.Specification),
) !a.Value(u64) {
    const overflow = try a.failure(c, "render_limit");
    const wording = try b.blobLength(try b.field(specification, "wording"));
    const ref = try b.blobLength(try b.field(try b.field(specification, "repository"), "ref"));
    return b.checked(.add, try b.checked(
        .add,
        try b.constant(u64, bounds.prelude_overhead_bytes),
        wording,
        .{ .overflow = overflow },
    ), ref, .{ .overflow = overflow });
}

pub fn valid(c: protean.Context, b: anytype, verdict: a.Value(?t.Name)) !a.Value(bool) {
    return b.equal(try b.variantTag(verdict), try b.variantTag(try c.literal(?t.Name, null)));
}

fn outside(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    value: a.Value(T),
    comptime rule: struct { min: comptime_int, max: comptime_int, reason: []const u8 },
    otherwise: a.Value(?t.Name),
) !a.Value(?t.Name) {
    const low = try b.less(value, try b.constant(T, rule.min));
    const high = try b.less(try b.constant(T, rule.max), value);
    return b.select(
        try b.select(low, try b.constant(bool, true), high),
        try c.literal(?t.Name, .{ .bytes = rule.reason }),
        otherwise,
    );
}
