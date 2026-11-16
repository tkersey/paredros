const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const admission = @import("admission.zig");
const preparation = @import("delivery_prepare.zig");
const continuity = @import("continuity.zig");
const slack = @import("slack.zig");

const Delivery = struct {
    value: t.Delivery,
    target: ?t.Id,
    input: ?t.InputReference,
    receipt: ?t.Receipt,
};
const quiescence_ms: i64 = 120_000;

pub fn request(
    driver: anytype,
    a: std.mem.Allocator,
    operation_name: []const u8,
    origin: t.Origin,
    key: t.DeliveryKey,
) !t.Id {
    if (!driver.attached or origin == .derived) return error.UnauthenticatedRequest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var index = try driver.rebuild(scratch);
    defer index.deinit();
    const deliveries = try retainedDeliveries(scratch, &index);
    const selected = try select(deliveries, key);
    try authenticateOrigin(origin, selected.value.destination);
    return admit(driver.service, scratch, &index, deliveries, operation_name, origin, 0, selected);
}

fn authenticateOrigin(origin: t.Origin, destination: t.Destination) !void {
    if (origin == .local) return;
    if (origin != .slack) return error.UnauthenticatedRequest;
    const actor = origin.slack;
    if (!same(actor.app.bytes, destination.app.bytes) or
        !same(actor.workspace.bytes, destination.workspace.bytes) or
        !same(actor.channel.bytes, destination.channel.bytes) or
        !same(actor.user.bytes, destination.operator.bytes)) return error.UnauthenticatedRequest;
}

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn equal(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    return continuity.equal(a, T, left, right);
}

fn select(values: []const Delivery, key: t.DeliveryKey) !Delivery {
    var found: ?Delivery = null;
    for (values) |value| {
        if (!std.meta.eql(value.value.key, key)) continue;
        if (found != null) return error.AmbiguousDelivery;
        found = value;
    }
    return found orelse error.MissingAdmittedDelivery;
}

pub fn operation(
    a: std.mem.Allocator,
    producer: t.Reference,
    ordinal: u64,
    key: t.DeliveryKey,
) ![]u8 {
    const identity: struct { producer: t.Reference, ordinal: u64, key: t.DeliveryKey } = .{
        .producer = producer,
        .ordinal = ordinal,
        .key = key,
    };
    return std.fmt.allocPrint(a, "audit:{s}", .{
        std.fmt.bytesToHex(try admission.stableDigest(a, identity), .lower),
    });
}

pub fn stableDigest(a: std.mem.Allocator, audit: t.Audit) !t.Digest {
    return admission.stableDigest(a, @as(struct {
        delivery: t.Delivery,
        ordinal: u64,
        oldest: t.Timestamp,
        latest: ?t.Timestamp,
        page_limit: u32,
        canary: @FieldType(t.Audit, "canary"),
    }, .{
        .delivery = audit.delivery,
        .ordinal = audit.ordinal,
        .oldest = audit.oldest,
        .latest = audit.latest,
        .page_limit = audit.page_limit,
        .canary = audit.canary,
    }));
}

fn admit(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    deliveries: []const Delivery,
    name: []const u8,
    origin: t.Origin,
    ordinal: u64,
    selected: Delivery,
) !t.Id {
    if (try service.operationLookup(a, name)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        var input = (try service.applicationValue(a, receipt.value.task, .input)) orelse
            return error.MissingAdmittedInput;
        defer input.deinit();
        if (input.encoding != .contract or !same(input.schema_id, t.input_schema_id))
            return error.UnsupportedApplicationSchema;
        var decoded = try c.decodeOwned(t.Input, a, input.bytes);
        defer decoded.deinit();
        if (decoded.value != .audit) return error.OperationConflict;
        const old = decoded.value.audit;
        if (old.ordinal != ordinal or !same(old.envelope.operation.bytes, name) or
            !try equal(a, t.Origin, old.envelope.origin, origin) or
            !try equal(a, t.Delivery, old.delivery, selected.value) or
            !std.meta.eql(old.envelope.stable_request, try stableDigest(a, old)))
            return error.OperationConflict;
        try validateWindow(a, index, deliveries, old);
        return (try service.submit(a, name, decoded.value)).receipt.task;
    }
    const canary = try chooseCanary(a, deliveries, selected.value.destination);
    var value: t.Audit = .{
        .envelope = .{
            .operation = .{ .bytes = name },
            .stable_request = @splat(0),
            .origin = origin,
        },
        .delivery = selected.value,
        .ordinal = ordinal,
        .oldest = if (canary) |known| known.receipt.timestamp else .{ .bytes = "0.0" },
        .latest = null,
        .page_limit = if (selected.target) |target|
            index.head(index.obligation(target).?).specification.policies.history_page_limit
        else
            100,
        .canary = canary,
    };
    value.envelope.stable_request = try stableDigest(a, value);
    try validateWindow(a, index, deliveries, value);
    return (try service.submit(a, name, .{ .audit = value })).receipt.task;
}

fn chooseCanary(
    a: std.mem.Allocator,
    deliveries: []const Delivery,
    destination: t.Destination,
) !@FieldType(t.Audit, "canary") {
    var selected: @FieldType(t.Audit, "canary") = null;
    for (deliveries) |delivery| {
        const receipt = delivery.receipt orelse continue;
        if (!try equal(a, t.Destination, destination, receipt.destination)) continue;
        if (selected) |old| {
            const prior = try slack.Timestamp.parse(old.receipt.timestamp.bytes);
            if (prior.order(try slack.Timestamp.parse(receipt.timestamp.bytes)) != .gt) continue;
        }
        selected = .{ .receipt = receipt, .admitted = delivery.value };
    }
    return selected;
}

fn validateWindow(
    a: std.mem.Allocator,
    index: *const idx.Index,
    deliveries: []const Delivery,
    audit: t.Audit,
) !void {
    const oldest = try slack.Timestamp.parse(audit.oldest.bytes);
    if (audit.latest) |latest| {
        if (oldest.order(try slack.Timestamp.parse(latest.bytes)) == .gt)
            return error.InvalidAuditWindow;
    }
    if (audit.page_limit == 0) return error.InvalidAuditWindow;
    if (audit.canary) |canary| {
        const saved = try select(deliveries, canary.admitted.key);
        if (!try equal(a, t.Delivery, saved.value, canary.admitted) or
            !try equal(a, t.Destination, audit.delivery.destination, canary.admitted.destination) or
            !try equal(a, t.Destination, canary.receipt.destination, canary.admitted.destination) or
            !std.meta.eql(canary.receipt.key, canary.admitted.key) or
            !std.meta.eql(canary.receipt.payload_digest, canary.admitted.payload.content_digest) or
            !same(audit.oldest.bytes, canary.receipt.timestamp.bytes)) return error.InvalidCanary;
        if (!try provenCanary(a, index, saved, canary.receipt)) return error.UnprovenCanary;
    }
}

fn provenCanary(
    a: std.mem.Allocator,
    index: *const idx.Index,
    delivery: Delivery,
    receipt: t.Receipt,
) !bool {
    if (delivery.receipt) |known| if (try equal(a, t.Receipt, known, receipt)) return true;
    for (index.obligations) |obligation| for (obligation.chain) |position| {
        const result = index.records[position].result.?;
        const head = if (result == .genesis) result.genesis else result.step.head;
        if (head.told_receipt) |known| if (try equal(a, t.Receipt, known, receipt)) return true;
    };
    for (index.records) |record| {
        if (record.input != .audit or record.result == null or record.result.? != .audit or
            record.result.?.audit != .found or
            !try equal(a, t.Delivery, record.input.audit.delivery, delivery.value)) continue;
        const known = makeReceipt(delivery.value, record.result.?.audit.found.timestamp, .{
            .task = record.task,
            .digest = record.result_digest.?,
        }, .history_match);
        if (try equal(a, t.Receipt, known, receipt)) return true;
    }
    return false;
}

fn retainedDeliveries(a: std.mem.Allocator, index: *const idx.Index) ![]Delivery {
    var result: std.ArrayList(Delivery) = .empty;
    for (index.records) |record| {
        if (record.input != .delivery) continue;
        const delivery = record.input.delivery;
        try verifyLocal(a, index, delivery);
        try result.append(a, .{
            .value = delivery,
            .target = @import("delivery_target.zig").resolve(index, delivery),
            .input = .{ .task = record.task, .digest = record.input_digest },
            .receipt = try localReceipt(a, index, record),
        });
    }
    for (index.imports) |imported| try importedDeliveries(
        a,
        imported,
        index.head(index.obligation(imported.obligation).?).lineage,
        &result,
    );
    return result.toOwnedSlice(a);
}

fn localReceipt(a: std.mem.Allocator, index: *const idx.Index, record: idx.Record) !?t.Receipt {
    if (record.owner_snapshot) |snapshot| if (record.owner_evidence) |raw| {
        var fact = try @import("delivery_fact.zig").settlement(a, snapshot, raw);
        defer fact.deinit();
        if (fact.value) |delivery| if (delivery.receipt) |receipt| {
            const bytes = try c.encodeOwned(t.Receipt, a, receipt);
            return (try c.decodeOwned(t.Receipt, a, bytes)).value;
        };
    };
    for (index.obligations) |obligation| for (obligation.chain) |position| {
        const candidate = index.records[position];
        const head = if (candidate.result.? == .genesis)
            candidate.result.?.genesis
        else
            candidate.result.?.step.head;
        if (head.told_receipt) |receipt|
            if (std.meta.eql(receipt.key, record.input.delivery.key)) return receipt;
    };
    for (index.records) |candidate| {
        if (candidate.input != .audit or candidate.result == null or
            candidate.result.? != .audit or candidate.result.?.audit != .found or
            !try equal(a, t.Delivery, candidate.input.audit.delivery, record.input.delivery))
            continue;
        return makeReceipt(record.input.delivery, candidate.result.?.audit.found.timestamp, .{
            .task = candidate.task,
            .digest = candidate.result_digest.?,
        }, .history_match);
    }
    return null;
}

fn makeReceipt(
    delivery: t.Delivery,
    timestamp: t.Timestamp,
    proof: t.Reference,
    basis: @FieldType(t.Receipt, "basis"),
) t.Receipt {
    return .{
        .key = delivery.key,
        .destination = delivery.destination,
        .timestamp = timestamp,
        .payload_digest = delivery.payload.content_digest,
        .evidence = proof,
        .basis = basis,
    };
}

fn verifyLocal(a: std.mem.Allocator, index: *const idx.Index, value: t.Delivery) !void {
    try preparation.verifyStored(a, value);
    const reference = value.envelope.origin.derived.predecessor;
    const source = index.record(reference.task) orelse return error.MissingProducer;
    if (source.result_digest == null or source.result == null or
        !std.meta.eql(source.result_digest.?, reference.digest)) return error.MissingProducer;
    if (!try produced(a, source.result.?, preparation.projectIntent(value)))
        return error.UnauthorizedIntent;
}

fn produced(a: std.mem.Allocator, output: t.Output, intent: t.DeliveryIntent) !bool {
    if (output == .turn) {
        const delivery = output.turn.delivery orelse return false;
        return equal(a, t.DeliveryIntent, delivery, intent);
    }
    const head = switch (output) {
        .genesis => |value| value,
        .step => |value| value.head,
        else => return false,
    };
    if (head.activation) |activation|
        if (try equal(a, t.DeliveryIntent, activation, intent)) return true;
    if (head.digest) |digest|
        if (try equal(a, t.DeliveryIntent, digest.delivery, intent)) return true;
    if (head.question) |question|
        if (try equal(a, t.DeliveryIntent, question.prompt, intent)) return true;
    if (output == .step) for (output.step.notices.items) |notice|
        if (try equal(a, t.DeliveryIntent, notice, intent)) return true;
    return false;
}

fn importedDeliveries(
    a: std.mem.Allocator,
    imported: continuity.Imported,
    lineage: t.Digest,
    result: *std.ArrayList(Delivery),
) !void {
    for (imported.bundle.members.items) |member| {
        if (member.data.kind != .delivery or !std.meta.eql(member.data.lineage, lineage)) continue;
        const decoded = try continuity.decode(.delivery, a, member.data);
        const delivery = decoded.value.input;
        try preparation.verifyStored(a, delivery);
        const source = try importedProducer(
            a,
            imported,
            member.data.source.namespace,
            delivery.envelope.origin.derived.predecessor,
        );
        if (!try produced(a, source, preparation.projectIntent(delivery)))
            return error.UnauthorizedIntent;
        const reference = try continuity.binding(imported.metadata.members.items, member.identity);
        const receipt = if (decoded.value.result) |outcome|
            if (outcome == .confirmed)
                makeReceipt(delivery, outcome.confirmed.timestamp, reference, .captured_response)
            else
                null
        else
            null;
        try result.append(a, .{
            .value = delivery,
            .target = imported.obligation,
            .input = null,
            .receipt = receipt,
        });
    }
}

fn importedProducer(
    a: std.mem.Allocator,
    imported: continuity.Imported,
    namespace: t.Digest,
    producer: t.Reference,
) !t.Output {
    for (imported.bundle.members.items) |member| {
        if (member.data.kind != .settlement or
            !std.meta.eql(member.data.source.namespace, namespace) or
            !std.meta.eql(member.data.source.task, producer.task)) continue;
        const source = try continuity.decode(.settlement, a, member.data);
        const result = source.value.snapshot.result orelse continue;
        if (!std.meta.eql(result.reference.digest, producer.digest)) continue;
        return (try continuity.sourceOutput(a, source.value.result)) orelse
            error.MissingProducerResult;
    }
    return error.MissingProducer;
}

pub fn deliveryTarget(index: *const idx.Index, value: t.Delivery) ?t.Id {
    for (index.imports) |imported| {
        const head = index.head(index.obligation(imported.obligation).?);
        if (!std.meta.eql(value.key.lineage, head.lineage)) continue;
        if (value.payload.logical.obligation) |original| {
            for (imported.bundle.lineages.items) |lineage|
                if (std.meta.eql(lineage.obligation, original)) return imported.obligation;
        } else if (value.key.purpose == .activation) return imported.obligation;
    }
    return @import("delivery_target.zig").resolve(index, value);
}

pub fn schedule(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    clock_ms: i64,
) ![]t.Id {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    const deliveries = try retainedDeliveries(scratch, index);
    var tasks: std.ArrayList(t.Id) = .empty;
    errdefer tasks.deinit(a);
    for (obligation.chain) |position| {
        const record = index.records[position];
        if (record.result == null or record.result.? != .step) continue;
        const producer = index.reference(position);
        for (record.result.?.step.audit_requests.items, 0..) |wanted, ordinal| {
            var matched = false;
            for (deliveries) |delivery| {
                if (!std.meta.eql(delivery.target, @as(?t.Id, target))) continue;
                if (wanted == .delivery and !std.meta.eql(wanted.delivery, delivery.value.key))
                    continue;
                matched = true;
                try tasks.append(a, try admitDerived(
                    service,
                    scratch,
                    index,
                    deliveries,
                    producer,
                    @intCast(ordinal + 1),
                    delivery,
                ));
            }
            if (wanted == .delivery and !matched) return error.MissingAdmittedDelivery;
        }
        for (deliveries) |delivery| {
            if (!std.meta.eql(delivery.target, @as(?t.Id, target)) or
                !try automatic(index, obligation, position, delivery.value, clock_ms)) continue;
            try tasks.append(a, try admitDerived(
                service,
                scratch,
                index,
                deliveries,
                producer,
                0,
                delivery,
            ));
        }
    }
    if (try recoverySource(index, obligation)) |producer| {
        for (deliveries) |delivery| {
            if (!std.meta.eql(delivery.target, @as(?t.Id, target)) or
                !recoveryDelivery(index, producer, delivery)) continue;
            try tasks.append(a, try admitDerived(
                service,
                scratch,
                index,
                deliveries,
                producer,
                0,
                delivery,
            ));
        }
    }
    return tasks.toOwnedSlice(a);
}

fn admitDerived(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    deliveries: []const Delivery,
    producer: t.Reference,
    ordinal: u64,
    delivery: Delivery,
) !t.Id {
    const name = try operation(a, producer, ordinal, delivery.value.key);
    defer a.free(name);
    return admit(service, a, index, deliveries, name, .{
        .derived = .{ .predecessor = producer },
    }, ordinal, delivery);
}

const Automatic = enum { unknown, activation };

fn automaticFact(step_input: t.Step, delivery: t.Delivery) ?Automatic {
    for (step_input.facts.items) |fact| {
        const evidence = fact.delivery orelse continue;
        if (!std.meta.eql(evidence.admitted.key, delivery.key)) continue;
        if (evidence.outcome == .indeterminate) return .unknown;
        if (delivery.key.purpose == .activation and evidence.outcome == .confirmed and
            evidence.receipt != null and evidence.receipt.?.basis == .captured_response)
            return .activation;
    }
    return null;
}

fn automatic(
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    position: usize,
    delivery: t.Delivery,
    clock_ms: i64,
) !bool {
    const record = index.records[position];
    if (record.input != .step or record.result == null or record.result.? != .step) return false;
    const cause = automaticFact(record.input.step, delivery) orelse return false;
    for (obligation.chain) |prior| {
        if (prior == position) break;
        if (index.records[prior].input != .step) continue;
        if (automaticFact(index.records[prior].input.step, delivery) == cause) return false;
    }
    if (cause == .activation) return true;
    const due = std.math.add(i64, record.input.step.clock_ms, quiescence_ms) catch return false;
    return clock_ms >= due;
}

fn recoverySource(index: *const idx.Index, obligation: *const idx.Obligation) !?t.Reference {
    if (index.recovery) |reference| {
        const marker = index.record(reference.task) orelse return error.MissingRestoreBoundary;
        if (marker.result_digest) |digest| return .{ .task = marker.task, .digest = digest };
        return null;
    }
    const genesis = index.records[obligation.chain[0]];
    if (genesis.input.genesis.imported != null)
        return index.reference(obligation.chain[0]);
    return null;
}

fn recoveryDelivery(index: *const idx.Index, producer: t.Reference, delivery: Delivery) bool {
    const record = index.record(producer.task) orelse return false;
    if (record.input == .genesis) return delivery.input == null;
    if (record.input != .restore or record.input.restore.action != .begin) return false;
    const reference = delivery.input orelse return true;
    for (record.input.restore.action.begin.cut.items) |item|
        if (std.meta.eql(item, reference)) return true;
    return false;
}

pub fn permits(
    a: std.mem.Allocator,
    index: *const idx.Index,
    audit: t.Audit,
    clock_ms: i64,
) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const deliveries = try retainedDeliveries(scratch, index);
    const saved = select(deliveries, audit.delivery.key) catch return false;
    if (!try equal(scratch, t.Delivery, saved.value, audit.delivery)) return false;
    if (!std.meta.eql(audit.envelope.stable_request, try stableDigest(scratch, audit)))
        return false;
    validateWindow(scratch, index, deliveries, audit) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    if (audit.envelope.origin != .derived) {
        authenticateOrigin(audit.envelope.origin, audit.delivery.destination) catch return false;
        return audit.ordinal == 0;
    }
    const reference = audit.envelope.origin.derived.predecessor;
    const source = index.record(reference.task) orelse return false;
    if (source.result == null or source.result_digest == null or
        !std.meta.eql(source.result_digest.?, reference.digest)) return false;
    const name = try operation(scratch, reference, audit.ordinal, audit.delivery.key);
    if (!same(name, audit.envelope.operation.bytes)) return false;
    const target = saved.target orelse return false;
    const obligation = index.obligation(target) orelse return false;
    if (audit.ordinal == 0) {
        if (source.input == .step) {
            for (obligation.chain) |position| {
                if (!std.meta.eql(index.records[position].task, source.task)) continue;
                return automatic(index, obligation, position, audit.delivery, clock_ms);
            }
            return false;
        }
        const recovery = (try recoverySource(index, obligation)) orelse return false;
        return std.meta.eql(recovery, reference) and recoveryDelivery(index, recovery, saved);
    }
    if (!source.selected or source.result.? != .step) return false;
    var related = false;
    for (obligation.chain) |position|
        if (std.meta.eql(index.records[position].task, source.task)) {
            related = true;
        };
    if (!related) return false;
    const requests = source.result.?.step.audit_requests.items;
    if (audit.ordinal > requests.len) return false;
    const wanted = requests[@intCast(audit.ordinal - 1)];
    return wanted == .frontier or std.meta.eql(wanted.delivery, audit.delivery.key);
}
