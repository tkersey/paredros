const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");

pub const Request = struct {
    operation: []const u8,
    kind: std.meta.Tag(t.Input),
    target: ?t.Id,
    origin: t.Origin,
    digest: t.Digest,
};

pub fn stableDigest(a: std.mem.Allocator, value: anytype) !t.Digest {
    const bytes = try c.encodeOwned(@TypeOf(value), a, value);
    defer a.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("paredros.stable-request.v1\x00");
    hash.update(bytes);
    var digest: t.Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn directiveDigest(
    a: std.mem.Allocator,
    operation: []const u8,
    request: t.Digest,
) !t.Digest {
    return stableDigest(a, .{
        .operation = t.OperationId{ .bytes = operation },
        .request = request,
    });
}

pub fn admit(
    service: anytype,
    a: std.mem.Allocator,
    request: Request,
    materializer: anytype,
) !@typeInfo(
    @TypeOf(service.submit(a, request.operation, @as(t.Input, undefined))),
).error_union.payload {
    if (try service.operationLookup(a, request.operation)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        var input = (try service.applicationValue(a, receipt.value.task, .input)) orelse
            return error.MissingAdmittedInput;
        defer input.deinit();
        if (!std.mem.eql(u8, input.schema_id, t.input_schema_id) or input.encoding != .contract)
            return error.UnsupportedApplicationSchema;
        var decoded = try c.decodeOwned(t.Input, a, input.bytes);
        defer decoded.deinit();
        try matches(a, request, decoded.value);
        return service.submit(a, request.operation, decoded.value);
    }
    const input = try materializer.materialize(a, request);
    try matches(a, request, input);
    return service.submit(a, request.operation, input);
}

fn envelope(input: t.Input) t.Envelope {
    return switch (input) {
        inline else => |value| value.envelope,
    };
}

fn target(input: t.Input) ?t.Id {
    return switch (input) {
        .directive => |value| value.obligation,
        .step => |value| value.obligation,
        .turn => |value| value.target,
        .delivery => |value| value.payload.logical.obligation,
        else => null,
    };
}

fn matches(a: std.mem.Allocator, request: Request, input: t.Input) !void {
    const frozen = envelope(input);
    if (frozen.version != 1) return error.UnsupportedApplicationSchema;
    if (std.meta.activeTag(input) != request.kind or
        !std.mem.eql(u8, frozen.operation.bytes, request.operation) or
        !std.meta.eql(frozen.stable_request, request.digest) or
        !std.meta.eql(target(input), request.target)) return error.OperationConflict;
    const expected_origin = try c.encodeOwned(t.Origin, a, request.origin);
    defer a.free(expected_origin);
    const frozen_origin = try c.encodeOwned(t.Origin, a, frozen.origin);
    defer a.free(frozen_origin);
    if (!std.mem.eql(u8, expected_origin, frozen_origin)) return error.OperationConflict;
}
