const std = @import("std");
const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const temporal = @import("temporal.zig");
const specification_bounds = @import("specification.zig");

pub const Change = union(enum) {
    amend: t.Amendment,
    adopt: @FieldType(t.DirectiveBody, "adopt"),
    revert: @FieldType(t.DirectiveBody, "revert"),
};
pub const Input = struct { head: t.Head, change: Change };
pub const Disposition = @FieldType(t.DirectiveDisposition, "outcome");
pub const Result = struct { head: t.Head, disposition: Disposition };
pub const Function = a.Function(struct { input: Input }, Result);
const Tools = struct {
    validate: specification_bounds.Function,
    next: temporal.Function,
    due: temporal.AdvanceDue,
};

pub fn emit(c: protean.Context) !Function {
    const tools: Tools = .{
        .validate = try specification_bounds.emit(c),
        .next = try temporal.emit(c),
        .due = try temporal.advanceDue(c),
    };
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
        .amend = try amend.ret(try fold(c, amend.body(), tools, head, amend.payload(), "amend")),
        .adopt = try adopt.ret(try fold(c, adopt.body(), tools, head, adopt.payload(), "adopt")),
        .revert = try revert.ret(
            try fold(c, revert.body(), tools, head, revert.payload(), "revert"),
        ),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn fold(
    c: protean.Context,
    b: anytype,
    tools: Tools,
    head: a.Value(t.Head),
    change: anytype,
    comptime tag: []const u8,
) !a.Value(Result) {
    const specification = try b.field(head, "specification");
    const revision = try b.field(specification, "revision");
    const current = try b.equal(revision, try b.field(change, "expected_revision"));
    const space = try b.less(revision, try b.constant(u64, std.math.maxInt(u64)));
    const verdict = try permittedChange(c, b, tools, specification, change, tag);
    const no = try b.constant(bool, false);
    const change_valid = try b.select(space, try b.field(verdict, "permitted"), no);
    const valid = try b.select(current, change_valid, no);
    const admissibility = try b.select(
        space,
        try b.field(verdict, "reason"),
        try name(c, "revision_overflow"),
    );
    const code = try b.select(current, admissibility, try name(c, "stale_revision"));
    const accepted = try b.branch();
    const rejected = try b.branch();
    const next = try changedHead(c, accepted, tools, head, change, tag);
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

const Verdict = struct { permitted: bool, reason: t.Name };

fn permittedChange(
    c: protean.Context,
    b: anytype,
    tools: Tools,
    specification: a.Value(t.Specification),
    change: anytype,
    comptime tag: []const u8,
) !a.Value(Verdict) {
    if (comptime std.mem.eql(u8, tag, "amend")) {
        const verdict = try b.call(tools.validate, .{
            .specification = try amended(b, specification, change),
        });
        const none = try b.caseOf(verdict, "none");
        const some = try b.caseOf(verdict, "some");
        return b.product(try c.schema(Verdict), .{
            .permitted = try specification_bounds.valid(c, b, verdict),
            .reason = try b.match(verdict, .{
                .none = try none.ret(try name(c, "invalid_specification")),
                .some = try some.ret(some.payload()),
            }),
        });
    }
    const permitted = if (comptime std.mem.eql(u8, tag, "adopt")) blk: {
        const method = try b.field(change, "method");
        const ordinary = try b.caseOf(method, "ordinary");
        const retained = try b.caseOf(method, "retained");
        break :blk try b.match(method, .{
            .ordinary = try ordinary.ret(try ordinary.body().constant(bool, false)),
            .retained = try retained.ret(try retained.body().constant(bool, true)),
        });
    } else try b.constant(bool, true);
    return b.product(try c.schema(Verdict), .{
        .permitted = permitted,
        .reason = try name(c, "ordinary_adoption"),
    });
}

fn amended(
    b: anytype,
    previous: a.Value(t.Specification),
    change: a.Value(t.Amendment),
) !a.Value(t.Specification) {
    return b.update(previous, .{
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
}

fn changedHead(
    c: protean.Context,
    b: anytype,
    tools: Tools,
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
        const specification = try b.update(
            try amended(b, previous, change),
            .{ .revision = revision },
        );
        return b.update(try rescheduled(c, b, tools, head, previous, specification), .{
            .specification = specification,
            .question = try answerable(c, b, head, change),
        });
    }
    return b.update(head, .{
        .specification = try b.update(previous, .{ .revision = revision }),
        .method = if (comptime std.mem.eql(u8, tag, "adopt"))
            try b.field(change, "method")
        else
            try c.literal(t.Method, .{ .ordinary = {} }),
    });
}

fn rescheduled(
    c: protean.Context,
    b: anytype,
    tools: Tools,
    head: a.Value(t.Head),
    previous: a.Value(t.Specification),
    specification: a.Value(t.Specification),
) !a.Value(t.Head) {
    const interval = try b.field(specification, "interval_ms");
    const schedule = try b.field(head, "schedule");
    const due = try b.field(schedule, "next_due_ms");
    const clock = try b.field(head, "clock_ms");
    const anchor = try b.field(specification, "anchor_ms");
    const passed = try b.call(tools.due, .{ .input = try b.product(
        try c.schema(temporal.DueInput),
        .{
            .anchor_ms = anchor,
            .interval_ms = try b.field(previous, "interval_ms"),
            .next_due_ms = due,
            .clock_ms = clock,
        },
    ) });
    const recomputed = try b.call(tools.next, .{ .input = try b.product(
        try c.schema(temporal.Input),
        .{ .anchor_ms = anchor, .interval_ms = interval, .clock_ms = clock },
    ) });
    const changed = try b.booleanNot(try b.equal(try b.field(previous, "interval_ms"), interval));
    const owed = try b.select(try b.less(clock, due), recomputed, clock);
    const coalesced = try b.select(changed, try b.field(passed, "coalesced"), try b.constant(
        u64,
        0,
    ));
    return b.update(head, .{
        .schedule = try b.update(schedule, .{
            .next_due_ms = try b.select(changed, owed, due),
        }),
        .skipped_slots = try b.checked(
            .add,
            try b.field(head, "skipped_slots"),
            coalesced,
            .{ .overflow = try a.failure(c, "skipped_slot_overflow") },
        ),
    });
}

fn answerable(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    change: a.Value(t.Amendment),
) !a.Value(?t.Question) {
    const route = try b.field(change, "repository_route");
    const none = try b.caseOf(route, "none");
    const some = try b.caseOf(route, "some");
    const sb = some.body();
    const current = try sb.field(try sb.field(head, "specification"), "repository");
    var same = try sb.constant(bool, true);
    inline for (.{ "owner", "name" }) |field| same = try sb.select(same, try sb.equal(
        try sb.blobCompare(try sb.field(current, field), try sb.field(some.payload(), field)),
        try sb.constant(i8, 0),
    ), try sb.constant(bool, false));
    const question = try b.field(head, "question");
    return b.match(route, .{
        .none = try none.ret(question),
        .some = try some.ret(try sb.select(same, question, try c.literal(?t.Question, null))),
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
