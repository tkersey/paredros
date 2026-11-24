const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");

pub fn resolve(index: *const idx.Index, value: t.Delivery) ?t.Id {
    if (value.payload.logical.obligation) |target| return owner(index, target, value.key.lineage);
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

pub fn owner(index: *const idx.Index, claimed: t.Id, lineage: t.Digest) ?t.Id {
    if (index.obligation(claimed) != null) return claimed;
    const position = index.lineages.get(lineage) orelse return null;
    const genesis = index.records[position];
    const imported = genesis.input.genesis.imported orelse return null;
    if (!vouches(imported.head, claimed) or index.obligation(genesis.task) == null) return null;
    return genesis.task;
}

fn vouches(head: t.Head, claimed: t.Id) bool {
    if (names(head.activation, claimed)) return true;
    if (head.digest) |digest| if (names(digest.delivery, claimed)) return true;
    if (head.question) |question| if (names(question.prompt, claimed)) return true;
    return false;
}

fn names(intent: ?t.DeliveryIntent, claimed: t.Id) bool {
    const value = intent orelse return false;
    const obligation = value.payload.obligation orelse return false;
    return std.meta.eql(obligation, claimed);
}
