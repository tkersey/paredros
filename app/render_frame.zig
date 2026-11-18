const std = @import("std");
const h = @import("horos").authoring;
const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");
const oid_text = @import("oid_text.zig");
const bytes = @import("bytes.zig");

pub const Highlight = struct { oid: t.Oid, text: cts.Text(256) };
pub const Commits = cts.Vector(t.Commit, null);
pub const Highlights = cts.Vector(Highlight, 8);
pub const Oids = cts.Vector(t.Oid, 8);
pub const Text = cts.Text(4000);
pub const Comparison = struct { repository: t.Repository, base: t.Oid, tip: t.Oid };
pub const Input = struct {
    repository: t.Repository,
    base: t.Oid,
    tip: t.Oid,
    observed_ms: i64,
    commits: Commits,
    prior_sequence: u64,
    through_sequence: u64,
    epoch: u64,
    summary: cts.Text(1024),
    highlights: Highlights,
};
pub const Result = struct {
    text: Text,
    total_commits: u64,
    listed_commits: u64,
    listed_oids: Oids,
    invalid_highlights: u64,
    abbreviated: bool,
    comparison: Comparison,
};
pub const Function = a.Function(struct { input: Input }, Result);
const Frame = struct { text: Text, listed_oids: Oids, invalid_highlights: u64, abbreviated: bool };
const ClipResult = struct { text: cts.Utf8, abbreviated: bool };
const Clip = a.Function(struct {
    text: cts.Utf8,
    index: u64,
    remaining: u64,
    start: u64,
    output: cts.Utf8,
}, ClipResult);
const Contains = a.Function(struct { commits: Commits, oid: t.Oid, index: u64 }, bool);
const List = a.Function(struct { commits: Commits, index: u64, frame: Frame }, Frame);
const Notes = a.Function(struct {
    commits: Commits,
    highlights: Highlights,
    index: u64,
    frame: Frame,
}, Frame);

fn failure(c: protean.Context) !*const h.FailureLiteral(h.Shape(t.Failure)) {
    return a.failure(c, "render_bounds");
}

fn literal(c: protean.Context, value: []const u8) !a.Value(cts.Utf8) {
    return c.literal(cts.Utf8, .{ .bytes = value });
}

fn join(c: protean.Context, b: anytype, parts: anytype) !a.Value(Text) {
    var result = try c.literal(Text, .{ .bytes = "" });
    inline for (parts) |part| result = try b.blobConcat(
        try c.schema(Text),
        result,
        part,
        try failure(c),
    );
    return result;
}

fn add(c: protean.Context, b: anytype, left: a.Value(u64), right: a.Value(u64)) !a.Value(u64) {
    return b.checked(.add, left, right, .{ .overflow = try failure(c) });
}

fn either(b: anytype, left: a.Value(bool), right: a.Value(bool)) !a.Value(bool) {
    return b.select(left, try b.constant(bool, true), right);
}

fn widen(c: protean.Context, b: anytype, value: anytype) !a.Value(cts.Utf8) {
    return b.blobConcat(try c.schema(cts.Utf8), try literal(c, ""), value, try failure(c));
}

fn clipped(
    c: protean.Context,
    b: anytype,
    clip: Clip,
    value: anytype,
    budget: u64,
) !a.Value(ClipResult) {
    return b.call(clip, .{
        .text = try widen(c, b, value),
        .index = try b.constant(u64, 0),
        .remaining = try b.constant(u64, budget - 3),
        .start = try b.constant(u64, 0),
        .output = try literal(c, ""),
    });
}

// The cost of an unchanged scalar is its UTF-8 width, except for Slack markup.
// A zero entry marks an ASCII control, which becomes a one-byte space.
const escaped_costs = blk: {
    var costs: [256]u8 = @splat(1);
    @memset(costs[0..32], 0);
    costs[127] = 0;
    costs['&'] = 5;
    costs['<'] = 4;
    costs['>'] = 4;
    @memset(costs[128..224], 2);
    @memset(costs[224..240], 3);
    @memset(costs[240..], 4);
    break :blk costs;
};

fn clipFunction(c: protean.Context) !Clip {
    const function = try c.author.function("bounded scalar-safe inert text", .{
        .text = try c.schema(cts.Utf8),
        .index = try c.schema(u64),
        .remaining = try c.schema(u64),
        .start = try c.schema(u64),
        .output = try c.schema(cts.Utf8),
    }, try c.schema(ClipResult), &.{});
    const b = try c.author.body(function);
    const text = try b.parameter("text");
    const index = try b.parameter("index");
    const start = try b.parameter("start");
    const output = try b.parameter("output");
    const remaining = try b.parameter("remaining");
    const byte = try b.blobByte(text, index);
    const ended = try b.caseOf(byte, "none");
    const present = try b.caseOf(byte, "some");
    const active = present.body();
    const one = try active.constant(u64, 1);
    const code = try active.variantPayload(try active.blobByte(
        try c.literal(cts.Bytes(256), .{ .bytes = &escaped_costs }),
        try active.convertInteger(try c.schema(u64), present.payload(), .{}),
    ), "some", try failure(c));
    const value = try active.convertInteger(try c.schema(u64), code, .{});
    const control = try active.equal(code, try active.constant(u8, 0));
    const width = try active.select(
        try active.less(present.payload(), try active.constant(u8, 128)),
        one,
        value,
    );
    const cost = try active.select(control, one, value);
    const fits = try active.branch();
    const full = try active.branch();
    const end = try add(c, fits, index, width);
    const replace = try fits.branch();
    const keep = try fits.branch();
    const changed = try replace.blobConcat(
        try c.schema(cts.Utf8),
        try clipPrefix(c, replace, text, start, index, output),
        try literal(c, " "),
        try failure(c),
    );
    const next = try fits.call(function, .{
        .text = text,
        .index = end,
        .remaining = try fits.checked(.subtract, remaining, cost, .{ .overflow = try failure(c) }),
        .start = try fits.select(control, end, start),
        .output = try fits.conditional(control, try replace.ret(changed), try keep.ret(output)),
    });
    const truncated = try full.product(try c.schema(ClipResult), .{
        .text = try full.blobConcat(
            try c.schema(cts.Utf8),
            try clipPrefix(c, full, text, start, index, output),
            try literal(c, "..."),
            try failure(c),
        ),
        .abbreviated = try full.constant(bool, true),
    });
    const consumed = try active.conditional(
        try active.less(remaining, cost),
        try full.ret(truncated),
        try fits.ret(next),
    );
    const complete = try ended.body().product(try c.schema(ClipResult), .{
        .text = try clipPrefix(c, ended.body(), text, start, index, output),
        .abbreviated = try ended.body().constant(bool, false),
    });
    try c.author.define(function, try b.ret(try b.match(byte, .{
        .none = try ended.ret(complete),
        .some = try present.ret(consumed),
    })));
    return function;
}

// Bytes between start and index are complete, unchanged UTF-8 scalars.
fn clipPrefix(
    c: protean.Context,
    b: anytype,
    text: a.Value(cts.Utf8),
    start: a.Value(u64),
    index: a.Value(u64),
    output: a.Value(cts.Utf8),
) !a.Value(cts.Utf8) {
    const span = try b.blobSlice(
        try c.schema(cts.Utf8),
        text,
        start,
        index,
        .{ .capacity = try failure(c), .invalid_utf8 = try failure(c) },
    );
    return b.blobConcat(try c.schema(cts.Utf8), output, span, try failure(c));
}

fn containsFunction(c: protean.Context) !Contains {
    const equal = try bytes.emit(c, 40);
    const function = try c.author.function("highlight belongs to acquired commits", .{
        .commits = try c.schema(Commits),
        .oid = try c.schema(t.Oid),
        .index = try c.schema(u64),
    }, try c.schema(bool), &.{});
    const b = try c.author.body(function);
    const commits = try b.parameter("commits");
    const oid = try b.parameter("oid");
    const index = try b.parameter("index");
    const active = try b.branch();
    const ended = try b.branch();
    const commit = try active.variantPayload(
        try active.sequenceGet(commits, index),
        "some",
        try failure(c),
    );
    const same = try active.call(
        equal,
        .{
            .left = oid,
            .right = try active.field(commit, "oid"),
            .index = try active.constant(u64, 0),
        },
    );
    const found = try active.branch();
    const search = try active.branch();
    const next = try search.call(
        function,
        .{
            .commits = commits,
            .oid = oid,
            .index = try add(c, search, index, try search.constant(u64, 1)),
        },
    );
    const result = try active.conditional(
        same,
        try found.ret(try found.constant(bool, true)),
        try search.ret(next),
    );
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(commits)),
        try active.ret(result),
        try ended.ret(try ended.constant(bool, false)),
    )));
    return function;
}

fn listFunction(c: protean.Context, clip: Clip, oid: oid_text.Function) !List {
    const function = try c.author.function("oldest bounded commit presentation", .{
        .commits = try c.schema(Commits),
        .index = try c.schema(u64),
        .frame = try c.schema(Frame),
    }, try c.schema(Frame), &.{});
    const b = try c.author.body(function);
    const commits = try b.parameter("commits");
    const index = try b.parameter("index");
    const frame = try b.parameter("frame");
    const active = try b.branch();
    const ended = try b.branch();
    const commit = try active.variantPayload(
        try active.sequenceGet(commits, index),
        "some",
        try failure(c),
    );
    const message = try clipped(c, active, clip, try active.field(commit, "message"), 100);
    const selected_oid = try active.field(commit, "oid");
    const next = try active.update(frame, .{
        .text = try join(c, active, .{
            try b.field(frame, "text"),
            try literal(c, "\n- "),
            try oid_text.format(c, active, oid, selected_oid),
            try literal(c, " "),
            try active.field(message, "text"),
        }),
        .listed_oids = try active.append(
            try b.field(frame, "listed_oids"),
            selected_oid,
            .{ .capacity = try failure(c) },
        ),
        .abbreviated = try either(
            active,
            try b.field(frame, "abbreviated"),
            try active.field(message, "abbreviated"),
        ),
    });
    const in_range = try b.select(
        try b.less(index, try b.constant(u64, 8)),
        try b.less(index, try b.sequenceLength(commits)),
        try b.constant(bool, false),
    );
    const finished = try ended.update(frame, .{
        .abbreviated = try either(
            ended,
            try b.field(frame, "abbreviated"),
            try b.less(index, try b.sequenceLength(commits)),
        ),
    });
    try c.author.define(
        function,
        try b.ret(try b.conditional(
            in_range,
            try active.ret(try active.call(
                function,
                .{
                    .commits = commits,
                    .index = try add(c, active, index, try active.constant(u64, 1)),
                    .frame = next,
                },
            )),
            try ended.ret(finished),
        )),
    );
    return function;
}

fn notesFunction(c: protean.Context, clip: Clip, oid: oid_text.Function, contains: Contains) !Notes {
    const function = try c.author.function("retain only acquired commit method highlights", .{
        .commits = try c.schema(Commits),
        .highlights = try c.schema(Highlights),
        .index = try c.schema(u64),
        .frame = try c.schema(Frame),
    }, try c.schema(Frame), &.{});
    const b = try c.author.body(function);
    const commits = try b.parameter("commits");
    const highlights = try b.parameter("highlights");
    const index = try b.parameter("index");
    const frame = try b.parameter("frame");
    const active = try b.branch();
    const ended = try b.branch();
    const note = try active.variantPayload(
        try active.sequenceGet(highlights, index),
        "some",
        try failure(c),
    );
    const valid = try active.call(
        contains,
        .{
            .commits = commits,
            .oid = try active.field(note, "oid"),
            .index = try active.constant(u64, 0),
        },
    );
    const kept = try active.branch();
    const dropped = try active.branch();
    const revised = try active.conditional(valid, try kept.ret(try appendNote(
        c,
        kept,
        clip,
        oid,
        frame,
        note,
    )), try dropped.ret(try dropped.update(frame, .{
        .invalid_highlights = try add(
            c,
            dropped,
            try b.field(frame, "invalid_highlights"),
            try dropped.constant(u64, 1),
        ),
    })));
    const next = try active.call(
        function,
        .{
            .commits = commits,
            .highlights = highlights,
            .index = try add(c, active, index, try active.constant(u64, 1)),
            .frame = revised,
        },
    );
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(highlights)),
        try active.ret(next),
        try ended.ret(frame),
    )));
    return function;
}

fn appendNote(
    c: protean.Context,
    b: anytype,
    clip: Clip,
    oid: oid_text.Function,
    frame: a.Value(Frame),
    note: a.Value(Highlight),
) !a.Value(Frame) {
    const text = try clipped(c, b, clip, try b.field(note, "text"), 80);
    return b.update(frame, .{
        .text = try join(
            c,
            b,
            .{
                try b.field(frame, "text"),
                try literal(c, "\nUnverified note for "),
                try oid_text.format(c, b, oid, try b.field(note, "oid")),
                try literal(c, ": "),
                try b.field(text, "text"),
            },
        ),
        .abbreviated = try either(
            b,
            try b.field(frame, "abbreviated"),
            try b.field(text, "abbreviated"),
        ),
    });
}

fn header(
    c: protean.Context,
    b: anytype,
    clip: Clip,
    oid: oid_text.Function,
    input: a.Value(Input),
) !a.Value(Frame) {
    const repo = try b.field(input, "repository");
    const owner = try clipped(c, b, clip, try b.field(repo, "owner"), 80);
    const name = try clipped(c, b, clip, try b.field(repo, "name"), 80);
    const ref = try clipped(c, b, clip, try b.field(repo, "ref"), 160);
    const text = try join(c, b, .{
        try literal(c, "Repository: "),
        try b.field(owner, "text"),
        try literal(c, "/"),
        try b.field(name, "text"),
        try literal(c, "\nRef: "),
        try b.field(ref, "text"),
        try literal(c, "\nComparison: "),
        try oid_text.format(c, b, oid, try b.field(input, "base")),
        try literal(c, "..."),
        try oid_text.format(c, b, oid, try b.field(input, "tip")),
        try literal(c, "\nObserved at (Unix ms): "),
        try b.textInteger(try b.field(input, "observed_ms")),
        try literal(c, "\nCoverage: observations after "),
        try b.textInteger(try b.field(input, "prior_sequence")),
        try literal(c, " through "),
        try b.textInteger(try b.field(input, "through_sequence")),
        try literal(c, "; epoch "),
        try b.textInteger(try b.field(input, "epoch")),
        try literal(c, "\nVerified commits: "),
        try b.textInteger(try b.sequenceLength(try b.field(input, "commits"))),
    });
    return b.product(try c.schema(Frame), .{
        .text = text,
        .listed_oids = try c.literal(Oids, .{ .items = &.{} }),
        .invalid_highlights = try b.constant(u64, 0),
        .abbreviated = try either(
            b,
            try b.field(owner, "abbreviated"),
            try either(b, try b.field(name, "abbreviated"), try b.field(ref, "abbreviated")),
        ),
    });
}

fn summary(
    c: protean.Context,
    b: anytype,
    clip: Clip,
    frame: a.Value(Frame),
    input: a.Value(Input),
) !a.Value(Frame) {
    const value = try b.field(input, "summary");
    const present = try b.branch();
    const absent = try b.branch();
    const text = try clipped(c, present, clip, value, 500);
    const next = try present.update(frame, .{
        .text = try join(
            c,
            present,
            .{
                try b.field(frame, "text"),
                try literal(c, "\nMethod commentary (unverified): "),
                try present.field(text, "text"),
            },
        ),
        .abbreviated = try either(
            present,
            try b.field(frame, "abbreviated"),
            try present.field(text, "abbreviated"),
        ),
    });
    return b.conditional(
        try b.less(try b.constant(u64, 0), try b.blobLength(value)),
        try present.ret(next),
        try absent.ret(frame),
    );
}

fn finalize(
    c: protean.Context,
    b: anytype,
    frame: a.Value(Frame),
    input: a.Value(Input),
) !a.Value(Result) {
    const total = try b.sequenceLength(try b.field(input, "commits"));
    const listed = try b.sequenceLength(try b.field(frame, "listed_oids"));
    const footer = try join(c, b, .{
        try b.field(frame, "text"),
        try literal(
            c,
            "\nListed ",
        ),
        try b.textInteger(listed),
        try literal(
            c,
            " of ",
        ),
        try b.textInteger(total),
        try literal(
            c,
            "; full acquired evidence retained locally.\nDropped invalid highlights: ",
        ),
        try b.textInteger(try b.field(frame, "invalid_highlights")),
        try b.select(
            try b.field(frame, "abbreviated"),
            try literal(c, "\nPresentation abbreviated."),
            try literal(c, ""),
        ),
    });
    return b.product(try c.schema(Result), .{
        .text = footer,
        .total_commits = total,
        .listed_commits = listed,
        .listed_oids = try b.field(frame, "listed_oids"),
        .invalid_highlights = try b.field(frame, "invalid_highlights"),
        .abbreviated = try b.field(frame, "abbreviated"),
        .comparison = try b.product(try c.schema(Comparison), .{
            .repository = try b.field(input, "repository"),
            .base = try b.field(input, "base"),
            .tip = try b.field(input, "tip"),
        }),
    });
}

pub fn emit(c: protean.Context, oid: oid_text.Function) !Function {
    const clip = try clipFunction(c);
    const contains = try containsFunction(c);
    const list = try listFunction(c, clip, oid);
    const notes = try notesFunction(c, clip, oid, contains);
    const function = try c.author.function("verified bounded digest frame", .{
        .input = try c.schema(Input),
    }, try c.schema(Result), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const prior = try b.field(input, "prior_sequence");
    const through = try b.field(input, "through_sequence");
    const nonempty = try b.less(
        try b.constant(u64, 0),
        try b.sequenceLength(try b.field(input, "commits")),
    );
    try a.require(
        c,
        b,
        try b.select(
            nonempty,
            try b.less(prior, through),
            try b.select(
                try b.less(through, prior),
                try b.constant(bool, false),
                try b.constant(bool, true),
            ),
        ),
        "render_invalid_coverage",
    );
    const frame = try header(c, b, clip, oid, input);
    const with_summary = try summary(c, b, clip, frame, input);
    const with_list = try b.call(
        list,
        .{
            .commits = try b.field(input, "commits"),
            .index = try b.constant(u64, 0),
            .frame = with_summary,
        },
    );
    const with_notes = try b.call(
        notes,
        .{
            .commits = try b.field(input, "commits"),
            .highlights = try b.field(input, "highlights"),
            .index = try b.constant(u64, 0),
            .frame = with_list,
        },
    );
    try c.author.define(function, try b.ret(try finalize(c, b, with_notes, input)));
    return function;
}
