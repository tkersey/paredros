const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const compatibility = @import("compatibility.zig");
const continuity = @import("continuity.zig");
const configuration = @import("configuration.zig");
const materialize = @import("materialize.zig");
const method_catalog = @import("method_catalog.zig");
const experiments = @import("experiments.zig");
const continuity_turn = @import("continuity_turn.zig");

pub const Bundle = continuity.Bundle;
pub const Source = continuity.Source;
pub const Mode = continuity.Mode;
pub const OwnedBundle = c.Decoded(Bundle);

fn cutDigest(a: std.mem.Allocator, index: *const idx.Index) !t.Digest {
    const Row = struct {
        task: t.Id,
        revision: u64,
        input: t.Digest,
        result: ?t.Digest,
        event: u64,
    };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    for (index.records) |record| {
        if (record.input == .continuity_cut) continue;
        const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
        try rows.append(a, .{
            .task = record.task,
            .revision = record.revision,
            .input = record.input_digest,
            .result = record.result_digest,
            .event = snapshot.event_cut,
        });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            return std.mem.order(u8, &left.task, &right.task) == .lt;
        }
    }.less);
    return continuity.digest(a, c.Vector(Row, null), .{ .items = rows.items });
}

fn portableReport(record: idx.Record) !?t.ReportValue {
    var value = try method_catalog.reportOf(record) orelse return null;
    if (record.input == .experiment) {
        const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
        value.result = experiments.accounted(value.result, snapshot.accounting);
    }
    return value;
}

fn referencedReport(index: *const idx.Index, reference: t.Reference) !t.ReportValue {
    _ = try method_catalog.reportValue(index, reference);
    return try portableReport(index.record(reference.task).?.*) orelse error.InvalidExperiment;
}

fn carriedMethod(index: *const idx.Index, method: t.Method) !?continuity.Method {
    if (method != .retained) return null;
    return .{
        .source = try referencedReport(index, method.retained.source),
        .report = try referencedReport(index, method.retained.report),
    };
}

fn carriedControls(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    imported: ?continuity.Imported,
) ![]const continuity.Control {
    var result: std.ArrayList(continuity.Control) = .empty;
    const folded = index.head(obligation).folded_directive_ordinal;
    for (obligation.directives) |position| {
        const body = index.records[position].input.directive.body;
        if (index.records[position].input.directive.ordinal <= folded or body == .transfer)
            continue;
        try result.append(a, .{
            .body = continuity.detachBody(body),
            .method = try carriedMethod(index, continuity.directiveMethod(body)),
        });
    }
    const found = imported orelse return result.toOwnedSlice(a);
    for (found.value.controls.items, 0..) |control, position| {
        if (try continuity.mappedControl(a, index, obligation.task, found, position) == null)
            try result.append(a, control);
    }
    return result.toOwnedSlice(a);
}

fn turnValue(index: *const idx.Index, own: t.Digest, record: idx.Record) !continuity.Turn {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    const turn = record.input.turn;
    const prior = continuity_turn.carried(index, turn);
    return .{
        .namespace = if (prior) |value| value.namespace else own,
        .input = continuity.detachTurn(turn),
        .result = if (record.result) |output| output.turn else null,
        .accounting = snapshot.accounting,
    };
}

fn localTurns(
    a: std.mem.Allocator,
    index: *const idx.Index,
    own: t.Digest,
    target: ?t.Id,
    completed: bool,
) ![]continuity.Turn {
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(a);
    for (index.records, 0..) |record, position| {
        if (record.input != .turn or record.superseded or (record.result != null) != completed)
            continue;
        if (!completed and !std.meta.eql(record.input.turn.target, target)) continue;
        try positions.append(a, position);
    }
    std.mem.sort(usize, positions.items, index, struct {
        fn less(context: *const idx.Index, left: usize, right: usize) bool {
            const x = context.records[left];
            const y = context.records[right];
            if (x.input.turn.ordinal != y.input.turn.ordinal)
                return x.input.turn.ordinal < y.input.turn.ordinal;
            return std.mem.order(u8, &x.task, &y.task) == .lt;
        }
    }.less);
    const result = try a.alloc(continuity.Turn, positions.items.len);
    for (result, positions.items) |*slot, position|
        slot.* = try turnValue(index, own, index.records[position]);
    return result;
}

fn unadmittedTurns(
    a: std.mem.Allocator,
    index: *const idx.Index,
    member: u32,
    turns: []const continuity.Turn,
    result: *std.ArrayList(continuity.Turn),
) !void {
    const view = index.continuity_import.?;
    for (turns, 0..) |turn, position| {
        const name = try continuity_turn.operation(a, view, .{
            .member = member,
            .position = @intCast(position),
        });
        if (!index.operations.contains(name)) try result.append(a, turn);
    }
}

fn carry(
    a: std.mem.Allocator,
    index: *const idx.Index,
    own: t.Digest,
    obligation: *const idx.Obligation,
    mode: Mode,
) !continuity.Obligation {
    const head = index.head(obligation);
    if (mode == .transfer and head.mode != .transferred and head.mode != .cancelled)
        return error.SourceNotTransferred;
    const imported = continuity.importedObligation(index, obligation.task);
    var turns: std.ArrayList(continuity.Turn) = .empty;
    try turns.appendSlice(a, try localTurns(a, index, own, obligation.task, false));
    if (imported) |found|
        try unadmittedTurns(a, index, found.member, found.value.turns.items, &turns);
    const owed = try materialize.candidates(a, index, obligation);
    var batches: std.ArrayList(t.Batch) = .empty;
    for (owed) |fact| {
        if (fact.value.sequence > head.told.sequence) try batches.append(a, fact.value);
    }
    return .{
        .lineage = head.lineage,
        .origin = if (imported) |found|
            found.value.origin
        else
            index.records[obligation.chain[0]].input.genesis.envelope,
        .state = .{ .head = .{
            .head = continuity.detachHead(head),
            .method = try carriedMethod(index, head.method),
            .disposition = if (head.method_disposition) |disposition|
                try referencedReport(index, disposition.source)
            else
                null,
            .batches = .{ .items = batches.items },
        } },
        .controls = .{ .items = try carriedControls(a, index, obligation, imported) },
        .turns = .{ .items = turns.items },
    };
}

fn strandedObligation(index: *const idx.Index, task: t.Id) !continuity.Obligation {
    const record = index.record(task) orelse return error.MissingContinuityGenesis;
    if (record.input != .genesis or record.result != null or
        record.input.genesis.imported != null) return error.InvalidContinuityGenesis;
    const genesis = record.input.genesis;
    return .{
        .lineage = genesis.lineage,
        .origin = genesis.envelope,
        .state = .{ .genesis = genesis.specification },
        .controls = .{ .items = &.{} },
        .turns = .{ .items = &.{} },
    };
}

fn conversation(
    a: std.mem.Allocator,
    index: *const idx.Index,
    own: t.Digest,
) !continuity.Conversation {
    var tail: std.ArrayList(continuity.Turn) = .empty;
    var pending: std.ArrayList(continuity.Turn) = .empty;
    try pending.appendSlice(a, try localTurns(a, index, own, null, false));
    if (index.continuity_import) |view| for (view.bundle.?.members.items, 0..) |item, member| {
        if (item != .conversation) continue;
        try tail.appendSlice(a, item.conversation.tail.items);
        try unadmittedTurns(a, index, @intCast(member), item.conversation.pending.items, &pending);
    };
    try tail.appendSlice(a, try localTurns(a, index, own, null, true));
    const kept = tail.items[tail.items.len - @min(tail.items.len, continuity.tail_max) ..];
    return .{ .tail = .{ .items = kept }, .pending = .{ .items = pending.items } };
}

const Members = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(continuity.Member) = .empty,
    manifest: std.ArrayList(t.Digest) = .empty,
    seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty,

    fn add(self: *Members, item: continuity.Member) !void {
        const identity = try continuity.digest(self.allocator, continuity.Member, item);
        if ((try self.seen.getOrPut(self.allocator, identity)).found_existing) return;
        try self.items.append(self.allocator, item);
        try self.manifest.append(self.allocator, identity);
    }
};

pub fn prepare(
    a: std.mem.Allocator,
    index: *const idx.Index,
    source: Source,
    mode: Mode,
    stranded: []const t.Id,
) !OwnedBundle {
    if (importPending(index)) return error.ContinuityImportPending;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var members: Members = .{ .allocator = scratch };
    for (index.obligations) |*obligation| try members.add(.{
        .obligation = try carry(scratch, index, source.namespace, obligation, mode),
    });
    for (stranded) |task| try members.add(.{ .obligation = try strandedObligation(index, task) });
    for (index.records) |record| {
        const report = try portableReport(record) orelse continue;
        try members.add(.{ .report = report });
    }
    const talk = try conversation(scratch, index, source.namespace);
    if (talk.tail.items.len + talk.pending.items.len != 0)
        try members.add(.{ .conversation = talk });
    const bundle: Bundle = .{
        .source = source,
        .mode = mode,
        .cut = try cutDigest(scratch, index),
        .archive_boundary = .{ .bytes = "Portable application values through this cut; " ++
            "the source namespace retains native execution and historical archive custody." },
        .manifest = .{ .items = members.manifest.items },
        .members = .{ .items = members.items.items },
    };
    try continuity.validate(scratch, bundle);
    return c.decodeOwned(Bundle, a, try c.encodeOwned(Bundle, scratch, bundle));
}

pub fn capture(driver: anytype, a: std.mem.Allocator, source: Source, mode: Mode) !OwnedBundle {
    if (!driver.attached) return error.DriverDetached;
    const gate = driver.service.dispatch_gate;
    driver.service.dispatch_gate = .held;
    defer driver.service.dispatch_gate = gate;
    var index = try driver.rebuild(a);
    defer index.deinit();
    const unrun = try unrunGeneses(driver.service, a, &index);
    defer a.free(unrun.stranded);
    if (unrun.pending) return error.ContinuityGenesisPending;
    return prepare(a, &index, source, mode, unrun.stranded);
}

pub const ImportProgress = struct {
    phase: continuity.ImportPhase,
    manifest: t.Id,
    members: u64,
    obligations: []const t.Id,

    pub fn deinit(self: *ImportProgress, a: std.mem.Allocator) void {
        a.free(self.obligations);
        self.* = undefined;
    }
};
pub const members_per_step = 64;

pub fn validateBindings(bundle: Bundle, bindings: configuration.Bindings) !void {
    for (bundle.members.items) |item| {
        if (item != .obligation) continue;
        const specification = switch (item.obligation.state) {
            .head => |carried| if (carried.head.mode == .cancelled)
                continue
            else
                carried.head.specification,
            .genesis => |value| value,
        };
        if (!bindings.admits(specification.repository)) return error.ContinuityResourceMismatch;
    }
}

fn validateFresh(index: *const idx.Index, identity: t.Digest) !void {
    for (index.records) |record| switch (record.input) {
        .continuity_cut => |cut| {
            if (!std.meta.eql(cut.bundle_digest, identity)) return error.ContinuityImportConflict;
        },
        .continuity_member => |member| {
            if (!std.meta.eql(member.bundle, identity)) return error.ContinuityImportConflict;
        },
        .genesis => |genesis| {
            const imported = genesis.imported orelse return error.ImportTargetNotFresh;
            if (!std.meta.eql(imported.continuity.bundle, identity))
                return error.ContinuityImportConflict;
        },
        else => return error.ImportTargetNotFresh,
    };
}

fn validateTarget(
    index: *const idx.Index,
    namespace: t.Digest,
    bundle: Bundle,
    identity: t.Digest,
) !void {
    if (std.meta.eql(bundle.source.namespace, namespace)) return error.ImportTargetNotFresh;
    for (bundle.members.items) |item| {
        if (item == .obligation)
            _ = try continuity.importedLineage(index, item.obligation.lineage, identity);
    }
    const view = index.continuity_import orelse return validateFresh(index, identity);
    if (!std.meta.eql(view.digest, identity)) return error.ContinuityImportConflict;
}

pub fn validateImport(
    a: std.mem.Allocator,
    index: *const idx.Index,
    config: configuration.Config,
    namespace: t.Digest,
    bundle: Bundle,
) !?t.Id {
    try continuity.validate(a, bundle);
    const identity = try continuity.digest(a, Bundle, bundle);
    try validateTarget(index, namespace, bundle, identity);
    try validateBindings(bundle, configuration.bindings(config));
    const view = index.continuity_import orelse return null;
    return index.records[view.position].task;
}

fn completedCut(a: std.mem.Allocator, record: idx.Record, identity: t.Digest) !?t.Reference {
    if (record.input != .continuity_cut or
        !std.meta.eql(record.input.continuity_cut.bundle_digest, identity))
        return error.InvalidContinuityManifest;
    const result = record.result orelse return null;
    if (result != .continuity_cut or record.result_digest == null or
        !try continuity.equal(
            a,
            t.ContinuityCut,
            record.input.continuity_cut,
            result.continuity_cut,
        )) return error.InvalidContinuityManifest;
    return .{ .task = record.task, .digest = record.result_digest.? };
}

pub fn importProgress(driver: anytype, a: std.mem.Allocator) !ImportProgress {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var index = try driver.rebuild(arena.allocator());
    defer index.deinit();
    const view = index.continuity_import orelse return error.MissingContinuityManifest;
    var obligations: std.ArrayList(t.Id) = .empty;
    errdefer obligations.deinit(a);
    if (view.bundle) |bundle| for (bundle.members.items) |item| {
        if (item != .obligation) continue;
        const position = try continuity.importedLineage(
            &index,
            item.obligation.lineage,
            view.digest,
        ) orelse continue;
        try obligations.append(a, index.records[position].task);
    };
    return .{
        .phase = view.phase,
        .manifest = index.records[view.position].task,
        .members = view.materialized,
        .obligations = try obligations.toOwnedSlice(a),
    };
}

pub fn advanceImport(driver: anytype, a: std.mem.Allocator, index: *const idx.Index) !bool {
    if (!driver.attached) return error.DriverDetached;
    const view = index.continuity_import orelse return false;
    if (view.phase == .manifest_pending or view.phase == .materialized) return false;
    const bindings = driver.bindings orelse return error.MissingResourceBindings;
    validateBindings(view.bundle.?, bindings) catch return false;
    const origin = index.records[view.position].input.continuity_cut.envelope.origin;
    if (view.phase == .values_pending) return submitValues(driver, a, index, view, origin);
    return submitGeneses(driver, a, index, view, origin);
}

fn submitValues(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    view: continuity.ImportView,
    origin: t.Origin,
) !bool {
    var submitted: usize = 0;
    for (try continuity.values(a, view.bundle.?)) |value| {
        if (submitted == members_per_step) break;
        const operation = try continuity.mappedOperation(a, .report, view.digest, value.identity);
        if (index.operations.contains(operation)) continue;
        _ = try driver.service.submit(a, operation, .{ .continuity_member = .{
            .envelope = .{
                .operation = .{ .bytes = operation },
                .stable_request = value.identity,
                .origin = origin,
            },
            .bundle = view.digest,
            .report = value.report,
        } });
        submitted += 1;
    }
    return submitted != 0;
}

fn submitGeneses(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    view: continuity.ImportView,
    origin: t.Origin,
) !bool {
    const clock_ms = try driver.clock.now(driver.clock.context);
    var submitted: usize = 0;
    for (view.bundle.?.members.items, 0..) |item, member| {
        if (submitted == members_per_step) break;
        if (item != .obligation) continue;
        if (try continuity.importedLineage(index, item.obligation.lineage, view.digest) != null)
            continue;
        const position: u32 = @intCast(member);
        const input = try continuity.genesisInput(a, index, view, position, clock_ms, origin) orelse
            return error.MissingContinuityReport;
        _ = try driver.service.submit(a, input.envelope.operation.bytes, .{ .genesis = input });
        submitted += 1;
    }
    return submitted != 0;
}

pub fn committedBundle(
    a: std.mem.Allocator,
    index: *const idx.Index,
    task: t.Id,
) !OwnedBundle {
    const record = index.record(task) orelse return error.MissingContinuityManifest;
    if (record.input != .continuity_cut) return error.InvalidContinuityManifest;
    const identity = record.input.continuity_cut.bundle_digest;
    _ = (try completedCut(a, record.*, identity)) orelse return error.ContinuityCutPending;
    const bytes = record.input.continuity_cut.bytes.bytes;
    if (!std.meta.eql(continuity.hash(bytes), identity)) return error.ContinuityDigestMismatch;
    var bundle = try c.decodeOwned(Bundle, a, bytes);
    errdefer bundle.deinit();
    try continuity.validate(a, bundle.value);
    return bundle;
}

fn privateDescriptor(fd: std.c.fd_t) !void {
    if (@import("builtin").os.tag == .linux) {
        var status: std.os.linux.Statx = undefined;
        if (std.c.statx(
            fd,
            "",
            std.c.AT.EMPTY_PATH,
            .{ .UID = true, .MODE = true },
            &status,
        ) != 0) return error.TransferPathUnavailable;
        if (!status.mask.UID or !status.mask.MODE) return error.TransferPathUnavailable;
        if (status.uid != std.c.geteuid() or status.mode & 0o077 != 0)
            return error.UnsafeTransferPath;
    } else {
        var status: std.c.Stat = undefined;
        if (std.c.fstat(fd, &status) != 0) return error.TransferPathUnavailable;
        if (status.uid != std.c.geteuid() or status.mode & 0o077 != 0)
            return error.UnsafeTransferPath;
    }
}

fn openDestination(io: std.Io, path: []const u8, name: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path) or name.len == 0 or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidTransferPath;
    const directory = try std.Io.Dir.openDirAbsolute(io, path, .{
        .follow_symlinks = false,
        .iterate = true,
    });
    errdefer directory.close(io);
    try privateDescriptor(directory.handle);
    return directory;
}

fn sameFile(
    a: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    expected: []const u8,
) !bool {
    const file = try directory.openFile(io, name, .{
        .follow_symlinks = false,
        .allow_directory = false,
    });
    defer file.close(io);
    try privateDescriptor(file.handle);
    const status = try file.stat(io);
    if (status.nlink != 1 or status.size != expected.len) return false;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .limited(expected.len));
    defer a.free(bytes);
    return std.mem.eql(u8, bytes, expected);
}

fn writeBytes(
    a: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    name: []const u8,
    bytes: []const u8,
) !t.Digest {
    const directory = try openDestination(io, directory_path, name);
    defer directory.close(io);
    var atomic = try directory.createFileAtomic(io, name, .{
        .permissions = .fromMode(0o600),
        .replace = false,
    });
    defer atomic.deinit(io);
    try privateDescriptor(atomic.file.handle);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!try sameFile(a, io, directory, name, bytes)) return error.TransferFileConflict;
        },
        else => return err,
    };
    if (std.c.fsync(directory.handle) != 0) return error.TransferDirectorySyncFailed;
    return continuity.hash(bytes);
}

pub fn writeCommitted(
    a: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    index: *const idx.Index,
    task: t.Id,
) !t.Digest {
    var bundle = try committedBundle(a, index, task);
    defer bundle.deinit();
    const bytes = try c.encodeOwned(Bundle, a, bundle.value);
    defer a.free(bytes);
    return writeBytes(a, io, directory, name, bytes);
}

pub const PendingControlProgress = struct { admitted: ?t.Id = null, remaining: u64 = 0 };

pub fn admitPendingControls(
    driver: anytype,
    a: std.mem.Allocator,
    target: t.Id,
    origin: t.Origin,
) !PendingControlProgress {
    if (!driver.attached or origin != .local) return error.TransferLocalOnly;
    var index = try driver.rebuild(a);
    defer index.deinit();
    const found = continuity.importedObligation(&index, target) orelse return .{};
    var result: PendingControlProgress = .{};
    var next: ?usize = null;
    for (0..found.value.controls.items.len) |position| {
        if (try continuity.mappedControl(a, &index, target, found, position) != null) continue;
        result.remaining += 1;
        if (next == null) next = position;
    }
    const position = next orelse return result;
    const control = found.value.controls.items[position];
    const operation = try continuity.controlOperation(a, found, position);
    defer a.free(operation);
    result.admitted = try driver.directiveRequest(
        a,
        operation,
        origin,
        target,
        try continuity.controlBody(a, &index, found.view.digest, control),
        try continuity.digest(a, continuity.Control, control),
    );
    result.remaining -= 1;
    return result;
}

pub fn pendingControlsAdmitted(a: std.mem.Allocator, index: *const idx.Index, target: t.Id) !bool {
    return continuity.controlsComplete(a, index, target, null);
}

pub fn importPending(index: anytype) bool {
    const view = index.continuity_import orelse return false;
    return view.phase != .materialized;
}

pub fn genesisPending(service: anytype, a: std.mem.Allocator, index: *const idx.Index) !bool {
    const unrun = try unrunGeneses(service, a, index);
    a.free(unrun.stranded);
    return unrun.pending;
}

pub const Unrun = struct { pending: bool, stranded: []const t.Id };

pub fn unrunGeneses(service: anytype, a: std.mem.Allocator, index: *const idx.Index) !Unrun {
    var stranded: std.ArrayList(t.Id) = .empty;
    errdefer stranded.deinit(a);
    var pending = false;
    for (index.records) |record| {
        if (record.input != .genesis or record.result != null) continue;
        switch (try genesisDisposition(service, a, record.task)) {
            .settled => {},
            .runnable => pending = true,
            .stranded => if (record.input.genesis.imported == null) {
                try stranded.append(a, record.task);
            } else {
                pending = true;
            },
        }
    }
    return .{ .pending = pending, .stranded = try stranded.toOwnedSlice(a) };
}

const GenesisDisposition = enum { runnable, stranded, settled };

fn genesisDisposition(service: anytype, a: std.mem.Allocator, task: t.Id) !GenesisDisposition {
    var saved = try service.task(a, task);
    defer saved.deinit();
    const value = saved.value;
    const unrun: GenesisDisposition = if (value.cancellation == null) .stranded else .settled;
    switch (try service.status(a, value)) {
        .completed, .failed, .cancelled => return .settled,
        .blocked, .unknown => return unrun,
        .queued, .running, .waiting_input, .parked, .cancelling => {},
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const candidate = try compatibility.fromProfile(
        arena.allocator(),
        compatibility.ImageDigest.of(service.assets.image),
        service.application.controller != null,
        service.profile,
    );
    const disposition = try compatibility.classify(candidate, .{
        .task = value.id,
        .revision = value.revision,
        .terminal = value.terminal(),
        .application_id = value.application_id.bytes,
        .principal = value.principal.bytes,
        .tenant = value.tenant.bytes,
        .image = value.image,
        .profile = value.profile,
        .resources = value.resources.items,
        .runtime_identity = value.runtime_identity,
        .has_controller = value.controller != null,
    });
    return if (disposition == .exact_continuation) .runnable else unrun;
}

pub fn validateExportDestination(io: std.Io, directory: []const u8, name: []const u8) !void {
    const opened = try openDestination(io, directory, name);
    opened.close(io);
}

pub fn validateExportName(io: std.Io, directory: []const u8, name: []const u8) !void {
    const opened = try openDestination(io, directory, name);
    defer opened.close(io);
    _ = opened.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TransferFileConflict;
}

pub const PendingTurnProgress = continuity_turn.Progress;

pub fn admitPendingTurns(
    driver: anytype,
    a: std.mem.Allocator,
    origin: t.Origin,
) !PendingTurnProgress {
    return continuity_turn.admit(driver, a, origin);
}
