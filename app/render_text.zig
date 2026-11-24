const protean = @import("protean");
const cts = @import("protean_contracts");
const a = @import("author.zig");

pub const instruction = "Operator instruction bytes=";
pub const instruction_end = "\n";
pub const repository = "\nState: repository id=";
pub const ref = " ref=";
pub const lead_end = "\nComplete commit records and immutable provenance follow. " ++
    "Provider captures remain retained locally; this context projects commit evidence.\n";
pub const batch = "\nState: complete batch sequence=";
pub const epoch = " epoch=";
pub const acquired = " acquired_ms=";
pub const task = " retained task bytes=";
pub const digest = " result digest bytes=";
pub const batch_end = "\n";
pub const identity_open = "[";
pub const identity_separator = ",";
pub const identity_close = "]";
pub const commit_lead = "\nEvidence untrusted: commit ";
pub const commit_size = " message bytes=";
pub const commit_end = "\n";

pub const Scalar = struct { width: u64, code: u32, permitted: bool };
pub const Inert = a.Function(struct { text: cts.Utf8, index: u64 }, Scalar);
pub const printable = [_][2]u32{
    .{ 0x20, 0x7E },       .{ 0xA0, 0xAC },       .{ 0xAE, 0x5FF },
    .{ 0x606, 0x61B },     .{ 0x61D, 0x6DC },     .{ 0x6DE, 0x70E },
    .{ 0x710, 0x88F },     .{ 0x892, 0x8E1 },     .{ 0x8E3, 0x180D },
    .{ 0x180F, 0x200A },   .{ 0x2010, 0x2027 },   .{ 0x202F, 0x205F },
    .{ 0x2070, 0xD7FF },   .{ 0xF900, 0xFDCF },   .{ 0xFDF0, 0xFEFE },
    .{ 0xFF00, 0xFFF8 },   .{ 0xFFFC, 0xFFFD },   .{ 0x10000, 0x110BC },
    .{ 0x110BE, 0x110CC }, .{ 0x110CE, 0x1342F }, .{ 0x13440, 0x1BC9F },
    .{ 0x1BCA4, 0x1D172 }, .{ 0x1D17B, 0x3FFFF }, .{ 0xE0100, 0xE01EF },
};

pub fn inert(c: protean.Context) !Inert {
    const function = try c.author.function("classify untrusted scalar by printable allow-list", .{
        .text = try c.schema(cts.Utf8),
        .index = try c.schema(u64),
    }, try c.schema(Scalar), &.{});
    const b = try c.author.body(function);
    const text = try b.parameter("text");
    const index = try b.parameter("index");
    const bounds = try a.failure(c, "inert_text_bounds");
    const lead = try b.variantPayload(try b.blobByte(text, index), "some", bounds);
    var width = try b.constant(u64, 4);
    var mask = try b.constant(u32, 0x07);
    inline for (.{ .{ 0xF0, 3, 0x0F }, .{ 0xE0, 2, 0x1F }, .{ 0x80, 1, 0x7F } }) |entry| {
        const below = try b.less(lead, try b.constant(u8, entry[0]));
        width = try b.select(below, try b.constant(u64, entry[1]), width);
        mask = try b.select(below, try b.constant(u32, entry[2]), mask);
    }
    var code = try b.bitwise(.@"and", try b.convertInteger(try c.schema(u32), lead, .{}), mask);
    inline for (1..4) |offset| {
        const shifted = try b.checked(.multiply, code, try b.constant(u32, 64), .{
            .overflow = bounds,
        });
        const joined = try b.checked(.add, shifted, try continuation(c, b, text, index, offset), .{
            .overflow = bounds,
        });
        code = try b.select(try b.less(try b.constant(u64, offset), width), joined, code);
    }
    try c.author.define(function, try b.ret(try b.product(try c.schema(Scalar), .{
        .width = width,
        .code = code,
        .permitted = try within(b, code, &printable),
    })));
    return function;
}

pub fn scalar(
    c: protean.Context,
    b: anytype,
    function: Inert,
    text: a.Value(cts.Utf8),
    index: a.Value(u64),
    lead: a.Value(u8),
) !a.Value(Scalar) {
    const ascii = try b.select(
        try b.less(lead, try b.constant(u8, printable[0][0])),
        try b.constant(bool, false),
        try b.less(lead, try b.constant(u8, printable[0][1] + 1)),
    );
    const direct = try b.branch();
    const decoded = try b.branch();
    return b.conditional(
        ascii,
        try direct.ret(try direct.product(try c.schema(Scalar), .{
            .width = try direct.constant(u64, 1),
            .code = try direct.convertInteger(try c.schema(u32), lead, .{}),
            .permitted = try direct.constant(bool, true),
        })),
        try decoded.ret(try decoded.call(function, .{ .text = text, .index = index })),
    );
}

fn within(b: anytype, code: a.Value(u32), comptime ranges: []const [2]u32) !a.Value(bool) {
    const last = ranges.len - 1;
    const head = try b.branch();
    var lowers: [last]@TypeOf(head) = undefined;
    var uppers: [last]@TypeOf(head) = undefined;
    var below: [last]a.Value(bool) = undefined;
    var leaves: [last]a.Value(bool) = undefined;
    lowers[0] = head;
    uppers[0] = try b.branch();
    below[0] = try b.less(code, try b.constant(u32, ranges[1][0]));
    inline for (1..last) |level| {
        const parent = uppers[level - 1];
        lowers[level] = try parent.branch();
        uppers[level] = try parent.branch();
        below[level] = try parent.less(code, try parent.constant(u32, ranges[level + 1][0]));
    }
    inline for (0..last) |level| leaves[level] = try contains(lowers[level], code, ranges[level]);
    var value = try contains(uppers[last - 1], code, ranges[last]);
    inline for (1..last) |step| {
        const level = last - step;
        value = try uppers[level - 1].conditional(
            below[level],
            try lowers[level].ret(leaves[level]),
            try uppers[level].ret(value),
        );
    }
    return b.conditional(below[0], try lowers[0].ret(leaves[0]), try uppers[0].ret(value));
}

fn contains(b: anytype, code: a.Value(u32), comptime range: [2]u32) !a.Value(bool) {
    return b.select(
        try b.less(code, try b.constant(u32, range[0])),
        try b.constant(bool, false),
        try b.less(code, try b.constant(u32, range[1] + 1)),
    );
}

fn continuation(
    c: protean.Context,
    b: anytype,
    text: a.Value(cts.Utf8),
    index: a.Value(u64),
    comptime offset: u64,
) !a.Value(u32) {
    const position = try b.checked(.add, index, try b.constant(u64, offset), .{
        .overflow = try a.failure(c, "inert_text_bounds"),
    });
    const byte = try b.blobByte(text, position);
    const absent = try b.caseOf(byte, "none");
    const present = try b.caseOf(byte, "some");
    const pb = present.body();
    return b.match(byte, .{
        .none = try absent.ret(try absent.body().constant(u32, 0)),
        .some = try present.ret(try pb.bitwise(
            .@"and",
            try pb.convertInteger(try c.schema(u32), present.payload(), .{}),
            try pb.constant(u32, 0x3F),
        )),
    });
}
