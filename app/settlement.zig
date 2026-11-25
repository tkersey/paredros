const std = @import("std");
const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const bytes = @import("bytes.zig");

pub const Input = struct { head: t.Head, facts: @FieldType(t.Step, "facts") };
pub const Function = a.Function(struct { input: Input }, t.Head);
const Consumed = @FieldType(t.Head, "consumed");
const State = struct { input: Input, head: t.Head, index: u64 };
const Loop = a.Function(struct { state: State }, t.Head);
const UniqueArgs = struct { references: Consumed, reference: t.RevisionReference, index: u64 };
const Unique = a.Function(UniqueArgs, bool);

pub fn emit(c: protean.Context) !Function {
    const unique = try uniqueFunction(c, try bytes.emit(c, 16));
    const loop = try foldLoop(c, unique);
    const function = try c.author.function("fold retained settlements", .{
        .input = try c.schema(Input),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.update(try b.field(input, "head"), .{
        .consumed = try c.literal(Consumed, .{ .items = &.{} }),
    });
    const result = try b.call(loop, .{ .state = try b.product(try c.schema(State), .{
        .input = input,
        .head = head,
        .index = try b.constant(u64, 0),
    }) });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn foldLoop(c: protean.Context, unique: Unique) !Loop {
    const loop = try c.author.function("consume next settlement revision", .{
        .state = try c.schema(State),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(loop);
    const state = try b.parameter("state");
    const input = try b.field(state, "input");
    const facts = try b.field(input, "facts");
    const index = try b.field(state, "index");
    const head = try b.field(state, "head");
    const more = try b.branch();
    const done = try b.branch();
    const fact = try more.variantPayload(
        try more.sequenceGet(facts, index),
        "some",
        try a.failure(c, "settlement_bounds"),
    );
    const next = try foldOne(c, more, unique, input, head, fact);
    const continued = try more.call(loop, .{ .state = try more.update(state, .{
        .head = next,
        .index = try more.checked(.add, index, try more.constant(u64, 1), .{
            .overflow = try a.failure(c, "settlement_count_overflow"),
        }),
    }) });
    const result = try b.conditional(
        try b.less(index, try b.sequenceLength(facts)),
        try more.ret(continued),
        try done.ret(head),
    );
    try c.author.define(loop, try b.ret(result));
    return loop;
}

fn foldOne(
    c: protean.Context,
    b: anytype,
    unique: Unique,
    input: a.Value(Input),
    head: a.Value(t.Head),
    fact: a.Value(t.Settlement),
) !a.Value(t.Head) {
    const reference = try b.field(fact, "reference");
    const consumed = try b.field(head, "consumed");
    try a.require(c, b, try b.call(unique, .{
        .references = consumed,
        .reference = reference,
        .index = try b.constant(u64, 0),
    }), "duplicate_settlement");
    try a.require(c, b, try b.call(unique, .{
        .references = try b.field(try b.field(input, "head"), "consumed"),
        .reference = reference,
        .index = try b.constant(u64, 0),
    }), "previous_settlement");
    try previousAccounting(c, b, fact);
    return b.update(head, .{
        .accounting = try accounting(c, b, try b.field(head, "accounting"), fact),
        .consumed = try b.append(consumed, reference, .{
            .capacity = try a.failure(c, "settlement_capacity"),
        }),
    });
}

fn accounting(
    c: protean.Context,
    b: anytype,
    old: a.Value(t.Accounting),
    fact: a.Value(t.Settlement),
) !a.Value(t.Accounting) {
    return b.product(try c.schema(t.Accounting), .{
        .known_calls = try increment(c, b, old, fact, "known_calls"),
        .known_input_tokens = try increment(c, b, old, fact, "known_input_tokens"),
        .known_output_tokens = try increment(c, b, old, fact, "known_output_tokens"),
        .retained_bytes = try increment(c, b, old, fact, "retained_bytes"),
        .failed_attempts = try increment(c, b, old, fact, "failed_attempts"),
        .possible_charged_calls = try possibleCharges(c, b, old, fact),
    });
}

fn increment(
    c: protean.Context,
    b: anytype,
    old: a.Value(t.Accounting),
    fact: a.Value(t.Settlement),
    comptime field: []const u8,
) !a.Value(u64) {
    const before = try b.field(try b.field(fact, "previous_accounting"), field);
    const after = try b.field(try b.field(fact, "accounting"), field);
    const delta = try b.checked(.subtract, after, before, .{
        .overflow = try a.failure(c, "accounting_regression"),
    });
    return b.checked(.add, try b.field(old, field), delta, .{
        .overflow = try a.failure(c, "accounting_overflow"),
    });
}

fn possibleCharges(
    c: protean.Context,
    b: anytype,
    old: a.Value(t.Accounting),
    fact: a.Value(t.Settlement),
) !a.Value(u64) {
    const before = try b.field(try b.field(fact, "previous_accounting"), "possible_charged_calls");
    const after = try b.field(try b.field(fact, "accounting"), "possible_charged_calls");
    const total = try b.field(old, "possible_charged_calls");
    const resolved = try b.branch();
    const added = try b.branch();
    const underflow = try a.failure(c, "unknown_charge_underflow");
    const overflow = try a.failure(c, "accounting_overflow");
    const removed = try resolved.checked(.subtract, before, after, .{ .overflow = underflow });
    const remaining = try resolved.checked(.subtract, total, removed, .{ .overflow = underflow });
    const extra = try added.checked(.subtract, after, before, .{ .overflow = overflow });
    const sum = try added.checked(.add, total, extra, .{ .overflow = overflow });
    return b.conditional(
        try b.less(after, before),
        try resolved.ret(remaining),
        try added.ret(sum),
    );
}

fn previousAccounting(c: protean.Context, b: anytype, fact: a.Value(t.Settlement)) !void {
    const reference = try b.field(fact, "reference");
    const prior = try b.field(fact, "previous_reference");
    const none = try b.caseOf(prior, "none");
    const some = try b.caseOf(prior, "some");
    const nb = none.body();
    const sb = some.body();
    const empty = try same(
        c,
        nb,
        t.Accounting,
        try nb.field(fact, "previous_accounting"),
        try c.literal(t.Accounting, .{}),
    );
    const same_task = try same(
        c,
        sb,
        t.Id,
        try sb.field(reference, "task"),
        try sb.field(some.payload(), "task"),
    );
    const earlier = try sb.less(
        try sb.field(some.payload(), "revision"),
        try sb.field(reference, "revision"),
    );
    const valid = try b.match(prior, .{
        .none = try none.ret(empty),
        .some = try some.ret(try sb.select(same_task, earlier, try sb.constant(bool, false))),
    });
    try a.require(c, b, valid, "invalid_previous_accounting");
}

fn uniqueFunction(c: protean.Context, ids: anytype) !Unique {
    const function = try c.author.function("unconsumed settlement revision", .{
        .references = try c.schema(Consumed),
        .reference = try c.schema(t.RevisionReference),
        .index = try c.schema(u64),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const references = try b.parameter("references");
    const reference = try b.parameter("reference");
    const index = try b.parameter("index");
    const more = try b.branch();
    const done = try b.branch();
    const prior = try more.variantPayload(
        try more.sequenceGet(references, index),
        "some",
        try a.failure(c, "settlement_reference_bounds"),
    );
    const same_task = try more.call(ids, .{
        .left = try more.field(reference, "task"),
        .right = try more.field(prior, "task"),
        .index = try more.constant(u64, 0),
    });
    const same_revision = try more.equal(
        try more.field(reference, "revision"),
        try more.field(prior, "revision"),
    );
    const duplicate = try more.select(same_task, same_revision, try more.constant(bool, false));
    const found = try more.branch();
    const next = try more.branch();
    const continued = try next.call(function, .{
        .references = references,
        .reference = reference,
        .index = try next.checked(.add, index, try next.constant(u64, 1), .{
            .overflow = try a.failure(c, "settlement_reference_overflow"),
        }),
    });
    const result = try more.conditional(
        duplicate,
        try found.ret(try found.constant(bool, false)),
        try next.ret(continued),
    );
    const value = try b.conditional(
        try b.less(index, try b.sequenceLength(references)),
        try more.ret(result),
        try done.ret(try done.constant(bool, true)),
    );
    try c.author.define(function, try b.ret(value));
    return function;
}

inline fn same(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    left: a.Value(T),
    right: a.Value(T),
) anyerror!a.Value(bool) {
    switch (@typeInfo(T)) {
        .int => return b.equal(left, right),
        .array => |array| return b.call(try bytes.emit(c, array.len), .{
            .left = left,
            .right = right,
            .index = try b.constant(u64, 0),
        }),
        .@"struct" => {
            var result = try b.constant(bool, true);
            inline for (comptime std.meta.fieldNames(T)) |field| {
                const equal = try same(
                    c,
                    b,
                    @FieldType(T, field),
                    try b.field(left, field),
                    try b.field(right, field),
                );
                result = try b.select(result, equal, try b.constant(bool, false));
            }
            return result;
        },
        else => @compileError("unsupported settlement equality"),
    }
}
