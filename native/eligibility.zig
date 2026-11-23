const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");

pub fn permits(
    index: *const idx.Index,
    request: native.tasks.DispatchRequest,
) bool {
    const record = index.record(request.task) orelse return false;
    if (record.superseded or request.kind == .placement_move or
        request.kind == .placement_control) return false;
    if (index.recovery_purpose == .transfer) return false;
    return switch (record.input) {
        .step => |value| blk: {
            const obligation = index.obligation(value.obligation) orelse break :blk false;
            const position = obligation.eligible orelse break :blk false;
            break :blk !index.outputHeld() and
                std.meta.eql(index.records[position].task, record.task) and
                obligation.ordinaryDispatch() and !value.fold_only;
        },
        .turn => record.input.turn.envelope.origin != .derived and !index.outputHeld(),
        .experiment => |value| experimentPermitted(index, value, request.capability),
        .delivery,
        .audit,
        .lineage_audit,
        .genesis,
        .directive,
        .continuity_member,
        .continuity_cut,
        .restore,
        => false,
    };
}

fn equal(a: std.mem.Allocator, comptime T: type, x: T, y: T) !bool {
    const left = try c.encodeOwned(T, a, x);
    defer a.free(left);
    const right = try c.encodeOwned(T, a, y);
    defer a.free(right);
    return std.mem.eql(u8, left, right);
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

fn experimentPermitted(
    index: *const idx.Index,
    value: t.Experiment,
    capability: []const u8,
) bool {
    if (value.envelope.origin == .derived) return false;
    const experiment = @import("../app/experiment_contract.zig");
    const method = @import("../app/method_contract.zig");
    if (std.mem.eql(u8, capability, experiment.codec_identity) or
        std.mem.eql(u8, capability, experiment.clock_identity) or
        std.mem.eql(u8, capability, method.workspace_identity) or
        std.mem.eql(u8, capability, method.codec_identity)) return true;
    const model_identity = @import("../app/model_contract.zig").P.identity;
    return value.live_model and !index.outputHeld() and
        std.mem.eql(u8, capability, model_identity);
}
