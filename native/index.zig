const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const preparation = @import("delivery_prepare.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");
const restore = @import("restore.zig");
const interaction = @import("interaction_evidence.zig");

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
pub const Obligation = struct {
    task: t.Id,
    chain: []const usize,
    directives: []const usize,
    eligible: ?usize,
    folded_mode: t.Mode,
    effective_mode: t.Mode,
    recovery_hold: bool,

    pub fn ordinaryDispatch(self: Obligation) bool {
        return self.effective_mode == .active and !self.recovery_hold;
    }
};
pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    records: []Record,
    storage: std.ArrayList(Record) = .empty,
    obligations: []Obligation,
    tasks: std.AutoHashMapUnmanaged(t.Id, usize),
    imports: []const continuity.Imported = &.{},
    portable: []const continuity.Portable = &.{},
    recovery: ?t.InputReference = null,
    recovery_hold: bool = false,
    recovery_purpose: ?t.RestorePurpose = null,
    restore_cut: []const t.InputReference = &.{},

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
        for (self.records) |item| _ = try interaction.settlement(scratch, self, item);
        const recovery_view = try restore.inspect(scratch, self);
        self.recovery = recovery_view.recovery;
        self.recovery_hold = recovery_view.recovery_hold;
        self.recovery_purpose = recovery_view.recovery_purpose;
        self.restore_cut = recovery_view.restore_cut;
        self.imports = try continuity.prepareImports(scratch, self);
        self.portable = try continuity.preparePortable(scratch, self);
        try validateTurns(self, cancellations);
        for (self.records, 0..) |item, position| {
            if (item.input != .genesis or recordHead(item) == null) continue;
            try obligations.append(scratch, try buildObligation(self, position, cancellations));
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
    while (true) {
        var page = try service.taskPage(a, after, page_limit);
        defer page.deinit();
        for (page.tasks) |task| {
            const scratch = temporary.allocator();
            const loaded = try retained.load(service, scratch, task, page_limit);
            const item = try index.add(@import("protean_native"), scratch, retained.row(loaded), loaded.snapshot.bytes);
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
        const next = page.next orelse break;
        if (after) |previous| if (std.mem.order(u8, &previous, &next) != .lt)
            return error.InvalidTaskOrder;
        after = next;
    }
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
    var operations: std.StringHashMapUnmanaged(void) = .empty;
    var lineages: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    for (self.records) |item| {
        switch (item.input) {
            .delivery => |delivery| try preparation.verifyStored(a, delivery),
            .audit => |audit| try preparation.verifyStored(a, audit.delivery),
            .directive => |directive| try restore.validateRetainedDirective(
                self,
                directive.obligation,
                directive.body,
                directive.envelope.origin,
            ),
            else => {},
        }
        const envelope = switch (item.input) {
            inline else => |value| value.envelope,
        };
        if (envelope.version != 1 or envelope.operation.bytes.len == 0)
            return error.UnsupportedEnvelope;
        const entry = try operations.getOrPut(a, envelope.operation.bytes);
        if (entry.found_existing) return error.OperationConflict;
        if (item.input == .genesis) {
            const lineage = try lineages.getOrPut(a, item.input.genesis.lineage);
            if (lineage.found_existing) return error.DuplicateLineage;
        }
    }
}

fn validateTurns(self: *Index, receipts: []const Cancellation) !void {
    const a = self.arena.allocator();
    for (self.records) |record| {
        if (record.input != .turn) continue;
        const turn = record.input.turn;
        if (turn.attempt > 2 or turn.envelope.origin == .derived)
            return error.InvalidTurnAttempt;
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

fn buildObligation(
    self: *Index,
    genesis_position: usize,
    cancellations: []const Cancellation,
) !Obligation {
    const a = self.arena.allocator();
    const genesis = self.records[genesis_position];
    const initial = recordHead(genesis) orelse return error.MissingGenesisResult;
    try validateGenesis(genesis, initial);
    const directives = try orderedDirectives(self, genesis.task, initial);
    var chain: std.ArrayList(usize) = .empty;
    try chain.append(a, genesis_position);
    self.records[genesis_position].selected = true;
    var eligible: ?usize = null;
    var selected = genesis_position;
    var remaining = self.records.len;
    while (remaining > 0) : (remaining -= 1) {
        const next = try nextAttempt(self, selected, genesis.task, cancellations) orelse break;
        const current = recordHead(self.records[selected]).?;
        if (current.mode == .cancelled or current.mode == .transferred)
            return error.FinalHeadSuccessor;
        try validateStep(self, next, selected, directives, chain.items);
        if (recordHead(self.records[next]) == null) {
            eligible = next;
            break;
        }
        self.records[next].selected = true;
        try chain.append(a, next);
        selected = next;
    }
    for (self.records) |item| if (item.input == .step and
        std.meta.eql(item.input.step.obligation, genesis.task) and !item.selected and
        !item.superseded and
        (eligible == null or !std.meta.eql(item.task, self.records[eligible.?].task)))
        return error.OrphanStep;
    const latest = recordHead(self.records[selected]).?;
    var effective = latest.mode;
    var recovery_hold = latest.recovery_hold or self.recovery_hold or
        !try continuity.controlsComplete(a, self, genesis.task, latest.folded_directive_ordinal);
    for (directives) |position| {
        const directive = self.records[position].input.directive;
        if (directive.ordinal <= latest.folded_directive_ordinal) continue;
        effective = restrict(effective, directive.body);
        if (directive.body == .recovery_hold) recovery_hold = true;
    }
    return .{
        .task = genesis.task,
        .chain = try chain.toOwnedSlice(a),
        .directives = directives,
        .eligible = eligible,
        .folded_mode = latest.mode,
        .effective_mode = effective,
        .recovery_hold = recovery_hold,
    };
}

fn validateGenesis(record: Record, initial: t.Head) !void {
    const input = record.input.genesis;
    if (initial.version != 1 or initial.sequence != 0 or initial.obligation != .self or
        initial.attempt != 0 or initial.superseded != null or
        !std.meta.eql(initial.lineage, input.lineage)) return error.InvalidGenesisHead;
    if (input.imported) |imported| {
        if (!std.meta.eql(initial.predecessor, @as(?t.Reference, imported.source)) or
            initial.folded_directive_ordinal != 0 or initial.last_directive != null or
            !initial.recovery_hold) return error.InvalidGenesisHead;
    } else if (initial.predecessor != null or initial.folded_directive_ordinal != 0 or
        initial.last_directive != null) return error.InvalidGenesisHead;
}

fn restrict(mode: t.Mode, body: t.DirectiveBody) t.Mode {
    if (mode == .cancelled or mode == .transferred) return mode;
    return switch (body) {
        .pause => .paused,
        .cancel => .cancelled,
        .transfer => .transferred,
        else => mode,
    };
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
    selected: usize,
    obligation: t.Id,
    receipts: []const Cancellation,
) !?usize {
    var attempts: std.ArrayList(usize) = .empty;
    const a = self.arena.allocator();
    for (self.records, 0..) |item, position| {
        if (item.input != .step or !std.meta.eql(item.input.step.obligation, obligation)) continue;
        if (std.meta.eql(item.input.step.predecessor.task, self.records[selected].task))
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
    recovery_hold: bool,
    boundary: ?t.InputReference,

    fn fromHead(head: t.Head) ControlState {
        return .{
            .mode = head.mode,
            .desired = head.desired_mode,
            .recovery_hold = head.recovery_hold,
            .boundary = head.recovery_boundary,
        };
    }

    fn apply(self: *ControlState, directive: t.Directive) void {
        if (self.mode == .cancelled or self.mode == .transferred) return;
        switch (directive.body) {
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
                self.mode = if (self.recovery_hold) .paused else .active;
                self.desired = .active;
            },
            .recovery_hold => |value| {
                self.mode = .paused;
                self.recovery_hold = true;
                self.boundary = value.recovery;
            },
            .recovery_release => |value| {
                if (self.boundary == null or !value.exclusive_owner or
                    !std.meta.eql(self.boundary.?, value.recovery)) return;
                self.mode = switch (self.desired) {
                    .active => .active,
                    .paused => .paused,
                    .cancelled => .cancelled,
                };
                self.recovery_hold = false;
                self.boundary = null;
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
    chain: []const usize,
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
        const base = recordHead(self.records[chain[0]]).?.folded_directive_ordinal;
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
        control_state.apply(fact.value);
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

fn validateBatches(self: *Index, step: t.Step, chain: []const usize) !void {
    const a = self.arena.allocator();
    var sequence = step.previous.told.sequence;
    for (step.batches.items) |copied| {
        const batch = try selectedBatch(self, step.obligation, copied.reference, chain);
        if (!try sameValue(a, t.Batch, batch, copied.value)) return error.CopiedBatchMismatch;
        sequence = try std.math.add(u64, sequence, 1);
        if (batch.sequence != sequence or sequence > step.previous.observed.sequence)
            return error.BatchCoverageGap;
    }
}

fn selectedBatch(
    self: *Index,
    obligation: t.Id,
    reference: t.Reference,
    chain: []const usize,
) !t.Batch {
    const source = self.record(reference.task) orelse return error.MissingBatch;
    const output = source.result orelse return error.MissingBatch;
    if (source.result_digest == null or !std.meta.eql(source.result_digest.?, reference.digest))
        return error.BatchReferenceMismatch;
    if (output == .continuity_member) {
        const data = try continuity.resolve(self, obligation, reference, .batch);
        const decoded = try continuity.decode(.batch, self.arena.allocator(), data);
        return decoded.value;
    }
    if (output != .step or source.input != .step or
        !std.meta.eql(source.input.step.obligation, obligation)) return error.ForeignBatch;
    const position = self.tasks.get(source.task).?;
    if (std.mem.indexOfScalar(usize, chain, position) == null) return error.UnselectedBatch;
    return output.step.batch orelse error.MissingBatch;
}

fn validateFacts(self: *Index, step: t.Step, chain: []const usize) !void {
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
        var frozen = item.*;
        if (snapshot.value.result == null) {
            frozen.result = null;
            frozen.result_digest = null;
        }
        try validateDeliveryFact(self, a, fact, frozen, snapshot.value);
        for (step.facts.items[0..position]) |prior|
            if (sameCut(prior.reference, fact.reference)) return error.DuplicateConsumption;
        for (chain) |prior| for (recordHead(self.records[prior]).?.consumed.items) |used|
            if (sameCut(used, fact.reference)) return error.DuplicateConsumption;
    }
}

fn sameCut(left: t.RevisionReference, right: t.RevisionReference) bool {
    return std.meta.eql(left.task, right.task) and left.revision == right.revision;
}

fn previousFact(
    self: *Index,
    chain: []const usize,
    current: []const t.Settlement,
    fact: t.Settlement,
) !?retained.OwnedSnapshot {
    var selected: ?t.Settlement = null;
    for (chain) |position| {
        const input = self.records[position].input;
        if (input != .step) continue;
        for (input.step.facts.items) |candidate| {
            if (std.meta.eql(candidate.reference.task, fact.reference.task)) selected = candidate;
        }
    }
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

fn validateDeliveryFact(
    self: *const Index,
    a: std.mem.Allocator,
    fact: t.Settlement,
    item: Record,
    snapshot: retained.Snapshot,
) !void {
    if (fact.kind == .interaction) {
        const expected = try interaction.settlement(a, self, item);
        if (expected == null or !try sameValue(
            a,
            @FieldType(t.Settlement, "delivery"),
            fact.delivery,
            expected,
        )) return error.CopiedInteractionMismatch;
        return;
    }
    if (fact.kind != .delivery and fact.kind != .audit) {
        if (fact.delivery != null) return error.UnexpectedDeliveryFact;
        return;
    }
    if (fact.kind == .delivery) {
        if (item.input != .delivery) return error.FactKindMismatch;
        var evidence = item.owner_evidence orelse return error.MissingOwnerEvidence;
        if (fact.delivery) |claimed| if (claimed.outcome == .indeterminate) {
            evidence.status = .unknown;
        };
        var expected = try @import("delivery_fact.zig").settlement(a, snapshot, evidence);
        defer expected.deinit();
        if ((fact.delivery == null) != (expected.value == null))
            return error.CopiedDeliveryMismatch;
        if (fact.delivery) |claimed| {
            const actual = expected.value.?;
            if (!try sameValue(a, t.Delivery, claimed.admitted, actual.admitted) or
                !try sameValue(a, t.DeliveryOutcome, claimed.outcome, actual.outcome))
                return error.CopiedDeliveryMismatch;
            if (!try sameValue(a, ?t.Receipt, claimed.receipt, actual.receipt))
                return error.InvalidDeliveryReceipt;
        }
        return;
    }
    const result = item.result orelse {
        if (item.input != .audit or fact.delivery != null) return error.FactKindMismatch;
        return;
    };
    if (fact.kind == .audit and result == .audit and result.audit != .found) {
        if (item.input != .audit or fact.delivery != null) return error.FactKindMismatch;
        return;
    }
    try validateAuditFact(a, fact, item);
}

fn validateAuditFact(a: std.mem.Allocator, fact: t.Settlement, item: Record) !void {
    const result = item.result orelse return error.MissingFact;
    if (item.input != .audit or result != .audit) return error.FactKindMismatch;
    const claimed = fact.delivery orelse return error.MissingDeliveryFact;
    const target = item.input.audit.delivery;
    if (!try sameValue(a, t.Delivery, claimed.admitted, target))
        return error.CopiedDeliveryMismatch;
    if (result.audit != .found or claimed.receipt == null) return error.InvalidDeliveryReceipt;
    const timestamp = result.audit.found.timestamp;
    const receipt: t.Receipt = .{
        .key = target.key,
        .destination = target.destination,
        .payload_digest = target.payload.content_digest,
        .timestamp = timestamp,
        .evidence = .{ .task = item.task, .digest = item.result_digest.? },
        .basis = .history_match,
    };
    if (!try sameValue(a, t.Receipt, claimed.receipt.?, receipt))
        return error.InvalidDeliveryReceipt;
    const outcome: t.DeliveryOutcome = .{ .confirmed = .{
        .timestamp = timestamp,
        .metadata_observed = true,
    } };
    if (!try sameValue(a, t.DeliveryOutcome, claimed.outcome, outcome))
        return error.CopiedDeliveryMismatch;
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

pub fn readRow(service: anytype, a: std.mem.Allocator, task: t.Id) !c.Decoded(Row) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var input = (try service.applicationValue(a, task, .input)) orelse return error.MissingInput;
    defer input.deinit();
    const copied = try copyValue(scratch, input);
    var result: ?Value = null;
    if (try service.applicationValue(a, task, .result)) |owned| {
        var output = owned;
        defer output.deinit();
        result = try copyValue(scratch, output);
    }
    if (!std.meta.eql(copied.task, task)) return error.WrongTask;
    if (result) |output| if (!std.meta.eql(output.task, task) or
        output.revision != copied.revision) return error.RevisionMismatch;
    return .{ .arena = arena, .value = .{ .input = copied, .result = result } };
}

fn copyValue(a: std.mem.Allocator, value: anytype) !Value {
    if (value.reference.bytes != value.bytes.len or
        !std.meta.eql(value.reference.digest, digest(value.bytes))) return error.DigestMismatch;
    return .{
        .task = value.task,
        .revision = value.revision,
        .digest = value.reference.digest,
        .schema_id = try a.dupe(u8, value.schema_id),
        .encoding = switch (value.encoding) {
            .contract => .contract,
            .json => .json,
        },
        .bytes = try a.dupe(u8, value.bytes),
    };
}
