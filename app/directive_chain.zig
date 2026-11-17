const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const bytes = @import("bytes.zig");

pub const Outcome = @FieldType(t.DirectiveDisposition, "outcome");
pub const ApplyInput = struct { head: t.Head, directive: t.Directive };
pub const Applied = struct {
    head: t.Head,
    outcome: Outcome,
    gap: ?t.Batch = null,
    notice: ?t.DeliveryIntent = null,
    audit_request: ?t.AuditRequest = null,
};
pub const Apply = a.Function(struct { input: ApplyInput }, Applied);
pub const Input = struct {
    obligation: t.Id,
    head: t.Head,
    directives: @FieldType(t.Step, "directives"),
};
pub const Result = struct {
    head: t.Head,
    dispositions: cts.Vector(t.DirectiveDisposition, 128),
    gap: ?t.Batch = null,
    notices: cts.Vector(t.DeliveryIntent, 128) = .{ .items = &.{} },
    audit_requests: cts.Vector(t.AuditRequest, 128) = .{ .items = &.{} },
};
pub const Function = a.Function(struct { input: Input }, Result);
const State = struct { input: Input, result: Result, index: u64 };
const Loop = a.Function(struct { state: State }, Result);
const ReferenceInput = struct { left: ?t.InputReference, right: ?t.InputReference };
const References = a.Function(struct { input: ReferenceInput }, bool);

pub fn emit(c: protean.Context, apply: Apply) !Function {
    const identifiers = try bytes.emit(c, 16);
    const references = try referenceEquality(c, identifiers, try bytes.emit(c, 32));
    const loop = try foldLoop(c, apply, identifiers, references);
    const function = try c.author.function("fold admitted directive chain", .{
        .input = try c.schema(Input),
    }, try c.schema(Result), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const result = try b.product(try c.schema(Result), .{
        .head = try b.field(input, "head"),
        .dispositions = try c.literal(@FieldType(Result, "dispositions"), .{ .items = &.{} }),
        .gap = try c.literal(?t.Batch, null),
        .notices = try c.literal(@FieldType(Result, "notices"), .{ .items = &.{} }),
        .audit_requests = try c.literal(@FieldType(Result, "audit_requests"), .{ .items = &.{} }),
    });
    const value = try b.call(loop, .{ .state = try b.product(try c.schema(State), .{
        .input = input,
        .result = result,
        .index = try b.constant(u64, 0),
    }) });
    try c.author.define(function, try b.ret(value));
    return function;
}

fn foldLoop(c: protean.Context, apply: Apply, ids: anytype, refs: References) !Loop {
    const loop = try c.author.function("fold next admitted directive", .{
        .state = try c.schema(State),
    }, try c.schema(Result), &.{});
    const b = try c.author.body(loop);
    const state = try b.parameter("state");
    const input = try b.field(state, "input");
    const directives = try b.field(input, "directives");
    const index = try b.field(state, "index");
    const result = try b.field(state, "result");
    const more = try b.branch();
    const done = try b.branch();
    const fact = try more.variantPayload(
        try more.sequenceGet(directives, index),
        "some",
        try a.failure(c, "directive_bounds"),
    );
    const next = try foldOne(c, more, apply, ids, refs, input, result, fact);
    const continued = try more.call(loop, .{ .state = try more.update(state, .{
        .result = next,
        .index = try more.checked(.add, index, try more.constant(u64, 1), .{
            .overflow = try a.failure(c, "directive_count_overflow"),
        }),
    }) });
    const value = try b.conditional(
        try b.less(index, try b.sequenceLength(directives)),
        try more.ret(continued),
        try done.ret(result),
    );
    try c.author.define(loop, try b.ret(value));
    return loop;
}

fn foldOne(
    c: protean.Context,
    b: anytype,
    apply: Apply,
    ids: anytype,
    refs: References,
    input: a.Value(Input),
    result: a.Value(Result),
    fact: a.Value(t.DirectiveFact),
) !a.Value(Result) {
    const head = try b.field(result, "head");
    const directive = try b.field(fact, "value");
    const ordinal = try b.checked(
        .add,
        try b.field(head, "folded_directive_ordinal"),
        try b.constant(u64, 1),
        .{ .overflow = try a.failure(c, "directive_ordinal_overflow") },
    );
    const same_ordinal = try b.equal(ordinal, try b.field(directive, "ordinal"));
    try a.require(c, b, same_ordinal, "directive_ordinal_gap");
    try a.require(c, b, try b.call(ids, .{
        .left = try b.field(input, "obligation"),
        .right = try b.field(directive, "obligation"),
    }), "directive_obligation_mismatch");
    try a.require(c, b, try b.call(refs, .{ .input = try b.product(
        try c.schema(ReferenceInput),
        .{
            .left = try b.field(head, "last_directive"),
            .right = try b.field(directive, "predecessor"),
        },
    ) }), "directive_predecessor_mismatch");
    const applied = try b.call(apply, .{ .input = try b.product(try c.schema(ApplyInput), .{
        .head = head,
        .directive = directive,
    }) });
    const reference = try b.field(fact, "reference");
    const advanced = try b.update(try b.field(applied, "head"), .{
        .folded_directive_ordinal = ordinal,
        .last_directive = try b.variant(try c.schema(?t.InputReference), "some", reference),
    });
    const disposition = try b.product(try c.schema(t.DirectiveDisposition), .{
        .directive = reference,
        .ordinal = ordinal,
        .outcome = try b.field(applied, "outcome"),
    });
    return b.product(try c.schema(Result), .{
        .head = advanced,
        .dispositions = try b.append(try b.field(result, "dispositions"), disposition, .{
            .capacity = try a.failure(c, "directive_disposition_capacity"),
        }),
        .gap = try appendGap(c, b, try b.field(result, "gap"), try b.field(applied, "gap")),
        .notices = try appendOptional(
            c,
            b,
            t.DeliveryIntent,
            try b.field(result, "notices"),
            try b.field(applied, "notice"),
        ),
        .audit_requests = try appendOptional(
            c,
            b,
            t.AuditRequest,
            try b.field(result, "audit_requests"),
            try b.field(applied, "audit_request"),
        ),
    });
}

fn referenceEquality(c: protean.Context, ids: anytype, digests: anytype) !References {
    const function = try c.author.function("compare directive predecessor references", .{
        .input = try c.schema(ReferenceInput),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const left = try b.field(input, "left");
    const right = try b.field(input, "right");
    const absent = try b.caseOf(left, "none");
    const present = try b.caseOf(left, "some");
    const missing = try present.body().caseOf(right, "none");
    const found = try present.body().caseOf(right, "some");
    const x = present.payload();
    const y = found.payload();
    const fb = found.body();
    const same_id = try fb.call(
        ids,
        .{
            .left = try fb.field(x, "task"),
            .right = try fb.field(y, "task"),
        },
    );
    const same_digest = try fb.call(
        digests,
        .{
            .left = try fb.field(x, "digest"),
            .right = try fb.field(y, "digest"),
        },
    );
    const compared = try present.body().match(right, .{
        .none = try missing.ret(try missing.body().constant(bool, false)),
        .some = try found.ret(try fb.select(same_id, same_digest, try fb.constant(bool, false))),
    });
    const result = try b.match(left, .{
        .none = try absent.ret(try absent.body().equal(
            try b.variantTag(right),
            try b.variantTag(try c.literal(?t.InputReference, null)),
        )),
        .some = try present.ret(compared),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn appendGap(
    c: protean.Context,
    b: anytype,
    previous: a.Value(?t.Batch),
    next: a.Value(?t.Batch),
) !a.Value(?t.Batch) {
    const none = try b.caseOf(next, "none");
    const some = try b.caseOf(next, "some");
    const sb = some.body();
    try a.require(
        c,
        sb,
        try sb.equal(try sb.variantTag(previous), try sb.variantTag(try c.literal(?t.Batch, null))),
        "multiple_directive_gaps",
    );
    return b.match(next, .{ .none = try none.ret(previous), .some = try some.ret(next) });
}

fn appendOptional(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    previous: a.Value(cts.Vector(T, 128)),
    next: a.Value(?T),
) !a.Value(cts.Vector(T, 128)) {
    const none = try b.caseOf(next, "none");
    const some = try b.caseOf(next, "some");
    const appended = try some.body().append(previous, some.payload(), .{
        .capacity = try a.failure(c, "directive_emission_capacity"),
    });
    return b.match(next, .{ .none = try none.ret(previous), .some = try some.ret(appended) });
}
