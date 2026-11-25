const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");
const transfer_marker = @import("transfer_marker.zig");
const admission = @import("admission.zig");

pub const Encoding = enum { contract, json };
pub const Value = struct {
    task: t.Id,
    revision: u64,
    digest: t.Digest,
    schema_id: []const u8,
    encoding: Encoding,
    bytes: []const u8,
};
pub const Row = struct {
    input: Value,
    result: ?Value = null,
    owner_snapshot: ?retained.Snapshot = null,
    owner_evidence: ?retained.Evidence = null,
};
pub const Cancellation = struct {
    operation: []const u8,
    task: t.Id,
    revision: u64,
    bytes: []const u8,
};
pub const Record = struct {
    task: t.Id,
    revision: u64,
    input_digest: t.Digest,
    result_digest: ?t.Digest,
    input: t.Input,
    result: ?t.Output,
    superseded: bool = false,
    selected: bool = false,
    owner_snapshot: ?retained.Snapshot = null,
    owner_evidence: ?retained.Evidence = null,
};
pub const Fault = struct { reason: []const u8, at_ms: i64, failures: u32, retry_ms: i64 };
pub const Obligation = struct {
    task: t.Id,
    chain: []const usize,
    directives: []const usize,
    eligible: ?usize,
    folded_mode: t.Mode,
    effective_mode: t.Mode,
    controls_pending: bool,
    settlements: std.AutoHashMapUnmanaged(t.Id, t.Settlement) = .empty,
    fault: ?Fault = null,

    pub fn ordinaryDispatch(self: Obligation) bool {
        return self.effective_mode == .active and !self.controls_pending;
    }
};
pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    records: []Record,
    storage: std.ArrayList(Record) = .empty,
    obligations: []Obligation,
    tasks: std.AutoHashMapUnmanaged(t.Id, usize),
    namespace: ?t.Digest = null,
    operations: std.StringHashMapUnmanaged(usize) = .empty,
    lineages: std.AutoHashMapUnmanaged(t.Digest, usize) = .empty,
    continuity_import: ?continuity.ImportView = null,
    transfer_marker: ?usize = null,

    pub fn transferred(self: *const Index) bool {
        return self.transfer_marker != null;
    }

    pub fn deinit(self: *Index) void {
        self.storage.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn record(self: *const Index, id: t.Id) ?*const Record {
        return &self.records[self.tasks.get(id) orelse return null];
    }

    pub fn obligation(self: *const Index, id: t.Id) ?*const Obligation {
        for (self.obligations) |*item| if (std.meta.eql(item.task, id)) return item;
        return null;
    }

    pub fn head(self: *const Index, item: *const Obligation) t.Head {
        return recordHead(self.records[item.chain[item.chain.len - 1]]).?;
    }

    pub fn reference(self: *const Index, position: usize) t.Reference {
        const item = self.records[position];
        return .{ .task = item.task, .digest = item.result_digest.? };
    }

    pub fn init(
        comptime Native: type,
        a: std.mem.Allocator,
        rows: []const Row,
        cancellations: []const Cancellation,
    ) !Index {
        var self = empty(a);
        errdefer self.deinit();
        try self.storage.ensureTotalCapacityPrecise(a, rows.len);
        var temporary = std.heap.ArenaAllocator.init(a);
        defer temporary.deinit();
        for (rows) |row| {
            _ = try self.add(Native, temporary.allocator(), row, null);
            if (!temporary.reset(.retain_capacity)) return error.OutOfMemory;
        }
        try self.finish(cancellations);
        return self;
    }

    fn empty(a: std.mem.Allocator) Index {
        return .{
            .arena = std.heap.ArenaAllocator.init(a),
            .records = &.{},
            .obligations = &.{},
            .tasks = .empty,
        };
    }

    fn add(
        self: *Index,
        comptime Native: type,
        scratch: std.mem.Allocator,
        row: Row,
        snapshot_bytes: ?[]const u8,
    ) !*const Record {
        const a = self.arena.allocator();
        const decoded = try decodeRow(Native, a, scratch, row, snapshot_bytes);
        const existing = try self.tasks.getOrPut(a, row.input.task);
        if (existing.found_existing) return error.DuplicateTask;
        errdefer _ = self.tasks.remove(row.input.task);
        existing.value_ptr.* = self.records.len;
        try self.storage.append(self.arena.child_allocator, decoded);
        self.records = self.storage.items;
        return &self.records[self.records.len - 1];
    }

    fn finish(self: *Index, cancellations: []const Cancellation) !void {
        const scratch = self.arena.allocator();
        var obligations: std.ArrayList(Obligation) = .empty;
        try validateOperations(self, scratch);
        self.transfer_marker = try transfer_marker.inspect(scratch, self);
        self.continuity_import = try continuity.prepareImport(scratch, self);
        try continuity.validateImports(scratch, self);
        try validateTurns(self, cancellations);
        const successors = try stepSuccessors(self);
        for (self.records, 0..) |item, position| {
            if (item.input != .genesis or recordHead(item) == null) continue;
            if (self.lineages.get(item.input.genesis.lineage).? != position) continue;
            try obligations.append(
                scratch,
                try buildObligation(self, position, &successors, cancellations),
            );
        }
        self.obligations = try obligations.toOwnedSlice(scratch);
        for (self.records) |item| switch (item.input) {
            .step => |step| if (self.obligation(step.obligation) == null)
                return error.MissingGenesis,
            .directive => |directive| if (self.obligation(directive.obligation) == null)
                return error.MissingGenesis,
            else => {},
        };
    }
};

pub fn rebuild(service: anytype, a: std.mem.Allocator, page_limit: u32) !Index {
    if (page_limit == 0) return error.InvalidPageLimit;
    var index = Index.empty(a);
    errdefer index.deinit();
    var receipts = std.heap.ArenaAllocator.init(a);
    defer receipts.deinit();
    var cancellations: std.ArrayList(Cancellation) = .empty;
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    var after: ?t.Id = null;
    var exhausted = false;
    while (!exhausted) {
        var page = try service.taskPage(a, after, page_limit);
        defer page.deinit();
        for (page.tasks) |task| {
            const scratch = temporary.allocator();
            const loaded = try retained.load(service, scratch, task, page_limit);
            const item = try index.add(
                @import("protean_native"),
                scratch,
                retained.row(loaded),
                loaded.snapshot.bytes,
            );
            const replacement = switch (item.input) {
                .step => |step| if (step.supersession) |x| x.cancellation else null,
                .turn => |turn| if (turn.replacement) |x| x.cancellation else null,
                else => null,
            };
            if (replacement) |request| {
                const receipt = try readCancellation(service, receipts.allocator(), request);
                try cancellations.append(receipts.allocator(), receipt.value);
            }
            if (!temporary.reset(.retain_capacity)) return error.OutOfMemory;
        }
        if (page.next) |next| {
            if (after) |previous| if (std.mem.order(u8, &previous, &next) != .lt)
                return error.InvalidTaskOrder;
            after = next;
        } else exhausted = true;
    }
    index.namespace = service.namespace.identity;
    try index.finish(cancellations.items);
    return index;
}

pub fn digest(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn verify(value: Value, task: t.Id, schema: []const u8, encoding: Encoding) !void {
    if (!std.meta.eql(value.task, task)) return error.WrongTask;
    if (!std.meta.eql(digest(value.bytes), value.digest)) return error.DigestMismatch;
    if (!std.mem.eql(u8, value.schema_id, schema) or value.encoding != encoding)
        return error.UnsupportedEncoding;
}

fn decodeRow(
    comptime Native: type,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    row: Row,
    snapshot_bytes: ?[]const u8,
) !Record {
    try verify(row.input, row.input.task, t.input_schema_id, .contract);
    const input = try c.decodeOwned(t.Input, a, row.input.bytes);
    var item: Record = .{
        .task = row.input.task,
        .revision = row.input.revision,
        .input_digest = row.input.digest,
        .result_digest = null,
        .input = input.value,
        .result = null,
        .owner_snapshot = if (row.owner_snapshot) |snapshot|
            (try c.decodeOwned(
                retained.Snapshot,
                a,
                snapshot_bytes orelse try c.encodeOwned(retained.Snapshot, scratch, snapshot),
            )).value
        else
            null,
        .owner_evidence = if (row.owner_evidence) |evidence|
            try retained.copyEvidence(a, evidence)
        else
            null,
    };
    if (row.result) |result| {
        if (result.revision != row.input.revision) return error.RevisionMismatch;
        const failure = std.mem.eql(u8, result.schema_id, t.failure_schema_id);
        try verify(
            result,
            item.task,
            if (failure) t.failure_schema_id else t.output_schema_id,
            .json,
        );
        const parsed = try Native.json.parseAsset(scratch, result.bytes, result.bytes.len);
        if (failure) {
            _ = try Native.values.fromJson(t.Failure, scratch, parsed.value);
        } else {
            const output = try Native.values.fromJson(t.Output, scratch, parsed.value);
            const bytes = try c.encodeOwned(t.Output, scratch, output);
            item.result = (try c.decodeOwned(t.Output, a, bytes)).value;
            if (!std.mem.eql(u8, @tagName(item.input), @tagName(item.result.?)))
                return error.WrongResultKind;
        }
        item.result_digest = result.digest;
    }
    return item;
}

fn validateOperations(self: *Index, a: std.mem.Allocator) !void {
    for (self.records, 0..) |item, position| {
        const envelope = switch (item.input) {
            inline else => |value| value.envelope,
        };
        if (envelope.version != 1 or envelope.operation.bytes.len == 0)
            return error.UnsupportedEnvelope;
        const entry = try self.operations.getOrPut(a, envelope.operation.bytes);
        if (entry.found_existing) return error.OperationConflict;
        entry.value_ptr.* = position;
        if (item.input == .genesis) try addLineage(self, a, position);
    }
}

fn addLineage(self: *Index, a: std.mem.Allocator, position: usize) !void {
    const entry = try self.lineages.getOrPut(a, self.records[position].input.genesis.lineage);
    entry.value_ptr.* = if (entry.found_existing)
        try replayedLineage(a, self.records, entry.value_ptr.*, position)
    else
        position;
}

fn replayedLineage(
    a: std.mem.Allocator,
    records: []const Record,
    first: usize,
    second: usize,
) !usize {
    const left = records[first].input.genesis;
    const right = records[second].input.genesis;
    if ((left.imported == null) == (right.imported == null)) return error.DuplicateLineage;
    const local = if (left.imported == null) left else right;
    const derived = try admission.stableDigest(a, local.envelope);
    if (!std.meta.eql(derived, local.lineage)) return error.DuplicateLineage;
    return if (left.imported == null) second else first;
}

fn validateTurns(self: *Index, receipts: []const Cancellation) !void {
    const a = self.arena.allocator();
    for (self.records) |record| {
        if (record.input != .turn) continue;
        const turn = record.input.turn;
        if (turn.envelope.origin == .derived) return error.InvalidTurnAttempt;
        const replacement = turn.replacement orelse {
            if (turn.continuity != null) {
                try @import("continuity_turn.zig").validateMapped(a, self, turn);
            } else if (turn.attempt != 0) return error.MissingTurnReplacement;
            continue;
        };
        const position = self.tasks.get(replacement.input.task) orelse return error.MissingTurn;
        const old = self.records[position];
        if (old.input != .turn or old.superseded or
            !std.meta.eql(old.input_digest, replacement.input.digest) or
            old.input.turn.attempt != replacement.attempt or
            turn.attempt != try std.math.add(u32, replacement.attempt, 1))
            return error.InvalidTurnReplacement;
        var original = turn;
        original.attempt = old.input.turn.attempt;
        original.envelope.operation = old.input.turn.envelope.operation;
        original.replacement = old.input.turn.replacement;
        if (!try sameValue(a, t.Turn, original, old.input.turn))
            return error.TurnContextChanged;
        const operation = try std.fmt.allocPrint(a, "turn-retry:{s}:{d}", .{
            std.fmt.bytesToHex(old.task, .lower), turn.attempt,
        });
        if (!std.mem.eql(u8, operation, turn.envelope.operation.bytes))
            return error.InvalidTurnReplacement;
        try turnReceipt(old, replacement.cancellation, receipts);
        var snapshot = try retained.decodeFrozen(
            a,
            replacement.reference,
            replacement.owner_snapshot.bytes,
        );
        defer snapshot.deinit();
        try validateSnapshot(a, snapshot.value, old.owner_snapshot orelse
            return error.MissingOwnerSnapshot, old);
        self.records[position].superseded = true;
    }
}

fn turnReceipt(old: Record, cancellation: t.ControlReceipt, receipts: []const Cancellation) !void {
    if (!std.meta.eql(cancellation.task, old.task)) return error.InvalidCancellationReceipt;
    var matched = false;
    for (receipts) |receipt| {
        if (!std.mem.eql(u8, receipt.operation, cancellation.operation.bytes)) continue;
        if (matched or !std.meta.eql(receipt.task, old.task) or receipt.revision > old.revision or
            !std.mem.eql(u8, receipt.bytes, cancellation.bytes.bytes))
            return error.InvalidCancellationReceipt;
        matched = true;
    }
    if (!matched) return error.MissingCancellationReceipt;
}

fn recordHead(item: Record) ?t.Head {
    return switch (item.result orelse return null) {
        .genesis => |value| value,
        .step => |value| value.head,
        else => null,
    };
}

fn sameValue(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const x = try c.encodeOwned(T, a, left);
    defer a.free(x);
    const y = try c.encodeOwned(T, a, right);
    defer a.free(y);
    return std.mem.eql(u8, x, y);
}

const Successors = std.AutoHashMapUnmanaged(t.Id, std.ArrayList(usize));
const Cut = struct { task: t.Id, revision: u64 };
const Chain = struct {
    positions: std.ArrayList(usize) = .empty,
    members: std.AutoHashMapUnmanaged(usize, void) = .empty,
    settlements: std.AutoHashMapUnmanaged(t.Id, t.Settlement) = .empty,
    consumed: std.AutoHashMapUnmanaged(Cut, void) = .empty,

    fn append(self: *Chain, a: std.mem.Allocator, item: Record, position: usize) !void {
        try self.positions.append(a, position);
        try self.members.put(a, position, {});
        if (item.input == .step) for (item.input.step.facts.items) |fact|
            try self.settlements.put(a, fact.reference.task, fact);
        for (recordHead(item).?.consumed.items) |used|
            try self.consumed.put(a, .{ .task = used.task, .revision = used.revision }, {});
    }
};

fn stepSuccessors(self: *Index) !Successors {
    const a = self.arena.allocator();
    var result: Successors = .empty;
    for (self.records, 0..) |item, position| {
        if (item.input != .step) continue;
        const entry = try result.getOrPut(a, item.input.step.predecessor.task);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, position);
    }
    return result;
}

fn buildObligation(
    self: *Index,
    genesis_position: usize,
    successors: *const Successors,
    cancellations: []const Cancellation,
) !Obligation {
    const a = self.arena.allocator();
    const genesis = self.records[genesis_position];
    const initial = recordHead(genesis) orelse return error.MissingGenesisResult;
    try validateGenesis(genesis, initial);
    const directives = try orderedDirectives(self, genesis.task, initial);
    var chain: Chain = .{};
    try chain.append(a, genesis, genesis_position);
    self.records[genesis_position].selected = true;
    var eligible: ?usize = null;
    var selected = genesis_position;
    var remaining = self.records.len;
    while (remaining > 0) : (remaining -= 1) {
        const next = try nextAttempt(
            self,
            successors,
            selected,
            genesis.task,
            cancellations,
        ) orelse break;
        const current = recordHead(self.records[selected]).?;
        if (current.mode == .cancelled or current.mode == .transferred)
            return error.FinalHeadSuccessor;
        try validateStep(self, next, selected, directives, &chain);
        if (recordHead(self.records[next]) == null) {
            eligible = next;
            break;
        }
        self.records[next].selected = true;
        try chain.append(a, self.records[next], next);
        selected = next;
    }
    for (self.records) |item| if (item.input == .step and
        std.meta.eql(item.input.step.obligation, genesis.task) and !item.selected and
        !item.superseded and
        (eligible == null or !std.meta.eql(item.task, self.records[eligible.?].task)))
        return error.OrphanStep;
    const latest = recordHead(self.records[selected]).?;
    var effective = latest.mode;
    const controls_pending =
        !try continuity.controlsComplete(a, self, genesis.task, latest.folded_directive_ordinal);
    for (directives) |position| {
        const directive = self.records[position].input.directive;
        if (directive.ordinal <= latest.folded_directive_ordinal) continue;
        effective = restrict(effective, directive.body);
    }
    return .{
        .task = genesis.task,
        .chain = try chain.positions.toOwnedSlice(a),
        .directives = directives,
        .eligible = eligible,
        .folded_mode = latest.mode,
        .effective_mode = effective,
        .controls_pending = controls_pending,
        .settlements = chain.settlements,
    };
}

fn validateGenesis(record: Record, initial: t.Head) !void {
    const input = record.input.genesis;
    if (initial.version != 1 or initial.sequence != 0 or initial.obligation != .self or
        initial.attempt != 0 or initial.superseded != null or
        !std.meta.eql(initial.lineage, input.lineage)) return error.InvalidGenesisHead;
    if (initial.predecessor != null or initial.folded_directive_ordinal != 0 or
        initial.last_directive != null) return error.InvalidGenesisHead;
}

fn restrict(mode: t.Mode, body: t.DirectiveBody) t.Mode {
    if (body == .@"resume") return mode;
    var state: ControlState = .{ .mode = mode, .desired = .active };
    state.apply(body);
    return state.mode;
}

fn orderedDirectives(self: *Index, obligation: t.Id, initial: t.Head) ![]const usize {
    const a = self.arena.allocator();
    var ordered: std.ArrayList(usize) = .empty;
    for (self.records, 0..) |item, position| {
        if (item.input == .directive and std.meta.eql(item.input.directive.obligation, obligation))
            try ordered.append(a, position);
    }
    std.mem.sort(usize, ordered.items, self, struct {
        fn less(index: *Index, x: usize, y: usize) bool {
            return index.records[x].input.directive.ordinal <
                index.records[y].input.directive.ordinal;
        }
    }.less);
    var predecessor = initial.last_directive;
    var ordinal = initial.folded_directive_ordinal;
    for (ordered.items) |position| {
        const item = self.records[position];
        ordinal = try std.math.add(u64, ordinal, 1);
        if (item.input.directive.ordinal != ordinal) return error.DirectiveGapOrConflict;
        if (!std.meta.eql(predecessor, item.input.directive.predecessor))
            return error.DirectivePredecessorMismatch;
        predecessor = .{ .task = item.task, .digest = item.input_digest };
        if (item.result) |result| if (!try sameValue(
            a,
            t.Directive,
            item.input.directive,
            result.directive,
        ))
            return error.DirectiveResultMismatch;
    }
    return ordered.toOwnedSlice(a);
}

fn nextAttempt(
    self: *Index,
    successors: *const Successors,
    selected: usize,
    obligation: t.Id,
    receipts: []const Cancellation,
) !?usize {
    var attempts: std.ArrayList(usize) = .empty;
    const a = self.arena.allocator();
    const candidates = successors.get(self.records[selected].task) orelse return null;
    for (candidates.items) |position| {
        if (std.meta.eql(self.records[position].input.step.obligation, obligation))
            try attempts.append(a, position);
    }
    std.mem.sort(usize, attempts.items, self, struct {
        fn less(index: *Index, x: usize, y: usize) bool {
            return index.records[x].input.step.attempt < index.records[y].input.step.attempt;
        }
    }.less);
    var previous: ?usize = null;
    for (attempts.items, 0..) |position, ordinal| {
        const item = self.records[position];
        const step = item.input.step;
        if (step.attempt != ordinal) return error.AttemptGapOrConflict;
        if (!std.meta.eql(step.predecessor, self.reference(selected)) or
            step.sequence != try std.math.add(
                u64,
                recordHead(self.records[selected]).?.sequence,
                1,
            ))
            return error.PredecessorMismatch;
        if (previous) |prior| {
            try validateSupersession(self, position, prior, receipts);
            self.records[prior].superseded = true;
        } else if (step.supersession != null) return error.InvalidSupersession;
        previous = position;
    }
    return previous;
}

fn validateSupersession(
    self: *Index,
    current: usize,
    prior: usize,
    receipts: []const Cancellation,
) !void {
    const step = self.records[current].input.step;
    const old = self.records[prior];
    const supersession = step.supersession orelse return error.MissingSupersession;
    if (!step.fold_only or !std.meta.eql(supersession.input.task, old.task) or
        !std.meta.eql(supersession.input.digest, old.input_digest) or
        supersession.attempt != old.input.step.attempt or
        !std.meta.eql(supersession.cancellation.task, old.task)) return error.InvalidSupersession;
    if (supersession.phase != try @import("phase.zig").attempted(old))
        return error.InvalidSupersession;
    var matched = false;
    for (receipts) |receipt| {
        if (!std.mem.eql(u8, receipt.operation, supersession.cancellation.operation.bytes))
            continue;
        if (matched or !std.meta.eql(receipt.task, old.task) or receipt.revision > old.revision or
            !std.mem.eql(u8, receipt.bytes, supersession.cancellation.bytes.bytes))
            return error.InvalidCancellationReceipt;
        matched = true;
    }
    if (!matched) return error.MissingCancellationReceipt;
}

const ControlState = struct {
    mode: t.Mode,
    desired: @FieldType(t.Head, "desired_mode"),

    fn fromHead(head: t.Head) ControlState {
        return .{ .mode = head.mode, .desired = head.desired_mode };
    }

    fn apply(self: *ControlState, body: t.DirectiveBody) void {
        if (self.mode == .cancelled or self.mode == .transferred) return;
        switch (body) {
            .pause => {
                self.mode = .paused;
                self.desired = .paused;
            },
            .cancel => {
                self.mode = .cancelled;
                self.desired = .cancelled;
            },
            .transfer => self.mode = .transferred,
            .@"resume" => {
                self.mode = .active;
                self.desired = .active;
            },
            else => {},
        }
    }
};

fn validateStep(
    self: *Index,
    position: usize,
    predecessor: usize,
    directives: []const usize,
    chain: *const Chain,
) !void {
    const a = self.arena.allocator();
    const step = self.records[position].input.step;
    const previous = recordHead(self.records[predecessor]).?;
    if (!try sameValue(a, t.Head, step.previous, previous)) return error.CopiedHeadMismatch;
    var ordinal = previous.folded_directive_ordinal;
    var last = previous.last_directive;
    var control_state = ControlState.fromHead(previous);
    for (step.directives.items) |fact| {
        ordinal = try std.math.add(u64, ordinal, 1);
        const base = recordHead(self.records[chain.positions.items[0]]).?.folded_directive_ordinal;
        const relative = try std.math.sub(u64, ordinal, base);
        if (relative == 0 or relative > directives.len) return error.MissingDirective;
        const admitted = self.records[directives[@intCast(relative - 1)]];
        const reference: t.InputReference = .{
            .task = admitted.task,
            .digest = admitted.input_digest,
        };
        if (!std.meta.eql(fact.reference, reference) or
            !try sameValue(a, t.Directive, fact.value, admitted.input.directive))
            return error.CopiedDirectiveMismatch;
        last = reference;
        control_state.apply(fact.value.body);
    }
    try validateFacts(self, step, chain);
    try validateBatches(self, step, chain);
    const output = recordHead(self.records[position]) orelse return;
    if (!std.meta.eql(control_state, ControlState.fromHead(output)))
        return error.InvalidControlFold;
    const replaced = if (step.supersession) |value| value.input else null;
    if (!std.meta.eql(output.superseded, replaced)) return error.InvalidSupersession;
    if (output.version != 1 or output.obligation != .task or
        !std.meta.eql(output.obligation.task, step.obligation) or
        !std.meta.eql(output.lineage, previous.lineage) or output.sequence != step.sequence or
        !std.meta.eql(output.predecessor, @as(?t.Reference, step.predecessor)) or
        output.attempt != step.attempt or output.folded_directive_ordinal != ordinal or
        !std.meta.eql(output.last_directive, last)) return error.InvalidStepHead;
    if (output.consumed.items.len != step.facts.items.len) return error.ConsumptionMismatch;
    for (output.consumed.items, step.facts.items) |used, fact|
        if (!std.meta.eql(used, fact.reference)) return error.ConsumptionMismatch;
}

fn validateBatches(self: *Index, step: t.Step, chain: *const Chain) !void {
    const a = self.arena.allocator();
    var sequence = step.previous.told.sequence;
    for (step.batches.items) |copied| {
        const batch = try selectedBatch(self, step.obligation, copied, chain);
        if (!try sameValue(a, t.Batch, batch, copied.value)) return error.CopiedBatchMismatch;
        sequence = try std.math.add(u64, sequence, 1);
        if (batch.sequence != sequence or sequence > step.previous.observed.sequence)
            return error.BatchCoverageGap;
    }
}

fn selectedBatch(
    self: *Index,
    obligation: t.Id,
    copied: @FieldType(t.Step, "batches").Child,
    chain: *const Chain,
) !t.Batch {
    const source = self.record(copied.reference.task) orelse return error.MissingBatch;
    if (source.result_digest == null or
        !std.meta.eql(source.result_digest.?, copied.reference.digest))
        return error.BatchReferenceMismatch;
    if (!chain.members.contains(self.tasks.get(source.task).?)) return error.UnselectedBatch;
    switch (source.input) {
        .genesis => |genesis| {
            const imported = genesis.imported orelse return error.MissingBatch;
            const carried = imported.carried orelse return error.MissingBatch;
            for (carried.batches.items) |batch| {
                if (batch.sequence == copied.value.sequence) return batch;
            }
            return error.MissingBatch;
        },
        .step => |step| {
            if (!std.meta.eql(step.obligation, obligation)) return error.ForeignBatch;
            const output = source.result orelse return error.MissingBatch;
            return output.step.batch orelse error.MissingBatch;
        },
        else => return error.ForeignBatch,
    }
}

fn validateFacts(self: *Index, step: t.Step, chain: *const Chain) !void {
    const a = self.arena.allocator();
    for (step.facts.items, 0..) |fact, position| {
        const item = self.record(fact.reference.task) orelse return error.MissingFact;
        var snapshot = try retained.decodeFrozen(a, fact.reference, fact.owner_snapshot.bytes);
        defer snapshot.deinit();
        const current = item.owner_snapshot orelse return error.MissingOwnerSnapshot;
        try validateSnapshot(a, snapshot.value, current, item.*);
        const previous = try previousFact(self, chain, step.facts.items[0..position], fact);
        defer if (previous) |owned| {
            var value = owned;
            value.deinit();
        };
        try retained.verifySettlement(fact, snapshot, previous);
        for (step.facts.items[0..position]) |prior|
            if (sameCut(prior.reference, fact.reference)) return error.DuplicateConsumption;
        if (chain.consumed.contains(.{
            .task = fact.reference.task,
            .revision = fact.reference.revision,
        })) return error.DuplicateConsumption;
    }
}

fn sameCut(left: t.RevisionReference, right: t.RevisionReference) bool {
    return std.meta.eql(left.task, right.task) and left.revision == right.revision;
}

fn previousFact(
    self: *Index,
    chain: *const Chain,
    current: []const t.Settlement,
    fact: t.Settlement,
) !?retained.OwnedSnapshot {
    var selected = chain.settlements.get(fact.reference.task);
    for (current) |candidate| {
        if (std.meta.eql(candidate.reference.task, fact.reference.task)) selected = candidate;
    }
    const previous = selected orelse return null;
    return try retained.decodeFrozen(
        self.arena.allocator(),
        previous.reference,
        previous.owner_snapshot.bytes,
    );
}

fn validateSnapshot(
    a: std.mem.Allocator,
    snapshot: retained.Snapshot,
    current: retained.Snapshot,
    item: Record,
) !void {
    if (!std.meta.eql(snapshot.task, item.task) or snapshot.revision > item.revision or
        current.revision != item.revision or snapshot.event_cut > current.event_cut or
        !std.meta.eql(snapshot.input.reference.digest, item.input_digest) or
        !std.meta.eql(snapshot.profile, current.profile)) return error.FactReferenceMismatch;
    if (snapshot.revision == current.revision and
        !try sameValue(a, retained.Snapshot, snapshot, current))
        return error.OwnerSnapshotMismatch;
    if (snapshot.result) |result| {
        if (item.result_digest == null or
            !std.meta.eql(item.result_digest.?, result.reference.digest))
            return error.FactReferenceMismatch;
    }
    if (snapshot.inference_attempts > current.inference_attempts or
        snapshot.inference_request_bytes > current.inference_request_bytes or
        snapshot.inference_output_tokens > current.inference_output_tokens or
        snapshot.evidence_bytes > current.evidence_bytes) return error.AccountingMismatch;
    var cursor: usize = 0;
    for (snapshot.attempts.items) |old| {
        while (cursor < current.attempts.items.len and
            std.mem.order(u8, &current.attempts.items[cursor].id, &old.id) == .lt) cursor += 1;
        if (cursor >= current.attempts.items.len or
            !std.meta.eql(current.attempts.items[cursor].id, old.id)) return error.MissingAttempt;
        try validateRetainedAttempt(a, old, current.attempts.items[cursor]);
    }
}

fn validateRetainedAttempt(
    a: std.mem.Allocator,
    old: retained.Attempt,
    current: retained.Attempt,
) !void {
    var left = old;
    var right = current;
    left.capture = null;
    left.usage = null;
    right.capture = null;
    right.usage = null;
    if (!try sameValue(a, retained.Attempt, left, right)) return error.AttemptBindingMismatch;
    const before = old.capture orelse return;
    const after = current.capture orelse return error.CaptureBindingMismatch;
    if (before.disposition != .unknown and before.disposition != after.disposition)
        return error.CaptureBindingMismatch;
    if (before.response) |reference|
        if (after.response == null or !std.meta.eql(reference, after.response.?))
            return error.CaptureBindingMismatch;
    if (before.reply) |reference|
        if (after.reply == null or !std.meta.eql(reference, after.reply.?))
            return error.CaptureBindingMismatch;
    if (before.output_tokens) |tokens|
        if (after.output_tokens == null or tokens != after.output_tokens.?)
            return error.AccountingMismatch;
}

pub fn readCancellation(
    service: anytype,
    a: std.mem.Allocator,
    requested: t.ControlReceipt,
) !c.Decoded(Cancellation) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var saved = (try service.operationLookup(a, requested.operation.bytes)) orelse
        return error.MissingCancellationReceipt;
    defer saved.deinit();
    if (saved.value.method != .cancel or saved.value.disposition != .cancellation_requested or
        !std.meta.eql(saved.value.task, requested.task) or
        !std.mem.eql(u8, saved.value.client_operation_id.bytes, requested.operation.bytes))
        return error.InvalidCancellationReceipt;
    const bytes = try c.encodeOwned(@TypeOf(saved.value), scratch, saved.value);
    if (!std.mem.eql(u8, bytes, requested.bytes.bytes)) return error.InvalidCancellationReceipt;
    return .{ .arena = arena, .value = .{
        .task = saved.value.task,
        .operation = try scratch.dupe(u8, requested.operation.bytes),
        .revision = saved.value.revision,
        .bytes = bytes,
    } };
}
