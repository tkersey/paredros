const std = @import("std");
const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const oid_text = @import("oid_text.zig");
const bytes = @import("bytes.zig");
const step = @import("step.zig");
const model = @import("model.zig");
const m = @import("model_contract.zig");
const frame = @import("render_frame.zig");
const method = @import("method.zig");
const mc = @import("method_contract.zig");

const Batches = @FieldType(t.Step, "batches");
const BatchFact = Batches.Child;
const Context = @FieldType(m.Input, "context");
const Prefix = struct {
    count: u64 = 0,
    bytes: u64 = 0,
    commits: frame.Commits = .{ .items = &.{} },
    base: t.Oid = @splat(0),
    tip: t.Oid = @splat(0),
    epoch: u64,
    through: u64,
    observed_ms: i64 = 0,
    gap: bool = false,
    oversized: bool = false,
};
const Selection = struct { input: step.RenderInput, prefix: Prefix };
const Select = a.Function(struct { state: Selection }, Prefix);
const ContextState = struct {
    batches: Batches,
    count: u64,
    index: u64,
    limit: u64,
    text: Context,
};
const ContextBatches = a.Function(struct { state: ContextState }, ?Context);
const ContextCommits = a.Function(struct {
    commits: frame.Commits,
    index: u64,
    limit: u64,
    text: Context,
}, ?Context);
const RenderBody = struct { body: m.Summary, head: t.Head };
const Retained = @FieldType(t.Method, "retained");
const Helpers = struct {
    select: Select,
    frame: frame.Function,
    context: ContextBatches,
    method: method.Function,
    digest: a.Function(bytes.Parameters(32), bool),
    id: a.Function(bytes.Parameters(16), bool),
};

pub fn emit(
    c: protean.Context,
    completion: model.Function,
    retained: method.Function,
    effects: anytype,
) !step.Render {
    const oid = try oid_text.emit(c);
    const helpers: Helpers = .{
        .select = try selection(c),
        .frame = try frame.emit(c, oid),
        .context = try contextBatches(c, try contextCommits(c, oid)),
        .method = retained,
        .digest = try bytes.emit(c, 32),
        .id = try bytes.emit(c, 16),
    };
    const function = try c.author.function("render oldest complete responsibility prefix", .{
        .input = try c.schema(step.RenderInput),
    }, try c.schema(t.Head), effects);
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    try a.require(
        c,
        b,
        try b.equal(
            try b.variantTag(try b.field(head, "digest")),
            try b.variantTag(try c.literal(?t.DigestIntent, null)),
        ),
        "render_digest_pending",
    );
    const told = try b.field(head, "told");
    const prefix = try b.call(helpers.select, .{ .state = try b.product(
        try c.schema(Selection),
        .{
            .input = input,
            .prefix = try b.update(try c.literal(Prefix, .{ .epoch = 0, .through = 0 }), .{
                .bytes = try methodState(c, b, head),
                .epoch = try b.field(told, "epoch"),
                .through = try b.field(told, "sequence"),
            }),
        },
    ) });
    const some = try b.branch();
    const none = try b.branch();
    const output = try renderPrefix(c, some, helpers, completion, input, prefix);
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(try b.constant(u64, 0), try b.field(prefix, "count")),
        try some.ret(output),
        try none.ret(head),
    )));
    return function;
}

fn methodState(c: protean.Context, b: anytype, head: a.Value(t.Head)) !a.Value(u64) {
    const selected = try b.field(head, "method");
    const ordinary = try b.caseOf(selected, "ordinary");
    const retained = try b.caseOf(selected, "retained");
    const rb = retained.body();
    const state = try rb.field(retained.payload(), "state");
    return b.match(selected, .{
        .ordinary = try ordinary.ret(try ordinary.body().constant(u64, 0)),
        .retained = try retained.ret(try measure(c, rb, @FieldType(Retained, "state"), state)),
    });
}

fn add(c: protean.Context, b: anytype, x: a.Value(u64), y: a.Value(u64)) !a.Value(u64) {
    return b.checked(.add, x, y, .{ .overflow = try a.failure(c, "render_size_overflow") });
}

fn natural(b: anytype, value: a.Value(u64)) !a.Value(u64) {
    var result = try b.constant(u64, 1);
    inline for (1..10) |index| result = try b.select(
        try b.less(value, try b.constant(u64, @as(u64, 1) << @intCast(7 * index))),
        result,
        try b.constant(u64, index + 1),
    );
    return result;
}

inline fn measure(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    value: a.Value(T),
) anyerror!a.Value(u64) {
    if (comptime cts.native.wrapped(T)) {
        if (T.protean_value_kind == .vector) {
            const function = try measureSequence(c, T);
            return b.call(
                function,
                .{
                    .values = value,
                    .index = try b.constant(u64, 0),
                    .total = try natural(b, try b.sequenceLength(value)),
                },
            );
        }
        const length = try b.blobLength(value);
        return add(c, b, length, try natural(b, length));
    }
    switch (@typeInfo(T)) {
        .void => return b.constant(u64, 0),
        .bool => return b.constant(u64, 1),
        .int => return b.constant(u64, @sizeOf(T)),
        .@"enum" => return b.constant(u64, 4),
        .array => |info| {
            if (info.child != u8) @compileError("render wire measurement expects byte identities");
            return b.constant(u64, info.len);
        },
        .@"struct" => |info| {
            var total = try b.constant(u64, 0);
            inline for (info.field_names, info.field_types) |name, Child| {
                total = try add(c, b, total, try measure(c, b, Child, try b.field(value, name)));
            }
            return total;
        },
        .optional => |info| {
            const none = try b.caseOf(value, "none");
            const some = try b.caseOf(value, "some");
            const size = try add(
                c,
                some.body(),
                try some.body().constant(u64, 1),
                try measure(c, some.body(), info.child, some.payload()),
            );
            return b.match(value, .{
                .none = try none.ret(try none.body().constant(u64, 1)),
                .some = try some.ret(size),
            });
        },
        else => @compileError("unsupported render wire measurement: " ++ @typeName(T)),
    }
}

fn MeasureSequence(comptime T: type) type {
    return a.Function(struct { values: T, index: u64, total: u64 }, u64);
}

fn measureSequence(c: protean.Context, comptime T: type) !MeasureSequence(T) {
    const function = try c.author.function("measure complete render evidence sequence", .{
        .values = try c.schema(T),
        .index = try c.schema(u64),
        .total = try c.schema(u64),
    }, try c.schema(u64), &.{});
    const b = try c.author.body(function);
    const values = try b.parameter("values");
    const index = try b.parameter("index");
    const total = try b.parameter("total");
    const more = try b.branch();
    const done = try b.branch();
    const value = try more.variantPayload(
        try more.sequenceGet(values, index),
        "some",
        try a.failure(c, "render_evidence_bounds"),
    );
    const next = try more.call(function, .{
        .values = values,
        .index = try add(c, more, index, try more.constant(u64, 1)),
        .total = try add(c, more, total, try measure(c, more, T.Child, value)),
    });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(values)),
        try more.ret(next),
        try done.ret(total),
    )));
    return function;
}

fn selection(c: protean.Context) !Select {
    const equal_oids = try bytes.emit(c, 40);
    const function = try c.author.function("select whole bounded evidence batches", .{
        .state = try c.schema(Selection),
    }, try c.schema(Prefix), &.{});
    const b = try c.author.body(function);
    const state = try b.parameter("state");
    const input = try b.field(state, "input");
    const prefix = try b.field(state, "prefix");
    const count = try b.field(prefix, "count");
    const batches = try b.field(try b.field(input, "step"), "batches");
    const more = try b.branch();
    const done = try b.branch();
    const fact = try more.variantPayload(
        try more.sequenceGet(batches, count),
        "some",
        try a.failure(c, "render_batch_bounds"),
    );
    const value = try selectNext(c, more, function, equal_oids, state, fact);
    const active = try andAll(
        b,
        &.{
            try b.less(count, try b.sequenceLength(batches)),
            try b.booleanNot(try b.field(prefix, "gap")),
            try b.booleanNot(try b.field(prefix, "oversized")),
        },
    );
    try c.author.define(function, try b.ret(try b.conditional(
        active,
        try more.ret(value),
        try done.ret(prefix),
    )));
    return function;
}

fn selectNext(
    c: protean.Context,
    b: anytype,
    loop: Select,
    oids: anytype,
    state: a.Value(Selection),
    fact: a.Value(BatchFact),
) !a.Value(Prefix) {
    const input = try b.field(state, "input");
    const prefix = try b.field(state, "prefix");
    const batch = try b.field(fact, "value");
    const gap = try coverage(c, b, batch, .accepted_gap);
    const first = try b.equal(try b.field(prefix, "count"), try b.constant(u64, 0));
    const boundary = try andAll(b, &.{ gap, try b.booleanNot(first) });
    const stop = try b.branch();
    const consider = try b.branch();
    try validateBatch(c, consider, oids, input, prefix, batch, gap, first);
    const size = try add(
        c,
        consider,
        try b.field(prefix, "bytes"),
        try measure(c, consider, BatchFact, fact),
    );
    const count = try add(c, consider, try b.field(prefix, "count"), try consider.constant(u64, 1));
    const policies = try consider.field(
        try consider.field(try consider.field(input, "head"), "specification"),
        "policies",
    );
    const oversized = try consider.less(
        try consider.field(policies, "render_input_bytes"),
        try add(c, consider, size, try natural(consider, count)),
    );
    const accepted = try consider.branch();
    const refused = try consider.branch();
    const revised = try accepted.update(prefix, .{
        .count = count,
        .bytes = size,
        .commits = try accepted.concat(
            try accepted.field(prefix, "commits"),
            try accepted.field(batch, "commits"),
            .{},
        ),
        .base = try accepted.select(
            first,
            try accepted.field(batch, "base"),
            try accepted.field(prefix, "base"),
        ),
        .tip = try accepted.field(batch, "tip"),
        .epoch = try accepted.field(batch, "epoch"),
        .through = try accepted.field(batch, "sequence"),
        .observed_ms = try accepted.field(batch, "acquired_ms"),
        .gap = gap,
        .oversized = oversized,
    });
    const next = try accepted.call(loop, .{ .state = try accepted.update(state, .{
        .prefix = revised,
    }) });
    const fit = try consider.select(
        first,
        try consider.constant(bool, true),
        try consider.booleanNot(oversized),
    );
    const selected = try consider.conditional(fit, try accepted.ret(next), try refused.ret(prefix));
    return b.conditional(boundary, try stop.ret(prefix), try consider.ret(selected));
}

fn validateBatch(
    c: protean.Context,
    b: anytype,
    oids: anytype,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    batch: a.Value(t.Batch),
    gap: a.Value(bool),
    first: a.Value(bool),
) !void {
    const head = try b.field(input, "head");
    const repository = try b.field(try b.field(head, "specification"), "repository");
    const source = try b.field(batch, "repository");
    const sequence = try add(c, b, try b.field(prefix, "through"), try b.constant(u64, 1));
    try a.require(
        c,
        b,
        try b.equal(sequence, try b.field(batch, "sequence")),
        "render_noncontiguous_batches",
    );
    const observed = try b.field(try b.field(head, "observed"), "sequence");
    try a.require(
        c,
        b,
        try b.booleanNot(try b.less(observed, sequence)),
        "render_unobserved_batch",
    );
    try a.require(c, b, try andAll(b, &.{
        try b.equal(try b.field(repository, "id"), try b.field(source, "id")),
        try textEqual(b, try b.field(repository, "account"), try b.field(source, "account")),
        try textEqual(b, try b.field(repository, "ref"), try b.field(source, "ref")),
    }), "render_repository_mismatch");
    try a.require(
        c,
        b,
        try b.select(gap, try b.constant(bool, true), try coverage(c, b, batch, .complete)),
        "render_incomplete_coverage",
    );
    try validateTransition(c, b, oids, head, prefix, batch, gap, first);
}

fn validateTransition(
    c: protean.Context,
    b: anytype,
    oids: anytype,
    head: a.Value(t.Head),
    prefix: a.Value(Prefix),
    batch: a.Value(t.Batch),
    gap: a.Value(bool),
    first: a.Value(bool),
) !void {
    const baseline = try b.field(try b.field(head, "told"), "tip");
    const missing = try b.caseOf(baseline, "none");
    const present = try b.caseOf(baseline, "some");
    const prior = try b.match(baseline, .{
        .none = try missing.fail(
            try c.schema(t.Oid),
            try c.literal(t.Failure, .{ .code = .{ .bytes = "render_baseline_missing" } }),
        ),
        .some = try present.ret(present.payload()),
    });
    try a.require(c, b, try b.call(oids, .{
        .left = try b.select(first, prior, try b.field(prefix, "tip")),
        .right = try b.field(batch, "base"),
        .index = try b.constant(u64, 0),
    }), "render_base_mismatch");
    const gap_epoch = try b.branch();
    const same_epoch = try b.branch();
    const expected = try b.conditional(
        gap,
        try gap_epoch.ret(try add(
            c,
            gap_epoch,
            try gap_epoch.field(prefix, "epoch"),
            try gap_epoch.constant(u64, 1),
        )),
        try same_epoch.ret(try same_epoch.field(prefix, "epoch")),
    );
    const count = try b.sequenceLength(try b.field(batch, "commits"));
    try a.require(
        c,
        b,
        try b.equal(expected, try b.field(batch, "epoch")),
        "render_epoch_mismatch",
    );
    try a.require(
        c,
        b,
        try b.select(
            gap,
            try b.equal(count, try b.constant(u64, 0)),
            try b.constant(bool, true),
        ),
        "render_gap_has_commits",
    );
}

fn andAll(b: anytype, values: []const a.Value(bool)) !a.Value(bool) {
    var result = try b.constant(bool, true);
    for (values) |value| result = try b.select(result, value, try b.constant(bool, false));
    return result;
}

fn textEqual(b: anytype, left: anytype, right: anytype) !a.Value(bool) {
    return b.equal(try b.blobCompare(left, right), try b.constant(i8, 0));
}

fn coverage(
    c: protean.Context,
    b: anytype,
    batch: a.Value(t.Batch),
    expected: t.Coverage,
) !a.Value(bool) {
    return b.equal(
        try b.enumTag(try b.field(batch, "coverage")),
        try b.enumTag(try c.literal(t.Coverage, expected)),
    );
}

fn join(c: protean.Context, b: anytype, parts: anytype) !a.Value(Context) {
    var text = try c.literal(Context, .{ .bytes = "" });
    inline for (parts) |part| text = try b.blobConcat(
        try c.schema(Context),
        text,
        part,
        try a.failure(c, "render_context_capacity"),
    );
    return text;
}

fn literal(c: protean.Context, text: []const u8) !a.Value(Context) {
    return c.literal(Context, .{ .bytes = text });
}

fn identityText(
    c: protean.Context,
    b: anytype,
    comptime N: usize,
    identity: a.Value([N]u8),
) !a.Value(Context) {
    var text = try literal(c, "[");
    inline for (0..N) |index| {
        const byte = try b.variantPayload(
            try b.sequenceGet(identity, try b.constant(u64, index)),
            "some",
            try a.failure(c, "render_identity_bounds"),
        );
        text = try join(
            c,
            b,
            .{ text, try b.textInteger(byte), try literal(c, if (index + 1 == N) "]" else ",") },
        );
    }
    return text;
}

fn contextCommits(c: protean.Context, oid: oid_text.Function) !ContextCommits {
    const function = try c.author.function("materialize complete commit context", .{
        .commits = try c.schema(frame.Commits),
        .index = try c.schema(u64),
        .limit = try c.schema(u64),
        .text = try c.schema(Context),
    }, try c.schema(?Context), &.{});
    const b = try c.author.body(function);
    const commits = try b.parameter("commits");
    const index = try b.parameter("index");
    const limit = try b.parameter("limit");
    const text = try b.parameter("text");
    const more = try b.branch();
    const done = try b.branch();
    const commit = try more.variantPayload(
        try more.sequenceGet(commits, index),
        "some",
        try a.failure(c, "render_commit_bounds"),
    );
    const message = try more.field(commit, "message");
    const header = try join(
        c,
        more,
        .{
            try literal(c, "\nEvidence untrusted: commit "),
            try oid_text.format(c, more, oid, try more.field(commit, "oid")),
            try literal(c, " message bytes="),
            try more.textInteger(try more.blobLength(message)),
            try literal(c, "\n"),
        },
    );
    const required = try add(
        c,
        more,
        try more.blobLength(text),
        try add(c, more, try more.blobLength(header), try more.blobLength(message)),
    );
    const fits = try more.branch();
    const full = try more.branch();
    const next = try fits.call(function, .{
        .commits = commits,
        .index = try add(c, fits, index, try fits.constant(u64, 1)),
        .limit = limit,
        .text = try join(c, fits, .{ text, header, message }),
    });
    const output = try more.conditional(
        try more.less(limit, required),
        try full.ret(try c.literal(?Context, null)),
        try fits.ret(next),
    );
    const complete = try done.variant(try c.schema(?Context), "some", text);
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(commits)),
        try more.ret(output),
        try done.ret(complete),
    )));
    return function;
}

fn contextBatches(c: protean.Context, commits: ContextCommits) !ContextBatches {
    const function = try c.author.function("materialize whole selected batch provenance", .{
        .state = try c.schema(ContextState),
    }, try c.schema(?Context), &.{});
    const b = try c.author.body(function);
    const state = try b.parameter("state");
    const index = try b.field(state, "index");
    const more = try b.branch();
    const done = try b.branch();
    const fact = try more.variantPayload(
        try more.sequenceGet(try more.field(state, "batches"), index),
        "some",
        try a.failure(c, "render_context_batch_bounds"),
    );
    const header = try batchHeader(c, more, fact);
    const required = try add(
        c,
        more,
        try more.blobLength(try more.field(state, "text")),
        try more.blobLength(header),
    );
    const fits = try more.branch();
    const full = try more.branch();
    const output = try appendContextBatch(c, fits, function, commits, state, fact, header);
    const result = try more.conditional(
        try more.less(try more.field(state, "limit"), required),
        try full.ret(try c.literal(?Context, null)),
        try fits.ret(output),
    );
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.field(state, "count")),
        try more.ret(result),
        try done.ret(try done.variant(
            try c.schema(?Context),
            "some",
            try done.field(state, "text"),
        )),
    )));
    return function;
}

fn batchHeader(c: protean.Context, b: anytype, fact: a.Value(BatchFact)) !a.Value(Context) {
    const batch = try b.field(fact, "value");
    const reference = try b.field(fact, "reference");
    return join(
        c,
        b,
        .{
            try literal(c, "\nState: complete batch sequence="),
            try b.textInteger(try b.field(batch, "sequence")),
            try literal(c, " epoch="),
            try b.textInteger(try b.field(batch, "epoch")),
            try literal(c, " acquired_ms="),
            try b.textInteger(try b.field(batch, "acquired_ms")),
            try literal(c, " retained task bytes="),
            try identityText(c, b, 16, try b.field(reference, "task")),
            try literal(c, " result digest bytes="),
            try identityText(c, b, 32, try b.field(reference, "digest")),
            try literal(c, "\n"),
        },
    );
}

fn appendContextBatch(
    c: protean.Context,
    b: anytype,
    loop: ContextBatches,
    commits: ContextCommits,
    state: a.Value(ContextState),
    fact: a.Value(BatchFact),
    header: a.Value(Context),
) !a.Value(?Context) {
    const result = try b.call(commits, .{
        .commits = try b.field(try b.field(fact, "value"), "commits"),
        .index = try b.constant(u64, 0),
        .limit = try b.field(state, "limit"),
        .text = try join(c, b, .{ try b.field(state, "text"), header }),
    });
    const none = try b.caseOf(result, "none");
    const some = try b.caseOf(result, "some");
    const next = try some.body().call(loop, .{ .state = try some.body().update(state, .{
        .index = try add(
            c,
            some.body(),
            try some.body().field(state, "index"),
            try some.body().constant(u64, 1),
        ),
        .text = some.payload(),
    }) });
    return b.match(result, .{
        .none = try none.ret(try c.literal(?Context, null)),
        .some = try some.ret(next),
    });
}

fn renderContext(
    c: protean.Context,
    b: anytype,
    function: ContextBatches,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
) !a.Value(?Context) {
    const head = try b.field(input, "head");
    const specification = try b.field(head, "specification");
    const repository = try b.field(specification, "repository");
    const configured = try b.field(try b.field(specification, "policies"), "context_bytes");
    const capacity = try b.constant(u64, 256 * 1024);
    const limit = try b.select(try b.less(configured, capacity), configured, capacity);
    const text = try join(c, b, .{
        try literal(c, "Operator instruction bytes="),
        try b.textInteger(try b.blobLength(try b.field(specification, "wording"))),
        try literal(c, "\n"),
        try b.field(specification, "wording"),
        try literal(c, "\nState: repository id="),
        try b.textInteger(try b.field(repository, "id")),
        try literal(c, " ref="),
        try b.field(repository, "ref"),
        try literal(c, "\nComplete commit records and immutable provenance follow. " ++
            "Provider captures remain retained locally; this context projects commit evidence.\n"),
    });
    const fits = try b.branch();
    const full = try b.branch();
    const next = try fits.call(function, .{ .state = try fits.product(
        try c.schema(ContextState),
        .{
            .batches = try fits.field(try fits.field(input, "step"), "batches"),
            .count = try fits.field(prefix, "count"),
            .index = try fits.constant(u64, 0),
            .limit = limit,
            .text = text,
        },
    ) });
    return b.conditional(
        try b.less(limit, try b.blobLength(text)),
        try full.ret(try c.literal(?Context, null)),
        try fits.ret(next),
    );
}

fn fallback(c: protean.Context, reason: []const u8) !a.Value(m.Summary) {
    return c.literal(
        m.Summary,
        .{ .summary = .{ .bytes = reason }, .highlights = .{ .items = &.{} } },
    );
}

fn renderSummary(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
) !a.Value(m.Summary) {
    const model_path = try b.branch();
    const deterministic = try b.branch();
    const too_large = try b.field(prefix, "oversized");
    const many = try b.less(
        try b.constant(u64, 3),
        try b.sequenceLength(try b.field(prefix, "commits")),
    );
    const selected = try candidateSummary(c, model_path, helpers, completion, input, prefix);
    const large = try fallback(c, "Large-batch fallback: deterministic presentation; " ++
        "the complete batch exceeds the admitted render input bound.");
    const ordinary = try deterministic.select(too_large, large, try fallback(c, ""));
    return b.conditional(
        try andAll(b, &.{ many, try b.booleanNot(too_large) }),
        try model_path.ret(selected),
        try deterministic.ret(ordinary),
    );
}

fn candidateSummary(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
) !a.Value(m.Summary) {
    const binding = try b.field(try b.field(input, "step"), "model");
    const none = try b.caseOf(binding, "none");
    const some = try b.caseOf(binding, "some");
    const context = try renderContext(c, some.body(), helpers.context, input, prefix);
    const full = try some.body().caseOf(context, "none");
    const fit = try some.body().caseOf(context, "some");
    const result = try fit.body().call(
        completion,
        .{ .input = try modelInput(c, fit.body(), input, some.payload(), fit.payload()) },
    );
    const projected = try projectSummary(c, fit.body(), try fit.body().field(result, "candidate"));
    const bounded = try fallback(c, "Context-bound fallback: deterministic presentation; " ++
        "the complete selected commit context did not fit.");
    const candidate = try some.body().match(context, .{
        .none = try full.ret(bounded),
        .some = try fit.ret(projected),
    });
    return b.match(binding, .{
        .none = try none.ret(try fallback(c, "No model configured; deterministic presentation.")),
        .some = try some.ret(candidate),
    });
}

fn modelInput(
    c: protean.Context,
    b: anytype,
    input: a.Value(step.RenderInput),
    binding: a.Value(t.ModelBinding),
    context: a.Value(Context),
) !a.Value(m.Input) {
    const admitted = try b.field(input, "step");
    const specification = try b.field(try b.field(input, "head"), "specification");
    return b.product(try c.schema(m.Input), .{
        .binding = binding,
        .phase = try c.literal(@FieldType(m.Input, "phase"), .summary),
        .context = context,
        .initiating_input = try b.field(try b.field(admitted, "envelope"), "stable_request"),
        .target = try b.variant(try c.schema(?t.Id), "some", try b.field(admitted, "obligation")),
        .expected_revision = try b.variant(
            try c.schema(?u64),
            "some",
            try b.field(specification, "revision"),
        ),
        .proposal_offers = try c.literal(
            @FieldType(m.Input, "proposal_offers"),
            .{ .items = &.{} },
        ),
        .genesis_template = try c.literal(?t.Specification, null),
    });
}

fn projectSummary(
    c: protean.Context,
    b: anytype,
    candidate: a.Value(m.Candidate),
) !a.Value(m.Summary) {
    const summary = try b.caseOf(candidate, "summary");
    const conversation = try b.caseOf(candidate, "conversation");
    const rejected = try b.caseOf(candidate, "rejected");
    const refused = try fallback(c, "Rejected model candidate; deterministic presentation.");
    return b.match(candidate, .{
        .summary = try summary.ret(summary.payload()),
        .conversation = try conversation.ret(refused),
        .rejected = try rejected.ret(refused),
    });
}

fn renderPrefix(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
) !a.Value(t.Head) {
    const gap = try b.branch();
    const complete = try b.branch();
    const gap_delivery = try delivery(
        c,
        gap,
        input,
        prefix,
        try gapText(c, gap, input, prefix),
        try c.literal(@FieldType(t.LogicalPayload, "comparison"), null),
    );
    const rendered = try renderBody(c, complete, helpers, completion, input, prefix);
    const summary = try complete.field(rendered, "body");
    const updated = try complete.update(input, .{ .head = try complete.field(rendered, "head") });
    const result = try complete.call(helpers.frame, .{
        .input = try frameInput(c, complete, input, prefix, summary),
    });
    const text = try complete.blobConcat(
        try c.schema(t.Text),
        try c.literal(t.Text, .{ .bytes = "" }),
        try complete.field(result, "text"),
        try a.failure(c, "render_text_capacity"),
    );
    const comparison = try complete.variant(
        try c.schema(@FieldType(t.LogicalPayload, "comparison")),
        "some",
        try complete.field(result, "comparison"),
    );
    const complete_delivery = try delivery(c, complete, updated, prefix, text, comparison);
    return b.conditional(
        try b.field(prefix, "gap"),
        try gap.ret(gap_delivery),
        try complete.ret(complete_delivery),
    );
}

fn frameInput(
    c: protean.Context,
    b: anytype,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    summary: a.Value(m.Summary),
) !a.Value(frame.Input) {
    const head = try b.field(input, "head");
    return b.product(try c.schema(frame.Input), .{
        .repository = try b.field(try b.field(head, "specification"), "repository"),
        .base = try b.field(prefix, "base"),
        .tip = try b.field(prefix, "tip"),
        .observed_ms = try b.field(prefix, "observed_ms"),
        .commits = try b.field(prefix, "commits"),
        .prior_sequence = try b.field(try b.field(head, "told"), "sequence"),
        .through_sequence = try b.field(prefix, "through"),
        .epoch = try b.field(prefix, "epoch"),
        .summary = try b.field(summary, "summary"),
        .highlights = try b.field(summary, "highlights"),
    });
}

fn gapText(
    c: protean.Context,
    b: anytype,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
) !a.Value(t.Text) {
    const text = try join(c, b, .{
        try literal(c, "Accepted source gap: observations after "),
        try b.textInteger(try b.field(try b.field(try b.field(input, "head"), "told"), "sequence")),
        try literal(c, " through "),
        try b.textInteger(try b.field(prefix, "through")),
        try literal(c, "; epoch "),
        try b.textInteger(try b.field(prefix, "epoch")),
        try literal(c, ". The operator accepted a new baseline without claiming that all " ++
            "intervening commits were acquired. No complete comparison is claimed. " ++
            "Earlier verified observations remain in local history."),
    });
    return b.blobConcat(
        try c.schema(t.Text),
        try c.literal(t.Text, .{ .bytes = "" }),
        text,
        try a.failure(c, "render_gap_text_capacity"),
    );
}

fn delivery(
    c: protean.Context,
    b: anytype,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    text: a.Value(t.Text),
    comparison: a.Value(@FieldType(t.LogicalPayload, "comparison")),
) !a.Value(t.Head) {
    const head = try b.field(input, "head");
    const admitted = try b.field(input, "step");
    const specification = try b.field(head, "specification");
    const intent = try b.product(try c.schema(t.DeliveryIntent), .{
        .destination = try b.field(specification, "destination"),
        .key = try b.product(try c.schema(t.DeliveryKey), .{
            .lineage = try b.field(head, "lineage"),
            .purpose = try c.literal(@FieldType(t.DeliveryKey, "purpose"), .digest),
            .identity = try b.field(try b.field(admitted, "envelope"), "stable_request"),
            .generation = try b.constant(u32, 0),
        }),
        .payload = try b.product(try c.schema(t.LogicalPayload), .{
            .schema_version = try b.constant(u32, 1),
            .obligation = try b.variant(
                try c.schema(?t.Id),
                "some",
                try b.field(admitted, "obligation"),
            ),
            .specification_revision = try b.field(specification, "revision"),
            .prior_sequence = try b.field(try b.field(head, "told"), "sequence"),
            .through_sequence = try b.field(prefix, "through"),
            .frozen_text = text,
            .prompt = try c.literal(?t.Digest, null),
            .supersedes = try c.literal(?t.DeliveryKey, null),
            .coverage = try b.variant(try c.schema(?t.Frontier), "some", try b.product(
                try c.schema(t.Frontier),
                .{
                    .sequence = try b.field(prefix, "through"),
                    .epoch = try b.field(prefix, "epoch"),
                    .tip = try b.variant(try c.schema(?t.Oid), "some", try b.field(prefix, "tip")),
                },
            )),
            .issue = try b.constant(u32, 0),
            .buttons = try c.literal(@FieldType(t.LogicalPayload, "buttons"), .{ .items = &.{} }),
            .comparison = comparison,
        }),
    });
    return b.update(head, .{
        .digest = try b.variant(try c.schema(?t.DigestIntent), "some", try b.product(
            try c.schema(t.DigestIntent),
            .{
                .delivery = intent,
                .hold = try c.literal(t.DeliveryHold, .none),
                .not_before_ms = try b.field(head, "clock_ms"),
            },
        )),
        .render_failure_streak = try b.constant(u32, 0),
    });
}

fn body(
    c: protean.Context,
    b: anytype,
    summary: a.Value(m.Summary),
    head: a.Value(t.Head),
) !a.Value(RenderBody) {
    return b.product(try c.schema(RenderBody), .{ .body = summary, .head = head });
}

fn renderBody(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
) !a.Value(RenderBody) {
    const head = try b.field(input, "head");
    const selected = try b.field(head, "method");
    const ordinary = try b.caseOf(selected, "ordinary");
    const retained = try b.caseOf(selected, "retained");
    const normal = try renderSummary(c, ordinary.body(), helpers, completion, input, prefix);
    const bounded = try retained.body().branch();
    const oversized = try retained.body().branch();
    const result = try retainedBody(
        c,
        bounded,
        helpers,
        completion,
        input,
        prefix,
        retained.payload(),
    );
    const large = try renderSummary(c, oversized, helpers, completion, input, prefix);
    const limited = try retained.body().conditional(
        try retained.body().field(prefix, "oversized"),
        try oversized.ret(try body(c, oversized, large, head)),
        try bounded.ret(result),
    );
    return b.match(selected, .{
        .ordinary = try ordinary.ret(try body(c, ordinary.body(), normal, head)),
        .retained = try retained.ret(limited),
    });
}

fn same(b: anytype, function: anytype, left: anytype, right: anytype) !a.Value(bool) {
    return b.call(function, .{ .left = left, .right = right, .index = try b.constant(u64, 0) });
}

fn sourceMatches(
    b: anytype,
    helpers: Helpers,
    retained: a.Value(Retained),
    provided: a.Value(t.RetainedMethodSource),
) !a.Value(bool) {
    const expected = try b.field(retained, "source");
    const actual = try b.field(provided, "source");
    return andAll(b, &.{
        try same(b, helpers.id, try b.field(expected, "task"), try b.field(actual, "task")),
        try same(b, helpers.digest, try b.field(expected, "digest"), try b.field(actual, "digest")),
        try same(
            b,
            helpers.digest,
            try b.field(retained, "source_digest"),
            try b.field(provided, "source_digest"),
        ),
        try same(
            b,
            helpers.digest,
            try b.field(retained, "contract_digest"),
            try b.field(provided, "contract_digest"),
        ),
    });
}

fn retainedBody(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    retained: a.Value(Retained),
) !a.Value(RenderBody) {
    const provided = try b.field(try b.field(input, "step"), "method_source");
    const absent = try b.caseOf(provided, "none");
    const present = try b.caseOf(provided, "some");
    const valid = try present.body().branch();
    const invalid = try present.body().branch();
    const missing = try c.literal(mc.Result, .{
        .outcome = .{ .fault = .{ .bytes = "retained_source_missing_or_mismatched" } },
        .model_consumed = false,
    });
    const called = try valid.call(helpers.method, .{
        .input = try methodInput(c, valid, input, prefix, retained, present.payload()),
    });
    const checked = try present.body().conditional(
        try sourceMatches(present.body(), helpers, retained, present.payload()),
        try valid.ret(called),
        try invalid.ret(missing),
    );
    const result = try b.match(provided, .{
        .none = try absent.ret(missing),
        .some = try present.ret(checked),
    });
    return methodBody(c, b, helpers, completion, input, prefix, retained, result);
}

fn methodInput(
    c: protean.Context,
    b: anytype,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    retained: a.Value(Retained),
    provided: a.Value(t.RetainedMethodSource),
) !a.Value(mc.MethodInput) {
    const admitted = try b.field(input, "step");
    const specification = try b.field(try b.field(input, "head"), "specification");
    const policies = try b.field(specification, "policies");
    return b.product(try c.schema(mc.MethodInput), .{
        .retained = provided,
        .guest = try b.product(try c.schema(mc.GuestInput), .{
            .batches = try b.sequenceTake(
                try b.field(admitted, "batches"),
                try b.field(prefix, "count"),
            ),
            .state = try b.field(retained, "state"),
        }),
        .input_bytes_max = try b.field(policies, "render_input_bytes"),
        .model = try b.field(admitted, "model"),
        .initiating_input = try b.field(try b.field(admitted, "envelope"), "stable_request"),
    });
}

fn methodBody(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    retained: a.Value(Retained),
    result: a.Value(mc.Result),
) !a.Value(RenderBody) {
    const outcome = try b.field(result, "outcome");
    const success = try b.caseOf(outcome, "success");
    const fault = try b.caseOf(outcome, "fault");
    const sb = success.body();
    const updated = try sb.update(retained, .{
        .state = try sb.field(success.payload(), "state"),
        .consecutive_faults = try sb.constant(u32, 0),
    });
    const head = try sb.update(try sb.field(input, "head"), .{
        .method = try sb.variant(try c.schema(t.Method), "retained", updated),
        .method_disposition = try c.literal(?t.MethodDisposition, null),
    });
    const failed = try methodFault(
        c,
        fault.body(),
        helpers,
        completion,
        input,
        prefix,
        retained,
        fault.payload(),
        try b.field(result, "model_consumed"),
    );
    return b.match(outcome, .{
        .success = try success.ret(try body(c, sb, try sb.field(success.payload(), "body"), head)),
        .fault = try fault.ret(failed),
    });
}

fn faultCount(c: protean.Context, b: anytype, retained: a.Value(Retained)) !a.Value(u32) {
    const count = try b.field(retained, "consecutive_faults");
    const maximum = try b.constant(u32, std.math.maxInt(u32));
    const more = try b.branch();
    const full = try b.branch();
    const next = try more.checked(.add, count, try more.constant(u32, 1), .{
        .overflow = try a.failure(c, "method_fault_count_overflow"),
    });
    return b.conditional(
        try b.less(count, maximum),
        try more.ret(next),
        try full.ret(maximum),
    );
}

fn faultHead(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    retained: a.Value(Retained),
    reason: a.Value(t.Name),
    consumed: a.Value(bool),
) !a.Value(t.Head) {
    const count = try faultCount(c, b, retained);
    const policies = try b.field(try b.field(head, "specification"), "policies");
    const reverted = try b.booleanNot(try b.less(count, try b.field(policies, "method_faults")));
    const next = try b.update(retained, .{
        .consecutive_faults = count,
        .state = try c.literal(mc.State, .{ .bytes = "" }),
    });
    const disposition = try b.product(try c.schema(t.MethodDisposition), .{
        .source = try b.field(retained, "source"),
        .source_digest = try b.field(retained, "source_digest"),
        .reason = reason,
        .consecutive_faults = count,
        .model_consumed = consumed,
        .reverted = reverted,
    });
    return b.update(head, .{
        .method = try b.select(
            reverted,
            try c.literal(t.Method, .{ .ordinary = {} }),
            try b.variant(try c.schema(t.Method), "retained", next),
        ),
        .method_disposition = try b.variant(
            try c.schema(?t.MethodDisposition),
            "some",
            disposition,
        ),
    });
}

fn methodFault(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    completion: model.Function,
    input: a.Value(step.RenderInput),
    prefix: a.Value(Prefix),
    retained: a.Value(Retained),
    reason: a.Value(t.Name),
    consumed: a.Value(bool),
) !a.Value(RenderBody) {
    const ordinary = try b.branch();
    const deterministic = try b.branch();
    const candidate = try renderSummary(c, ordinary, helpers, completion, input, prefix);
    const refused = try fallback(c, "Retained method fault after completion; " ++
        "deterministic presentation.");
    const summary = try b.conditional(
        consumed,
        try deterministic.ret(refused),
        try ordinary.ret(candidate),
    );
    const head = try faultHead(c, b, try b.field(input, "head"), retained, reason, consumed);
    return body(c, b, summary, head);
}
