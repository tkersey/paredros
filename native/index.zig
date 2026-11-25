const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");
const transfer_marker = @import("transfer_marker.zig");
const admission = @import("admission.zig");
const lifecycle = @import("lifecycle.zig");

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
    var index = Index.empty(a);
    errdefer index.deinit();
    var receipts = std.heap.ArenaAllocator.init(a);
    defer receipts.deinit();
    var cancellations: std.ArrayList(Cancellation) = .empty;
    try load(service, &index, page_limit, receipts.allocator(), &cancellations, null);
    try index.finish(cancellations.items);
    return index;
}

fn load(
    service: anytype,
    index: *Index,
    page_limit: u32,
    receipts: std.mem.Allocator,
    cancellations: *std.ArrayList(Cancellation),
    maintained: ?*Maintained,
) !void {
    if (page_limit == 0) return error.InvalidPageLimit;
    const a = index.arena.child_allocator;
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
            if (cancellationOf(item.*)) |request| {
                const receipt = try readCancellation(service, receipts, request);
                try cancellations.append(receipts, receipt.value);
            }
            if (maintained) |owner| {
                const status = loaded.evidence.status;
                if (!try settled(service, scratch, status, task))
                    try owner.watched.put(owner.allocator, task, {});
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
}

fn cancellationOf(item: Record) ?t.ControlReceipt {
    return switch (item.input) {
        .step => |step| if (step.supersession) |x| x.cancellation else null,
        .turn => |turn| if (turn.replacement) |x| x.cancellation else null,
        else => null,
    };
}

fn settled(
    service: anytype,
    a: std.mem.Allocator,
    status: ?@import("protean_native").tasks.Status,
    task: t.Id,
) !bool {
    const terminal = switch (status orelse return false) {
        .completed, .failed, .cancelled => true,
        else => false,
    };
    return terminal and try service.associatedWorkDisposed(a, task);
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
        entry.key_ptr.* = try a.dupe(u8, envelope.operation.bytes);
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
        const event = lifecycle.control(body) orelse return;
        const next = lifecycle.mode.next(self.mode, event) orelse return;
        self.mode = next;
        self.desired = switch (event) {
            .pause => .paused,
            .cancel => .cancelled,
            .@"resume" => .active,
            .transfer => self.desired,
        };
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

pub var verify_against_rebuild: bool = @import("builtin").is_test;

pub const Counters = struct { probes: u64 = 0, loads: u64 = 0, derivations: u64 = 0 };

pub const View = struct {
    index: Index,
    owner: ?*Maintained,

    pub fn deinit(self: *View) void {
        if (self.owner) |owner| owner.release() else self.index.deinit();
        self.* = undefined;
    }
};

const Retired = union(enum) {
    arena: *std.heap.ArenaAllocator,
    derived: std.heap.ArenaAllocator,
    records: std.ArrayList(Record),
};

const Change = struct {
    task: t.Id,
    position: ?usize,
    settled: bool,
    record: ?Record = null,
    arena: ?*std.heap.ArenaAllocator = null,
    evidence: ?retained.Evidence = null,
    cancellation: ?Cancellation = null,
    structural: bool = false,
};

fn destroyArena(a: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    a.destroy(arena);
}

pub const Maintained = struct {
    allocator: std.mem.Allocator,
    page_limit: u32,
    current: Index,
    base: std.heap.ArenaAllocator,
    receipts: std.heap.ArenaAllocator,
    cancellations: std.ArrayList(Cancellation) = .empty,
    owned: std.AutoHashMapUnmanaged(t.Id, *std.heap.ArenaAllocator) = .empty,
    watched: std.AutoArrayHashMapUnmanaged(t.Id, void) = .empty,
    pending: std.AutoArrayHashMapUnmanaged(t.Id, void) = .empty,
    referenced: std.AutoHashMapUnmanaged(t.Id, void) = .empty,
    retired: std.ArrayList(Retired) = .empty,
    pins: u32 = 0,
    derived: bool = false,
    counters: Counters = .{},

    pub fn init(self: *Maintained, service: anytype, a: std.mem.Allocator, page_limit: u32) !void {
        self.* = .{
            .allocator = a,
            .page_limit = page_limit,
            .current = Index.empty(a),
            .base = std.heap.ArenaAllocator.init(a),
            .receipts = std.heap.ArenaAllocator.init(a),
        };
        errdefer self.deinit();
        const receipts = self.receipts.allocator();
        try load(service, &self.current, page_limit, receipts, &self.cancellations, self);
        self.base.deinit();
        self.base = self.current.arena;
        self.current.arena = std.heap.ArenaAllocator.init(a);
        try self.derive();
    }

    pub fn deinit(self: *Maintained) void {
        std.debug.assert(self.pins == 0);
        self.reclaim();
        self.retired.deinit(self.allocator);
        var arenas = self.owned.valueIterator();
        while (arenas.next()) |arena| destroyArena(self.allocator, arena.*);
        self.owned.deinit(self.allocator);
        self.watched.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.current.deinit();
        self.base.deinit();
        self.receipts.deinit();
        self.* = undefined;
    }

    pub fn reserve(self: *Maintained) !void {
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
    }

    pub fn note(self: *Maintained, task: t.Id) void {
        self.pending.putAssumeCapacity(task, {});
    }

    pub fn acquire(self: *Maintained, service: anytype) !View {
        try self.sync(service);
        self.pins += 1;
        return .{ .index = self.current, .owner = self };
    }

    fn release(self: *Maintained) void {
        self.pins -= 1;
        if (self.pins == 0) self.reclaim();
    }

    fn reclaim(self: *Maintained) void {
        for (self.retired.items) |item| self.free(item);
        self.retired.clearRetainingCapacity();
    }

    fn free(self: *Maintained, item: Retired) void {
        var owned = item;
        switch (owned) {
            .arena => |arena| destroyArena(self.allocator, arena),
            .derived => |*arena| arena.deinit(),
            .records => |*records| records.deinit(self.allocator),
        }
    }

    fn retire(self: *Maintained, item: Retired) void {
        if (self.pins == 0) return self.free(item);
        self.retired.appendAssumeCapacity(item);
    }

    pub fn sync(self: *Maintained, service: anytype) !void {
        if (self.derived and self.pending.count() == 0 and self.watched.count() == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var subjects: std.AutoArrayHashMapUnmanaged(t.Id, void) = .empty;
        for (self.pending.keys()) |task| try subjects.put(a, task, {});
        for (self.watched.keys()) |task| try subjects.put(a, task, {});
        const changes = try a.alloc(Change, subjects.count());
        var prepared: usize = 0;
        errdefer for (changes[0..prepared]) |change| if (change.arena) |arena|
            destroyArena(self.allocator, arena);
        for (subjects.keys(), changes) |task, *change| {
            change.* = try self.probe(service, a, task);
            prepared += 1;
        }
        try self.watched.ensureUnusedCapacity(self.allocator, changes.len);
        try self.owned.ensureUnusedCapacity(self.allocator, @intCast(changes.len));
        try self.retired.ensureUnusedCapacity(self.allocator, changes.len + 2);
        var structural = !self.derived;
        for (changes) |change| structural = structural or change.structural;
        try self.apply(changes);
        prepared = 0;
        for (changes) |change| {
            if (change.settled) {
                _ = self.watched.swapRemove(change.task);
            } else self.watched.putAssumeCapacity(change.task, {});
        }
        self.pending.clearRetainingCapacity();
        if (structural) try self.derive();
    }

    fn probe(self: *Maintained, service: anytype, a: std.mem.Allocator, task: t.Id) !Change {
        self.counters.probes += 1;
        var saved = try service.task(a, task);
        defer saved.deinit();
        const done = saved.value.terminal() and try service.associatedWorkDisposed(a, task);
        const position = self.current.tasks.get(task);
        if (position) |found| {
            const record = self.current.records[found];
            if (saved.value.revision == record.revision) {
                var evidence = record.owner_evidence orelse return error.MissingOwnerEvidence;
                const status = try service.status(a, saved.value);
                const unchanged: Change = .{ .task = task, .position = found, .settled = done };
                if (evidence.status == status) return unchanged;
                evidence.status = status;
                var change = unchanged;
                change.evidence = evidence;
                return change;
            }
        }
        var change = try self.reload(service, a, task, position);
        change.settled = done;
        return change;
    }

    fn reload(
        self: *Maintained,
        service: anytype,
        a: std.mem.Allocator,
        task: t.Id,
        position: ?usize,
    ) !Change {
        self.counters.loads += 1;
        const loaded = try retained.load(service, a, task, self.page_limit);
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer destroyArena(self.allocator, arena);
        var record = try decodeRow(
            @import("protean_native"),
            arena.allocator(),
            a,
            retained.row(loaded),
            loaded.snapshot.bytes,
        );
        var change: Change = .{
            .task = task,
            .position = position,
            .settled = false,
            .arena = arena,
            .structural = true,
        };
        if (position) |found| {
            const old = self.current.records[found];
            record.selected = old.selected;
            record.superseded = old.superseded;
            change.structural = !std.meta.eql(old.input_digest, record.input_digest) or
                !std.meta.eql(old.result_digest, record.result_digest) or
                self.referenced.contains(task);
        } else if (cancellationOf(record)) |request| {
            const receipt = try readCancellation(service, self.receipts.allocator(), request);
            change.cancellation = receipt.value;
        }
        change.record = record;
        return change;
    }

    fn apply(self: *Maintained, changes: []const Change) !void {
        var inserts: usize = 0;
        var updates: usize = 0;
        for (changes) |change| {
            if (change.record != null and change.position == null) inserts += 1;
            if (change.record != null or change.evidence != null) updates += 1;
        }
        if (updates == 0) return;
        try self.cancellations.ensureUnusedCapacity(self.receipts.allocator(), inserts);
        if (self.pins != 0) {
            try self.copyRecords(inserts);
        } else try self.current.storage.ensureUnusedCapacity(self.allocator, inserts);
        const items = self.current.storage.items;
        for (changes) |change| {
            const position = change.position orelse continue;
            if (change.evidence) |evidence| items[position].owner_evidence = evidence;
            const record = change.record orelse continue;
            items[position] = record;
            const previous = self.owned.fetchPutAssumeCapacity(change.task, change.arena.?);
            if (previous) |entry| self.retire(.{ .arena = entry.value });
        }
        for (changes) |change| {
            if (change.position != null) continue;
            const record = change.record orelse continue;
            if (change.cancellation) |receipt| self.cancellations.appendAssumeCapacity(receipt);
            var low: usize = 0;
            var high = self.current.storage.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const other = self.current.storage.items[middle].task;
                if (std.mem.order(u8, &other, &record.task) == .lt) {
                    low = middle + 1;
                } else high = middle;
            }
            self.current.storage.insertAssumeCapacity(low, record);
            self.owned.putAssumeCapacity(change.task, change.arena.?);
        }
        self.current.records = self.current.storage.items;
    }

    fn copyRecords(self: *Maintained, extra: usize) !void {
        const items = self.current.storage.items;
        var copy = try std.ArrayList(Record).initCapacity(self.allocator, items.len + extra);
        copy.appendSliceAssumeCapacity(items);
        self.retire(.{ .records = self.current.storage });
        self.current.storage = copy;
        self.current.records = copy.items;
    }

    fn derive(self: *Maintained) !void {
        self.derived = false;
        try self.retired.ensureUnusedCapacity(self.allocator, 2);
        if (self.pins != 0) try self.copyRecords(0);
        const previous = self.current.arena;
        self.current.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.current.tasks = .empty;
        self.current.operations = .empty;
        self.current.lineages = .empty;
        self.current.continuity_import = null;
        self.current.transfer_marker = null;
        self.current.obligations = &.{};
        self.referenced = .empty;
        self.retire(.{ .derived = previous });
        const a = self.current.arena.allocator();
        const records = self.current.storage.items;
        try self.current.tasks.ensureTotalCapacity(a, @intCast(records.len));
        for (records, 0..) |*record, position| {
            record.selected = false;
            record.superseded = false;
            self.current.tasks.putAssumeCapacity(record.task, position);
        }
        self.counters.derivations += 1;
        try self.current.finish(self.cancellations.items);
        self.referenced = try references(a, records);
        self.derived = true;
    }
};

fn references(
    a: std.mem.Allocator,
    records: []const Record,
) !std.AutoHashMapUnmanaged(t.Id, void) {
    var result: std.AutoHashMapUnmanaged(t.Id, void) = .empty;
    for (records) |record| switch (record.input) {
        .step => |step| {
            for (step.facts.items) |fact| try result.put(a, fact.reference.task, {});
            if (step.supersession) |value| try result.put(a, value.input.task, {});
        },
        .turn => |turn| if (turn.replacement) |value|
            try result.put(a, value.input.task, {}),
        .continuity_cut => try result.put(a, record.task, {}),
        else => {},
    };
    return result;
}
pub fn difference(left: *const Index, right: *const Index) ?[]const u8 {
    if (!same(?t.Digest, left.namespace, right.namespace)) return "namespace";
    if (!same([]const Record, left.records, right.records)) return "records";
    if (!same(@TypeOf(left.tasks), left.tasks, right.tasks)) return "tasks";
    if (!same(@TypeOf(left.operations), left.operations, right.operations)) return "operations";
    if (!same(@TypeOf(left.lineages), left.lineages, right.lineages)) return "lineages";
    if (!same(?continuity.ImportView, left.continuity_import, right.continuity_import))
        return "continuity_import";
    if (!same(?usize, left.transfer_marker, right.transfer_marker)) return "transfer_marker";
    if (left.obligations.len != right.obligations.len) return "obligations";
    for (left.obligations, right.obligations) |x, y| {
        var l = x;
        var r = y;
        l.fault = null;
        r.fault = null;
        if (!same(Obligation, l, r)) return "obligations";
    }
    return null;
}

fn same(comptime T: type, x: T, y: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime @hasDecl(T, "KV") and @hasDecl(T, "iterator")) return sameMap(T, x, y);
            inline for (info.field_names, info.field_types) |name, Field| {
                if (!sameMember(Field, @field(x, name), @field(y, name))) return false;
            }
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
            return switch (x) {
                inline else => |value, tag| {
                    const other = @field(y, @tagName(tag));
                    return sameMember(@TypeOf(value), value, other);
                },
            };
        },
        .optional => |info| {
            if (x == null or y == null) return x == null and y == null;
            return sameMember(info.child, x.?, y.?);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) return std.mem.eql(u8, x, y);
                if (x.len != y.len) return false;
                for (x, y) |l, r| if (!sameMember(info.child, l, r)) return false;
                return true;
            },
            .one => return sameMember(info.child, x.*, y.*),
            else => @compileError("unsupported index pointer"),
        },
        .array => |info| {
            for (x, y) |l, r| if (!sameMember(info.child, l, r)) return false;
            return true;
        },
        else => return std.meta.eql(x, y),
    }
}

fn sameMember(comptime T: type, x: T, y: T) bool {
    return same(T, x, y);
}

fn sameMap(comptime T: type, x: T, y: T) bool {
    if (x.count() != y.count()) return false;
    var entries = x.iterator();
    while (entries.next()) |entry| {
        const other = y.get(entry.key_ptr.*) orelse return false;
        if (!sameMember(@TypeOf(other), entry.value_ptr.*, other)) return false;
    }
    return true;
}

pub fn verifyAgainstRebuild(
    service: anytype,
    a: std.mem.Allocator,
    maintained: *const Index,
    page_limit: u32,
) !void {
    var oracle = try rebuild(service, a, page_limit);
    defer oracle.deinit();
    if (difference(&oracle, maintained)) |field| {
        std.log.warn("maintained index differs from rebuild in {s}", .{field});
        return error.IndexDivergence;
    }
}
