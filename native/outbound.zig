const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const preparation = @import("delivery_prepare.zig");
const admission = @import("admission.zig");
const restore_eligibility = @import("restore_eligibility.zig");
const delivery_target = @import("delivery_target.zig");

const Wanted = struct { intent: t.DeliveryIntent, producer: t.Reference };

pub fn admitDeliveries(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    clock_ms: i64,
) ![]t.Id {
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    if (!admissible(index)) return &.{};
    const wanted = try collect(a, index, obligation);
    defer a.free(wanted);
    var tasks: std.ArrayList(t.Id) = .empty;
    errdefer tasks.deinit(a);
    for (wanted) |value| {
        if (!try permitted(a, index, obligation, value.intent, clock_ms)) continue;
        try tasks.append(a, try admitDelivery(service, a, index, obligation, value));
    }
    return tasks.toOwnedSlice(a);
}

pub fn admissible(index: *const idx.Index) bool {
    return !index.outputHeld() and index.recovery_purpose != .transfer;
}

pub fn permitted(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: ?*const idx.Obligation,
    intent: t.DeliveryIntent,
    clock_ms: i64,
) !bool {
    if (!admissible(index) or !restore_eligibility.allowsKey(index, intent.key)) return false;
    const selected = obligation orelse return false;
    if (!selected.ordinaryDispatch()) return false;
    const head = index.head(selected);
    return switch (intent.key.purpose) {
        .activation => if (head.activation) |activation|
            try equal(a, t.DeliveryIntent, activation, intent)
        else
            false,
        .digest => if (head.digest) |digest|
            digest.hold == .none and clock_ms >= digest.not_before_ms and
                try equal(a, t.DeliveryIntent, digest.delivery, intent)
        else
            false,
        .question => if (head.question) |question|
            question.specification_revision == head.specification.revision and
                question.prompt.payload.specification_revision ==
                    head.specification.revision and
                try equal(a, t.DeliveryIntent, question.prompt, intent)
        else
            false,
    };
}

pub fn resumable(
    a: std.mem.Allocator,
    index: *const idx.Index,
    delivery: t.Delivery,
    clock_ms: i64,
) !bool {
    if (delivery.envelope.origin != .derived) return false;
    const intent = preparation.projectIntent(delivery);
    const target = delivery_target.resolve(index, delivery) orelse return false;
    const owner = index.obligation(target) orelse return false;
    if (!try permitted(a, index, owner, intent, clock_ms)) return false;
    const producer = delivery.envelope.origin.derived.predecessor;
    authorizeDelivery(a, index, owner, intent, producer) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    return true;
}

fn collect(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
) ![]Wanted {
    var wanted: std.ArrayList(Wanted) = .empty;
    errdefer wanted.deinit(a);
    const head = index.head(obligation);
    const current = index.reference(obligation.chain[obligation.chain.len - 1]);
    if (head.activation) |activation|
        try append(a, &wanted, .{ .intent = activation, .producer = current });
    if (head.digest) |digest|
        try append(a, &wanted, .{ .intent = digest.delivery, .producer = current });
    if (head.question) |question|
        try append(a, &wanted, .{ .intent = question.prompt, .producer = current });
    return wanted.toOwnedSlice(a);
}

fn append(a: std.mem.Allocator, wanted: *std.ArrayList(Wanted), value: Wanted) !void {
    for (wanted.items) |existing| {
        if (!std.meta.eql(existing.intent.key, value.intent.key)) continue;
        if (!try equal(a, t.DeliveryIntent, existing.intent, value.intent))
            return error.OperationConflict;
        return;
    }
    try wanted.append(a, value);
}

fn equal(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const first = try c.encodeOwned(T, a, left);
    defer a.free(first);
    const second = try c.encodeOwned(T, a, right);
    defer a.free(second);
    return std.mem.eql(u8, first, second);
}

fn readInput(service: anytype, a: std.mem.Allocator, task: t.Id) !c.Decoded(t.Input) {
    var input = (try service.applicationValue(a, task, .input)) orelse
        return error.MissingAdmittedInput;
    defer input.deinit();
    if (!std.mem.eql(u8, input.schema_id, t.input_schema_id) or input.encoding != .contract)
        return error.UnsupportedApplicationSchema;
    return c.decodeOwned(t.Input, a, input.bytes);
}

fn admitDelivery(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    wanted: Wanted,
) !t.Id {
    try authorizeDelivery(a, index, obligation, wanted.intent, wanted.producer);
    const operation = try preparation.operation(a, wanted.intent.key);
    defer a.free(operation);
    if (try service.operationLookup(a, operation)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        var input = try readInput(service, a, receipt.value.task);
        defer input.deinit();
        if (input.value != .delivery) return error.OperationConflict;
        const original = input.value.delivery;
        try preparation.verifyStored(a, original);
        if (!try equal(a, t.DeliveryIntent, preparation.projectIntent(original), wanted.intent))
            return error.OperationConflict;
        try authorizeDelivery(
            a,
            index,
            obligation,
            wanted.intent,
            original.envelope.origin.derived.predecessor,
        );
        return (try service.submit(a, operation, input.value)).receipt.task;
    }
    var prepared = try preparation.materialize(
        a,
        wanted.intent,
        wanted.producer,
        try manifest(a, index, obligation, wanted),
    );
    defer prepared.deinit();
    return (try service.submit(a, operation, .{ .delivery = prepared.value })).receipt.task;
}

fn source(
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    reference: t.Reference,
) !idx.Record {
    const record = index.record(reference.task) orelse return error.MissingProducer;
    if (!record.selected or record.superseded or record.result == null or
        record.result_digest == null or !std.meta.eql(record.result_digest.?, reference.digest))
        return error.UnselectedProducer;
    for (obligation.chain) |position|
        if (std.meta.eql(index.records[position].task, reference.task)) return record.*;
    return error.UnrelatedProducer;
}

fn authorizeDelivery(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    intent: t.DeliveryIntent,
    producer: t.Reference,
) !void {
    if (intent.key.purpose != .activation and !owns(index, obligation, intent))
        return error.UnrelatedIntent;
    const record = try source(index, obligation, producer);
    const result = record.result.?;
    const head = if (result == .genesis) result.genesis else if (result == .step)
        result.step.head
    else
        return error.InvalidProducer;
    if (intent.key.purpose == .activation) {
        if (head.activation) |activation|
            if (try equal(a, t.DeliveryIntent, intent, activation)) return;
    } else if (intent.key.purpose == .digest) {
        if (head.digest) |digest|
            if (try equal(a, t.DeliveryIntent, intent, digest.delivery)) return;
    } else if (intent.key.purpose == .question) {
        if (head.question) |question|
            if (try equal(a, t.DeliveryIntent, intent, question.prompt)) return;
    }
    return error.UnauthorizedIntent;
}

fn owns(
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    intent: t.DeliveryIntent,
) bool {
    const claimed = intent.payload.obligation orelse return false;
    const resolved = delivery_target.owner(index, claimed, intent.key.lineage) orelse return false;
    return std.meta.eql(resolved, obligation.task);
}

fn manifest(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    wanted: Wanted,
) !t.Digest {
    var references: std.ArrayList(t.Reference) = .empty;
    defer references.deinit(a);
    var through = wanted.intent.payload.prior_sequence;
    if (wanted.intent.key.purpose == .digest) {
        for (obligation.chain) |position| {
            const result = index.records[position].result.?;
            if (result != .step) continue;
            const batch = result.step.batch orelse continue;
            if (batch.sequence <= through or
                batch.sequence > wanted.intent.payload.through_sequence) continue;
            if (batch.sequence != try std.math.add(u64, through, 1))
                return error.MissingDeliveryEvidence;
            try references.append(a, index.reference(position));
            through = batch.sequence;
        }
        if (through != wanted.intent.payload.through_sequence)
            return error.MissingDeliveryEvidence;
    }
    const value: struct { producer: t.Reference, batches: c.Vector(t.Reference, null) } = .{
        .producer = wanted.producer,
        .batches = .{ .items = references.items },
    };
    return admission.stableDigest(a, value);
}
