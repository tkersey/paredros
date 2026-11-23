const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const m = @import("../app/method_contract.zig");
const w = c.workspace;
const j = native.json;

fn hash(bytes: []const u8) t.Digest {
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn contractDigest(a: std.mem.Allocator) !t.Digest {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update("paredros.method.contract.v1\x00");
    inline for (.{
        m.GuestInput,
        m.GuestOutput,
        m.CompletionRequest,
        m.CompletionReply,
    }) |T| {
        const bytes = try native.values.schemaBytes(T, a);
        defer a.free(bytes);
        digest.update(&hash(bytes));
    }
    digest.update(m.completion_identity);
    return digest.finalResult();
}

pub fn declaration() native.Declaration {
    return .{
        .identity = m.workspace_identity,
        .resource_role = "workspace",
        .kind = .workspace,
        .workspace = authorize,
        .payload_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return native.values.schemaBytes(m.WorkspaceRequest, a);
            }
        }.schema,
        .resume_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return native.values.schemaBytes(w.Reply, a);
            }
        }.schema,
    };
}

pub fn codecDeclaration() native.Declaration {
    var result = native.registry.leaf(
        m.CodecRequest,
        m.CodecReply,
        .{
            .identity = m.codec_identity,
            .resource_role = "frozen",
        },
        invoke,
    );
    result.invoke = invokeBytes;
    result.recovery = .{
        .identity = "paredros.method.codec.recovery.v1",
        .version = 1,
        .rederive = rederive,
    };
    return result;
}

fn invokeBytes(ctx: native.Context, bytes: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const request = try c.decodeOwned(m.CodecRequest, scratch, bytes);
    return c.encodeOwned(
        m.CodecReply,
        ctx.allocator,
        try codec(scratch, request.value),
    );
}

fn invoke(ctx: native.Context, request: m.CodecRequest) !m.CodecReply {
    return codec(ctx.allocator, request);
}

fn rederive(
    ctx: native.registry.RederivationContext,
    _: native.registry.RecoveryInput,
    bytes: []const u8,
    _: ?[]const u8,
) !native.registry.RederivationFinding {
    try ctx.checkCancellation();
    var request = try c.decodeOwned(m.CodecRequest, ctx.allocator, bytes);
    defer request.deinit();
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    return .{ .result = try c.encodeOwned(
        m.CodecReply,
        ctx.allocator,
        try codec(arena.allocator(), request.value),
    ) };
}

pub fn authorize(
    ctx: native.registry.ProjectionContext,
    bytes: []const u8,
) ![]u8 {
    var request = try c.decodeOwned(m.WorkspaceRequest, ctx.allocator, bytes);
    defer request.deinit();
    const value = request.value;
    if (!std.meta.eql(
        value.contract_digest,
        try contractDigest(ctx.allocator),
    ))
        return error.InvalidMethodContract;
    switch (value.command) {
        .program => |program| switch (program) {
            .build => |build| try authorizeBuild(ctx.allocator, value.source_digest, build),
            else => return error.UnauthorizedMethodCommand,
        },
        .work => |work| try authorizeWork(work),
        .context => |context| switch (context) {
            .expand => |expand| {
                if ((expand.reference.kind != .value and expand.reference.kind != .port) or
                    expand.page.maximum != 48 * 1024 or
                    expand.page.offset > 2 * 1024 * 1024)
                    return error.UnauthorizedMethodCommand;
            },
            else => return error.UnauthorizedMethodCommand,
        },
        else => return error.UnauthorizedMethodCommand,
    }
    return c.encodeOwned(
        native.workspace.Authorized,
        ctx.allocator,
        .{
            .command = value.command,
        },
    );
}

fn authorizeBuild(
    a: std.mem.Allocator,
    digest: t.Digest,
    build: @FieldType(w.Program, "build"),
) !void {
    if (build.source_kind != .source_records or build.role != .computation or
        build.source != .json_text or !std.meta.eql(digest, hash(build.source.json_text.bytes)))
        return error.InvalidMethodSource;
    const expected = try exposures(a, build.source.json_text.bytes);
    defer a.free(expected);
    if (build.exposures.items.len != expected.len) return error.InvalidMethodPorts;
    for (build.exposures.items, expected) |left, right|
        if (!std.meta.eql(left, right)) return error.InvalidMethodPorts;
}

fn authorizeWork(work: w.Work) !void {
    switch (work) {
        .start => |start| {
            if (start.runtime != .packaged or start.trial != .none or
                start.input != .inline_json or start.program.kind != .program or
                start.policy.stop != .next_exposed_event or
                start.policy.continuation != .explicit_only)
                return error.UnauthorizedMethodCommand;
        },
        .interact => |interact| {
            if (interact.command != .resume_value or
                interact.command.resume_value != .inline_json or
                interact.expected.work.kind != .work or interact.port.kind != .port)
                return error.UnauthorizedMethodCommand;
        },
        .advance => |expected| if (expected.work.kind != .work)
            return error.UnauthorizedMethodCommand,
        .inspect => |inspect| if (inspect.work.kind != .work)
            return error.UnauthorizedMethodCommand,
        .cancel => |cancel| if (cancel.expected.work.kind != .work)
            return error.UnauthorizedMethodCommand,
        else => return error.UnauthorizedMethodCommand,
    }
}

fn exposures(a: std.mem.Allocator, bytes: []const u8) ![]w.Exposure {
    var source = try native.source_records.decode(a, bytes);
    defer source.deinit();
    var selected: ?u64 = null;
    for (source.module.effects, 0..) |effect, index| {
        if (!std.mem.eql(u8, effect.identity, m.completion_identity)) continue;
        if (selected != null or effect.external or effect.bodies.len != 0 or
            effect.control_use != .linear) return error.InvalidMethodPorts;
        selected = index;
    }
    const result = try a.alloc(w.Exposure, if (selected != null) 1 else 0);
    if (selected) |index| result[0] = .{ .effect = index, .class = .input };
    return result;
}

pub fn codec(a: std.mem.Allocator, request: m.CodecRequest) !m.CodecReply {
    return codecValue(a, request) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .fault = .{ .bytes = @errorName(err) } };
    };
}

fn codecValue(a: std.mem.Allocator, request: m.CodecRequest) !m.CodecReply {
    return switch (request) {
        .prepare => |input| .{ .prepared = try prepare(a, input) },
        .built => |value| .{ .built = try built(a, value.reply, value.prepared) },
        .observe => |value| .{ .observed = try observe(a, value.reply, value.port_identity) },
        .page => |value| .{ .page = try page(a, value.reply, value.offset) },
        .payload => |text| .{ .payload = try decodeJson(m.CompletionRequest, a, text.bytes) },
        .output => |text| .{ .output = try decodeJson(m.GuestOutput, a, text.bytes) },
        .encode_reply => |reply| .{ .encoded = .{
            .bytes = try encodeJson(m.CompletionReply, a, reply),
        } },
    };
}

pub fn guestFits(a: std.mem.Allocator, guest: m.GuestInput, bound: u64) !bool {
    const encoded = try c.encodeOwned(m.GuestInput, a, guest);
    defer a.free(encoded);
    return encoded.len <= bound;
}

fn prepare(a: std.mem.Allocator, input: m.MethodInput) !m.Prepared {
    if (!std.meta.eql(
        input.retained.source_digest,
        hash(input.retained.bytes.bytes),
    ) or
        !std.meta.eql(
            input.retained.contract_digest,
            try contractDigest(a),
        ))
        return error.InvalidMethodSource;
    if (!try guestFits(a, input.guest, input.input_bytes_max)) return error.MethodInputBound;
    const selected = try exposures(a, input.retained.bytes.bytes);
    return .{
        .build = .{ .program = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = input.retained.bytes.bytes } },
            .source_kind = .source_records,
            .exposures = .{ .items = selected },
            .role = .computation,
        } } },
        .input_json = .{ .bytes = try encodeJson(m.GuestInput, a, input.guest) },
        .port_identity = if (selected.len == 0) null else .{ .bytes = try std.fmt.allocPrint(
            a,
            "{s}{d}",
            .{
                native.program_construction.driver.prefix,
                selected[0].effect,
            },
        ) },
    };
}

fn root(a: std.mem.Allocator, reply: w.Reply) !j.Value {
    if (reply.disposition == .rejected) return error.MethodCommandRejected;
    const bytes = reply.observation_json.bytes;
    return (try j.parse(
        a,
        bytes,
        .{
            .bytes = bytes.len,
            .tokens = bytes.len,
            .members = bytes.len,
        },
    )).value;
}

fn field(value: j.Value, name: []const u8) !j.Value {
    return j.get(value, name) orelse error.InvalidMethodObservation;
}

fn typed(
    comptime T: type,
    a: std.mem.Allocator,
    value: j.Value,
    name: []const u8,
) !T {
    const selected = try field(value, name);
    if (T == u64) {
        if (selected != .number_string) return error.InvalidMethodCounter;
        return j.numberInteger(u64, selected.number_string);
    }
    return native.values.fromJson(T, a, selected);
}

fn schemaRef(comptime T: type, a: std.mem.Allocator) !w.Ref {
    const bytes = try native.values.schemaBytes(T, a);
    defer a.free(bytes);
    return .{
        .kind = .schema,
        .id = .{
            .bytes = try a.dupe(u8, &std.fmt.bytesToHex(hash(bytes), .lower)),
        },
    };
}

fn sameRef(left: w.Ref, right: w.Ref) bool {
    return left.kind == right.kind and std.mem.eql(u8, left.id.bytes, right.id.bytes);
}

fn requireSchema(
    comptime T: type,
    a: std.mem.Allocator,
    value: j.Value,
    name: []const u8,
) !w.Ref {
    const reference = try typed(w.Ref, a, value, name);
    if (!sameRef(reference, try schemaRef(T, a))) return error.InvalidMethodSchema;
    return reference;
}

fn built(
    a: std.mem.Allocator,
    reply: w.Reply,
    prepared: m.Prepared,
) !m.Built {
    const value = try root(a, reply);
    const program = reply.program orelse return error.InvalidMethodProgram;
    if (program.kind != .program or !sameRef(program, try typed(w.Ref, a, value, "program")))
        return error.InvalidMethodProgram;
    const input_schema = try requireSchema(m.GuestInput, a, value, "input_schema");
    _ = try requireSchema(m.GuestOutput, a, value, "result_schema");
    const ports = try field(value, "ports");
    if (ports != .array) return error.InvalidMethodPorts;
    if (ports.array.items.len != @as(
        usize,
        if (prepared.port_identity == null) 0 else 1,
    ))
        return error.InvalidMethodPorts;
    if (prepared.port_identity) |identity| {
        try portContract(a, ports.array.items[0], identity.bytes);
    }
    return .{
        .program = program,
        .input = .{ .inline_json = .{
            .schema = input_schema,
            .json_text = prepared.input_json,
        } },
    };
}

fn portContract(
    a: std.mem.Allocator,
    value: j.Value,
    identity: []const u8,
) !void {
    if (!std.mem.eql(
        u8,
        try j.text(try field(value, "identity")),
        identity,
    ) or
        !std.mem.eql(
            u8,
            try j.text(try field(value, "class")),
            "input",
        ))
        return error.InvalidMethodPort;
    _ = try requireSchema(m.CompletionRequest, a, value, "payload_schema");
    _ = try requireSchema(
        m.CompletionRequest,
        a,
        value,
        "observation_schema",
    );
    _ = try requireSchema(m.CompletionReply, a, value, "argument_schema");
    _ = try requireSchema(m.CompletionReply, a, value, "command_schema");
}

fn observe(
    a: std.mem.Allocator,
    reply: w.Reply,
    identity: ?c.Text(128),
) !m.Observation {
    const value = try root(a, reply);
    const work = try typed(w.Ref, a, value, "work");
    if (work.kind != .work) return error.InvalidMethodWork;
    const expected: w.Expected = .{
        .work = work,
        .execution_revision = try typed(u64, a, value, "execution_revision"),
        .control_revision = try typed(u64, a, value, "control_revision"),
    };
    const outcome = try j.text(try field(value, "outcome"));
    if (std.mem.eql(u8, outcome, "completed")) {
        const reference = try typed(w.Ref, a, value, "result");
        if (reference.kind != .value) return error.InvalidMethodResult;
        return .{
            .expected = expected,
            .state = .{ .done = reference },
        };
    }
    if (std.mem.eql(u8, outcome, "failed") or std.mem.eql(u8, outcome, "cancelled"))
        return .{
            .expected = expected,
            .state = .{ .fault = .{ .bytes = "MethodExecution" } },
        };
    if (!std.mem.eql(u8, try j.text(try field(value, "schedule")), "parked"))
        return .{ .expected = expected, .state = .{ .waiting = {} } };
    if (j.get(value, "port")) |port| {
        try portContract(
            a,
            port,
            (identity orelse return error.InvalidMethodPort).bytes,
        );
        if (!try typed(bool, a, value, "port_accepts_command"))
            return error.InvalidMethodPort;
        const reference = try typed(w.Ref, a, port, "reference");
        if (reference.kind != .port) return error.InvalidMethodPort;
        return .{
            .expected = expected,
            .state = .{ .port = .{
                .reference = reference,
                .generation = try typed(u64, a, port, "generation"),
                .argument_schema = try typed(w.Ref, a, port, "argument_schema"),
            } },
        };
    }
    if (!std.mem.eql(u8, outcome, "progressed") and !std.mem.eql(u8, outcome, "yielded"))
        return error.InvalidMethodOutcome;
    return .{
        .expected = expected,
        .state = .{ .running = {} },
    };
}

fn page(a: std.mem.Allocator, reply: w.Reply, offset: u64) !m.Page {
    const value = try root(a, reply);
    const start = try typed(u64, a, value, "offset");
    const next = try typed(u64, a, value, "next_offset");
    const total = try typed(u64, a, value, "total_bytes");
    const text = try typed(m.JsonText, a, value, "text");
    const eof = try typed(bool, a, value, "eof");
    if (start != offset or next < offset or next > total or total > 2 * 1024 * 1024 or
        next - offset != text.bytes.len or eof != (next == total) or
        (!eof and next == offset)) return error.InvalidMethodPage;
    return .{
        .text = text,
        .next = next,
        .total = total,
        .eof = eof,
    };
}

fn encodeJson(comptime T: type, a: std.mem.Allocator, value: T) ![]u8 {
    const schema = try native.values.schemaBytes(T, a);
    defer a.free(schema);
    const bytes = try c.encodeOwned(T, a, value);
    defer a.free(bytes);
    var decoded = try native.dynamic_values.decode(a, schema, bytes);
    defer decoded.deinit();
    return j.canonical(a, decoded.value);
}

fn decodeJson(
    comptime T: type,
    a: std.mem.Allocator,
    text: []const u8,
) !T {
    const schema = try native.values.schemaBytes(T, a);
    defer a.free(schema);
    var parsed = try j.parse(
        a,
        text,
        .{
            .bytes = text.len,
            .tokens = text.len,
            .members = text.len,
        },
    );
    defer parsed.deinit();
    const bytes = try native.dynamic_values.encode(a, schema, parsed.value);
    defer a.free(bytes);
    return (try c.decodeOwned(T, a, bytes)).value;
}
