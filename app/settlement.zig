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
    const delivery = try b.branch();
    const other = try b.branch();
    const settled = try b.conditional(
        try deliveryKind(c, b, fact),
        try delivery.ret(try settleDelivery(c, delivery, head, fact)),
        try other.ret(head),
    );
    return b.update(settled, .{
        .accounting = try accounting(c, b, try b.field(head, "accounting"), fact),
        .consumed = try b.append(consumed, reference, .{
            .capacity = try a.failure(c, "settlement_capacity"),
        }),
    });
}

fn deliveryKind(c: protean.Context, b: anytype, fact: a.Value(t.Settlement)) !a.Value(bool) {
    const Kind = @FieldType(t.Settlement, "kind");
    const kind = try b.enumTag(try b.field(fact, "kind"));
    const delivery = try b.equal(kind, try b.enumTag(try c.literal(Kind, .delivery)));
    const audit = try b.equal(kind, try b.enumTag(try c.literal(Kind, .audit)));
    const interaction = try b.equal(kind, try b.enumTag(try c.literal(Kind, .interaction)));
    return b.select(delivery, try b.constant(bool, true), try b.select(audit, try b.constant(bool, true), interaction));
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

const DeliveryFact = @typeInfo(@FieldType(t.Settlement, "delivery")).optional.child;
const Confirmation = @FieldType(t.DeliveryOutcome, "confirmed");

fn settleDelivery(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    fact: a.Value(t.Settlement),
) !a.Value(t.Head) {
    const delivery = try b.field(fact, "delivery");
    const none = try b.caseOf(delivery, "none");
    const some = try b.caseOf(delivery, "some");
    const sb = some.body();
    const intent = try sb.field(head, "digest");
    const absent = try sb.caseOf(intent, "none");
    const present = try sb.caseOf(intent, "some");
    const pb = present.body();
    const pending = try pb.field(present.payload(), "delivery");
    const received = try pb.field(some.payload(), "admitted");
    const matching = try same(c, pb, t.DeliveryIntent, pending, try projectIntent(c, pb, received));
    const accepted = try pb.branch();
    const unrelated = try pb.branch();
    const next = try foldDeliveryOutcome(c, accepted, head, some.payload(), present.payload());
    const result = try pb.conditional(matching, try accepted.ret(next), try unrelated.ret(head));
    const selected = try sb.match(intent, .{
        .none = try absent.ret(head),
        .some = try present.ret(result),
    });
    const activated = try settleActivation(c, sb, selected, some.payload());
    return b.match(delivery, .{ .none = try none.ret(head), .some = try some.ret(activated) });
}

fn projectIntent(
    c: protean.Context,
    b: anytype,
    delivery: a.Value(t.Delivery),
) !a.Value(t.DeliveryIntent) {
    return b.product(try c.schema(t.DeliveryIntent), .{
        .destination = try b.field(delivery, "destination"),
        .key = try b.field(delivery, "key"),
        .payload = try b.field(try b.field(delivery, "payload"), "logical"),
    });
}

fn foldDeliveryOutcome(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    fact: a.Value(DeliveryFact),
    intent: a.Value(t.DigestIntent),
) !a.Value(t.Head) {
    const outcome = try b.field(fact, "outcome");
    const confirmed = try b.caseOf(outcome, "confirmed");
    const rejected = try b.caseOf(outcome, "rejected");
    const unknown = try b.caseOf(outcome, "indeterminate");
    const cb = confirmed.body();
    const fault = try cb.branch();
    const healthy = try cb.branch();
    const next = try confirmDelivery(c, healthy, head, fact, confirmed.payload());
    const permanent = try cb.equal(
        try cb.enumTag(try cb.field(intent, "hold")),
        try cb.enumTag(try c.literal(t.DeliveryHold, .rendering_fault)),
    );
    const confirmation = try cb.conditional(
        try cb.field(confirmed.payload(), "rendering_fault"),
        try fault.ret(try hold(c, fault, head, intent, .rendering_fault)),
        try healthy.ret(try healthy.select(permanent, head, next)),
    );
    return b.match(outcome, .{
        .confirmed = try confirmed.ret(confirmation),
        .rejected = try rejected.ret(try rejectDelivery(
            c,
            rejected.body(),
            head,
            intent,
            rejected.payload(),
        )),
        .indeterminate = try unknown.ret(
            try hold(c, unknown.body(), head, intent, .uncertain_transmission),
        ),
    });
}

fn hold(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    intent: a.Value(t.DigestIntent),
    reason: t.DeliveryHold,
) !a.Value(t.Head) {
    const old = try b.field(intent, "hold");
    const fault = try b.select(
        try b.equal(
            try b.enumTag(old),
            try b.enumTag(try c.literal(t.DeliveryHold, .rendering_fault)),
        ),
        try b.constant(bool, true),
        try b.equal(try b.enumTag(old), try b.enumTag(try c.literal(t.DeliveryHold, .rejected))),
    );
    const next = try b.update(intent, .{
        .hold = try b.select(fault, old, try c.literal(t.DeliveryHold, reason)),
    });
    return b.update(head, .{
        .digest = try b.variant(try c.schema(?t.DigestIntent), "some", next),
    });
}

fn confirmDelivery(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    fact: a.Value(DeliveryFact),
    confirmation: a.Value(Confirmation),
) !a.Value(t.Head) {
    const receipt = try b.field(fact, "receipt");
    const none = try b.caseOf(receipt, "none");
    const some = try b.caseOf(receipt, "some");
    const sb = some.body();
    const delivery = try sb.field(fact, "admitted");
    const payload = try sb.field(try sb.field(delivery, "payload"), "logical");
    const valid = try receiptMatches(c, sb, delivery, some.payload(), confirmation);
    const accepted = try sb.branch();
    const rejected = try sb.branch();
    const next = try advanceCoverage(c, accepted, head, payload, some.payload());
    const result = try sb.conditional(valid, try accepted.ret(next), try rejected.ret(head));
    return b.match(receipt, .{ .none = try none.ret(head), .some = try some.ret(result) });
}

fn receiptMatches(
    c: protean.Context,
    b: anytype,
    delivery: a.Value(t.Delivery),
    receipt: a.Value(t.Receipt),
    confirmation: a.Value(Confirmation),
) !a.Value(bool) {
    const key = try same(
        c,
        b,
        t.DeliveryKey,
        try b.field(delivery, "key"),
        try b.field(receipt, "key"),
    );
    const destination = try same(
        c,
        b,
        t.Destination,
        try b.field(delivery, "destination"),
        try b.field(receipt, "destination"),
    );
    const content = try same(
        c,
        b,
        t.Digest,
        try b.field(try b.field(delivery, "payload"), "content_digest"),
        try b.field(receipt, "payload_digest"),
    );
    const timestamp = try same(
        c,
        b,
        t.Timestamp,
        try b.field(confirmation, "timestamp"),
        try b.field(receipt, "timestamp"),
    );
    const nonempty = try b.less(
        try b.constant(u64, 0),
        try b.blobLength(try b.field(receipt, "timestamp")),
    );
    const no = try b.constant(bool, false);
    return b.select(
        key,
        try b.select(
            destination,
            try b.select(content, try b.select(timestamp, nonempty, no), no),
            no,
        ),
        no,
    );
}

fn advanceCoverage(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    payload: a.Value(t.LogicalPayload),
    receipt: a.Value(t.Receipt),
) !a.Value(t.Head) {
    const coverage = try b.field(payload, "coverage");
    const none = try b.caseOf(coverage, "none");
    const some = try b.caseOf(coverage, "some");
    const sb = some.body();
    const told = try sb.field(head, "told");
    const through = try sb.field(payload, "through_sequence");
    const growing = try sb.less(try sb.field(told, "sequence"), through);
    const advances = try sb.branch();
    const stale = try sb.branch();
    const valid = try validCoverage(c, advances, head, payload, some.payload());
    const next = try advances.update(head, .{
        .told = some.payload(),
        .told_receipt = try advances.variant(try c.schema(?t.Receipt), "some", receipt),
        .digest = try c.literal(?t.DigestIntent, null),
    });
    const result = try sb.conditional(
        growing,
        try advances.ret(try advances.select(valid, next, head)),
        try stale.ret(head),
    );
    return b.match(coverage, .{ .none = try none.ret(head), .some = try some.ret(result) });
}

fn validCoverage(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    payload: a.Value(t.LogicalPayload),
    coverage: a.Value(t.Frontier),
) !a.Value(bool) {
    const told = try b.field(head, "told");
    const observed = try b.field(head, "observed");
    const through = try b.field(payload, "through_sequence");
    const prior = try b.field(payload, "prior_sequence");
    const no = try b.constant(bool, false);
    var valid = try b.equal(prior, try b.field(told, "sequence"));
    valid = try b.select(valid, try b.less(prior, through), no);
    valid = try b.select(valid, try b.equal(through, try b.field(coverage, "sequence")), no);
    valid = try b.select(
        valid,
        try b.booleanNot(try b.less(try b.field(observed, "sequence"), through)),
        no,
    );
    valid = try b.select(
        valid,
        try b.booleanNot(try b.less(try b.field(coverage, "epoch"), try b.field(told, "epoch"))),
        no,
    );
    valid = try b.select(
        valid,
        try b.booleanNot(
            try b.less(try b.field(observed, "epoch"), try b.field(coverage, "epoch")),
        ),
        no,
    );
    const endpoint = try b.select(
        try b.equal(through, try b.field(observed, "sequence")),
        try same(c, b, t.Frontier, coverage, observed),
        try b.constant(bool, true),
    );
    return b.select(valid, endpoint, no);
}

inline fn same(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    left: a.Value(T),
    right: a.Value(T),
) anyerror!a.Value(bool) {
    const S = @import("horos").authoring.Shape(T);
    if (comptime S.contract == .text or S.contract == .bytes)
        return b.equal(try b.blobCompare(left, right), try b.constant(i8, 0));
    if (comptime S.contract == .sequence)
        return b.call(try sequenceEquality(c, T), .{
            .left = left,
            .right = right,
            .index = try b.constant(u64, 0),
        });
    switch (@typeInfo(T)) {
        .int, .bool => return b.equal(left, right),
        .@"enum" => return b.equal(try b.enumTag(left), try b.enumTag(right)),
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
        .optional => |optional| {
            const none = try b.caseOf(left, "none");
            const some = try b.caseOf(left, "some");
            const sb = some.body();
            const absent = try sb.caseOf(right, "none");
            const present = try sb.caseOf(right, "some");
            const equal = try same(
                c,
                present.body(),
                optional.child,
                some.payload(),
                present.payload(),
            );
            const selected = try sb.match(right, .{
                .none = try absent.ret(try absent.body().constant(bool, false)),
                .some = try present.ret(equal),
            });
            return b.match(left, .{
                .none = try none.ret(
                    try none.body().equal(
                        try none.body().variantTag(right),
                        try none.body().variantTag(try c.literal(T, null)),
                    ),
                ),
                .some = try some.ret(selected),
            });
        },
        else => @compileError("unsupported settlement equality"),
    }
}

fn SequenceArgs(comptime T: type) type {
    return struct { left: T, right: T, index: u64 };
}

fn sequenceEquality(
    c: protean.Context,
    comptime T: type,
) !a.Function(SequenceArgs(T), bool) {
    const function = try c.author.function("compare logical delivery controls", .{
        .left = try c.schema(T),
        .right = try c.schema(T),
        .index = try c.schema(u64),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const left = try b.parameter("left");
    const right = try b.parameter("right");
    const index = try b.parameter("index");
    const length = try b.sequenceLength(left);
    const more = try b.branch();
    const done = try b.branch();
    const left_item = try more.sequenceGet(left, index);
    const right_item = try more.sequenceGet(right, index);
    const equal = try same(c, more, ?T.Child, left_item, right_item);
    const identical = try more.branch();
    const different = try more.branch();
    const next = try identical.call(function, .{
        .left = left,
        .right = right,
        .index = try identical.checked(.add, index, try identical.constant(u64, 1), .{
            .overflow = try a.failure(c, "logical_control_count_overflow"),
        }),
    });
    const compared = try more.conditional(
        equal,
        try identical.ret(next),
        try different.ret(try different.constant(bool, false)),
    );
    const result = try b.conditional(
        try b.less(index, length),
        try more.ret(compared),
        try done.ret(try done.equal(length, try done.sequenceLength(right))),
    );
    try c.author.define(function, try b.ret(result));
    return function;
}

const Rejection = @FieldType(t.DeliveryOutcome, "rejected");
const Seconds = a.Function(struct { text: t.Name, index: u64, value: i64 }, ?i64);

fn rejectDelivery(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    intent: a.Value(t.DigestIntent),
    rejection: a.Value(Rejection),
) !a.Value(t.Head) {
    const retry = try b.branch();
    const permanent = try b.branch();
    const hold_kind = try b.enumTag(try b.field(intent, "hold"));
    const fixed = try b.select(
        try b.equal(hold_kind, try b.enumTag(try c.literal(t.DeliveryHold, .rendering_fault))),
        try b.constant(bool, true),
        try b.equal(hold_kind, try b.enumTag(try c.literal(t.DeliveryHold, .rejected))),
    );
    const permitted = try b.select(
        fixed,
        try b.constant(bool, false),
        try b.field(rejection, "retryable"),
    );
    return b.conditional(
        permitted,
        try retry.ret(try retryDelivery(c, retry, head, intent, rejection)),
        try permanent.ret(try hold(c, permanent, head, intent, .rejected)),
    );
}

fn retryDelivery(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    intent: a.Value(t.DigestIntent),
    rejection: a.Value(Rejection),
) !a.Value(t.Head) {
    const header = try b.field(rejection, "retry_after");
    const absent = try b.caseOf(header, "none");
    const present = try b.caseOf(header, "some");
    const pb = present.body();
    const seconds = try b.match(header, .{
        .none = try absent.ret(try c.literal(?i64, 0)),
        .some = try present.ret(try pb.call(try secondsFunction(c), .{
            .text = present.payload(),
            .index = try pb.constant(u64, 0),
            .value = try pb.constant(i64, 0),
        })),
    });
    const invalid = try b.caseOf(seconds, "none");
    const valid = try b.caseOf(seconds, "some");
    return b.match(seconds, .{
        .none = try invalid.ret(try hold(c, invalid.body(), head, intent, .rejected)),
        .some = try valid.ret(try nextGeneration(c, valid.body(), head, intent, valid.payload())),
    });
}

fn nextGeneration(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    intent: a.Value(t.DigestIntent),
    seconds: a.Value(i64),
) !a.Value(t.Head) {
    const delivery = try b.field(intent, "delivery");
    const key = try b.field(delivery, "key");
    const generation = try b.field(key, "generation");
    const overflow = try a.failure(c, "delivery_retry_overflow");
    const delay = try b.checked(
        .multiply,
        seconds,
        try b.constant(i64, 1000),
        .{ .overflow = overflow },
    );
    const now = try b.field(head, "clock_ms");
    const provider = try b.checked(.add, now, delay, .{ .overflow = overflow });
    const local = try retryInstant(c, b, head);
    const previous = try b.field(intent, "not_before_ms");
    const constrained = try b.select(try b.less(provider, previous), previous, provider);
    const next = try b.update(intent, .{
        .delivery = try b.update(delivery, .{ .key = try b.update(key, .{
            .generation = try b.checked(
                .add,
                generation,
                try b.constant(u32, 1),
                .{ .overflow = overflow },
            ),
        }) }),
        .hold = try b.select(
            try b.equal(
                try b.enumTag(try b.field(intent, "hold")),
                try b.enumTag(try c.literal(t.DeliveryHold, .uncertain_transmission)),
            ),
            try c.literal(t.DeliveryHold, .none),
            try b.field(intent, "hold"),
        ),
        .not_before_ms = try b.select(try b.less(local, constrained), constrained, local),
    });
    return b.update(
        head,
        .{ .digest = try b.variant(try c.schema(?t.DigestIntent), "some", next) },
    );
}

fn retryInstant(c: protean.Context, b: anytype, head: a.Value(t.Head)) !a.Value(i64) {
    const specification = try b.field(head, "specification");
    const policies = try b.field(specification, "policies");
    const overflow = try a.failure(c, "delivery_retry_overflow");
    const delay = try b.convertInteger(
        try c.schema(i64),
        try b.field(policies, "notification_interval_ms"),
        .{ .overflow = overflow },
    );
    return b.checked(.add, try b.field(head, "clock_ms"), delay, .{ .overflow = overflow });
}

fn secondsFunction(c: protean.Context) !Seconds {
    const function = try c.author.function("delivery Retry After seconds", .{
        .text = try c.schema(t.Name),
        .index = try c.schema(u64),
        .value = try c.schema(i64),
    }, try c.schema(?i64), &.{});
    const b = try c.author.body(function);
    const text = try b.parameter("text");
    const index = try b.parameter("index");
    const value = try b.parameter("value");
    const active = try b.branch();
    const done = try b.branch();
    const byte = try active.variantPayload(
        try active.blobByte(text, index),
        "some",
        try a.failure(c, "retry_after_bounds"),
    );
    const zero = try active.constant(u8, '0');
    const digit = try active.select(
        try active.less(byte, zero),
        try active.constant(bool, false),
        try active.less(byte, try active.constant(u8, '9' + 1)),
    );
    const bounded = try active.less(value, try active.constant(i64, std.math.maxInt(i64) / 10 - 9));
    const valid = try active.branch();
    const invalid = try active.branch();
    const overflow = try a.failure(c, "retry_after_overflow");
    const next = try valid.checked(
        .add,
        try valid.checked(.multiply, value, try valid.constant(i64, 10), .{ .overflow = overflow }),
        try valid.convertInteger(
            try c.schema(i64),
            try valid.checked(.subtract, byte, zero, .{ .overflow = overflow }),
            .{},
        ),
        .{ .overflow = overflow },
    );
    const continued = try valid.call(function, .{
        .text = text,
        .index = try valid.checked(
            .add,
            index,
            try valid.constant(u64, 1),
            .{ .overflow = overflow },
        ),
        .value = next,
    });
    const parsed = try active.conditional(
        try active.select(digit, bounded, try active.constant(bool, false)),
        try valid.ret(continued),
        try invalid.ret(try c.literal(?i64, null)),
    );
    const complete = try done.select(
        try done.less(try done.constant(u64, 0), index),
        try done.variant(try c.schema(?i64), "some", value),
        try c.literal(?i64, null),
    );
    try c.author.define(
        function,
        try b.ret(try b.conditional(
            try b.less(index, try b.blobLength(text)),
            try active.ret(parsed),
            try done.ret(complete),
        )),
    );
    return function;
}

fn settleActivation(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    fact: a.Value(DeliveryFact),
) !a.Value(t.Head) {
    const activation = try b.field(head, "activation");
    const absent = try b.caseOf(activation, "none");
    const present = try b.caseOf(activation, "some");
    const pb = present.body();
    const matching = try same(
        c,
        pb,
        t.DeliveryIntent,
        present.payload(),
        try projectIntent(c, pb, try pb.field(fact, "admitted")),
    );
    const accepted = try pb.branch();
    const unrelated = try pb.branch();
    const next = try activationOutcome(c, accepted, head, fact);
    const result = try pb.conditional(matching, try accepted.ret(next), try unrelated.ret(head));
    return b.match(activation, .{ .none = try absent.ret(head), .some = try present.ret(result) });
}

fn activationOutcome(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    fact: a.Value(DeliveryFact),
) !a.Value(t.Head) {
    const outcome = try b.field(fact, "outcome");
    const confirmed = try b.caseOf(outcome, "confirmed");
    const rejected = try b.caseOf(outcome, "rejected");
    const unknown = try b.caseOf(outcome, "indeterminate");
    const cb = confirmed.body();
    const receipt = try cb.field(fact, "receipt");
    const absent = try cb.caseOf(receipt, "none");
    const present = try cb.caseOf(receipt, "some");
    const pb = present.body();
    const matches = try receiptMatches(
        c,
        pb,
        try pb.field(fact, "admitted"),
        present.payload(),
        confirmed.payload(),
    );
    const cleared = try pb.update(head, .{ .activation = try c.literal(?t.DeliveryIntent, null) });
    const valid = try cb.match(receipt, .{
        .none = try absent.ret(head),
        .some = try present.ret(try pb.select(matches, cleared, head)),
    });
    return b.match(outcome, .{
        .confirmed = try confirmed.ret(valid),
        .rejected = try rejected.ret(head),
        .indeterminate = try unknown.ret(head),
    });
}
