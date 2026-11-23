const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const outbound = @import("../native/outbound.zig");
const eligibility = @import("../native/eligibility.zig");
const preparation = @import("../native/delivery_prepare.zig");
const examples = @import("contracts.zig");
const a = std.testing.allocator;
const audit_control = @import("../native/audit_control.zig");

const Store = struct {
    owner_epoch: t.Digest = @splat(1),
    entries: std.ArrayList(Entry) = .empty,
    submits: u32 = 0,
    cancellations: std.ArrayList(t.Id) = .empty,
    const Entry = struct { operation: []u8, bytes: []u8, task: t.Id };
    const Receipt = struct {
        value: struct { task: t.Id },
        pub fn deinit(_: *Receipt) void {}
    };
    const Input = struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        schema_id: []const u8 = t.input_schema_id,
        encoding: enum { contract } = .contract,
        pub fn deinit(self: *Input) void {
            self.allocator.free(self.bytes);
        }
    };

    const Task = struct {
        value: State = .{},
        const State = struct {
            schedule: enum { queued, parked } = .queued,
            revision: u64 = 1,
            pub fn terminal(_: State) bool {
                return false;
            }
        };
        pub fn deinit(_: *Task) void {}
    };

    pub fn task(_: *Store, _: std.mem.Allocator, _: t.Id) !Task {
        return .{};
    }
    pub fn status(_: *Store, _: std.mem.Allocator, _: Task.State) !enum { ready, unknown } {
        return .ready;
    }
    pub fn resumeTask(
        _: *Store,
        _: std.mem.Allocator,
        _: []const u8,
        _: t.Id,
        _: u64,
    ) anyerror!void {}

    pub fn notificationHistory(
        _: *Store,
        _: std.mem.Allocator,
        _: t.Id,
        _: []const u8,
    ) !@import("protean_native").tasks.NotificationHistory {
        return .{ .complete = true };
    }
    pub fn requestCancel(
        self: *Store,
        _: std.mem.Allocator,
        _: []const u8,
        id: t.Id,
        _: []const u8,
    ) !void {
        for (self.cancellations.items) |existing|
            if (std.meta.eql(existing, id)) return;
        try self.cancellations.append(a, id);
    }

    fn deinit(self: *Store) void {
        for (self.entries.items) |entry| {
            a.free(entry.operation);
            a.free(entry.bytes);
        }
        self.entries.deinit(a);
        self.cancellations.deinit(a);
    }

    pub fn operationLookup(self: *Store, _: std.mem.Allocator, operation: []const u8) !?Receipt {
        for (self.entries.items) |entry|
            if (std.mem.eql(u8, entry.operation, operation))
                return .{ .value = .{ .task = entry.task } };
        return null;
    }

    pub fn applicationValue(
        self: *Store,
        allocator: std.mem.Allocator,
        task_id: t.Id,
        _: enum { input },
    ) !?Input {
        for (self.entries.items) |entry| if (std.meta.eql(entry.task, task_id))
            return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, entry.bytes) };
        return null;
    }

    pub fn submit(
        self: *Store,
        _: std.mem.Allocator,
        operation: []const u8,
        input: t.Input,
    ) !struct {
        receipt: struct { task: t.Id },
    } {
        const bytes = try c.encodeOwned(t.Input, a, input);
        defer a.free(bytes);
        self.submits += 1;
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.operation, operation)) {
            if (!std.mem.eql(u8, entry.bytes, bytes)) return error.OperationConflict;
            return .{ .receipt = .{ .task = entry.task } };
        };
        const saved = try a.dupe(u8, bytes);
        errdefer a.free(saved);
        const op = try a.dupe(u8, operation);
        errdefer a.free(op);
        const task_id: t.Id = @splat(@intCast(self.entries.items.len + 20));
        try self.entries.append(a, .{ .operation = op, .bytes = saved, .task = task_id });
        return .{ .receipt = .{ .task = task_id } };
    }

    fn read(self: *Store, ordinal: usize) !c.Decoded(t.Input) {
        return c.decodeOwned(t.Input, a, self.entries.items[ordinal].bytes);
    }
};

const Fixture = struct {
    index: idx.Index,
    target: t.Id = @splat(1),

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const records = try allocator.alloc(idx.Record, 4);
        const initial = examples.genesis();
        var first = @import("native_genesis.zig").expectedFresh(initial);
        first.obligation = .{ .task = @splat(1) };
        first.activation = null;
        first.observed = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') };
        first.digest = .{ .delivery = intent(.digest, 0), .hold = .none, .not_before_ms = 200 };
        records[0] = record(1, .{ .genesis = initial }, .{ .genesis = first });
        records[1] = record(2, step(first), .{ .step = .{
            .head = first,
            .batch = .{
                .repository = first.specification.repository,
                .sequence = 1,
                .epoch = 0,
                .base = @splat('a'),
                .tip = @splat('b'),
                .coverage = .complete,
                .commits = .{ .items = &.{} },
                .raw_evidence = .{ .items = &.{} },
                .acquired_ms = 100,
                .provider_date = null,
            },
            .dispositions = .{ .items = &.{} },
            .notices = .{ .items = &.{} },
        } });
        records[2] = record(3, step(first), .{ .step = .{
            .head = first,
            .batch = null,
            .dispositions = .{ .items = &.{} },
            .notices = .{ .items = &.{} },
        } });
        records[3] = records[2];
        records[3].task = @splat(4);
        records[3].selected = false;
        const obligations = try allocator.alloc(idx.Obligation, 1);
        obligations[0] = .{
            .task = @splat(1),
            .chain = try allocator.dupe(usize, &.{ 0, 1 }),
            .directives = &.{},
            .eligible = null,
            .folded_mode = .active,
            .effective_mode = .active,
            .recovery_hold = false,
        };
        var index: idx.Index = .{
            .arena = arena,
            .records = records,
            .obligations = obligations,
            .tasks = .empty,
        };
        for (records, 0..) |item, position| try index.tasks.put(allocator, item.task, position);
        return .{ .index = index };
    }

    fn head(self: *Fixture) *t.Head {
        return &self.index.records[1].result.?.step.head;
    }

    fn advance(self: *Fixture) !void {
        self.index.records[2].result.?.step.head = self.head().*;
        self.index.obligations[0].chain = try self.index.arena.allocator().dupe(
            usize,
            &.{ 0, 1, 2 },
        );
    }

    fn addDelivery(self: *Fixture, input: t.Delivery, task: t.Id) !void {
        self.index.records[3] = .{
            .task = task,
            .revision = 1,
            .input_digest = @splat(7),
            .result_digest = null,
            .input = .{ .delivery = input },
            .result = null,
        };
        try self.index.tasks.put(self.index.arena.allocator(), task, 3);
    }
};

fn record(id: u8, input: t.Input, output: t.Output) idx.Record {
    return .{
        .task = @splat(id),
        .revision = 1,
        .input_digest = @splat(id),
        .result_digest = @splat(id + 8),
        .input = input,
        .result = output,
        .selected = true,
    };
}

fn step(head: t.Head) t.Input {
    return .{ .step = .{
        .envelope = examples.genesis().envelope,
        .obligation = @splat(1),
        .predecessor = .{ .task = @splat(1), .digest = @splat(9) },
        .previous = head,
        .sequence = 1,
        .attempt = 0,
        .supersession = null,
        .directives = .{ .items = &.{} },
        .facts = .{ .items = &.{} },
        .batches = .{ .items = &.{} },
        .clock_ms = 200,
        .fold_only = false,
    } };
}

fn intent(purpose: @FieldType(t.DeliveryKey, "purpose"), generation: u32) t.DeliveryIntent {
    return .{
        .destination = examples.specification().destination,
        .key = .{
            .lineage = @splat(8),
            .purpose = purpose,
            .identity = @splat(3),
            .generation = generation,
        },
        .payload = .{
            .obligation = @splat(1),
            .specification_revision = examples.specification().revision,
            .prior_sequence = 0,
            .through_sequence = 1,
            .frozen_text = .{ .bytes = "one change" },
            .prompt = null,
            .supersedes = null,
            .coverage = if (purpose == .digest)
                .{ .sequence = 1, .epoch = 0, .tip = @splat('b') }
            else
                null,
        },
    };
}

test "outbound delivery reuses original frozen producer after the selected head advances" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const first = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(first);
    try std.testing.expectEqual(1, first.len);
    const bytes = try a.dupe(u8, store.entries.items[0].bytes);
    defer a.free(bytes);
    try fixture.advance();
    const second = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 900);
    defer a.free(second);
    try std.testing.expectEqualSlices(t.Id, first, second);
    try std.testing.expectEqual(1, store.entries.items.len);
    try std.testing.expectEqualSlices(u8, bytes, store.entries.items[0].bytes);
    var frozen = try store.read(0);
    defer frozen.deinit();
    try std.testing.expectEqualDeep(
        fixture.index.reference(1),
        frozen.value.delivery.envelope.origin.derived.predecessor,
    );
}

test "outbound delivery admits authored retry generation without inventing one for existing task" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const first = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(first);
    const repeat = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 5000);
    defer a.free(repeat);
    try std.testing.expectEqual(1, store.entries.items.len);
    var original = try store.read(0);
    defer original.deinit();
    fixture.head().digest.?.delivery.key.generation += 1;
    const retry = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 5000);
    defer a.free(retry);
    try std.testing.expectEqual(2, store.entries.items.len);
    var next = try store.read(1);
    defer next.deinit();
    try std.testing.expectEqual(1, next.value.delivery.key.generation);
    try std.testing.expectEqualDeep(
        original.value.delivery.payload.logical,
        next.value.delivery.payload.logical,
    );
    try std.testing.expectEqualDeep(
        original.value.delivery.payload.content_digest,
        next.value.delivery.payload.content_digest,
    );
}

test "outbound digest keeps its frozen payload across a specification amendment" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const first = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(first);
    try std.testing.expectEqual(1, first.len);
    var saved = try store.read(0);
    defer saved.deinit();
    try fixture.addDelivery(saved.value.delivery, first[0]);
    try fixture.advance();
    fixture.index.records[2].result.?.step.head.specification.revision += 1;
    const amended = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(amended);
    try std.testing.expectEqualSlices(t.Id, first, amended);
    try std.testing.expect(try permits(&fixture, first[0]));
    try std.testing.expectEqual(1, store.entries.items.len);
}

test "outbound delivery respects deadline hold and effective pending control fence" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const early = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 199);
    defer a.free(early);
    try std.testing.expectEqual(0, early.len);
    for (std.enums.values(t.DeliveryHold)) |hold| {
        if (hold == .none) continue;
        fixture.head().digest.?.hold = hold;
        const held = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
        defer a.free(held);
        try std.testing.expectEqual(0, held.len);
    }
    fixture.head().digest.?.hold = .none;
    fixture.index.obligations[0].effective_mode = .paused;
    const fenced = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(fenced);
    try std.testing.expectEqual(0, fenced.len);
    try std.testing.expectEqual(0, store.submits);
}

test "outbound delivers question and every selected control notice including final heads" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.head().digest = null;
    const question = intent(.question, 0);
    fixture.head().question = .{
        .identity = @splat(2),
        .condition = @splat(3),
        .specification_revision = fixture.head().specification.revision,
        .evidence = .{ .current = {} },
        .choices = .{ .items = &.{} },
        .prompt = question,
    };
    const asked = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(asked);
    try std.testing.expectEqual(1, asked.len);
    fixture.head().question = null;
    const first = intent(.control, 0);
    var last = first;
    last.key.identity = @splat(4);
    last.payload.frozen_text.bytes = "cancelled";
    fixture.index.records[1].result.?.step.notices.items = &.{first};
    try fixture.advance();
    fixture.index.records[2].result.?.step.notices.items = &.{last};
    fixture.index.records[2].result.?.step.head.mode = .cancelled;
    fixture.index.obligations[0].effective_mode = .cancelled;
    const notices = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(notices);
    try std.testing.expectEqual(2, notices.len);
    try std.testing.expectEqual(3, store.entries.items.len);
}

test "outbound rejects reused operation with changed logical payload or original producer" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const first = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(first);
    try fixture.advance();
    const changed = &fixture.index.records[2].result.?.step.head.digest.?.delivery.payload;
    changed.frozen_text.bytes = "changed";
    try std.testing.expectError(
        error.OperationConflict,
        outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300),
    );
    fixture.index.records[2].result.?.step.head = fixture.head().*;
    fixture.index.records[1].selected = false;
    try std.testing.expectError(
        error.UnselectedProducer,
        outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300),
    );
    try std.testing.expectEqual(1, store.entries.items.len);
}

test "outbound audit requires admitted delivery and creates an honest moving window" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const requests = [_]t.AuditRequest{.{ .delivery = intent(.digest, 0).key }};
    fixture.index.records[1].result.?.step.audit_requests.items = &requests;
    try std.testing.expectError(
        error.MissingAdmittedDelivery,
        outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200),
    );
    const delivery = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(delivery);
    var frozen = try store.read(0);
    defer frozen.deinit();
    try fixture.addDelivery(frozen.value.delivery, delivery[0]);
    const audits = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(audits);
    try std.testing.expectEqual(1, audits.len);
    try std.testing.expectEqual(2, store.entries.items.len);
    var admitted = try store.read(1);
    defer admitted.deinit();
    try std.testing.expect(admitted.value.audit.latest == null);
    try std.testing.expectEqualStrings("0.0", admitted.value.audit.oldest.bytes);
}

fn savedAudit(fixture: *Fixture, store: *Store, delivery: t.Delivery) !t.Id {
    const producer = fixture.index.reference(1);
    const operation = try outbound.auditOperation(a, producer, 1, delivery.key);
    defer a.free(operation);
    var audit: t.Audit = .{
        .envelope = .{
            .operation = .{ .bytes = operation },
            .stable_request = @splat(0),
            .origin = .{ .derived = .{ .predecessor = producer } },
        },
        .delivery = delivery,
        .ordinal = 1,
        .oldest = .{ .bytes = "1700000000.000001" },
        .latest = .{ .bytes = "1700001000.000000" },
        .page_limit = 4,
        .canary = null,
    };
    audit.envelope.stable_request = try outbound.auditStableDigest(a, audit);
    return (try store.submit(a, operation, .{ .audit = audit })).receipt.task;
}

test "outbound audit reuses original admitted window without widening after head advance" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.records[1].result.?.step.audit_requests.items =
        &.{.{ .delivery = intent(.digest, 0).key }};
    const sent = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(sent);
    var delivery = try store.read(0);
    defer delivery.deinit();
    try fixture.addDelivery(delivery.value.delivery, sent[0]);
    const task = try savedAudit(&fixture, &store, delivery.value.delivery);
    const bytes = try a.dupe(u8, store.entries.items[1].bytes);
    defer a.free(bytes);
    try fixture.advance();
    const repeated = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(repeated);
    try std.testing.expectEqualSlices(t.Id, &.{task}, repeated);
    try std.testing.expectEqualSlices(u8, bytes, store.entries.items[1].bytes);
    try std.testing.expectEqual(2, store.entries.items.len);
}

test "outbound audit rejects changed retained window seal and delivery binding" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.records[1].result.?.step.audit_requests.items =
        &.{.{ .delivery = intent(.digest, 0).key }};
    const sent = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(sent);
    var delivery = try store.read(0);
    defer delivery.deinit();
    try fixture.addDelivery(delivery.value.delivery, sent[0]);
    _ = try savedAudit(&fixture, &store, delivery.value.delivery);
    var audit = try store.read(1);
    defer audit.deinit();
    audit.value.audit.latest.?.bytes = "1700002000.000000";
    const altered = try c.encodeOwned(t.Input, a, audit.value);
    a.free(store.entries.items[1].bytes);
    store.entries.items[1].bytes = altered;
    try std.testing.expectError(
        error.OperationConflict,
        outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200),
    );
    audit.value.audit.envelope.stable_request =
        try outbound.auditStableDigest(a, audit.value.audit);
    audit.value.audit.delivery.destination.channel.bytes = "Dother";
    const redirected = try c.encodeOwned(t.Input, a, audit.value);
    a.free(store.entries.items[1].bytes);
    store.entries.items[1].bytes = redirected;
    try std.testing.expectError(
        error.OperationConflict,
        outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200),
    );
}

test "outbound audit canary must be an admitted delivery with an owner retained receipt" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.records[1].result.?.step.audit_requests.items =
        &.{.{ .delivery = intent(.digest, 0).key }};
    const sent = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(sent);
    var delivery = try store.read(0);
    defer delivery.deinit();
    try fixture.addDelivery(delivery.value.delivery, sent[0]);
    _ = try savedAudit(&fixture, &store, delivery.value.delivery);
    var audit = try store.read(1);
    defer audit.deinit();
    const receipt: t.Receipt = .{
        .key = delivery.value.delivery.key,
        .destination = delivery.value.delivery.destination,
        .timestamp = audit.value.audit.oldest,
        .payload_digest = delivery.value.delivery.payload.content_digest,
        .evidence = .{ .task = sent[0], .digest = @splat(88) },
        .basis = .captured_response,
    };
    audit.value.audit.canary = .{ .receipt = receipt, .admitted = delivery.value.delivery };
    audit.value.audit.envelope.stable_request =
        try outbound.auditStableDigest(a, audit.value.audit);
    const frozen = try c.encodeOwned(t.Input, a, audit.value);
    a.free(store.entries.items[1].bytes);
    store.entries.items[1].bytes = frozen;
    try std.testing.expectError(
        error.UnprovenCanary,
        outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200),
    );
    fixture.head().told_receipt = receipt;
    const repeated = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(repeated);
    try std.testing.expectEqualSlices(t.Id, &.{store.entries.items[1].task}, repeated);
    try wrongCanaryPair(&fixture, &store, audit.value.audit);
}

fn wrongCanaryPair(fixture: *Fixture, store: *Store, original: t.Audit) !void {
    var audit_value = original;
    audit_value.canary.?.receipt.key.generation += 1;
    fixture.head().told_receipt = audit_value.canary.?.receipt;
    audit_value.envelope.stable_request = try outbound.auditStableDigest(a, audit_value);
    const bytes = try c.encodeOwned(t.Input, a, .{ .audit = audit_value });
    a.free(store.entries.items[1].bytes);
    store.entries.items[1].bytes = bytes;
    try std.testing.expectError(error.InvalidCanary, outbound.admitAudits(
        store,
        a,
        &fixture.index,
        fixture.target,
        200,
    ));
}

fn unknownFact(delivery: t.Delivery, task: t.Id) t.Settlement {
    return .{
        .reference = .{ .task = task, .revision = 1, .digest = @splat(90) },
        .kind = .delivery,
        .accounting = .{},
        .delivery = .{
            .admitted = delivery,
            .outcome = .{ .indeterminate = .{ .bytes = "lost_response" } },
            .receipt = null,
        },
    };
}

test "outbound automatic unknown audit waits two minutes after first fold and stays unique" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const sent = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(sent);
    var delivery = try store.read(0);
    defer delivery.deinit();
    try fixture.addDelivery(delivery.value.delivery, sent[0]);
    const fact = unknownFact(delivery.value.delivery, sent[0]);
    fixture.index.records[1].input.step.facts.items = &.{fact};
    fixture.index.obligations[0].effective_mode = .paused;
    fixture.index.obligations[0].recovery_hold = true;
    const before = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 120_199);
    defer a.free(before);
    try std.testing.expectEqual(0, before.len);
    const due = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 120_200);
    defer a.free(due);
    try std.testing.expectEqual(1, due.len);
    var first = try store.read(1);
    defer first.deinit();
    try std.testing.expectEqual(0, first.value.audit.ordinal);
    try std.testing.expect(first.value.audit.latest == null);
    try std.testing.expect(!try audit_control.permits(
        a,
        &fixture.index,
        first.value.audit,
        120_199,
    ));
    try std.testing.expect(try audit_control.permits(
        a,
        &fixture.index,
        first.value.audit,
        120_200,
    ));
    try fixture.advance();
    fixture.index.records[2].input.step.facts.items = &.{fact};
    const again = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 300_000);
    defer a.free(again);
    try std.testing.expectEqualSlices(t.Id, due, again);
    try std.testing.expectEqual(2, store.entries.items.len);
}

test "outbound confirmed activation schedules readback without unknown quiescence" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.head().digest = null;
    fixture.head().activation = @import("native_genesis.zig").expectedFresh(
        examples.genesis(),
    ).activation;
    const sent = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(sent);
    var delivery = try store.read(0);
    defer delivery.deinit();
    try fixture.addDelivery(delivery.value.delivery, sent[0]);
    var fact = unknownFact(delivery.value.delivery, sent[0]);
    fact.delivery.?.outcome = .{ .confirmed = .{
        .timestamp = .{ .bytes = "100.000001" },
        .metadata_observed = false,
    } };
    fact.delivery.?.receipt = .{
        .key = delivery.value.delivery.key,
        .destination = delivery.value.delivery.destination,
        .timestamp = .{ .bytes = "100.000001" },
        .payload_digest = delivery.value.delivery.payload.content_digest,
        .evidence = .{ .task = sent[0], .digest = @splat(91) },
        .basis = .captured_response,
    };
    fixture.index.records[1].input.step.facts.items = &.{fact};
    const tasks = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(tasks);
    try std.testing.expectEqual(1, tasks.len);
    var saved = try store.read(1);
    defer saved.deinit();
    try std.testing.expect(try audit_control.permits(a, &fixture.index, saved.value.audit, 200));
}

const AuditDriver = struct {
    attached: bool = true,
    service: *Store,
    index: *idx.Index,

    pub fn rebuild(self: *@This(), allocator: std.mem.Allocator) !idx.Index {
        var borrowed = self.index.*;
        borrowed.arena = std.heap.ArenaAllocator.init(allocator);
        return borrowed;
    }
};

test "outbound explicit audit remains read only for final and recovery held obligations" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const sent = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(sent);
    var delivery = try store.read(0);
    defer delivery.deinit();
    try fixture.addDelivery(delivery.value.delivery, sent[0]);
    fixture.head().mode = .cancelled;
    fixture.index.obligations[0].effective_mode = .cancelled;
    fixture.index.obligations[0].recovery_hold = true;
    fixture.index.recovery_hold = true;
    var driver: AuditDriver = .{ .service = &store, .index = &fixture.index };
    const origin: t.Origin = .{ .local = .{ .uid = 501 } };
    const task = try audit_control.request(
        &driver,
        a,
        "explicit-one",
        origin,
        delivery.value.delivery.key,
    );
    var admitted = try store.read(1);
    defer admitted.deinit();
    try std.testing.expect(admitted.value.audit.latest == null);
    try std.testing.expect(try audit_control.permits(
        a,
        &fixture.index,
        admitted.value.audit,
        -999_999,
    ));
    try std.testing.expectEqualDeep(task, try audit_control.request(
        &driver,
        a,
        "explicit-one",
        origin,
        delivery.value.delivery.key,
    ));
    const second = try audit_control.request(
        &driver,
        a,
        "explicit-two",
        origin,
        delivery.value.delivery.key,
    );
    try std.testing.expect(!std.meta.eql(task, second));
    var wrong = origin;
    wrong.local.uid = 502;
    try std.testing.expectError(error.OperationConflict, audit_control.request(
        &driver,
        a,
        "explicit-one",
        wrong,
        delivery.value.delivery.key,
    ));
    try std.testing.expectEqual(.cancelled, fixture.head().mode);
    try std.testing.expect(fixture.index.recovery_hold);
}

fn turnRecord(target: ?t.Id) idx.Record {
    const destination = examples.specification().destination;
    var delivery = intent(.turn, 0);
    delivery.key.lineage = @splat(7);
    delivery.key.identity = @splat(7);
    delivery.payload.obligation = target;
    delivery.payload.specification_revision = if (target != null) 1 else 0;
    delivery.payload.prior_sequence = 0;
    delivery.payload.through_sequence = 0;
    const request: t.Turn = .{
        .envelope = .{
            .operation = .{ .bytes = "slack-event-one" },
            .stable_request = @splat(7),
            .origin = .{ .slack = .{
                .app = destination.app,
                .workspace = destination.workspace,
                .user = destination.operator,
                .channel = destination.channel,
            } },
        },
        .destination = destination,
        .text = .{ .bytes = "hello" },
        .context = .{ .bytes = "" },
        .context_references = .{ .items = &.{} },
        .attempt = 0,
        .target = target,
        .expected_revision = if (target != null) 1 else null,
    };
    var result = record(3, .{ .turn = request }, .{ .turn = .{
        .reply = .{ .bytes = "one change" },
        .proposals = .{ .items = &.{} },
        .delivery = delivery,
    } });
    result.selected = false;
    return result;
}

fn permits(fixture: *Fixture, task: t.Id) !bool {
    return eligibility.permits(a, &fixture.index, .{
        .task = task,
        .identity = @splat(9),
        .kind = .acquisition,
        .capability = @import("../app/slack_contract.zig").notification_identity,
    }, 300);
}

test "outbound activation follows current selected intent and ordinary dispatch admission" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.head().digest = null;
    fixture.head().activation = @import("native_genesis.zig").expectedFresh(
        examples.genesis(),
    ).activation;
    const first = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(first);
    try std.testing.expectEqual(1, first.len);
    var saved = try store.read(0);
    defer saved.deinit();
    try std.testing.expectEqual(@as(?t.Id, null), saved.value.delivery.payload.logical.obligation);
    try fixture.addDelivery(saved.value.delivery, first[0]);
    try std.testing.expect(try permits(&fixture, first[0]));
    try fixture.advance();
    const again = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(again);
    try std.testing.expectEqualSlices(t.Id, first, again);
    fixture.head().activation.?.payload.frozen_text.bytes = "changed producer payload";
    try std.testing.expect(!try permits(&fixture, first[0]));
    fixture.head().activation = fixture.index.records[2].result.?.step.head.activation;
    fixture.index.obligations[0].recovery_hold = true;
    try std.testing.expect(!try permits(&fixture, first[0]));
    fixture.index.obligations[0].recovery_hold = false;
    fixture.index.obligations[0].effective_mode = .paused;
    const held = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(held);
    try std.testing.expectEqual(0, held.len);
    try std.testing.expect(!try permits(&fixture, first[0]));
    fixture.index.obligations[0].effective_mode = .active;
    fixture.index.records[2].result.?.step.head.activation = null;
    try std.testing.expect(!try permits(&fixture, first[0]));
    try std.testing.expectEqual(1, store.entries.items.len);
}

test "outbound Slack conversation replies need no obligation and reuse exact producer" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.records[2] = turnRecord(null);
    fixture.index.obligations = &.{};
    const first = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(first);
    try std.testing.expectEqual(1, first.len);
    var saved = try store.read(0);
    defer saved.deinit();
    try std.testing.expectEqualDeep(
        fixture.index.reference(2),
        saved.value.delivery.envelope.origin.derived.predecessor,
    );
    try fixture.addDelivery(saved.value.delivery, first[0]);
    try std.testing.expect(try permits(&fixture, first[0]));
    const again = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(again);
    try std.testing.expectEqualSlices(t.Id, first, again);
    fixture.index.records[2].result_digest = @splat(90);
    try std.testing.expect(!try permits(&fixture, first[0]));
    try std.testing.expectError(
        error.OperationConflict,
        outbound.admitTurnDeliveries(&store, a, &fixture.index),
    );
}

test "outbound keeps local turns local and permits replies about cancelled obligations" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.records[2] = turnRecord(fixture.target);
    fixture.index.obligations[0].effective_mode = .cancelled;
    const first = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(first);
    try std.testing.expectEqual(1, first.len);
    var saved = try store.read(0);
    defer saved.deinit();
    try fixture.addDelivery(saved.value.delivery, first[0]);
    try std.testing.expect(try permits(&fixture, first[0]));
    fixture.index.records[2].input.turn.envelope.origin = .{ .local = .{ .uid = 501 } };
    const local = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(local);
    try std.testing.expectEqual(0, local.len);
    try std.testing.expect(!try permits(&fixture, first[0]));
    try std.testing.expectEqual(1, store.entries.items.len);
}

test "outbound fences superseded replies before replacement result and rejects route changes" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.records[2] = turnRecord(null);
    const first = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(first);
    var saved = try store.read(0);
    defer saved.deinit();
    try fixture.addDelivery(saved.value.delivery, first[0]);
    fixture.index.records[2].superseded = true;
    try std.testing.expect(!try permits(&fixture, first[0]));
    const superseded = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(superseded);
    try std.testing.expectEqual(0, superseded.len);
    fixture.index.records[2].superseded = false;
    fixture.index.records[2].input.turn.envelope.origin.slack.channel.bytes = "Dother";
    try std.testing.expect(!try permits(&fixture, first[0]));
    try std.testing.expectError(
        error.UnauthorizedIntent,
        outbound.admitTurnDeliveries(&store, a, &fixture.index),
    );
    fixture.index.records[2] = turnRecord(null);
    fixture.index.records[2].result.?.turn.delivery.?.destination.channel.bytes = "Dother";
    try std.testing.expect(!try permits(&fixture, first[0]));
    try std.testing.expectError(
        error.UnauthorizedIntent,
        outbound.admitTurnDeliveries(&store, a, &fixture.index),
    );
}

test "frontier audit scans a lineage with no admitted delivery and preserves the head" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const before = fixture.head().*;
    const requests = [_]t.AuditRequest{.{ .frontier = {} }};
    fixture.index.records[1].result.?.step.audit_requests.items = &requests;
    const tasks = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, -200_000);
    defer a.free(tasks);
    try std.testing.expectEqual(1, tasks.len);
    var saved = try store.read(0);
    defer saved.deinit();
    try std.testing.expect(saved.value == .lineage_audit);
    try std.testing.expectEqualDeep(before, fixture.head().*);
    const scan = saved.value.lineage_audit;
    try std.testing.expectEqualSlices(u8, &before.lineage, &scan.lineage);
    try std.testing.expect(scan.latest == null);
    const checker = @import("../native/lineage_audit.zig");
    try std.testing.expect(try checker.permits(a, &fixture.index, scan));
    var forged = scan;
    forged.destination.channel.bytes = "D456";
    forged.envelope.stable_request = try checker.stableDigest(a, forged);
    try std.testing.expect(!try checker.permits(a, &fixture.index, forged));
    forged = scan;
    forged.latest = .{ .bytes = "200.000000" };
    forged.envelope.stable_request = try checker.stableDigest(a, forged);
    try std.testing.expect(!try checker.permits(a, &fixture.index, forged));
    const repeated = try outbound.admitAudits(&store, a, &fixture.index, fixture.target, 300_000);
    defer a.free(repeated);
    try std.testing.expectEqualSlices(t.Id, tasks, repeated);
    try std.testing.expectEqual(1, store.submits);
}

test "activation reconciliation needs retained readback and never releases digest holds" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.head().digest.?.hold = .uncertain_transmission;
    fixture.head().activation = @import("native_genesis.zig").expectedFresh(
        examples.genesis(),
    ).activation;
    const pending = fixture.head().*;
    const view = @import("../native/reconciliation.zig");
    try std.testing.expectEqual(.pending, try view.capability(a, &fixture.index, fixture.target));
    const tasks = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(tasks);
    var saved = try store.read(0);
    defer saved.deinit();
    try fixture.addDelivery(saved.value.delivery, tasks[0]);
    fixture.index.records[3].result = .{ .delivery = .{ .confirmed = .{
        .timestamp = .{ .bytes = "100.0" },
        .metadata_observed = true,
    } } };
    try std.testing.expectEqual(.pending, try view.capability(a, &fixture.index, fixture.target));
    fixture.index.records[3].result.?.delivery.confirmed.metadata_observed = false;
    try std.testing.expectEqual(.degraded, try view.capability(a, &fixture.index, fixture.target));
    fixture.index.records[3].input = .{ .audit = .{
        .envelope = saved.value.delivery.envelope,
        .delivery = saved.value.delivery,
        .ordinal = 0,
        .oldest = .{ .bytes = "0.0" },
        .latest = null,
        .page_limit = 10,
        .canary = null,
    } };
    fixture.index.records[3].result = .{ .audit = .{ .found = .{
        .timestamp = .{ .bytes = "100.0" },
    } } };
    try std.testing.expectEqual(.qualified, try view.capability(a, &fixture.index, fixture.target));
    const successful = fixture.index.records[3];
    fixture.index.records[2] = successful;
    fixture.index.records[2].task = @splat(3);
    fixture.index.records[2].result.?.audit = .{ .inconclusive = .{ .bytes = "missing history" } };
    const mixed = try view.inspect(a, &fixture.index, fixture.target);
    try std.testing.expectEqual(.degraded, mixed.capability);
    try std.testing.expect(mixed.previously_qualified);
    try std.testing.expectEqual(.unknown, mixed.readback_order);
    try std.testing.expectEqual(.inconclusive, mixed.failed_readback.?.outcome);
    std.mem.swap(idx.Record, &fixture.index.records[2], &fixture.index.records[3]);
    try std.testing.expectEqual(.degraded, try view.capability(a, &fixture.index, fixture.target));
    fixture.index.records[2] = successful;
    fixture.index.records[3].input = saved.value;
    fixture.index.records[3].result = .{ .delivery = .{ .confirmed = .{
        .timestamp = .{ .bytes = "100.0" },
        .metadata_observed = false,
    } } };
    try std.testing.expectEqual(.qualified, try view.capability(a, &fixture.index, fixture.target));
    try std.testing.expectEqualDeep(pending, fixture.head().*);
}
