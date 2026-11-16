const std = @import("std");
const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const mode = @import("mode.zig");

pub const Change = union(enum) {
    amend: t.Amendment,
    adopt: @FieldType(t.DirectiveBody, "adopt"),
    revert: @FieldType(t.DirectiveBody, "revert"),
};
pub const Input = struct { head: t.Head, change: Change };
pub const Disposition = union(enum) { applied: void, rejected: t.Name };
pub const Result = struct { head: t.Head, disposition: Disposition };
pub const Function = a.Function(struct { input: Input }, Result);

pub fn emit(c: protean.Context) !Function {
    const function = try c.author.function("fold specification revision", .{
        .input = try c.schema(Input),
    }, try c.schema(Result), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const change = try b.field(input, "change");
    const amend = try b.caseOf(change, "amend");
    const adopt = try b.caseOf(change, "adopt");
    const revert = try b.caseOf(change, "revert");
    const result = try b.match(change, .{
        .amend = try amend.ret(try fold(c, amend.body(), head, amend.payload(), "amend")),
        .adopt = try adopt.ret(try fold(c, adopt.body(), head, adopt.payload(), "adopt")),
        .revert = try revert.ret(try fold(c, revert.body(), head, revert.payload(), "revert")),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn fold(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    change: anytype,
    comptime tag: []const u8,
) !a.Value(Result) {
    const specification = try b.field(head, "specification");
    const revision = try b.field(specification, "revision");
    const current_mode = try b.field(head, "mode");
    const final = try b.select(
        try mode.enumIs(c, b, t.Mode, current_mode, .cancelled),
        try b.constant(bool, true),
        try mode.enumIs(c, b, t.Mode, current_mode, .transferred),
    );
    const current = try b.equal(revision, try b.field(change, "expected_revision"));
    const space = try b.less(revision, try b.constant(u64, std.math.maxInt(u64)));
    const permitted = try permittedChange(c, b, specification, change, tag);
    const no = try b.constant(bool, false);
    const change_valid = try b.select(space, permitted, no);
    const valid = try b.select(final, no, try b.select(current, change_valid, no));
    const invalid = if (comptime std.mem.eql(u8, tag, "amend"))
        "invalid_interval"
    else
        "ordinary_adoption";
    const admissibility = try b.select(
        space,
        try name(c, invalid),
        try name(c, "revision_overflow"),
    );
    const guarded = try b.select(current, admissibility, try name(c, "stale_revision"));
    const code = try b.select(final, try name(c, "final_head"), guarded);
    const accepted = try b.branch();
    const rejected = try b.branch();
    const next = try changedHead(c, accepted, head, change, tag);
    return b.conditional(valid, try accepted.ret(try accepted.product(try c.schema(Result), .{
        .head = next,
        .disposition = try c.literal(Disposition, .{ .applied = {} }),
    })), try rejected.ret(try rejected.product(try c.schema(Result), .{
        .head = head,
        .disposition = try rejected.variant(try c.schema(Disposition), "rejected", code),
    })));
}

fn name(c: protean.Context, bytes: []const u8) !a.Value(t.Name) {
    return c.literal(t.Name, .{ .bytes = bytes });
}

fn permittedChange(
    _: protean.Context,
    b: anytype,
    specification: a.Value(t.Specification),
    change: anytype,
    comptime tag: []const u8,
) !a.Value(bool) {
    if (comptime std.mem.eql(u8, tag, "amend")) {
        const interval = try optional(
            b,
            u64,
            try b.field(change, "interval_ms"),
            try b.field(specification, "interval_ms"),
        );
        return b.less(try b.constant(u64, 0), interval);
    }
    if (comptime std.mem.eql(u8, tag, "adopt")) {
        const method = try b.field(change, "method");
        const ordinary = try b.caseOf(method, "ordinary");
        const retained = try b.caseOf(method, "retained");
        return b.match(method, .{
            .ordinary = try ordinary.ret(try ordinary.body().constant(bool, false)),
            .retained = try retained.ret(try retained.body().constant(bool, true)),
        });
    }
    return b.constant(bool, true);
}

fn changedHead(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    change: anytype,
    comptime tag: []const u8,
) !a.Value(t.Head) {
    const previous = try b.field(head, "specification");
    const revision = try b.checked(
        .add,
        try b.field(previous, "revision"),
        try b.constant(u64, 1),
        .{ .overflow = try a.failure(c, "revision_overflow") },
    );
    if (comptime std.mem.eql(u8, tag, "amend")) {
        const specification = try b.update(previous, .{
            .revision = revision,
            .interval_ms = try optional(
                b,
                u64,
                try b.field(change, "interval_ms"),
                try b.field(previous, "interval_ms"),
            ),
            .wording = try optional(
                b,
                t.Text,
                try b.field(change, "wording"),
                try b.field(previous, "wording"),
            ),
            .policies = try optional(
                b,
                t.Policies,
                try b.field(change, "policies"),
                try b.field(previous, "policies"),
            ),
            .repository = try repository(
                b,
                try b.field(previous, "repository"),
                try b.field(change, "repository_route"),
            ),
        });
        return b.update(head, .{ .specification = specification });
    }
    return b.update(head, .{
        .specification = try b.update(previous, .{ .revision = revision }),
        .method = if (comptime std.mem.eql(u8, tag, "adopt"))
            try b.field(change, "method")
        else
            try c.literal(t.Method, .{ .ordinary = {} }),
    });
}

fn optional(
    b: anytype,
    comptime T: type,
    value: a.Value(?T),
    previous: a.Value(T),
) !a.Value(T) {
    const none = try b.caseOf(value, "none");
    const some = try b.caseOf(value, "some");
    return b.match(value, .{
        .none = try none.ret(previous),
        .some = try some.ret(some.payload()),
    });
}

fn repository(
    b: anytype,
    previous: a.Value(t.Repository),
    route: a.Value(@FieldType(t.Amendment, "repository_route")),
) !a.Value(t.Repository) {
    const none = try b.caseOf(route, "none");
    const some = try b.caseOf(route, "some");
    const changed = try some.body().update(previous, .{
        .owner = try some.body().field(some.payload(), "owner"),
        .name = try some.body().field(some.payload(), "name"),
    });
    return b.match(route, .{ .none = try none.ret(previous), .some = try some.ret(changed) });
}
