const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");

pub fn resolve(index: *const idx.Index, value: t.Delivery) ?t.Id {
    if (value.payload.logical.obligation) |target| return target;
    if (value.key.purpose != .activation or value.envelope.origin != .derived) return null;
    const reference = value.envelope.origin.derived.predecessor;
    const producer = index.record(reference.task) orelse return null;
    if (!producer.selected or producer.superseded or producer.result_digest == null or
        producer.result == null or !std.meta.eql(producer.result_digest.?, reference.digest))
        return null;
    const head = switch (producer.result.?) {
        .genesis => |head| head,
        .step => |step| step.head,
        else => return null,
    };
    const activation = head.activation orelse return null;
    if (!std.meta.eql(activation.key, value.key) or
        !std.meta.eql(head.lineage, value.key.lineage)) return null;
    for (index.obligations) |obligation| {
        for (obligation.chain) |position|
            if (std.meta.eql(index.records[position].task, producer.task)) return obligation.task;
    }
    return null;
}

pub fn auditTarget(index: *const idx.Index, value: t.Delivery) ?t.Id {
    for (index.imports) |imported| {
        const head = index.head(index.obligation(imported.obligation).?);
        if (!std.meta.eql(value.key.lineage, head.lineage)) continue;
        if (value.payload.logical.obligation) |original| {
            for (imported.bundle.lineages.items) |lineage|
                if (std.meta.eql(lineage.obligation, original)) return imported.obligation;
        } else if (value.key.purpose == .activation) return imported.obligation;
    }
    return resolve(index, value);
}
