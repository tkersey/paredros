const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const outbound = @import("../native/outbound.zig");
const eligibility = @import("../native/eligibility.zig");
const preparation = @import("../native/delivery_prepare.zig");
const examples = @import("contracts.zig");
const a = std.testing.allocator;

const Store = struct {
    owner_epoch: t.Digest = @splat(1),
    entries: std.ArrayList(Entry) = .empty,
    submits: u32 = 0,
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

    fn deinit(self: *Store) void {
        for (self.entries.items) |entry| {
            a.free(entry.operation);
            a.free(entry.bytes);
        }
        self.entries.deinit(a);
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
    try std.testing.expectEqual(
        .local,
        try preparation.verifyStored(a, next.value.delivery),
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
    try std.testing.expect(!dispatched(&fixture, first[0]));
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

fn dispatched(fixture: *Fixture, task: t.Id) bool {
    return eligibility.permits(&fixture.index, .{
        .task = task,
        .identity = @splat(9),
        .kind = .acquisition,
        .capability = "agent.notification.deliver.v1.slack",
    });
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
    try fixture.advance();
    const again = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(again);
    try std.testing.expectEqualSlices(t.Id, first, again);
    fixture.index.obligations[0].recovery_hold = true;
    const recovering = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(recovering);
    try std.testing.expectEqual(0, recovering.len);
    fixture.index.obligations[0].recovery_hold = false;
    fixture.index.obligations[0].effective_mode = .paused;
    const held = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300);
    defer a.free(held);
    try std.testing.expectEqual(0, held.len);
    fixture.index.obligations[0].effective_mode = .active;
    fixture.index.records[2].result.?.step.head.activation.?.payload.frozen_text.bytes =
        "changed producer payload";
    try std.testing.expectError(
        error.OperationConflict,
        outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 300),
    );
    try std.testing.expect(!dispatched(&fixture, first[0]));
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
    const again = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(again);
    try std.testing.expectEqualSlices(t.Id, first, again);
    fixture.index.records[2].result_digest = @splat(90);
    try std.testing.expectError(
        error.OperationConflict,
        outbound.admitTurnDeliveries(&store, a, &fixture.index),
    );
}

test "outbound keeps local turns local and admits replies about cancelled obligations" {
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
    fixture.index.records[2].input.turn.envelope.origin = .{ .local = .{ .uid = 501 } };
    const local = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(local);
    try std.testing.expectEqual(0, local.len);
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
    const superseded = try outbound.admitTurnDeliveries(&store, a, &fixture.index);
    defer a.free(superseded);
    try std.testing.expectEqual(0, superseded.len);
    fixture.index.records[2].superseded = false;
    fixture.index.records[2].input.turn.envelope.origin.slack.channel.bytes = "Dother";
    try std.testing.expectError(
        error.UnauthorizedIntent,
        outbound.admitTurnDeliveries(&store, a, &fixture.index),
    );
    fixture.index.records[2] = turnRecord(null);
    fixture.index.records[2].result.?.turn.delivery.?.destination.channel.bytes = "Dother";
    try std.testing.expectError(
        error.UnauthorizedIntent,
        outbound.admitTurnDeliveries(&store, a, &fixture.index),
    );
}

fn gatedFixture() !Fixture {
    var fixture = try Fixture.init();
    errdefer fixture.index.deinit();
    var notice = intent(.control, 0);
    notice.key.identity = @splat(4);
    fixture.index.records[1].result.?.step.notices.items =
        try fixture.index.arena.allocator().dupe(t.DeliveryIntent, &.{notice});
    fixture.index.records[2] = turnRecord(null);
    return fixture;
}

fn admitAll(fixture: *Fixture, store: *Store) ![2]usize {
    const deliveries = try outbound.admitDeliveries(store, a, &fixture.index, fixture.target, 200);
    defer a.free(deliveries);
    const replies = try outbound.admitTurnDeliveries(store, a, &fixture.index);
    defer a.free(replies);
    return .{ deliveries.len, replies.len };
}

test "outbound admits no delivery while a recovery hold covers the namespace" {
    var fixture = try gatedFixture();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.recovery_hold = true;
    try std.testing.expectEqual([2]usize{ 0, 0 }, try admitAll(&fixture, &store));
    try std.testing.expectEqual(0, store.submits);
    fixture.index.recovery_hold = false;
    try std.testing.expectEqual([2]usize{ 2, 1 }, try admitAll(&fixture, &store));
}

test "outbound admits no delivery while imported output is held" {
    var fixture = try gatedFixture();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.import_hold = true;
    try std.testing.expectEqual([2]usize{ 0, 0 }, try admitAll(&fixture, &store));
    try std.testing.expectEqual(0, store.submits);
    fixture.index.import_hold = false;
    try std.testing.expectEqual([2]usize{ 2, 1 }, try admitAll(&fixture, &store));
}

test "outbound admits no delivery in a transferred namespace" {
    var fixture = try gatedFixture();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    fixture.index.recovery_purpose = .transfer;
    try std.testing.expectEqual([2]usize{ 0, 0 }, try admitAll(&fixture, &store));
    try std.testing.expectEqual(0, store.submits);
    fixture.index.recovery_purpose = .rollback;
    try std.testing.expectEqual([2]usize{ 2, 1 }, try admitAll(&fixture, &store));
}

test "outbound admits no delivery whose key the restore cut contains" {
    var fixture = try gatedFixture();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    const step_cut = [_]t.InputReference{.{ .task = @splat(2), .digest = @splat(2) }};
    fixture.index.restore_cut = &step_cut;
    try std.testing.expectEqual([2]usize{ 0, 1 }, try admitAll(&fixture, &store));
    try std.testing.expectEqual(1, store.entries.items.len);
    var reply = try store.read(0);
    defer reply.deinit();
    try std.testing.expectEqual(.turn, reply.value.delivery.key.purpose);
    const turn_cut = [_]t.InputReference{
        .{ .task = @splat(2), .digest = @splat(2) },
        .{ .task = @splat(3), .digest = @splat(3) },
    };
    fixture.index.restore_cut = &turn_cut;
    try std.testing.expectEqual([2]usize{ 0, 0 }, try admitAll(&fixture, &store));
    const forged = [_]t.InputReference{.{ .task = @splat(2), .digest = @splat(99) }};
    fixture.index.restore_cut = &forged;
    try std.testing.expectEqual([2]usize{ 0, 0 }, try admitAll(&fixture, &store));
    fixture.index.restore_cut = &.{};
    try std.testing.expectEqual([2]usize{ 2, 1 }, try admitAll(&fixture, &store));
}

test "outbound returns a retained legacy delivery without rendering or resubmitting it" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var store: Store = .{};
    defer store.deinit();
    var local = try preparation.materialize(
        a,
        intent(.digest, 0),
        fixture.index.reference(1),
        @splat(0),
    );
    defer local.deinit();
    var retired = local.value;
    retired.payload.renderer_version = preparation.legacy_renderer_version;
    retired.payload.wire_json.bytes = "{\"channel\":\"D1\"}";
    const request = try c.encodeOwned(struct {
        destination: t.Destination,
        key: t.DeliveryKey,
        payload: t.DeliveryPayload,
    }, a, .{ .destination = retired.destination, .key = retired.key, .payload = retired.payload });
    defer a.free(request);
    retired.envelope.stable_request = preparation.hash(request);
    const bytes = try c.encodeOwned(t.Input, a, .{ .delivery = retired });
    errdefer a.free(bytes);
    const operation = try a.dupe(u8, retired.envelope.operation.bytes);
    errdefer a.free(operation);
    try store.entries.append(a, .{ .operation = operation, .bytes = bytes, .task = @splat(50) });
    const tasks = try outbound.admitDeliveries(&store, a, &fixture.index, fixture.target, 200);
    defer a.free(tasks);
    try std.testing.expectEqualSlices(t.Id, &.{@as(t.Id, @splat(50))}, tasks);
    try std.testing.expectEqual(0, store.submits);
    try std.testing.expectEqual(1, store.entries.items.len);
}
