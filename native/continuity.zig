const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const admission = @import("admission.zig");
const import_view = @import("continuity_import.zig");

pub const ImportView = import_view.View;
pub const ImportPhase = import_view.Phase;
pub const prepareImport = import_view.prepare;
pub const importedLineage = import_view.importedLineage;

pub const Source = struct {
    namespace: t.Digest,
    build: t.Digest,
    image: @import("compatibility.zig").ImageDigest,
    runtime: t.Digest,
    contracts: t.Digest,
    clock_ms: i64,
};
pub const Mode = enum { snapshot, transfer };
pub const Method = struct { source: t.ReportValue, report: t.ReportValue };
pub const Control = struct { body: t.DirectiveBody, method: ?Method };
pub const Turn = struct {
    namespace: t.Digest,
    input: t.Turn,
    result: ?t.TurnResult,
    accounting: t.Accounting,
};
pub const Carried = struct {
    head: t.Head,
    method: ?Method,
    disposition: ?t.ReportValue,
    batches: c.Vector(t.Batch, null),
};
pub const Obligation = struct {
    lineage: t.Digest,
    origin: t.Envelope,
    state: union(enum) { head: Carried, genesis: t.Specification },
    controls: c.Vector(Control, null),
    turns: c.Vector(Turn, null),
};
pub const tail_max = 128;
pub const Conversation = struct {
    tail: c.Vector(Turn, tail_max),
    pending: c.Vector(Turn, null),
};
pub const Member = union(enum) {
    obligation: Obligation,
    report: t.ReportValue,
    conversation: Conversation,
};
pub const Bundle = struct {
    version: u32 = 1,
    source: Source,
    mode: Mode,
    cut: t.Digest,
    archive_boundary: c.Text(1024),
    manifest: c.Vector(t.Digest, null),
    members: c.Vector(Member, null),
};

pub fn hash(bytes: []const u8) t.Digest {
    var result: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn digest(a: std.mem.Allocator, comptime T: type, value: T) !t.Digest {
    const bytes = try c.encodeOwned(T, a, value);
    defer a.free(bytes);
    return hash(bytes);
}

pub fn equal(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const first = try c.encodeOwned(T, a, left);
    defer a.free(first);
    const second = try c.encodeOwned(T, a, right);
    defer a.free(second);
    return std.mem.eql(u8, first, second);
}

const detached: t.Reference = .{ .task = @splat(0), .digest = @splat(0) };

pub fn detachMethod(method: t.Method) t.Method {
    var result = method;
    if (result == .retained) {
        result.retained.source = detached;
        result.retained.report = detached;
    }
    return result;
}

pub fn detachHead(head: t.Head) t.Head {
    var result = head;
    result.obligation = .{ .self = {} };
    result.predecessor = null;
    result.superseded = null;
    result.last_directive = null;
    result.consumed = .{ .items = &.{} };
    result.method = detachMethod(head.method);
    if (result.method_disposition) |*disposition| disposition.source = detached;
    if (result.last_observation) |*observation| if (observation.batch != null) {
        observation.batch = .{ .current = {} };
    };
    return result;
}

pub fn detachBody(body: t.DirectiveBody) t.DirectiveBody {
    var result = body;
    if (result == .adopt) result.adopt.method = detachMethod(body.adopt.method);
    return result;
}

pub fn detachTurn(turn: t.Turn) t.Turn {
    var result = turn;
    result.continuity = null;
    result.replacement = null;
    result.context_references = .{ .items = &.{} };
    result.target = null;
    result.model = null;
    return result;
}

pub fn validate(a: std.mem.Allocator, bundle: Bundle) !void {
    if (bundle.version != 1 or bundle.archive_boundary.bytes.len == 0)
        return error.UnsupportedContinuityBundle;
    if (bundle.manifest.items.len != bundle.members.items.len)
        return error.ContinuityManifestMismatch;
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    defer seen.deinit(a);
    var lineages: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    defer lineages.deinit(a);
    var conversations: usize = 0;
    for (bundle.manifest.items, bundle.members.items) |identity, item| {
        if (!std.meta.eql(try digest(a, Member, item), identity))
            return error.ContinuityDigestMismatch;
        if ((try seen.getOrPut(a, identity)).found_existing)
            return error.DuplicateContinuityMember;
        switch (item) {
            .obligation => |value| {
                if ((try lineages.getOrPut(a, value.lineage)).found_existing)
                    return error.DuplicateContinuityLineage;
                try validateObligation(a, bundle.mode, value);
            },
            .report => {},
            .conversation => |value| {
                conversations += 1;
                if (conversations > 1) return error.DuplicateContinuityConversation;
                for (value.tail.items) |turn| try validateTurn(a, turn, true);
                for (value.pending.items) |turn| try validateTurn(a, turn, false);
            },
        }
    }
}

fn validateObligation(a: std.mem.Allocator, mode: Mode, value: Obligation) !void {
    switch (value.state) {
        .head => |carried| try validateCarried(a, mode, value.lineage, carried),
        .genesis => |specification| try admission.specification(specification),
    }
    for (value.controls.items) |control| {
        if (control.body == .transfer) return error.InvalidContinuityControl;
        if (!try equal(a, t.DirectiveBody, detachBody(control.body), control.body))
            return error.AttachedContinuityReference;
        try validateMethod(directiveMethod(control.body), control.method);
    }
    for (value.turns.items) |turn| try validateTurn(a, turn, false);
}

fn validateCarried(a: std.mem.Allocator, mode: Mode, lineage: t.Digest, carried: Carried) !void {
    const head = carried.head;
    if (!std.meta.eql(head.lineage, lineage)) return error.ContinuityLineageMismatch;
    if (!try equal(a, t.Head, detachHead(head), head)) return error.AttachedContinuityReference;
    if (mode == .transfer and head.mode != .transferred and head.mode != .cancelled)
        return error.SourceNotTransferred;
    try admission.specification(head.specification);
    try validateMethod(head.method, carried.method);
    if ((head.method_disposition == null) != (carried.disposition == null))
        return error.InvalidContinuityMethod;
    var sequence = head.told.sequence;
    for (carried.batches.items) |batch| {
        sequence = try std.math.add(u64, sequence, 1);
        if (batch.sequence != sequence or sequence > head.observed.sequence)
            return error.BatchCoverageGap;
    }
}

pub fn directiveMethod(body: t.DirectiveBody) t.Method {
    return if (body == .adopt) body.adopt.method else .ordinary;
}

fn validateMethod(method: t.Method, value: ?Method) !void {
    if ((method == .retained) != (value != null)) return error.InvalidContinuityMethod;
}

fn validateTurn(a: std.mem.Allocator, turn: Turn, completed: bool) !void {
    if ((turn.result != null) != completed) return error.InvalidContinuityTurn;
    if (!try equal(a, t.Turn, detachTurn(turn.input), turn.input))
        return error.AttachedContinuityReference;
}

pub const Mapped = enum { report, genesis, directive, turn };
pub const Position = struct { member: u32, position: u32 };

pub fn mappedOperation(
    a: std.mem.Allocator,
    kind: Mapped,
    bundle: t.Digest,
    key: anytype,
) ![]u8 {
    const Key = struct { bundle: t.Digest, key: @TypeOf(key) };
    const identity = try digest(a, Key, .{ .bundle = bundle, .key = key });
    return std.fmt.allocPrint(a, "continuity-{s}:{s}", .{
        @tagName(kind), std.fmt.bytesToHex(identity, .lower),
    });
}

pub const attempts_max = 64;
const attempt_marker = ":attempt-";

pub fn attemptOperation(a: std.mem.Allocator, base: []const u8, attempt: usize) ![]u8 {
    if (attempt == 0) return a.dupe(u8, base);
    return std.fmt.allocPrint(a, "{s}{s}{d}", .{ base, attempt_marker, attempt });
}

pub fn attemptBase(operation: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, operation, attempt_marker) orelse return operation;
    return operation[0..at];
}

pub const Value = struct { identity: t.Digest, report: t.ReportValue };

pub fn values(a: std.mem.Allocator, bundle: Bundle) ![]const Value {
    var result: std.ArrayList(Value) = .empty;
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    defer seen.deinit(a);
    const Collect = struct {
        fn add(
            allocator: std.mem.Allocator,
            list: *std.ArrayList(Value),
            known: *std.AutoHashMapUnmanaged(t.Digest, void),
            report: t.ReportValue,
        ) !void {
            const identity = try digest(allocator, t.ReportValue, report);
            if ((try known.getOrPut(allocator, identity)).found_existing) return;
            try list.append(allocator, .{ .identity = identity, .report = report });
        }
        fn method(
            allocator: std.mem.Allocator,
            list: *std.ArrayList(Value),
            known: *std.AutoHashMapUnmanaged(t.Digest, void),
            value: ?Method,
        ) !void {
            const carried = value orelse return;
            try add(allocator, list, known, carried.source);
            try add(allocator, list, known, carried.report);
        }
    };
    for (bundle.members.items) |item| switch (item) {
        .report => |report| try Collect.add(a, &result, &seen, report),
        .conversation => {},
        .obligation => |value| {
            if (value.state == .head) {
                const carried = value.state.head;
                try Collect.method(a, &result, &seen, carried.method);
                if (carried.disposition) |report| try Collect.add(a, &result, &seen, report);
            }
            for (value.controls.items) |control|
                try Collect.method(a, &result, &seen, control.method);
        },
    };
    return result.toOwnedSlice(a);
}

pub fn localReport(
    a: std.mem.Allocator,
    index: anytype,
    bundle: t.Digest,
    report: t.ReportValue,
) !?t.Reference {
    const identity = try digest(a, t.ReportValue, report);
    const base = try mappedOperation(a, .report, bundle, identity);
    defer a.free(base);
    for (0..attempts_max) |attempt| {
        const operation = try attemptOperation(a, base, attempt);
        defer a.free(operation);
        const position = index.operations.get(operation) orelse return null;
        if (try reportAttempt(a, index.records[position], bundle, identity)) |found| return found;
    }
    return null;
}

fn reportAttempt(
    a: std.mem.Allocator,
    record: anytype,
    bundle: t.Digest,
    identity: t.Digest,
) !?t.Reference {
    if (record.input != .continuity_member) return error.InvalidContinuityMember;
    const input = record.input.continuity_member;
    if (!std.meta.eql(input.bundle, bundle) or
        !std.meta.eql(input.envelope.stable_request, identity) or
        !std.meta.eql(try digest(a, t.ReportValue, input.report), identity))
        return error.InvalidContinuityMember;
    if (record.result) |output| if (output != .continuity_member or
        !try equal(a, t.ContinuityMember, input, output.continuity_member))
        return error.InvalidContinuityMember;
    return .{ .task = record.task, .digest = record.result_digest orelse return null };
}

pub fn localMethod(
    a: std.mem.Allocator,
    index: anytype,
    bundle: t.Digest,
    method: t.Method,
    value: ?Method,
) !?t.Method {
    var result = method;
    if (result == .retained) {
        const carried = value orelse return error.InvalidContinuityMethod;
        result.retained.source = try localReport(a, index, bundle, carried.source) orelse
            return null;
        result.retained.report = try localReport(a, index, bundle, carried.report) orelse
            return null;
    }
    return result;
}

pub fn genesisInput(
    a: std.mem.Allocator,
    index: anytype,
    view: ImportView,
    member: u32,
    clock_ms: i64,
    origin: t.Origin,
) !?t.Genesis {
    const bundle = view.bundle orelse return error.MissingContinuityManifest;
    if (member >= bundle.members.items.len or bundle.members.items[member] != .obligation)
        return error.MissingContinuityLineage;
    const value = bundle.members.items[member].obligation;
    const carried: ?t.CarriedHead = switch (value.state) {
        .head => |state| try carriedHead(a, index, view.digest, state) orelse return null,
        .genesis => null,
    };
    return .{
        .envelope = .{
            .operation = .{ .bytes = try mappedOperation(a, .genesis, view.digest, value.lineage) },
            .stable_request = bundle.manifest.items[member],
            .origin = origin,
        },
        .lineage = value.lineage,
        .specification = switch (value.state) {
            .head => |state| state.head.specification,
            .genesis => |specification| specification,
        },
        .clock_ms = clock_ms,
        .imported = .{ .carried = carried, .continuity = .{
            .bundle = view.digest,
            .manifest = view.manifest.?,
            .member = member,
        } },
    };
}

fn carriedHead(
    a: std.mem.Allocator,
    index: anytype,
    bundle: t.Digest,
    state: Carried,
) !?t.CarriedHead {
    var head = state.head;
    head.method = try localMethod(a, index, bundle, head.method, state.method) orelse return null;
    if (head.method_disposition) |*disposition| {
        const report = state.disposition orelse return error.InvalidContinuityMethod;
        disposition.source = try localReport(a, index, bundle, report) orelse return null;
    }
    return .{ .head = head, .batches = state.batches };
}

pub fn validateImports(a: std.mem.Allocator, index: anytype) !void {
    for (index.records) |record| {
        if (record.input != .genesis) continue;
        const genesis = record.input.genesis;
        const imported = genesis.imported orelse continue;
        const view = index.continuity_import orelse return error.MissingContinuityManifest;
        const metadata = imported.continuity;
        if (view.bundle == null or !std.meta.eql(metadata.bundle, view.digest) or
            !std.meta.eql(metadata.manifest, view.manifest.?))
            return error.ContinuityCutMismatch;
        var expected = try genesisInput(
            a,
            index,
            view,
            metadata.member,
            genesis.clock_ms,
            genesis.envelope.origin,
        ) orelse return error.ContinuityHeadMismatch;
        const operation = genesis.envelope.operation;
        if (std.mem.eql(u8, attemptBase(operation.bytes), expected.envelope.operation.bytes))
            expected.envelope.operation = operation;
        if (!try equal(a, t.Genesis, expected, genesis)) return error.ContinuityHeadMismatch;
    }
}

pub const Imported = struct { view: ImportView, member: u32, value: Obligation };

pub fn importedObligation(index: anytype, target: t.Id) ?Imported {
    const record = index.record(target) orelse return null;
    if (record.input != .genesis) return null;
    const imported = record.input.genesis.imported orelse return null;
    const view = index.continuity_import orelse return null;
    const bundle = view.bundle orelse return null;
    const member = imported.continuity.member;
    return .{ .view = view, .member = member, .value = bundle.members.items[member].obligation };
}

pub fn controlOperation(a: std.mem.Allocator, found: Imported, position: usize) ![]u8 {
    return mappedOperation(a, .directive, found.view.digest, Position{
        .member = found.member,
        .position = @intCast(position),
    });
}

pub fn controlBody(
    a: std.mem.Allocator,
    index: anytype,
    bundle: t.Digest,
    control: Control,
) !t.DirectiveBody {
    var body = control.body;
    if (body == .adopt) body.adopt.method = try localMethod(
        a,
        index,
        bundle,
        body.adopt.method,
        control.method,
    ) orelse return error.MissingContinuityReport;
    return body;
}

pub fn mappedControl(
    a: std.mem.Allocator,
    index: anytype,
    target: t.Id,
    found: Imported,
    position: usize,
) !?usize {
    const operation = try controlOperation(a, found, position);
    defer a.free(operation);
    const local = index.operations.get(operation) orelse return null;
    const record = index.records[local];
    const control = found.value.controls.items[position];
    const body = try controlBody(a, index, found.view.digest, control);
    const stable = try admission.directiveDigest(a, operation, try digest(a, Control, control));
    if (record.input != .directive or
        !std.meta.eql(record.input.directive.obligation, target) or
        record.input.directive.envelope.origin != .local or
        !std.meta.eql(record.input.directive.envelope.stable_request, stable) or
        !try equal(a, t.DirectiveBody, body, record.input.directive.body))
        return error.InvalidMappedContinuityControl;
    return local;
}

pub fn controlsComplete(
    a: std.mem.Allocator,
    index: anytype,
    target: t.Id,
    folded_ordinal: ?u64,
) !bool {
    const found = importedObligation(index, target) orelse return true;
    for (0..found.value.controls.items.len) |position| {
        const local = try mappedControl(a, index, target, found, position) orelse return false;
        if (folded_ordinal) |ordinal|
            if (index.records[local].input.directive.ordinal > ordinal) return false;
    }
    return true;
}

pub fn importedGenesis(index: anytype, operation: []const u8) bool {
    const view = index.continuity_import orelse return false;
    const bundle = view.bundle orelse return false;
    for (bundle.members.items) |item| {
        if (item != .obligation) continue;
        if (std.mem.eql(u8, item.obligation.origin.operation.bytes, operation)) return true;
    }
    return false;
}
