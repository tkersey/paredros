const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const admission = @import("admission.zig");
const dialogue = @import("dialogue.zig");
const ingress_policy = @import("ingress_policy.zig");
const continuity = @import("continuity.zig");
const wire = @import("wire.zig");

pub const TurnRequest = struct {
    text: t.Text,
    target: ?t.Id = null,
    refusal: ?t.Name = null,
    genesis_template: ?t.Specification = null,

    pub const Caller = struct { text: t.Text, target: ?t.Id, refusal: ?t.Name };

    pub fn caller(self: TurnRequest) Caller {
        return .{ .text = self.text, .target = self.target, .refusal = self.refusal };
    }
};
pub const MonitorRequest = struct {
    wording: t.Text,
    interval_ms: ?u64,

    pub fn specification(self: MonitorRequest, template: t.Specification) t.Specification {
        var value = template;
        value.wording = self.wording;
        value.interval_ms = self.interval_ms orelse template.interval_ms;
        return value;
    }
};
pub const Confirmation = struct { turn: t.Reference, ordinal: u32 };
pub const ProposalIdentity = struct {
    request: t.Digest,
    attempt: u32,
    ordinal: u32,

    pub fn formatText(self: ProposalIdentity, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{
            &wire.hex(self.request),
            self.attempt,
            self.ordinal,
        });
    }

    pub fn parseText(bytes: []const u8) error{InvalidIdentity}!ProposalIdentity {
        var parts = std.mem.splitScalar(u8, bytes, ':');
        const request = parts.next() orelse return error.InvalidIdentity;
        const attempt = parts.next() orelse return error.InvalidIdentity;
        const ordinal = parts.next() orelse return error.InvalidIdentity;
        if (parts.next() != null) return error.InvalidIdentity;
        return .{
            .request = try wire.parse(t.Digest, request),
            .attempt = wire.number(u32, attempt) catch return error.InvalidIdentity,
            .ordinal = wire.number(u32, ordinal) catch return error.InvalidIdentity,
        };
    }
};
pub const CallerDirective = union(enum) {
    pause: void,
    @"resume": void,
    cancel: void,
    check: void,
    amend: t.Amendment,
    answer: @FieldType(t.DirectiveBody, "answer"),
    adopt: @FieldType(t.DirectiveBody, "adopt"),
    revert: @FieldType(t.DirectiveBody, "revert"),

    pub const Wire = t.DirectiveBody;

    pub fn narrow(body: t.DirectiveBody) error{SystemDirective}!CallerDirective {
        return switch (body) {
            .transfer => error.SystemDirective,
            inline else => |value, tag| @unionInit(CallerDirective, @tagName(tag), value),
        };
    }

    pub fn widen(self: CallerDirective) t.DirectiveBody {
        return switch (self) {
            inline else => |value, tag| @unionInit(t.DirectiveBody, @tagName(tag), value),
        };
    }
};
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

pub fn authenticate(driver: anytype, origin: t.Origin) !void {
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
    );
}

pub fn monitor(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    request: MonitorRequest,
    template: t.Specification,
) !t.Id {
    try authenticate(driver, origin);
    return admitGenesis(
        driver,
        a,
        operation,
        origin,
        request.specification(template),
        try admission.stableDigest(a, request),
        true,
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
    };
    const Materializer = struct {
        driver: @TypeOf(driver),
        index: *const idx.Index,
        specification: t.Specification,
        anchor_now: bool,

        pub fn materialize(
            self: @This(),
            allocator: std.mem.Allocator,
            requested: admission.Request,
        ) !t.Input {
            try ingress_policy.validate(self.index);
            const envelope = genesisEnvelope(requested);
            const clock_ms = try self.driver.clock.now(self.driver.clock.context);
            var frozen = self.specification;
            if (self.anchor_now) frozen.anchor_ms = clock_ms;
            try admission.specification(frozen);
            return .{ .genesis = .{
                .envelope = envelope,
                .lineage = try admission.stableDigest(allocator, envelope),
                .specification = frozen,
                .clock_ms = clock_ms,
                .imported = null,
            } };
        }
    };
    var index = try driver.rebuild(scratch);
    defer index.deinit();
    if (try importedGenesis(scratch, &index, request)) |task| return task;
    const result = try admission.admit(driver.service, scratch, request, Materializer{
        .driver = driver,
        .index = &index,
        .specification = specification,
        .anchor_now = anchor_now,
    });
    return result.receipt.task;
}

fn genesisEnvelope(request: admission.Request) t.Envelope {
    return .{
        .operation = .{ .bytes = request.operation },
        .stable_request = request.digest,
        .origin = request.origin,
    };
}

fn importedGenesis(
    a: std.mem.Allocator,
    index: *const idx.Index,
    request: admission.Request,
) !?t.Id {
    const lineage = try admission.stableDigest(a, genesisEnvelope(request));
    const position = index.lineages.get(lineage) orelse {
        if (continuity.importedGenesis(index, request.operation))
            return error.OperationConflict;
        return null;
    };
    const existing = index.records[position].input.genesis;
    if (std.mem.eql(u8, existing.envelope.operation.bytes, request.operation)) return null;
    if (existing.imported == null) return error.DuplicateLineage;
    if (index.operations.get(request.operation)) |other| {
        const value = index.records[other].input;
        if (value != .genesis or !std.meta.eql(value.genesis.lineage, lineage))
            return error.OperationConflict;
    }
    return index.records[position].task;
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
        .digest = try admission.stableDigest(
            scratch,
            @as(struct { operation: c.Utf8, request: TurnRequest.Caller }, .{
                .operation = .{ .bytes = operation },
                .request = requested_turn.caller(),
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
            if (frozen.genesis_template) |*template| {
                template.anchor_ms = try self.driver.clock.now(self.driver.clock.context);
            }
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
        .target = input.target,
        .context_bytes = @min(limit, 256 * 1024 - input.text.bytes.len - 256),
    });
    defer context.deinit();
    const value: t.Input = .{ .turn = .{
        .envelope = .{
            .operation = .{ .bytes = request.operation },
            .origin = request.origin,
            .stable_request = request.digest,
        },
        .ordinal = context.value.next_ordinal,
        .refusal = input.refusal,
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

fn proposalDigest(
    a: std.mem.Allocator,
    confirmation: Confirmation,
    selected: t.Proposal,
) !t.Digest {
    const identity: struct { confirmation: Confirmation, target: ?t.Id, body: @FieldType(
        t.Proposal,
        "body",
    ) } = .{
        .confirmation = confirmation,
        .target = selected.target,
        .body = selected.body,
    };
    return admission.stableDigest(a, identity);
}

pub fn confirmed(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    operation: []const u8,
    origin: t.Origin,
    confirmation: Confirmation,
) !?t.Id {
    try authenticate(driver, origin);
    if (index.operations.get(operation)) |position|
        if (index.records[position].input != .confirmation) return null;
    const selected = try proposal(index, confirmation);
    const digest = try proposalDigest(a, confirmation, selected);
    const prior = switch (selected.body) {
        .genesis => confirmedGenesis(index, digest),
        .directive => |body| try confirmedDirective(
            a,
            index,
            selected.target orelse return error.InvalidProposalTarget,
            body,
            digest,
        ),
    } orelse return null;
    const request: admission.Request = .{
        .operation = operation,
        .kind = .confirmation,
        .target = null,
        .origin = origin,
        .digest = digest,
    };
    _ = try admission.admit(driver.service, a, request, Receipt{ .task = prior });
    return prior;
}

const Receipt = struct {
    task: t.Id,

    pub fn materialize(self: Receipt, _: std.mem.Allocator, request: admission.Request) !t.Input {
        return .{ .confirmation = .{
            .envelope = .{
                .operation = .{ .bytes = request.operation },
                .stable_request = request.digest,
                .origin = request.origin,
            },
            .task = self.task,
        } };
    }
};

fn confirmedGenesis(index: *const idx.Index, digest: t.Digest) ?t.Id {
    for (index.records) |record| switch (record.input) {
        .genesis => |value| if (std.meta.eql(value.envelope.stable_request, digest))
            return index.records[index.lineages.get(value.lineage).?].task,
        else => {},
    };
    return null;
}

fn confirmedDirective(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    body: t.DirectiveBody,
    digest: t.Digest,
) !?t.Id {
    const obligation = index.obligation(target) orelse return null;
    for (obligation.directives) |position| {
        const value = index.records[position].input.directive;
        if (std.meta.activeTag(value.body) != std.meta.activeTag(body)) continue;
        if (std.meta.eql(
            value.envelope.stable_request,
            try admission.directiveDigest(a, value.envelope.operation.bytes, digest),
        )) return index.records[position].task;
    }
    return null;
}

pub fn admitConfirmation(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    operation: []const u8,
    origin: t.Origin,
    confirmation: Confirmation,
) !t.Id {
    try authenticate(driver, origin);
    const selected = try proposal(index, confirmation);
    const digest = try proposalDigest(a, confirmation, selected);
    return switch (selected.body) {
        .genesis => |specification| try admitGenesis(
            driver,
            a,
            operation,
            origin,
            specification,
            digest,
            false,
        ),
        .directive => |body| try driver.directiveRequest(
            a,
            operation,
            origin,
            selected.target orelse return error.InvalidProposalTarget,
            body,
            digest,
        ),
    };
}
