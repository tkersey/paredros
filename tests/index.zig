const std = @import("std");
const c = @import("protean_contracts");
const Native = @import("protean_native");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const fixture = @import("contracts.zig");
const retained_views = @import("../native/retained.zig");

pub fn head() t.Head {
    return .{
        .obligation = .{ .self = {} },
        .lineage = @splat(8),
        .sequence = 0,
        .predecessor = null,
        .attempt = 0,
        .superseded = null,
        .folded_directive_ordinal = 0,
        .last_directive = null,
        .consumed = .{ .items = &.{} },
        .specification = fixture.specification(),
        .mode = .active,
        .desired_mode = .active,
        .observed = .{ .sequence = 0, .epoch = 0, .tip = null },
        .told = .{ .sequence = 0, .epoch = 0, .tip = null },
        .last_observation = null,
        .message = null,
        .question = null,
        .method = .{ .ordinary = {} },
        .schedule = .{
            .next_due_ms = 100,
            .source_not_before_ms = 100,
            .render_not_before_ms = 100,
            .provider_not_before_ms = 100,
        },
        .check_requested = false,
        .clock_ms = 100,
        .skipped_slots = 0,
        .clock_regressions = 0,
        .last_clock_regression = null,
        .phase = .fold,
        .previous_check_overran = false,
        .check_failure_streak = 0,
        .render_failure_streak = 0,
        .accounting = .{},
    };
}

fn envelope(operation: []const u8) t.Envelope {
    var value = fixture.genesis().envelope;
    value.operation.bytes = operation;
    return value;
}

pub fn row(a: std.mem.Allocator, task: u8, input: t.Input, output: ?t.Output) !idx.Row {
    return rowId(a, @splat(task), input, output);
}

fn rowId(a: std.mem.Allocator, task: t.Id, input: t.Input, output: ?t.Output) !idx.Row {
    const bytes = try c.encodeOwned(t.Input, a, input);
    var result: ?idx.Value = null;
    if (output) |value| {
        const json = try Native.values.toJson(t.Output, a, value);
        const encoded = try Native.json.canonical(a, json);
        result = .{
            .task = task,
            .revision = 5,
            .digest = idx.digest(encoded),
            .schema_id = t.output_schema_id,
            .encoding = .json,
            .bytes = encoded,
        };
    }
    return freezeRow(.{ .input = .{
        .task = task,
        .revision = 5,
        .digest = idx.digest(bytes),
        .schema_id = t.input_schema_id,
        .encoding = .contract,
        .bytes = bytes,
    }, .result = result });
}

fn snapshotValue(value: idx.Value) retained_views.Value {
    return .{
        .schema_id = .{ .bytes = value.schema_id },
        .encoding = value.encoding,
        .reference = .{ .digest = value.digest, .bytes = value.bytes.len },
    };
}

fn freezeRow(value: idx.Row) idx.Row {
    var result = value;
    result.owner_snapshot = .{
        .task = value.input.task,
        .revision = value.input.revision,
        .event_cut = value.input.revision,
        .outcome = if (value.result != null) .completed else .progressed,
        .input = snapshotValue(value.input),
        .result = if (value.result) |output| snapshotValue(output) else null,
        .profile = .{ .digest = idx.digest(""), .bytes = 0 },
        .inference_attempts = 0,
        .inference_request_bytes = 0,
        .inference_output_tokens = 0,
        .evidence_bytes = 0,
        .attempts = .{ .items = &.{} },
        .unknown_calls = .{ .items = &.{} },
        .accounting = .{},
    };
    result.owner_evidence = .{
        .input = value.input,
        .result = value.result,
        .profile_bytes = "",
        .attempts = &.{},
    };
    return result;
}

fn snapshotBytes(a: std.mem.Allocator, value: idx.Row) ![]const u8 {
    return c.encodeOwned(retained_views.Snapshot, a, value.owner_snapshot.?);
}

pub fn genesis(a: std.mem.Allocator) !idx.Row {
    return row(a, 1, .{ .genesis = fixture.genesis() }, .{ .genesis = head() });
}

pub fn ref(value: idx.Row) t.Reference {
    return .{ .task = value.input.task, .digest = value.result.?.digest };
}

fn inputRef(value: idx.Row) t.InputReference {
    return .{ .task = value.input.task, .digest = value.input.digest };
}

fn directive(
    operation: []const u8,
    ordinal: u64,
    predecessor: ?t.InputReference,
    body: t.DirectiveBody,
) t.Directive {
    return .{
        .envelope = envelope(operation),
        .obligation = @splat(1),
        .ordinal = ordinal,
        .predecessor = predecessor,
        .body = body,
    };
}

pub fn step(previous: t.Head, reference: t.Reference, operation: []const u8) t.Step {
    return .{
        .envelope = envelope(operation),
        .obligation = @splat(1),
        .predecessor = reference,
        .previous = previous,
        .sequence = previous.sequence + 1,
        .attempt = 0,
        .supersession = null,
        .directives = .{ .items = &.{} },
        .facts = .{ .items = &.{} },
        .batches = .{ .items = &.{} },
        .clock_ms = 101,
        .fold_only = true,
    };
}

pub fn successor(value: t.Step) t.Output {
    var output = value.previous;
    output.obligation = .{ .task = value.obligation };
    output.predecessor = value.predecessor;
    output.sequence = value.sequence;
    output.attempt = value.attempt;
    output.superseded = if (value.supersession) |replacement| replacement.input else null;
    for (value.directives.items) |fact| {
        output.folded_directive_ordinal = fact.value.ordinal;
        output.last_directive = fact.reference;
        output.mode = switch (fact.value.body) {
            .pause => .paused,
            .@"resume" => .active,
            .cancel => .cancelled,
            .transfer => .transferred,
            else => output.mode,
        };
    }
    return .{ .step = .{
        .head = output,
        .batch = null,
        .dispositions = .{ .items = &.{} },
    } };
}

fn chainTask(sequence: usize) t.Id {
    var task: t.Id = @splat(0xc0);
    std.mem.writeInt(u64, task[0..8], sequence, .big);
    return task;
}

fn phaseFact(a: std.mem.Allocator, source: idx.Row) !t.Settlement {
    const bytes = try snapshotBytes(a, source);
    return .{
        .reference = .{
            .task = source.input.task,
            .revision = source.input.revision,
            .digest = idx.digest(bytes),
        },
        .owner_snapshot = .{ .bytes = bytes },
        .kind = .phase,
        .accounting = source.owner_snapshot.?.accounting,
    };
}

fn consumingChain(a: std.mem.Allocator, length: usize, initial: t.Head) ![]idx.Row {
    const rows = try a.alloc(idx.Row, length + 1);
    rows[0] = try row(a, 1, .{ .genesis = fixture.genesis() }, .{ .genesis = initial });
    var previous = initial;
    for (1..rows.len) |sequence| {
        const operation = try std.fmt.allocPrint(a, "chain-{d}", .{sequence});
        var input = step(previous, ref(rows[sequence - 1]), operation);
        if (sequence > 1)
            input.facts.items = try a.dupe(t.Settlement, &.{try phaseFact(a, rows[sequence - 1])});
        var output = successor(input);
        output.step.head.consumed.items = try a.alloc(t.RevisionReference, input.facts.items.len);
        for (@constCast(output.step.head.consumed.items), input.facts.items) |*used, fact|
            used.* = fact.reference;
        rows[sequence] = try rowId(a, chainTask(sequence), .{ .step = input }, output);
        previous = output.step.head;
    }
    return rows;
}

test "index rebuild links a consuming chain by predecessor and rejects distant repeated cuts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try consumingChain(a, 96, head());
    std.mem.reverse(idx.Row, rows);
    var index = try idx.Index.init(Native, std.testing.allocator, rows, &.{});
    defer index.deinit();
    const obligation = index.obligation(@splat(1)).?;
    try std.testing.expectEqual(97, obligation.chain.len);
    try std.testing.expectEqual(96, index.head(obligation).sequence);
    try std.testing.expectEqual(95, obligation.settlements.count());
    std.mem.reverse(idx.Row, rows);
    var repeated = step(index.head(obligation), ref(rows[96]), "chain-repeat");
    repeated.facts.items = try a.dupe(t.Settlement, &.{try phaseFact(a, rows[2])});
    var output = successor(repeated);
    output.step.head.consumed.items = &.{repeated.facts.items[0].reference};
    const extended = try a.alloc(idx.Row, rows.len + 1);
    @memcpy(extended[0..rows.len], rows);
    extended[rows.len] = try rowId(a, chainTask(97), .{ .step = repeated }, output);
    try std.testing.expectError(
        error.InvalidPreviousSettlement,
        idx.Index.init(Native, std.testing.allocator, extended, &.{}),
    );
    var initial = head();
    initial.consumed.items = &.{.{ .task = chainTask(89), .revision = 5, .digest = @splat(0) }};
    try std.testing.expectError(
        error.DuplicateConsumption,
        idx.Index.init(Native, std.testing.allocator, try consumingChain(a, 96, initial), &.{}),
    );
}

test "index rebuild orders shuffled heads and pending directives without task completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first = step(head(), ref(initial), "step-1");
    const completed = try row(a, 2, .{ .step = first }, successor(first));
    const second = step(successor(first).step.head, ref(completed), "step-2");
    const next = try row(a, 3, .{ .step = second }, successor(second));
    const pause = directive("pause", 1, null, .{ .pause = {} });
    const paused = try row(a, 4, .{ .directive = pause }, null);
    const resume_value = directive("resume", 2, inputRef(paused), .{ .@"resume" = {} });
    const resumed = try row(a, 5, .{ .directive = resume_value }, null);
    var index = try idx.Index.init(
        Native,
        std.testing.allocator,
        &.{ next, resumed, completed, paused, initial },
        &.{},
    );
    defer index.deinit();
    const state = index.obligation(@splat(1)).?;
    try std.testing.expectEqual(2, index.head(state).sequence);
    try std.testing.expectEqual(t.Mode.active, state.folded_mode);
    try std.testing.expectEqual(t.Mode.paused, state.effective_mode);
    try std.testing.expect(!state.ordinaryDispatch());
    try std.testing.expectEqualSlices(usize, &.{ 3, 1 }, state.directives);
}

test "index treats one local transfer marker as a terminal namespace fence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const marker: t.Input = .{ .transfer = .{ .envelope = envelope("transfer") } };
    const first = try row(a, 4, marker, markerOutput(marker));
    var index = try idx.Index.init(Native, std.testing.allocator, &.{ first, initial }, &.{});
    defer index.deinit();
    try std.testing.expect(index.transferred());
    try std.testing.expectEqualDeep(first.input.task, index.records[index.transfer_marker.?].task);
    var other_input = marker;
    other_input.transfer.envelope.operation = .{ .bytes = "transfer-again" };
    const second = try row(a, 5, other_input, null);
    try std.testing.expectError(
        error.DuplicateTransferMarker,
        idx.Index.init(Native, std.testing.allocator, &.{ first, second, initial }, &.{}),
    );
    var remote = marker;
    remote.transfer.envelope.origin = .{ .derived = .{ .predecessor = ref(initial) } };
    const derived = try row(a, 6, remote, null);
    try std.testing.expectError(
        error.TransferLocalOnly,
        idx.Index.init(Native, std.testing.allocator, &.{ derived, initial }, &.{}),
    );
    var changed = marker;
    changed.transfer.envelope.stable_request = @splat(3);
    const mismatched = try row(a, 7, marker, .{ .transfer = changed.transfer });
    try std.testing.expectError(
        error.TransferMarkerMismatch,
        idx.Index.init(Native, std.testing.allocator, &.{ mismatched, initial }, &.{}),
    );
}

fn markerOutput(input: t.Input) t.Output {
    return .{ .transfer = input.transfer };
}

test "index resume permits dispatch only after folding the directive chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const pause = directive("pause", 1, null, .{ .pause = {} });
    const paused = try row(a, 4, .{ .directive = pause }, null);
    const resume_value = directive("resume", 2, inputRef(paused), .{ .@"resume" = {} });
    const resumed = try row(a, 5, .{ .directive = resume_value }, null);
    var first = step(head(), ref(initial), "fold");
    first.directives.items = &.{
        .{ .reference = inputRef(paused), .value = pause },
        .{ .reference = inputRef(resumed), .value = resume_value },
    };
    const completed = try row(a, 2, .{ .step = first }, successor(first));
    var index = try idx.Index.init(
        Native,
        std.testing.allocator,
        &.{ resumed, completed, paused, initial },
        &.{},
    );
    defer index.deinit();
    try std.testing.expect(index.obligation(@splat(1)).?.ordinaryDispatch());
}

test "index rejects directive ordinal gaps duplicate ordinals and wrong predecessor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const gap = try row(a, 3, .{ .directive = directive("gap", 2, null, .{ .pause = {} }) }, null);
    try std.testing.expectError(
        error.DirectiveGapOrConflict,
        idx.Index.init(Native, std.testing.allocator, &.{ gap, initial }, &.{}),
    );
    const first = try row(
        a,
        2,
        .{ .directive = directive("first", 1, null, .{ .pause = {} }) },
        null,
    );
    const duplicate = try row(
        a,
        4,
        .{ .directive = directive("duplicate", 1, null, .{ .cancel = {} }) },
        null,
    );
    try std.testing.expectError(
        error.DirectiveGapOrConflict,
        idx.Index.init(Native, std.testing.allocator, &.{ initial, first, duplicate }, &.{}),
    );
    try std.testing.expectError(
        error.DirectivePredecessorMismatch,
        idx.Index.init(Native, std.testing.allocator, &.{ initial, first, gap }, &.{}),
    );
}

test "index verifies exact retained JSON digest and rejects copied contract result bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var initial = try genesis(a);
    const valid = initial;
    initial.result.?.bytes = try std.mem.concat(a, u8, &.{ valid.result.?.bytes, " " });
    try std.testing.expectError(
        error.DigestMismatch,
        idx.Index.init(Native, std.testing.allocator, &.{initial}, &.{}),
    );
    initial.result.?.digest = idx.digest(initial.result.?.bytes);
    var index = try idx.Index.init(Native, std.testing.allocator, &.{initial}, &.{});
    defer index.deinit();
    try std.testing.expectEqual(initial.result.?.digest, index.reference(0).digest);
    try std.testing.expect(!std.meta.eql(valid.result.?.digest, index.reference(0).digest));
    initial.result.?.bytes = try c.encodeOwned(t.Output, a, .{ .genesis = head() });
    initial.result.?.digest = idx.digest(initial.result.?.bytes);
    initial.result.?.encoding = .contract;
    try std.testing.expectError(
        error.UnsupportedEncoding,
        idx.Index.init(Native, std.testing.allocator, &.{initial}, &.{}),
    );
}

test "index fences conflicting successors missing heads and copied bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first = step(head(), ref(initial), "first");
    const one = try row(a, 2, .{ .step = first }, successor(first));
    var branch = first;
    branch.envelope = envelope("branch");
    const two = try row(a, 3, .{ .step = branch }, successor(branch));
    try std.testing.expectError(
        error.AttemptGapOrConflict,
        idx.Index.init(Native, std.testing.allocator, &.{ two, initial, one }, &.{}),
    );
    branch.predecessor.task = @splat(100);
    const missing = try row(a, 3, .{ .step = branch }, successor(branch));
    try std.testing.expectError(
        error.OrphanStep,
        idx.Index.init(Native, std.testing.allocator, &.{ initial, missing }, &.{}),
    );
    branch = first;
    branch.previous.clock_ms += 1;
    const forged = try row(a, 3, .{ .step = branch }, successor(branch));
    try std.testing.expectError(
        error.CopiedHeadMismatch,
        idx.Index.init(Native, std.testing.allocator, &.{ initial, forged }, &.{}),
    );
}

test "index retains late superseded result without selecting it as a head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first = step(head(), ref(initial), "first");
    const late = try row(a, 2, .{ .step = first }, successor(first));
    var replacement = first;
    replacement.envelope = envelope("replacement");
    replacement.attempt = 1;
    replacement.supersession = .{
        .input = inputRef(late),
        .attempt = 0,
        .cause = .control,
        .cancellation = .{
            .operation = .{ .bytes = "cancel-first" },
            .task = @splat(2),
            .bytes = .{ .bytes = "owner-retained-receipt" },
        },
    };
    const next = try row(a, 3, .{ .step = replacement }, successor(replacement));
    const receipt: idx.Cancellation = .{
        .task = @splat(2),
        .operation = "cancel-first",
        .revision = 4,
        .bytes = "owner-retained-receipt",
    };
    try std.testing.expectError(
        error.MissingCancellationReceipt,
        idx.Index.init(Native, std.testing.allocator, &.{ initial, next, late }, &.{}),
    );
    var index = try idx.Index.init(
        Native,
        std.testing.allocator,
        &.{ initial, next, late },
        &.{receipt},
    );
    defer index.deinit();
    try std.testing.expect(index.record(@splat(2)).?.superseded);
    try std.testing.expect(!index.record(@splat(2)).?.selected);
    try std.testing.expectEqual(1, index.head(index.obligation(@splat(1)).?).attempt);
    var forged = receipt;
    forged.bytes = "forged";
    try std.testing.expectError(
        error.InvalidCancellationReceipt,
        idx.Index.init(Native, std.testing.allocator, &.{ initial, next, late }, &.{forged}),
    );
}

fn allocationProbe(a: std.mem.Allocator, rows: []const idx.Row) !void {
    var index = try idx.Index.init(Native, a, rows, &.{});
    defer index.deinit();
    try std.testing.expect(index.obligation(@splat(1)).?.ordinaryDispatch());
}

test "index rebuild allocation failures release all decoded ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const initial = try genesis(arena.allocator());
    const rows = [_]idx.Row{initial};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{&rows});
}

const ReceiptValue = struct {
    task: t.Id,
    revision: u64,
    client_operation_id: t.OperationId,
    method: enum { submit, cancel },
    disposition: enum { accepted, cancellation_requested },
};
const ReceiptOwner = struct {
    value: ReceiptValue,
    calls: u32 = 0,

    pub fn operationLookup(
        self: *@This(),
        a: std.mem.Allocator,
        _: []const u8,
    ) !?c.Decoded(ReceiptValue) {
        self.calls += 1;
        const bytes = try c.encodeOwned(ReceiptValue, a, self.value);
        defer a.free(bytes);
        return try c.decodeOwned(ReceiptValue, a, bytes);
    }
};

test "index cancellation evidence is read independently and authenticates method task and bytes" {
    const a = std.testing.allocator;
    var owner: ReceiptOwner = .{ .value = .{
        .task = @splat(2),
        .revision = 4,
        .client_operation_id = .{ .bytes = "cancel-old" },
        .method = .cancel,
        .disposition = .cancellation_requested,
    } };
    const bytes = try c.encodeOwned(ReceiptValue, a, owner.value);
    defer a.free(bytes);
    const requested: t.ControlReceipt = .{
        .task = @splat(2),
        .operation = .{ .bytes = "cancel-old" },
        .bytes = .{ .bytes = bytes },
    };
    var accepted = try idx.readCancellation(&owner, a, requested);
    defer accepted.deinit();
    try std.testing.expectEqualSlices(u8, bytes, accepted.value.bytes);
    try std.testing.expectEqual(1, owner.calls);
    owner.value.method = .submit;
    try std.testing.expectError(
        error.InvalidCancellationReceipt,
        idx.readCancellation(&owner, a, requested),
    );
    owner.value.method = .cancel;
    owner.value.task = @splat(99);
    try std.testing.expectError(
        error.InvalidCancellationReceipt,
        idx.readCancellation(&owner, a, requested),
    );
    owner.value.task = @splat(2);
    owner.value.revision = 5;
    try std.testing.expectError(
        error.InvalidCancellationReceipt,
        idx.readCancellation(&owner, a, requested),
    );
}

test "index retains pending genesis and pending cancel transfer fences survive rebuild" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pending = try row(a, 1, .{ .genesis = fixture.genesis() }, null);
    var early = try idx.Index.init(Native, std.testing.allocator, &.{pending}, &.{});
    defer early.deinit();
    try std.testing.expect(early.record(@splat(1)) != null);
    try std.testing.expect(early.obligation(@splat(1)) == null);
    const initial = try genesis(a);
    for ([_]t.DirectiveBody{ .{ .cancel = {} }, .{ .transfer = {} } }) |body| {
        const admitted = try row(a, 2, .{ .directive = directive("control", 1, null, body) }, null);
        var restored = try idx.Index.init(
            Native,
            std.testing.allocator,
            &.{ admitted, initial },
            &.{},
        );
        defer restored.deinit();
        try std.testing.expect(!restored.obligation(@splat(1)).?.ordinaryDispatch());
        try std.testing.expectEqual(t.Mode.active, restored.obligation(@splat(1)).?.folded_mode);
    }
}

test "index rejects an imported head without a verified continuity manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var input = fixture.genesis();
    input.imported = .{
        .source = .{ .task = @splat(9), .digest = @splat(9) },
        .head = head(),
    };
    var imported = head();
    imported.predecessor = input.imported.?.source;
    const initial = try row(a, 1, .{ .genesis = input }, .{ .genesis = imported });
    try std.testing.expectError(
        error.UnprovenContinuityImport,
        idx.Index.init(Native, std.testing.allocator, &.{initial}, &.{}),
    );
}

test "index refuses a head that folds pause without applying its restriction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const pause = directive("pause", 1, null, .{ .pause = {} });
    const admitted = try row(a, 4, .{ .directive = pause }, null);
    var first = step(head(), ref(initial), "fold");
    first.directives.items = &.{.{ .reference = inputRef(admitted), .value = pause }};
    var result = successor(first);
    result.step.head.mode = .active;
    const completed = try row(a, 2, .{ .step = first }, result);
    try std.testing.expectError(
        error.InvalidControlFold,
        idx.Index.init(Native, std.testing.allocator, &.{ completed, admitted, initial }, &.{}),
    );
}

test "index rejects duplicated lineage even before either genesis finishes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try row(a, 1, .{ .genesis = fixture.genesis() }, null);
    var second = fixture.genesis();
    second.envelope = envelope("second-genesis");
    const two = try row(a, 2, .{ .genesis = second }, null);
    try std.testing.expectError(
        error.DuplicateLineage,
        idx.Index.init(Native, std.testing.allocator, &.{ two, one }, &.{}),
    );
}

test "index rejects unrelated batch bytes beside an authentic reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first = step(head(), ref(initial), "check");
    var checked = successor(first);
    checked.step.batch = .{
        .repository = fixture.specification().repository,
        .sequence = 1,
        .epoch = 0,
        .base = @splat('a'),
        .tip = @splat('b'),
        .coverage = .complete,
        .commits = .{ .items = &.{} },
        .raw_evidence = .{ .items = &.{} },
        .acquired_ms = 100,
        .provider_date = null,
    };
    const completed = try row(a, 2, .{ .step = first }, checked);
    var second = step(checked.step.head, ref(completed), "render");
    var unrelated = checked.step.batch.?;
    unrelated.tip = @splat('c');
    second.batches.items = &.{.{ .reference = ref(completed), .value = unrelated }};
    const rendering = try row(a, 3, .{ .step = second }, null);
    try std.testing.expectError(
        error.CopiedBatchMismatch,
        idx.Index.init(Native, std.testing.allocator, &.{ rendering, completed, initial }, &.{}),
    );
}

test "index copied batches must be the contiguous outstanding prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u64{ 1, 2 }) |sequence| {
        const initial = try genesis(a);
        const first = step(head(), ref(initial), "check");
        var checked = successor(first);
        checked.step.head.observed = .{ .sequence = sequence, .epoch = 0, .tip = @splat('b') };
        checked.step.batch = .{
            .repository = fixture.specification().repository,
            .sequence = sequence,
            .epoch = 0,
            .base = @splat('a'),
            .tip = @splat('b'),
            .coverage = .complete,
            .commits = .{ .items = &.{.{ .oid = @splat('b'), .message = .{ .bytes = "change" } }} },
            .raw_evidence = .{ .items = &.{} },
            .acquired_ms = 100,
            .provider_date = null,
        };
        const completed = try row(a, 2, .{ .step = first }, checked);
        var next = step(checked.step.head, ref(completed), "render");
        next.batches.items = &.{.{ .reference = ref(completed), .value = checked.step.batch.? }};
        const rendering = try row(a, 3, .{ .step = next }, null);
        if (sequence == 1) {
            var index = try idx.Index.init(
                Native,
                std.testing.allocator,
                &.{ rendering, completed, initial },
                &.{},
            );
            defer index.deinit();
            const backlog = try @import("../native/materialize.zig").backlog(
                a,
                &index,
                index.obligation(initial.input.task).?,
            );
            try std.testing.expectEqual(1, backlog.untold_batches);
            try std.testing.expectEqualDeep(ref(completed), backlog.oldest.?.reference);
            try std.testing.expectEqual(1, backlog.oldest.?.sequence);
            try std.testing.expectEqual(100, backlog.oldest.?.acquired_ms);
            try std.testing.expectEqual(t.Coverage.complete, backlog.oldest.?.coverage);
        } else {
            try std.testing.expectError(
                error.BatchCoverageGap,
                idx.Index.init(
                    Native,
                    std.testing.allocator,
                    &.{ rendering, completed, initial },
                    &.{},
                ),
            );
            var index = try idx.Index.init(
                Native,
                std.testing.allocator,
                &.{ completed, initial },
                &.{},
            );
            defer index.deinit();
            const backlog = try @import("../native/materialize.zig").backlog(
                std.testing.allocator,
                &index,
                index.obligation(initial.input.task).?,
            );
            try std.testing.expectEqual(2, backlog.untold_batches);
            try std.testing.expect(backlog.oldest == null);
        }
    }
}

test "index materialization freezes ordered controls and owner facts into a valid successor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first_input = step(head(), ref(initial), "first");
    const first = try row(a, 2, .{ .step = first_input }, successor(first_input));
    const pause = directive("materialize-pause", 1, null, .{ .pause = {} });
    const pending = try row(a, 3, .{ .directive = pause }, null);
    var index = try idx.Index.init(Native, a, &.{ pending, first, initial }, &.{});
    defer index.deinit();
    const materialize = @import("../native/materialize.zig");
    var frozen = try materialize.step(a, &index, initial.input.task, 900, null);
    defer frozen.deinit();
    try std.testing.expectEqualDeep(ref(first), frozen.value.predecessor);
    try std.testing.expectEqual(1, frozen.value.directives.items.len);
    try std.testing.expectEqualDeep(inputRef(pending), frozen.value.directives.items[0].reference);
    try std.testing.expectEqual(1, frozen.value.facts.items.len);
    try std.testing.expectEqualDeep(first.input.task, frozen.value.facts.items[0].reference.task);
    const admitted = try row(a, 4, .{ .step = frozen.value }, null);
    var rebuilt = try idx.Index.init(Native, a, &.{ admitted, initial, first, pending }, &.{});
    defer rebuilt.deinit();
    try std.testing.expectEqual(0, rebuilt.obligation(initial.input.task).?.eligible.?);
    try std.testing.expect(!rebuilt.obligation(initial.input.task).?.ordinaryDispatch());
    try std.testing.expectError(
        error.LiveStep,
        materialize.step(a, &rebuilt, @splat(1), 901, null),
    );
}

test "index materialization accounts changed revisions without repeating a consumed cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first_input = step(head(), ref(initial), "phase-first");
    const first = try row(a, 2, .{ .step = first_input }, successor(first_input));
    var index = try idx.Index.init(Native, a, &.{ first, initial }, &.{});
    defer index.deinit();
    const materialize = @import("../native/materialize.zig");
    var next = try materialize.step(a, &index, @splat(1), 900, null);
    defer next.deinit();
    var second_output = successor(next.value);
    second_output.step.head.consumed = .{ .items = &.{next.value.facts.items[0].reference} };
    const second = try row(a, 3, .{ .step = next.value }, second_output);
    var rebuilt = try idx.Index.init(Native, a, &.{ second, initial, first }, &.{});
    defer rebuilt.deinit();
    var last = try materialize.step(a, &rebuilt, @splat(1), 1000, null);
    defer last.deinit();
    try std.testing.expectEqual(1, last.value.facts.items.len);
    try std.testing.expectEqualDeep(second.input.task, last.value.facts.items[0].reference.task);
    try std.testing.expectEqual(
        @as(?t.RevisionReference, null),
        last.value.facts.items[0].previous_reference,
    );
}

fn capturedBatch(a: std.mem.Allocator, sequence: u64) !t.Batch {
    const body = try a.alloc(u8, 20 * 1024);
    @memset(body, 'x');
    const evidence = try a.dupe(t.ReadEvidence, &.{.{
        .request_digest = @splat(9),
        .target = .{ .bytes = "https://api.github.com/repositories/1/compare/a...b" },
        .status = 200,
        .body = .{ .bytes = body },
        .body_digest = @splat(8),
        .captured_ms = 100,
        .provider_date = null,
        .request_id = null,
        .link = null,
        .etag = null,
        .retry_after = null,
        .rate_remaining = null,
        .rate_reset = null,
    }});
    const commits = try a.dupe(t.Commit, &.{.{
        .oid = @splat('a' + @as(u8, @intCast(sequence))),
        .message = .{ .bytes = "small change" },
    }});
    return .{
        .repository = fixture.specification().repository,
        .sequence = sequence,
        .epoch = 0,
        .base = @splat('a' + @as(u8, @intCast(sequence - 1))),
        .tip = @splat('a' + @as(u8, @intCast(sequence))),
        .coverage = .complete,
        .commits = .{ .items = commits },
        .raw_evidence = .{ .items = evidence },
        .acquired_ms = 100,
        .provider_date = null,
    };
}

fn capturedBacklog(a: std.mem.Allocator, bound: u64) !usize {
    var rows: [9]idx.Row = undefined;
    var previous = head();
    previous.specification.policies.render_input_bytes = bound;
    var genesis_input = fixture.genesis();
    genesis_input.specification.policies.render_input_bytes = bound;
    rows[0] = try row(a, 1, .{ .genesis = genesis_input }, .{ .genesis = previous });
    for (1..rows.len) |sequence| {
        const operation = try std.fmt.allocPrint(a, "captured-check-{d}", .{sequence});
        const input = step(previous, ref(rows[sequence - 1]), operation);
        var output = successor(input);
        const batch = try capturedBatch(a, sequence);
        output.step.head.observed = .{ .sequence = sequence, .epoch = 0, .tip = batch.tip };
        output.step.batch = batch;
        rows[sequence] = try row(a, @intCast(sequence + 1), .{ .step = input }, output);
        previous = output.step.head;
    }
    var index = try idx.Index.init(Native, a, &rows, &.{});
    defer index.deinit();
    const materialize = @import("../native/materialize.zig");
    var frozen = try materialize.step(a, &index, rows[0].input.task, 900, null);
    defer frozen.deinit();
    const batches = frozen.value.batches;
    try std.testing.expect(batches.items.len > 0);
    try std.testing.expectEqual(1, batches.items[0].value.sequence);
    const wire = try c.encodeOwned(@TypeOf(batches), a, batches);
    try std.testing.expect(batches.items.len == 1 or wire.len <= bound);
    return batches.items.len;
}

test "index materialization bounds an ordinary backlog by context and step input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(3, try capturedBacklog(a, 64 * 1024));
    try std.testing.expectEqual(8, try capturedBacklog(a, 256 * 1024));
    try std.testing.expectEqual(1, try capturedBacklog(a, 1024));
}

test "index dispatch gate fences a selected step immediately after restrictive admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    var input = step(head(), ref(initial), "dispatch-step");
    input.fold_only = false;
    const live = try row(a, 2, .{ .step = input }, null);
    const gate = @import("../native/eligibility.zig");
    const request: Native.tasks.DispatchRequest = .{
        .task = live.input.task,
        .identity = @splat(7),
        .kind = .acquisition,
    };
    var ordinary = try idx.Index.init(Native, a, &.{ live, initial }, &.{});
    defer ordinary.deinit();
    try std.testing.expect(gate.permits(&ordinary, request));
    const pause = directive("pause-before-dispatch", 1, null, .{ .pause = {} });
    const pending = try row(a, 3, .{ .directive = pause }, null);
    var restricted = try idx.Index.init(Native, a, &.{ pending, live, initial }, &.{});
    defer restricted.deinit();
    try std.testing.expect(!gate.permits(&restricted, request));
    try std.testing.expectEqual(
        t.Mode.active,
        restricted.head(restricted.obligation(initial.input.task).?).mode,
    );
    var unsupported = request;
    unsupported.kind = .placement_move;
    try std.testing.expect(!gate.permits(&ordinary, unsupported));
}

test "index replacement binds current cancelled admission and preserves predecessor sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const old_input = step(head(), ref(initial), "old-attempt");
    const old = try row(a, 2, .{ .step = old_input }, null);
    const pending = try row(
        a,
        3,
        .{ .directive = directive("pause-replace", 1, null, .{ .pause = {} }) },
        null,
    );
    var index = try idx.Index.init(Native, a, &.{ pending, old, initial }, &.{});
    defer index.deinit();
    const materialize = @import("../native/materialize.zig");
    var supersession: t.Supersession = .{
        .input = inputRef(old),
        .attempt = 0,
        .cancellation = .{
            .task = old.input.task,
            .operation = .{ .bytes = "cancel-old" },
            .bytes = .{ .bytes = "retained-receipt" },
        },
        .cause = .control,
    };
    var replacement = try materialize.replacement(a, &index, @splat(1), 500, null, supersession);
    defer replacement.deinit();
    try std.testing.expectEqualDeep(old_input.predecessor, replacement.value.predecessor);
    try std.testing.expectEqual(old_input.sequence, replacement.value.sequence);
    try std.testing.expectEqual(1, replacement.value.attempt);
    try std.testing.expect(replacement.value.fold_only);
    try std.testing.expectEqual(1, replacement.value.directives.items.len);
    const admitted = try row(a, 4, .{ .step = replacement.value }, null);
    const cancellation: idx.Cancellation = .{
        .task = old.input.task,
        .operation = supersession.cancellation.operation.bytes,
        .bytes = supersession.cancellation.bytes.bytes,
        .revision = old.input.revision,
    };
    var rebuilt = try idx.Index.init(
        Native,
        a,
        &.{ admitted, old, pending, initial },
        &.{cancellation},
    );
    defer rebuilt.deinit();
    try std.testing.expect(rebuilt.record(old.input.task).?.superseded);
    try std.testing.expectEqual(0, rebuilt.obligation(@splat(1)).?.eligible.?);
    supersession.input.digest[0] ^= 1;
    try std.testing.expectError(
        error.StaleSupersession,
        materialize.replacement(a, &index, @splat(1), 501, null, supersession),
    );
}

fn conversation(a: std.mem.Allocator, id: u8, ordinal: u64, text: []const u8) !idx.Row {
    return row(a, id, .{ .turn = .{
        .envelope = envelope(text),
        .ordinal = ordinal,
        .target = @splat(1),
        .text = .{ .bytes = text },
        .context = .{ .bytes = "" },
        .context_references = .{ .items = &.{} },
        .attempt = 0,
    } }, .{
        .turn = .{
            .reply = .{ .bytes = "unconfirmed assistant text" },
            .proposals = .{ .items = &.{} },
        },
    });
}

test "index dialogue context orders admitted turns and owns its bounded provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const old = try conversation(a, 3, 1, "older operator text");
    const recent = try conversation(a, 2, 2, "newer operator text");
    var index = try idx.Index.init(Native, a, &.{ old, initial, recent }, &.{});
    const dialogue = @import("../native/dialogue.zig");
    var context = try dialogue.materialize(std.testing.allocator, &index, .{
        .target = @splat(1),
        .recent_turns = 1,
    });
    index.deinit();
    defer context.deinit();
    try std.testing.expectEqual(3, context.value.next_ordinal);
    try std.testing.expectEqual(2, context.value.references.items.len);
    try std.testing.expect(
        std.mem.indexOf(u8, context.value.text.bytes, "newer operator text") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, context.value.text.bytes, "older operator text") == null,
    );
    try std.testing.expectEqual(5, context.value.offers.items.len);
    try std.testing.expectEqual(
        fixture.specification().revision,
        context.value.expected_revision.?,
    );
}

test "index dialogue context leaves superseded turn attempts out of recent turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    const first = try conversation(a, 2, 1, "first operator text");
    const second = try conversation(a, 3, 2, "second operator text");
    const replaced = try conversation(a, 4, 3, "replaced attempt text");
    var index = try idx.Index.init(Native, a, &.{ initial, first, second, replaced }, &.{});
    defer index.deinit();
    index.records[index.tasks.get(replaced.input.task).?].superseded = true;
    const dialogue = @import("../native/dialogue.zig");
    var context = try dialogue.materialize(std.testing.allocator, &index, .{
        .target = @splat(1),
        .recent_turns = 2,
    });
    defer context.deinit();
    const text = context.value.text.bytes;
    try std.testing.expect(std.mem.indexOf(u8, text, "replaced attempt text") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second operator text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first operator text") != null);
    try std.testing.expectEqual(4, context.value.next_ordinal);
}

fn evidenceContext(a: std.mem.Allocator, mode: t.Mode) ![]const u8 {
    const initial = try genesis(a);
    const input = step(head(), ref(initial), "evidence-step");
    var output = successor(input);
    const batch = try capturedBatch(a, 1);
    output.step.head.observed = .{ .sequence = 1, .epoch = 0, .tip = batch.tip };
    output.step.batch = batch;
    const stepped = try row(a, 2, .{ .step = input }, output);
    var index = try idx.Index.init(Native, a, &.{ initial, stepped }, &.{});
    defer index.deinit();
    index.records[index.tasks.get(stepped.input.task).?].result.?.step.head.mode = mode;
    try std.testing.expectEqual(mode, index.head(index.obligation(@splat(1)).?).mode);
    const context = try @import("../native/dialogue.zig").materialize(a, &index, .{
        .target = null,
    });
    return context.value.text.bytes;
}

test "index dialogue context omits source evidence of finished obligations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const active = try evidenceContext(a, .active);
    try std.testing.expect(std.mem.indexOf(u8, active, "source_evidence") != null);
    for ([_]t.Mode{ .cancelled, .transferred }) |mode| {
        const finished = try evidenceContext(a, mode);
        try std.testing.expect(std.mem.indexOf(u8, finished, "source_evidence") == null);
    }
}

test "index dialogue context reports omitted whole records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    var index = try idx.Index.init(Native, a, &.{initial}, &.{});
    defer index.deinit();
    const dialogue = @import("../native/dialogue.zig");
    var context = try dialogue.materialize(std.testing.allocator, &index, .{
        .target = @splat(1),
        .context_bytes = 256,
    });
    defer context.deinit();
    try std.testing.expect(context.value.text.bytes.len <= 256);
    try std.testing.expectEqual(0, context.value.references.items.len);
    try std.testing.expect(
        std.mem.indexOf(u8, context.value.text.bytes, "\"omitted_records\":1") != null,
    );
}

test "index driver admits a clock regression before the stale due instant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try genesis(a);
    var index = try idx.Index.init(Native, a, &.{initial}, &.{});
    defer index.deinit();
    const obligation = index.obligation(@splat(1)).?;
    const driver = @import("../native/driver.zig");
    try std.testing.expect(!driver.needsStep(&index, obligation, 0));
    try std.testing.expect(driver.needsStep(&index, obligation, -600_000));
    try std.testing.expect(driver.needsStep(&index, obligation, std.math.minInt(i64)));
}
