const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const admission = @import("admission.zig");
const dialogue = @import("dialogue.zig");

pub const TurnRequest = struct {
    destination: t.Destination,
    text: t.Text,
    target: ?t.Id = null,
    genesis_template: ?t.Specification = null,
    anchor_template: bool = false,
    ingress: ?t.Ingress = null,
    refusal: ?t.Name = null,
};
pub const Confirmation = struct { turn: t.Reference, ordinal: u32 };
pub const ProposalIdentity = struct { request: t.Digest, attempt: u32, ordinal: u32 };
pub const ProposalSelector = union(enum) { identity: ProposalIdentity, retained: Confirmation };

pub fn resolveProposal(index: *const idx.Index, selector: ProposalSelector) !Confirmation {
    if (selector == .retained) {
        _ = try proposal(index, selector.retained);
        return selector.retained;
    }
    const identity = selector.identity;
    var found: ?Confirmation = null;
    for (index.records) |record| {
        if (record.input != .turn or record.superseded or record.result_digest == null or
            record.result == null or record.result.? != .turn) continue;
        const input = record.input.turn;
        if (input.attempt != identity.attempt or
            !std.meta.eql(input.envelope.stable_request, identity.request)) continue;
        const candidate: Confirmation = .{
            .turn = .{ .task = record.task, .digest = record.result_digest.? },
            .ordinal = identity.ordinal,
        };
        _ = try proposal(index, candidate);
        if (found != null) return error.AmbiguousProposal;
        found = candidate;
    }
    return found orelse error.UnknownProposal;
}

fn authenticate(driver: anytype, origin: t.Origin) !void {
    if (!driver.attached or origin == .derived) return error.UnauthenticatedRequest;
}

pub fn genesis(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    specification: t.Specification,
) !t.Id {
    try authenticate(driver, origin);
    return admitGenesis(
        driver,
        a,
        operation,
        origin,
        specification,
        try admission.stableDigest(a, specification),
        false,
        null,
    );
}

pub fn monitor(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    specification: t.Specification,
) !t.Id {
    try authenticate(driver, origin);
    return admitGenesis(
        driver,
        a,
        operation,
        origin,
        specification,
        try admission.stableDigest(a, specification),
        true,
        null,
    );
}

fn admitGenesis(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    specification: t.Specification,
    digest: t.Digest,
    anchor_now: bool,
    ingress: ?t.Ingress,
) !t.Id {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const request: admission.Request = .{
        .operation = operation,
        .kind = .genesis,
        .target = null,
        .origin = origin,
        .digest = digest,
        .ingress = ingress,
    };
    const Materializer = struct {
        driver: @TypeOf(driver),
        specification: t.Specification,
        anchor_now: bool,

        pub fn materialize(
            self: @This(),
            allocator: std.mem.Allocator,
            requested: admission.Request,
        ) !t.Input {
            const envelope: t.Envelope = .{
                .operation = .{ .bytes = requested.operation },
                .stable_request = requested.digest,
                .origin = requested.origin,
                .ingress = requested.ingress,
            };
            const clock_ms = try self.driver.clock.now(self.driver.clock.context);
            var frozen = self.specification;
            if (self.anchor_now) frozen.anchor_ms = clock_ms;
            return .{ .genesis = .{
                .envelope = envelope,
                .lineage = try admission.stableDigest(allocator, envelope),
                .specification = frozen,
                .clock_ms = clock_ms,
                .imported = null,
            } };
        }
    };
    const result = try admission.admit(driver.service, scratch, request, Materializer{
        .driver = driver,
        .specification = specification,
        .anchor_now = anchor_now,
    });
    return result.receipt.task;
}

pub fn turn(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    requested_turn: TurnRequest,
) !t.Id {
    try authenticate(driver, origin);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const request: admission.Request = .{
        .operation = operation,
        .kind = .turn,
        .target = requested_turn.target,
        .origin = origin,
        .ingress = requested_turn.ingress,
        .digest = try admission.stableDigest(
            scratch,
            @as(struct { operation: c.Utf8, request: TurnRequest }, .{
                .operation = .{ .bytes = operation },
                .request = requested_turn,
            }),
        ),
    };
    const Materializer = struct {
        driver: @TypeOf(driver),
        request: TurnRequest,

        pub fn materialize(
            self: @This(),
            allocator: std.mem.Allocator,
            requested: admission.Request,
        ) !t.Input {
            var index = try self.driver.rebuild(allocator);
            defer index.deinit();
            var frozen = self.request;
            if (frozen.anchor_template) if (frozen.genesis_template) |*template| {
                template.anchor_ms = try self.driver.clock.now(self.driver.clock.context);
            };
            return turnInput(allocator, &index, self.driver.model, requested, frozen);
        }
    };
    const result = try admission.admit(driver.service, scratch, request, Materializer{
        .driver = driver,
        .request = requested_turn,
    });
    return result.receipt.task;
}

fn turnInput(
    a: std.mem.Allocator,
    index: *const idx.Index,
    model: ?t.ModelBinding,
    request: admission.Request,
    input: TurnRequest,
) !t.Input {
    if (input.text.bytes.len > 16 * 1024 or !std.unicode.utf8ValidateSlice(input.text.bytes))
        return error.InvalidText;
    const limit = if (input.target) |target| blk: {
        const obligation = index.obligation(target) orelse return error.UnknownObligation;
        break :blk index.head(obligation).specification.policies.context_bytes;
    } else 64 * 1024;
    var context = try dialogue.materialize(a, index, .{
        .destination = input.destination,
        .target = input.target,
        .context_bytes = @min(limit, 256 * 1024 - input.text.bytes.len - 256),
    });
    defer context.deinit();
    const value: t.Input = .{ .turn = .{
        .envelope = .{
            .operation = .{ .bytes = request.operation },
            .origin = request.origin,
            .stable_request = request.digest,
            .ingress = request.ingress,
        },
        .ordinal = context.value.next_ordinal,
        .refusal = input.refusal,
        .ingress_stable = if (input.ingress) |ingress| ingress.stable_request else null,
        .destination = input.destination,
        .text = input.text,
        .context = context.value.text,
        .context_references = context.value.references,
        .attempt = 0,
        .model = model,
        .target = input.target,
        .expected_revision = context.value.expected_revision,
        .proposal_offers = context.value.offers,
        .genesis_template = input.genesis_template,
    } };
    return (try c.decodeOwned(t.Input, a, try c.encodeOwned(t.Input, a, value))).value;
}

pub fn proposal(index: *const idx.Index, confirmation: Confirmation) !t.Proposal {
    const record = index.record(confirmation.turn.task) orelse return error.UnknownProposal;
    if (record.input != .turn or record.superseded or
        record.result == null or record.result.? != .turn or record.result_digest == null or
        !std.meta.eql(record.result_digest.?, confirmation.turn.digest))
        return error.UnknownProposal;
    const proposals = record.result.?.turn.proposals.items;
    if (confirmation.ordinal >= proposals.len) return error.UnknownProposal;
    const value = proposals[confirmation.ordinal];
    if (value.identity.ordinal != confirmation.ordinal or
        !std.mem.eql(
            u8,
            value.identity.operation.bytes,
            record.input.turn.envelope.operation.bytes,
        ) or
        value.identity.attempt != record.input.turn.attempt or
        !std.meta.eql(value.target, record.input.turn.target)) return error.InvalidProposalIdentity;
    return value;
}

pub fn confirm(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    confirmation: Confirmation,
) !t.Id {
    return confirmIngress(driver, a, operation, origin, confirmation, null);
}

pub fn confirmIngress(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    confirmation: Confirmation,
    ingress: ?t.Ingress,
) !t.Id {
    try authenticate(driver, origin);
    var index = try driver.rebuild(a);
    defer index.deinit();
    const selected = try proposal(&index, confirmation);
    const identity: struct { confirmation: Confirmation, target: ?t.Id, body: @FieldType(
        t.Proposal,
        "body",
    ) } = .{
        .confirmation = confirmation,
        .target = selected.target,
        .body = selected.body,
    };
    const digest = try admission.stableDigest(a, identity);
    return switch (selected.body) {
        .genesis => |specification| try admitGenesis(
            driver,
            a,
            operation,
            origin,
            specification,
            digest,
            false,
            ingress,
        ),
        .directive => |body| try driver.directiveIngress(
            a,
            operation,
            origin,
            selected.target orelse return error.InvalidProposalTarget,
            body,
            digest,
            ingress,
        ),
    };
}
