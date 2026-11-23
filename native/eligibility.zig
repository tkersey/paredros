const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");
const preparation = @import("delivery_prepare.zig");
const delivery_target = @import("delivery_target.zig");
const slack = @import("../app/slack_contract.zig");

pub fn permits(
    a: std.mem.Allocator,
    index: *const idx.Index,
    request: native.tasks.DispatchRequest,
    clock_ms: i64,
) !bool {
    const record = index.record(request.task) orelse return false;
    if (record.superseded or request.kind == .placement_move or
        request.kind == .placement_control) return false;
    if (index.recovery_purpose == .transfer and record.input != .audit and
        record.input != .lineage_audit) return false;
    return switch (record.input) {
        .step => |value| blk: {
            const obligation = index.obligation(value.obligation) orelse break :blk false;
            const position = obligation.eligible orelse break :blk false;
            break :blk !index.outputHeld() and
                std.meta.eql(index.records[position].task, record.task) and
                obligation.ordinaryDispatch() and !value.fold_only;
        },
        .delivery => |value| std.mem.eql(u8, request.capability, slack.notification_identity) and
            @import("restore_eligibility.zig").allows(index, value) and
            try deliveryPermitted(a, index, value, clock_ms),
        .audit => |value| std.mem.eql(
            u8,
            request.capability,
            @import("../app/audit_contract.zig").identity,
        ) and
            try auditPermitted(a, index, value, clock_ms),
        .lineage_audit => |value| std.mem.eql(
            u8,
            request.capability,
            @import("../app/lineage_audit_contract.zig").identity,
        ) and
            try @import("lineage_audit.zig").permits(a, index, value),
        .turn => record.input.turn.envelope.origin != .derived and !index.outputHeld(),
        .experiment => |value| experimentPermitted(value, request.capability),
        .genesis, .directive, .continuity_member, .continuity_cut, .restore => false,
    };
}

fn equal(a: std.mem.Allocator, comptime T: type, x: T, y: T) !bool {
    const left = try c.encodeOwned(T, a, x);
    defer a.free(left);
    const right = try c.encodeOwned(T, a, y);
    defer a.free(right);
    return std.mem.eql(u8, left, right);
}

fn producer(index: *const idx.Index, envelope: t.Envelope) ?*const idx.Record {
    if (envelope.origin != .derived) return null;
    const reference = envelope.origin.derived.predecessor;
    const record = index.record(reference.task) orelse return null;
    if (record.result_digest == null or record.result == null or
        !std.meta.eql(record.result_digest.?, reference.digest) or record.superseded) return null;
    return record;
}

fn deliveryPermitted(
    a: std.mem.Allocator,
    index: *const idx.Index,
    value: t.Delivery,
    clock_ms: i64,
) !bool {
    const source = producer(index, value.envelope) orelse return false;
    const intent = preparation.projectIntent(value);
    if (value.key.purpose == .turn) return turnDeliveryPermitted(a, source, intent);
    const target = delivery_target.resolve(index, value) orelse return false;
    const obligation = index.obligation(target) orelse return false;
    const head = index.head(obligation);
    if (!source.selected) return false;
    if (value.key.purpose == .activation)
        return obligation.ordinaryDispatch() and try activationPermitted(a, source, head, intent);
    if (value.key.purpose == .control) {
        if (source.result.? != .step) return false;
        for (source.result.?.step.notices.items) |notice|
            if (try equal(a, t.DeliveryIntent, notice, intent)) return true;
        return false;
    }
    if (!obligation.ordinaryDispatch()) return false;
    if (value.key.purpose == .digest) {
        const wanted = head.digest orelse return false;
        return wanted.hold == .none and clock_ms >= wanted.not_before_ms and
            try equal(a, t.DeliveryIntent, wanted.delivery, intent);
    }
    if (value.key.purpose == .question) {
        const question = head.question orelse return false;
        return question.specification_revision == head.specification.revision and
            value.payload.logical.specification_revision == head.specification.revision and
            try equal(a, t.DeliveryIntent, question.prompt, intent);
    }
    return false;
}

fn auditPermitted(
    a: std.mem.Allocator,
    index: *const idx.Index,
    value: t.Audit,
    clock_ms: i64,
) !bool {
    return @import("audit_control.zig").permits(a, index, value, clock_ms);
}

pub fn turnDeliveryPermitted(
    a: std.mem.Allocator,
    source: *const idx.Record,
    intent: t.DeliveryIntent,
) !bool {
    if (source.superseded or source.input != .turn or source.result == null or
        source.result.? != .turn or source.result_digest == null) return false;
    const turn = source.input.turn;
    if (turn.envelope.origin != .slack) return false;
    const origin = turn.envelope.origin.slack;
    const destination = turn.destination;
    if (!std.mem.eql(u8, origin.app.bytes, destination.app.bytes) or
        !std.mem.eql(u8, origin.workspace.bytes, destination.workspace.bytes) or
        !std.mem.eql(u8, origin.user.bytes, destination.operator.bytes) or
        !std.mem.eql(u8, origin.channel.bytes, destination.channel.bytes)) return false;
    const expected = source.result.?.turn.delivery orelse return false;
    if (intent.key.purpose != .turn or
        !std.meta.eql(intent.key.lineage, turn.envelope.stable_request) or
        !std.meta.eql(intent.key.identity, turn.envelope.stable_request) or
        intent.key.generation != turn.attempt or
        !std.meta.eql(intent.payload.obligation, turn.target) or
        intent.payload.specification_revision != (turn.expected_revision orelse 0)) return false;
    return try equal(a, t.Destination, destination, intent.destination) and
        try equal(a, t.DeliveryIntent, expected, intent);
}

fn activationPermitted(
    a: std.mem.Allocator,
    source: *const idx.Record,
    head: t.Head,
    intent: t.DeliveryIntent,
) !bool {
    const produced = switch (source.result.?) {
        .genesis => |value| value.activation,
        .step => |result| result.head.activation,
        else => null,
    } orelse return false;
    const wanted = head.activation orelse return false;
    return try equal(a, t.DeliveryIntent, produced, intent) and
        try equal(a, t.DeliveryIntent, wanted, intent);
}

fn experimentPermitted(value: t.Experiment, capability: []const u8) bool {
    if (value.envelope.origin == .derived) return false;
    const experiment = @import("../app/experiment_contract.zig");
    const method = @import("../app/method_contract.zig");
    if (std.mem.eql(u8, capability, experiment.codec_identity) or
        std.mem.eql(u8, capability, experiment.clock_identity) or
        std.mem.eql(u8, capability, method.workspace_identity) or
        std.mem.eql(u8, capability, method.codec_identity)) return true;
    const model_identity = @import("../app/model_contract.zig").P.identity;
    return value.live_model and std.mem.eql(u8, capability, model_identity);
}
