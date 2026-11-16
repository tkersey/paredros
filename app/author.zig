const horos = @import("horos");
const protean = @import("protean");
const t = @import("application_types");
const a = horos.authoring;

pub fn Value(comptime T: type) type {
    return *const a.Value(a.Shape(T));
}

pub fn Function(comptime Input: type, comptime Output: type) type {
    return *const a.Function(a.Signature(a.Shape(Input).contract.product, a.Shape(Output)));
}

pub fn Operation(comptime Input: type, comptime Output: type) type {
    return *const a.Operation(a.OperationSignature(
        a.Shape(Input),
        a.Shape(Output),
        horos.data.schema.native.Fields(&.{}, &.{}),
    ));
}

pub fn failure(c: protean.Context, code: []const u8) !*const a.FailureLiteral(a.Shape(t.Failure)) {
    return a.interop.literalFailure(c.author, try c.literal(t.Failure, .{ .code = .{ .bytes = code } }));
}

pub fn replace(
    _: protean.Context,
    b: anytype,
    comptime T: type,
    previous: Value(T),
    changes: anytype,
) !Value(T) {
    return b.update(previous, changes);
}

pub fn require(c: protean.Context, b: anytype, condition: Value(bool), code: []const u8) !void {
    const accepted = try b.branch();
    const rejected = try b.branch();
    _ = try b.conditional(
        condition,
        try accepted.ret(try accepted.constant(void, {})),
        try rejected.fail(try c.schema(void), try c.literal(t.Failure, .{ .code = .{ .bytes = code } })),
    );
}
