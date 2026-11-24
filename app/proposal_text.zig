const std = @import("std");
const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const a = @import("author.zig");

pub const Text = t.Text;
pub const Input = struct { target: ?t.Id, body: @FieldType(t.Proposal, "body") };
pub const Function = a.Function(struct { input: Input }, Rendering);
const budget: u64 = 4000;
pub const Complete = struct { text: Text, cost: u64 };
pub const Rendering = union(enum) { complete: Complete, cli: void };
const Append = a.Function(struct { rendering: Rendering, text: Text, cost: u64 }, Rendering);
const Piece = struct { text: Text, cost: u64, width: u64 };
const Span = struct { end: u64, cost: u64 };
const Scan = a.Function(struct { input: cts.Utf8, end: u64, cost: u64, limit: u64 }, Span);
fn Blob(comptime hex: bool) type {
    return if (hex) cts.Bytes(null) else cts.Utf8;
}
fn Convert(comptime hex: bool) type {
    return a.Function(struct { input: Blob(hex), index: u64, rendering: Rendering }, Rendering);
}
const Helpers = struct { append: Append, text: Convert(false), bytes: Convert(true) };

pub fn emit(c: protean.Context) !Function {
    @setEvalBranchQuota(100_000);
    const append = try appender(c);
    const helpers: Helpers = .{
        .append = append,
        .text = try converter(c, false, append),
        .bytes = try converter(c, true, append),
    };
    const function = try c.author.function("render complete confirmation proposal", .{
        .input = try c.schema(Input),
    }, try c.schema(Rendering), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const empty = try c.literal(Rendering, .{ .complete = .{
        .text = .{ .bytes = "" },
        .cost = 0,
    } });
    const prefix = try writeLiteral(c, b, append, empty, "Proposed action; not yet applied.\n");
    const rendered = try value(c, b, helpers, Input, input, prefix);
    try c.author.define(function, try b.ret(rendered));
    return function;
}

fn appender(c: protean.Context) !Append {
    const function = try c.author.function("append complete confirmation text within budget", .{
        .rendering = try c.schema(Rendering),
        .text = try c.schema(Text),
        .cost = try c.schema(u64),
    }, try c.schema(Rendering), &.{});
    const b = try c.author.body(function);
    const rendering = try b.parameter("rendering");
    const text = try b.parameter("text");
    const cost = try b.parameter("cost");
    const cli = try b.caseOf(rendering, "cli");
    const complete = try b.caseOf(rendering, "complete");
    const cb = complete.body();
    const total = try cb.checked(.add, try cb.field(complete.payload(), "cost"), cost, .{
        .overflow = try a.failure(c, "proposal_description_budget"),
    });
    const fits = try cb.branch();
    const oversized = try cb.branch();
    const text_next = try fits.blobConcat(
        try c.schema(Text),
        try fits.field(complete.payload(), "text"),
        text,
        try a.failure(c, "proposal_description_capacity"),
    );
    const next = try fits.variant(try c.schema(Rendering), "complete", try fits.product(
        try c.schema(Complete),
        .{ .text = text_next, .cost = total },
    ));
    const result = try cb.conditional(
        try cb.less(try cb.constant(u64, budget), total),
        try oversized.ret(try c.literal(Rendering, .{ .cli = {} })),
        try fits.ret(next),
    );
    try c.author.define(function, try b.ret(try b.match(rendering, .{
        .cli = try cli.ret(rendering),
        .complete = try complete.ret(result),
    })));
    return function;
}

fn literal(c: protean.Context, text: []const u8) !a.Value(Text) {
    return c.literal(Text, .{ .bytes = text });
}

fn literalCost(text: []const u8) !u64 {
    var total: u64 = 0;
    for (text) |byte| {
        const cost: u64 = switch (byte) {
            '&' => 5,
            '<', '>' => 4,
            128...191 => 0,
            else => 1,
        };
        total = try std.math.add(u64, total, cost);
    }
    return total;
}

fn writeLiteral(
    c: protean.Context,
    b: anytype,
    append: Append,
    rendering: a.Value(Rendering),
    text: []const u8,
) !a.Value(Rendering) {
    return b.call(append, .{
        .rendering = rendering,
        .text = try literal(c, text),
        .cost = try b.constant(u64, try literalCost(text)),
    });
}

inline fn value(
    c: protean.Context,
    b: anytype,
    helpers: Helpers,
    comptime T: type,
    item: a.Value(T),
    rendering: a.Value(Rendering),
) anyerror!a.Value(Rendering) {
    const cli = try b.caseOf(rendering, "cli");
    const complete = try b.caseOf(rendering, "complete");
    return b.match(rendering, .{
        .cli = try cli.ret(rendering),
        .complete = try complete.ret(try inner(
            c,
            complete.body(),
            helpers,
            T,
            item,
            rendering,
        )),
    });
}

inline fn inner(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    comptime T: type,
    item: a.Value(T),
    state: a.Value(Rendering),
) anyerror!a.Value(Rendering) {
    if (comptime cts.native.wrapped(T)) {
        if (T.protean_value_kind == .vector)
            @compileError("proposal description needs finite fields");
        return quoted(c, b, h, item, state, T.protean_value_kind == .bytes);
    }
    return switch (@typeInfo(T)) {
        .void => writeLiteral(c, b, h.append, state, "null"),
        .int => integer(c, b, h.append, item, state),
        .bool => b.call(h.append, .{
            .rendering = state,
            .text = try b.select(item, try literal(c, "true"), try literal(c, "false")),
            .cost = try b.select(item, try b.constant(u64, 4), try b.constant(u64, 5)),
        }),
        .@"enum" => enumeration(c, b, h, T, item, state),
        .array => array(c, b, h, T, item, state),
        .optional => optional(c, b, h, T, item, state),
        .@"struct" => record(c, b, h, T, item, state),
        .@"union" => alternative(c, b, h, T, item, state),
        else => @compileError("unsupported proposal field: " ++ @typeName(T)),
    };
}

fn integer(
    c: protean.Context,
    b: anytype,
    append: Append,
    item: anytype,
    state: a.Value(Rendering),
) !a.Value(Rendering) {
    const text = try b.textInteger(item);
    const length = try b.blobLength(text);
    return b.call(append, .{
        .rendering = state,
        .text = try b.blobSlice(try c.schema(Text), text, try b.constant(u64, 0), length, .{
            .capacity = try a.failure(c, "proposal_integer_capacity"),
            .invalid_utf8 = try a.failure(c, "proposal_integer_utf8"),
        }),
        .cost = length,
    });
}

inline fn record(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    comptime T: type,
    item: a.Value(T),
    state: a.Value(Rendering),
) anyerror!a.Value(Rendering) {
    var result = try writeLiteral(c, b, h.append, state, "{");
    inline for (
        @typeInfo(T).@"struct".field_names,
        @typeInfo(T).@"struct".field_types,
        0..,
    ) |name, Child, index| {
        result = try writeLiteral(c, b, h.append, result, if (index == 0) "" else ", ");
        result = try writeLiteral(c, b, h.append, result, "\"" ++ name ++ "\": ");
        result = try value(c, b, h, Child, try b.field(item, name), result);
    }
    return writeLiteral(c, b, h.append, result, "}");
}

inline fn alternative(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    comptime T: type,
    item: a.Value(T),
    state: a.Value(Rendering),
) anyerror!a.Value(Rendering) {
    var result = state;
    inline for (
        @typeInfo(T).@"union".field_names,
        @typeInfo(T).@"union".field_types,
        0..,
    ) |name, Child, index| {
        const selected = try b.branch();
        const other = try b.branch();
        const payload = try selected.variantPayload(
            item,
            name,
            try a.failure(c, "proposal_variant"),
        );
        const prefix = try writeLiteral(c, selected, h.append, state, "{\"" ++ name ++ "\": ");
        const body = try value(c, selected, h, Child, payload, prefix);
        result = try b.conditional(
            try b.equal(try b.variantTag(item), try b.constant(u64, index)),
            try selected.ret(try writeLiteral(c, selected, h.append, body, "}")),
            try other.ret(result),
        );
    }
    return result;
}

inline fn optional(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    comptime T: type,
    item: a.Value(T),
    state: a.Value(Rendering),
) anyerror!a.Value(Rendering) {
    const absent = try b.caseOf(item, "none");
    const present = try b.caseOf(item, "some");
    return b.match(item, .{
        .none = try absent.ret(try writeLiteral(c, absent.body(), h.append, state, "null")),
        .some = try present.ret(
            try value(c, present.body(), h, @typeInfo(T).optional.child, present.payload(), state),
        ),
    });
}

fn enumeration(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    comptime T: type,
    item: a.Value(T),
    state: a.Value(Rendering),
) !a.Value(Rendering) {
    var result = state;
    inline for (@typeInfo(T).@"enum".field_names) |name| {
        const selected = try b.branch();
        const other = try b.branch();
        result = try b.conditional(
            try b.equal(try b.enumTag(item), try b.enumTag(try c.literal(T, @field(T, name)))),
            try selected.ret(try writeLiteral(c, selected, h.append, state, "\"" ++ name ++ "\"")),
            try other.ret(result),
        );
    }
    return result;
}

fn array(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    comptime T: type,
    item: a.Value(T),
    state: a.Value(Rendering),
) !a.Value(Rendering) {
    if (@typeInfo(T).array.child != u8) @compileError("proposal identities must be bytes");
    var bytes = try c.literal(cts.Bytes(null), .{ .bytes = "" });
    inline for (0..@typeInfo(T).array.len) |index| {
        const byte = try b.variantPayload(
            try b.sequenceGet(item, try b.constant(u64, index)),
            "some",
            try a.failure(c, "proposal_identity_bounds"),
        );
        bytes = try b.blobConcat(
            try c.schema(cts.Bytes(null)),
            bytes,
            try b.blobFromByte(byte),
            try a.failure(c, "proposal_identity_capacity"),
        );
    }
    return quoted(c, b, h, bytes, state, true);
}

fn quoted(
    c: protean.Context,
    b: anytype,
    h: Helpers,
    item: anytype,
    state: a.Value(Rendering),
    comptime hex: bool,
) !a.Value(Rendering) {
    const opened = try writeLiteral(c, b, h.append, state, "\"");
    const bytes = try b.blobSlice(
        try c.schema(Blob(hex)),
        item,
        try b.constant(u64, 0),
        try b.blobLength(item),
        if (hex) .{ .capacity = try a.failure(c, "proposal_input_capacity") } else .{
            .capacity = try a.failure(c, "proposal_input_capacity"),
            .invalid_utf8 = try a.failure(c, "proposal_input_utf8"),
        },
    );
    const function = if (hex) h.bytes else h.text;
    const encoded = try b.call(function, .{
        .input = bytes,
        .index = try b.constant(u64, 0),
        .rendering = opened,
    });
    return writeLiteral(c, b, h.append, encoded, "\"");
}

fn converter(c: protean.Context, comptime hex: bool, append: Append) !Convert(hex) {
    const function = try c.author.function("encode confirmation text until complete or CLI only", .{
        .input = try c.schema(Blob(hex)),
        .index = try c.schema(u64),
        .rendering = try c.schema(Rendering),
    }, try c.schema(Rendering), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const index = try b.parameter("index");
    const state = try b.parameter("rendering");
    const cli = try b.caseOf(state, "cli");
    const complete = try b.caseOf(state, "complete");
    const cb = complete.body();
    const more = try cb.branch();
    const done = try cb.branch();
    const byte = try more.variantPayload(
        try more.blobByte(input, index),
        "some",
        try a.failure(c, "proposal_text_bounds"),
    );
    const piece = if (hex) try more.product(try c.schema(Piece), .{
        .text = try byteEncoding(c, more, byte, true),
        .cost = try more.constant(u64, 2),
        .width = try more.constant(u64, 1),
    }) else try textPiece(
        c,
        more,
        try spanScanner(c),
        input,
        index,
        byte,
        try more.field(complete.payload(), "cost"),
    );
    const next = try more.call(append, .{
        .rendering = state,
        .text = try more.field(piece, "text"),
        .cost = try more.field(piece, "cost"),
    });
    const continued = try more.call(function, .{
        .input = input,
        .index = try more.checked(.add, index, try more.field(piece, "width"), .{
            .overflow = try a.failure(c, "proposal_text_bounds"),
        }),
        .rendering = next,
    });
    const result = try cb.conditional(
        try cb.less(index, try cb.blobLength(input)),
        try more.ret(continued),
        try done.ret(state),
    );
    try c.author.define(function, try b.ret(try b.match(state, .{
        .cli = try cli.ret(state),
        .complete = try complete.ret(result),
    })));
    return function;
}

fn encodings(comptime hex: bool) [if (hex) 256 else 128]cts.Text(6) {
    var result: [if (hex) 256 else 128]cts.Text(6) = undefined;
    const digits = "0123456789abcdef";
    inline for (0..result.len) |index| {
        result[index] = .{ .bytes = if (hex)
            &.{ digits[index / 16], digits[index % 16] }
        else if (index < 32)
            &.{ '\\', 'u', '0', '0', digits[index / 16], digits[index % 16] }
        else if (index == '"' or index == '\\')
            &.{ '\\', @intCast(index) }
        else
            &.{@intCast(index)} };
    }
    return result;
}

fn byteEncoding(
    c: protean.Context,
    b: anytype,
    byte: a.Value(u8),
    comptime hex: bool,
) !a.Value(Text) {
    const table = comptime encodings(hex);
    const encoded = try b.variantPayload(
        try b.sequenceGet(
            try c.literal(@TypeOf(table), table),
            try b.convertInteger(try c.schema(u64), byte, .{}),
        ),
        "some",
        try a.failure(c, "proposal_encoding_bounds"),
    );
    return b.blobSlice(
        try c.schema(Text),
        encoded,
        try b.constant(u64, 0),
        try b.blobLength(encoded),
        .{
            .capacity = try a.failure(c, "proposal_piece_capacity"),
            .invalid_utf8 = try a.failure(c, "proposal_piece_utf8"),
        },
    );
}

fn needsEscape(b: anytype, byte: a.Value(u8)) !a.Value(bool) {
    const yes = try b.constant(bool, true);
    return b.select(
        try b.less(byte, try b.constant(u8, 32)),
        yes,
        try b.select(
            try b.equal(byte, try b.constant(u8, '"')),
            yes,
            try b.equal(byte, try b.constant(u8, '\\')),
        ),
    );
}

fn scalarWidth(b: anytype, byte: a.Value(u8)) !a.Value(u64) {
    var width = try b.constant(u64, 4);
    inline for (.{ .{ 240, 3 }, .{ 224, 2 }, .{ 128, 1 } }) |entry|
        width = try b.select(
            try b.less(byte, try b.constant(u8, entry[0])),
            try b.constant(u64, entry[1]),
            width,
        );
    return width;
}

// The caller supplies the leading byte of an admitted UTF-8 scalar.
fn scalarCost(b: anytype, byte: a.Value(u8)) !a.Value(u64) {
    var cost = try b.constant(u64, 1);
    inline for (.{ .{ '&', 5 }, .{ '<', 4 }, .{ '>', 4 } }) |entry|
        cost = try b.select(
            try b.equal(byte, try b.constant(u8, entry[0])),
            try b.constant(u64, entry[1]),
            cost,
        );
    return cost;
}

// Walk admitted UTF-8 by scalar without carrying or copying the growing description.
fn spanScanner(c: protean.Context) !Scan {
    const scan = try c.author.function("measure unchanged proposal text", .{
        .input = try c.schema(cts.Utf8),
        .end = try c.schema(u64),
        .cost = try c.schema(u64),
        .limit = try c.schema(u64),
    }, try c.schema(Span), &.{});
    const b = try c.author.body(scan);
    const input = try b.parameter("input");
    const end = try b.parameter("end");
    const cost = try b.parameter("cost");
    const limit = try b.parameter("limit");
    const span = try b.product(try c.schema(Span), .{ .end = end, .cost = cost });
    const more = try b.branch();
    const done = try b.branch();
    const byte = try more.variantPayload(
        try more.blobByte(input, end),
        "some",
        try a.failure(c, "proposal_text_bounds"),
    );
    const escape = try more.branch();
    const raw = try more.branch();
    const bounds = try a.failure(c, "proposal_scalar_bounds");
    const overflow = try a.failure(c, "proposal_description_budget");
    const next = try raw.call(scan, .{
        .input = input,
        .end = try raw.checked(.add, end, try scalarWidth(raw, byte), .{ .overflow = bounds }),
        .cost = try raw.checked(.add, cost, try scalarCost(raw, byte), .{ .overflow = overflow }),
        .limit = limit,
    });
    const scanned = try more.conditional(
        try needsEscape(more, byte),
        try escape.ret(span),
        try raw.ret(next),
    );
    const active = try b.select(
        try b.less(cost, limit),
        try b.less(end, try b.blobLength(input)),
        try b.constant(bool, false),
    );
    try c.author.define(
        scan,
        try b.ret(try b.conditional(active, try more.ret(scanned), try done.ret(span))),
    );
    return scan;
}

fn textPiece(
    c: protean.Context,
    b: anytype,
    scan: Scan,
    input: a.Value(cts.Utf8),
    index: a.Value(u64),
    byte: a.Value(u8),
    used: a.Value(u64),
) !a.Value(Piece) {
    const escape = try b.branch();
    const raw = try b.branch();
    const encoded = try byteEncoding(c, escape, byte, false);
    const bounds = try a.failure(c, "proposal_scalar_bounds");
    const overflow = try a.failure(c, "proposal_description_budget");
    const span = try raw.call(scan, .{
        .input = input,
        .end = try raw.checked(.add, index, try scalarWidth(raw, byte), .{ .overflow = bounds }),
        .cost = try scalarCost(raw, byte),
        .limit = try raw.checked(
            .subtract,
            try raw.constant(u64, budget + 1),
            used,
            .{ .overflow = overflow },
        ),
    });
    const end = try raw.field(span, "end");
    const text = try raw.blobSlice(try c.schema(Text), input, index, end, .{
        .capacity = try a.failure(c, "proposal_scalar_capacity"),
        .invalid_utf8 = try a.failure(c, "proposal_scalar_utf8"),
    });
    return b.conditional(
        try needsEscape(b, byte),
        try escape.ret(try escape.product(try c.schema(Piece), .{
            .text = encoded,
            .cost = try escape.blobLength(encoded),
            .width = try escape.constant(u64, 1),
        })),
        try raw.ret(try raw.product(try c.schema(Piece), .{
            .text = text,
            .cost = try raw.field(span, "cost"),
            .width = try raw.checked(.subtract, end, index, .{ .overflow = bounds }),
        })),
    );
}
