const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");

pub fn allowsKey(index: *const idx.Index, key: t.DeliveryKey) bool {
    for (index.restore_cut) |reference| {
        const record = index.record(reference.task) orelse return false;
        if (!std.meta.eql(record.input_digest, reference.digest)) return false;
        if (inputContains(record.input, key)) return false;
        if (record.result) |result| if (outputContains(result, key)) return false;
    }
    return true;
}

fn sameKey(left: t.DeliveryKey, right: t.DeliveryKey) bool {
    return left.purpose == right.purpose and std.meta.eql(left.lineage, right.lineage) and
        std.meta.eql(left.identity, right.identity);
}

fn matches(intent: ?t.DeliveryIntent, key: t.DeliveryKey) bool {
    return if (intent) |value| sameKey(value.key, key) else false;
}

fn headContains(head: t.Head, key: t.DeliveryKey) bool {
    if (matches(head.activation, key)) return true;
    if (head.digest) |digest| if (sameKey(digest.delivery.key, key)) return true;
    if (head.question) |question| if (sameKey(question.prompt.key, key)) return true;
    return false;
}

fn inputContains(input: t.Input, key: t.DeliveryKey) bool {
    return switch (input) {
        .delivery => |value| sameKey(value.key, key),
        .step => |value| headContains(value.previous, key),
        .genesis => |value| key.purpose == .activation and
            std.meta.eql(key.lineage, value.lineage) and
            std.meta.eql(key.identity, value.envelope.stable_request),
        else => false,
    };
}

fn outputContains(output: t.Output, key: t.DeliveryKey) bool {
    return switch (output) {
        .genesis => |head| headContains(head, key),
        .step => |value| headContains(value.head, key),
        else => false,
    };
}
