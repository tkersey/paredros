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
    if (index.transferred()) return false;
    return switch (record.input) {
        .step => |value| blk: {
            const obligation = index.obligation(value.obligation) orelse break :blk false;
            const position = obligation.eligible orelse break :blk false;
            break :blk std.meta.eql(index.records[position].task, record.task) and
                obligation.ordinaryDispatch() and !value.fold_only;
        },
        .turn => record.input.turn.envelope.origin != .derived,
        .experiment => |value| experimentPermitted(value, request.capability),
        .genesis,
        .directive,
        .continuity_member,
        .continuity_cut,
        .transfer,
        => false,
    };
}

fn experimentPermitted(
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
    return value.live_model and std.mem.eql(u8, capability, model_identity);
}
