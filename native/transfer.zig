const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const compatibility = @import("compatibility.zig");
const continuity = @import("continuity.zig");
const configuration = @import("configuration.zig");
const experiments = @import("experiments.zig");

pub const Bundle = continuity.Bundle;
pub const Source = continuity.Source;
pub const Mode = @FieldType(Bundle, "mode");
pub const OwnedBundle = c.Decoded(Bundle);

fn global() t.Digest {
    return @splat(0);
}

fn rowReference(record: idx.Record, result: bool) !t.Reference {
    return .{
        .task = record.task,
        .digest = if (result)
            record.result_digest orelse return error.MissingContinuityResult
        else
            record.input_digest,
    };
}

fn recordLineage(index: *const idx.Index, record: idx.Record) !t.Digest {
    const target: ?t.Id = switch (record.input) {
        .genesis => return record.input.genesis.lineage,
        .step => |value| value.obligation,
        .directive => |value| value.obligation,
        .turn => |value| value.target,
        else => null,
    };
    const source = if (target) |value| index.record(value) else null;
    if (source) |value| {
        if (value.input != .genesis) return error.InvalidContinuityTarget;
        return value.input.genesis.lineage;
    }
    return global();
}

fn portableValue(value: idx.Value) continuity.Value {
    return .{
        .schema = .{ .bytes = value.schema_id },
        .encoding = switch (value.encoding) {
            .contract => .contract,
            .json => .json,
        },
        .bytes = .{ .bytes = value.bytes },
    };
}

fn sourceFact(a: std.mem.Allocator, record: idx.Record) !continuity.SourceFact {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    const evidence = record.owner_evidence orelse return error.MissingOwnerEvidence;
    const attempts = try a.alloc(continuity.SourceAttempt, evidence.attempts.len);
    for (attempts, evidence.attempts) |*target, value| target.* = .{
        .id = value.id,
        .response = if (value.response) |bytes| .{ .bytes = bytes } else null,
        .reply = if (value.reply) |bytes| .{ .bytes = bytes } else null,
    };
    return .{
        .snapshot = snapshot,
        .input = portableValue(evidence.input),
        .result = if (evidence.result) |value| portableValue(value) else null,
        .attempts = .{ .items = attempts },
    };
}

const Builder = struct {
    allocator: std.mem.Allocator,
    source: Source,
    members: std.ArrayList(continuity.Member) = .empty,
    seen: std.AutoHashMapUnmanaged(t.Digest, usize) = .empty,
    directives: std.AutoHashMapUnmanaged(t.Id, usize) = .empty,

    fn add(
        self: *Builder,
        comptime kind: t.ContinuityKind,
        lineage_id: t.Digest,
        record: idx.Record,
        current: t.Reference,
        value: continuity.Payload(kind),
    ) !t.Digest {
        const source_digest = if (kind == .settlement)
            try continuity.digest(self.allocator, retained.Snapshot, value.snapshot)
        else
            current.digest;
        const source_schema = if (kind == .settlement)
            "paredros.owner.snapshot.v1"
        else if (std.meta.eql(current.digest, record.input_digest))
            t.input_schema_id
        else
            t.output_schema_id;
        const data: t.ContinuityData = .{
            .lineage = lineage_id,
            .kind = kind,
            .schema = .{ .bytes = continuity.schema(kind) },
            .source = .{
                .namespace = self.source.namespace,
                .build = self.source.build,
                .task = record.task,
                .revision = record.revision,
                .schema = .{ .bytes = source_schema },
                .digest = source_digest,
            },
            .payload = .{ .bytes = try c.encodeOwned(
                continuity.Payload(kind),
                self.allocator,
                value,
            ) },
            .dependencies = .{ .items = &.{} },
        };
        return self.addData(current, data);
    }

    fn addData(self: *Builder, current: t.Reference, data: t.ContinuityData) !t.Digest {
        const identity = try continuity.digest(self.allocator, t.ContinuityData, data);
        const entry = try self.seen.getOrPut(self.allocator, identity);
        if (entry.found_existing) {
            const old = self.members.items[entry.value_ptr.*];
            if (!std.meta.eql(old.current, current)) return error.AmbiguousContinuityProducer;
            return identity;
        }
        entry.value_ptr.* = self.members.items.len;
        if (data.kind == .directive)
            try self.directives.put(self.allocator, current.task, self.members.items.len);
        try self.members.append(self.allocator, .{
            .identity = identity,
            .current = current,
            .data = data,
        });
        return identity;
    }

    fn link(self: *Builder, mode: Mode) !void {
        var catalog = try continuity.Catalog.init(self.allocator, .{
            .source = self.source,
            .mode = mode,
            .cut = .{ .items = &.{} },
            .cut_digest = @splat(0),
            .lineages = .{ .items = &.{} },
            .members = .{ .items = self.members.items },
            .archive_boundary = .{ .bytes = "" },
        });
        defer catalog.deinit();
        for (self.members.items) |*item| {
            if (item.data.kind == .head or
                !std.meta.eql(item.data.source.namespace, self.source.namespace)) continue;
            var linked: Linked = .{ .catalog = &catalog, .allocator = self.allocator };
            switch (item.data.kind) {
                inline else => |kind| {
                    const decoded = try continuity.decode(kind, self.allocator, item.data);
                    try continuity.visit(continuity.Payload(kind), decoded.value, &linked);
                },
            }
            if (linked.dependencies.items.len == 0) continue;
            const old = item.identity;
            item.data.dependencies = .{ .items = linked.dependencies.items };
            item.identity = try continuity.digest(self.allocator, t.ContinuityData, item.data);
            const position = self.seen.fetchRemove(old).?.value;
            try self.seen.put(self.allocator, item.identity, position);
        }
    }

    fn appendRecord(self: *Builder, index: *const idx.Index, value: idx.Record) !void {
        switch (value.input) {
            .continuity_cut => return,
            .continuity_member => |input| {
                _ = try self.addData(try rowReference(value, true), input.data);
                return;
            },
            else => {},
        }
        _ = try self.add(
            .settlement,
            global(),
            value,
            try rowReference(value, false),
            try sourceFact(self.allocator, value),
        );
        const lineage_id = try recordLineage(index, value);
        switch (value.input) {
            .directive => |input| {
                _ = try self.add(
                    .directive,
                    lineage_id,
                    value,
                    try rowReference(value, false),
                    input,
                );
            },
            .turn => |input| {
                _ = try self.add(.turn, lineage_id, value, try rowReference(value, false), .{
                    .input = input,
                    .result = if (value.result) |output| output.turn else null,
                });
            },
            .step => if (value.selected and value.result != null) {
                if (value.result.?.step.batch) |batch|
                    _ = try self.add(
                        .batch,
                        lineage_id,
                        value,
                        try rowReference(value, true),
                        batch,
                    );
            },
            .experiment => |input| if (try experiments.settled(value)) |result| {
                _ = try self.add(.method_report, global(), value, try rowReference(value, true), .{
                    .input = input,
                    .result = result,
                });
            },
            .genesis, .continuity_member, .continuity_cut, .transfer => {},
        }
    }
};

const Linked = struct {
    catalog: *const continuity.Catalog,
    allocator: std.mem.Allocator,
    dependencies: std.ArrayList(t.Digest) = .empty,

    pub fn reference(self: *Linked, kind: t.ContinuityKind, value: t.Reference) !void {
        const identity = try self.catalog.resolve(kind, value);
        for (self.dependencies.items) |prior| if (std.meta.eql(prior, identity)) return;
        try self.dependencies.append(self.allocator, identity);
    }
};

fn cutRows(a: std.mem.Allocator, index: *const idx.Index) ![]continuity.CutRow {
    var rows: std.ArrayList(continuity.CutRow) = .empty;
    for (index.records) |record| {
        if (record.input == .continuity_cut) continue;
        const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
        try rows.append(a, .{
            .task = record.task,
            .revision = record.revision,
            .input = record.input_digest,
            .result = record.result_digest,
            .event_cut = snapshot.event_cut,
        });
    }
    std.mem.sort(continuity.CutRow, rows.items, {}, struct {
        fn less(_: void, left: continuity.CutRow, right: continuity.CutRow) bool {
            return std.mem.order(u8, &left.task, &right.task) == .lt;
        }
    }.less);
    return rows.toOwnedSlice(a);
}

fn addRoots(
    builder: *Builder,
    index: *const idx.Index,
    mode: Mode,
) ![]const continuity.Lineage {
    const roots = try builder.allocator.alloc(continuity.Lineage, index.obligations.len);
    for (roots, index.obligations) |*root, obligation| {
        const head = index.head(&obligation);
        if (mode == .transfer and head.mode != .transferred and head.mode != .cancelled)
            return error.SourceNotTransferred;
        const position = obligation.chain[obligation.chain.len - 1];
        const current = index.reference(position);
        _ = try builder.add(.head, head.lineage, index.records[position], current, head);
        const selected = &builder.members.items[builder.members.items.len - 1];
        var dependencies: std.ArrayList(t.Digest) = .empty;
        for (builder.members.items[0 .. builder.members.items.len - 1]) |item| {
            if (item.data.kind == .head and !std.meta.eql(
                item.data.lineage,
                head.lineage,
            )) continue;
            if (std.meta.eql(item.data.lineage, head.lineage) or
                std.meta.eql(item.data.lineage, global()))
                try dependencies.append(builder.allocator, item.identity);
        }
        selected.data.dependencies.items = try dependencies.toOwnedSlice(builder.allocator);
        selected.identity = try continuity.digest(
            builder.allocator,
            t.ContinuityData,
            selected.data,
        );
        root.* = .{
            .identity = head.lineage,
            .obligation = obligation.task,
            .source_head = current,
            .head = selected.identity,
            .pending_controls = .{ .items = try pendingControlKeys(builder, index, obligation) },
        };
    }
    return roots;
}

fn ordered(a: std.mem.Allocator, members: []const continuity.Member) ![]const continuity.Member {
    var positions: std.AutoHashMapUnmanaged(t.Digest, usize) = .empty;
    defer positions.deinit(a);
    for (members, 0..) |item, position| try positions.put(a, item.identity, position);
    const waiting = try a.alloc(usize, members.len);
    defer a.free(waiting);
    const dependents = try a.alloc(std.ArrayList(usize), members.len);
    defer {
        for (dependents) |*list| list.deinit(a);
        a.free(dependents);
    }
    @memset(dependents, .empty);
    for (members, waiting, 0..) |item, *count, position| {
        count.* = item.data.dependencies.items.len;
        for (item.data.dependencies.items) |dependency| {
            const source = positions.get(dependency) orelse
                return error.MissingContinuityDependency;
            try dependents[source].append(a, position);
        }
    }
    var result: std.ArrayList(continuity.Member) = .empty;
    errdefer result.deinit(a);
    for (waiting, 0..) |count, position| if (count == 0) try result.append(a, members[position]);
    var cursor: usize = 0;
    while (cursor < result.items.len) : (cursor += 1) {
        const position = positions.get(result.items[cursor].identity).?;
        for (dependents[position].items) |next| {
            waiting[next] -= 1;
            if (waiting[next] == 0) try result.append(a, members[next]);
        }
    }
    if (result.items.len != members.len) return error.CyclicContinuityDependency;
    return result.toOwnedSlice(a);
}

pub fn prepare(
    a: std.mem.Allocator,
    index: *const idx.Index,
    source: Source,
    mode: Mode,
) !OwnedBundle {
    if (importPending(index)) return error.ContinuityImportPending;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var builder: Builder = .{ .allocator = scratch, .source = source };
    for (index.records) |record| try builder.appendRecord(index, record);
    try builder.link(mode);
    const roots = try addRoots(&builder, index, mode);
    const cut: @FieldType(Bundle, "cut") = .{ .items = try cutRows(scratch, index) };
    const bundle: Bundle = .{
        .source = source,
        .mode = mode,
        .cut = cut,
        .cut_digest = try continuity.digest(scratch, @TypeOf(cut), cut),
        .lineages = .{ .items = roots },
        .members = .{ .items = try ordered(scratch, builder.members.items) },
        .archive_boundary = .{ .bytes = "Portable application facts through this cut; " ++
            "the source namespace retains native execution and historical archive custody." },
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
    if (try genesisPending(driver.service, a, &index)) return error.ContinuityGenesisPending;
    return prepare(a, &index, source, mode);
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
pub const mappedOperation = continuity.mappedOperation;

pub fn validateBindings(
    a: std.mem.Allocator,
    bundle: Bundle,
    bindings: configuration.Bindings,
) !void {
    for (bundle.lineages.items) |root| {
        var head = try continuity.decode(.head, a, continuity.member(bundle, root.head).?.data);
        defer head.deinit();
        if (head.value.mode == .cancelled) continue;
        if (!bindings.admits(head.value.specification.repository))
            return error.ContinuityResourceMismatch;
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
            const metadata = imported.continuity orelse return error.ImportTargetNotFresh;
            if (!std.meta.eql(metadata.bundle, identity)) return error.ContinuityImportConflict;
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
    for (bundle.lineages.items) |root|
        _ = try continuity.importedLineage(index, root.identity, identity);
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
    try validateBindings(a, bundle, configuration.bindings(config));
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

fn genesisInput(
    a: std.mem.Allocator,
    origin: t.Origin,
    bundle: Bundle,
    identity: t.Digest,
    manifest: t.Reference,
    mappings: []const t.ContinuityBinding,
    root: continuity.Lineage,
    clock_ms: i64,
) !t.Genesis {
    var source = try continuity.decode(.head, a, continuity.member(bundle, root.head).?.data);
    defer source.deinit();
    const rebased = try continuity.rebaseHead(bundle, mappings, source.value);
    const value: t.Genesis = .{
        .envelope = .{
            .operation = .{ .bytes = try mappedOperation(a, .genesis, identity, root.identity) },
            .stable_request = try continuity.digest(a, continuity.Lineage, root),
            .origin = origin,
        },
        .lineage = root.identity,
        .specification = rebased.specification,
        .clock_ms = clock_ms,
        .imported = .{
            .source = root.source_head,
            .head = rebased,
            .continuity = .{
                .bundle = identity,
                .manifest = manifest,
                .source_namespace = bundle.source.namespace,
                .source_cut = bundle.cut_digest,
                .members = .{ .items = mappings },
            },
        },
    };
    const bytes = try c.encodeOwned(t.Genesis, a, value);
    return (try c.decodeOwned(t.Genesis, a, bytes)).value;
}

pub fn importProgress(driver: anytype, a: std.mem.Allocator) !ImportProgress {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var index = try driver.rebuild(arena.allocator());
    defer index.deinit();
    const view = index.continuity_import orelse return error.MissingContinuityManifest;
    var obligations: std.ArrayList(t.Id) = .empty;
    errdefer obligations.deinit(a);
    if (view.bundle) |bundle| for (bundle.lineages.items) |root| {
        const position = try continuity.importedLineage(&index, root.identity, view.digest) orelse
            continue;
        try obligations.append(a, index.records[position].task);
    };
    return .{
        .phase = view.phase,
        .manifest = index.records[view.position].task,
        .members = view.members,
        .obligations = try obligations.toOwnedSlice(a),
    };
}

pub fn advanceImport(driver: anytype, a: std.mem.Allocator, index: *const idx.Index) !bool {
    if (!driver.attached) return error.DriverDetached;
    const view = index.continuity_import orelse return false;
    if (view.phase == .manifest_pending or view.phase == .materialized) return false;
    const bindings = driver.bindings orelse return error.MissingResourceBindings;
    validateBindings(a, view.bundle.?, bindings) catch |err| switch (err) {
        error.ContinuityResourceMismatch => return false,
        else => return err,
    };
    const origin = index.records[view.position].input.continuity_cut.envelope.origin;
    if (view.phase == .members_pending) return submitMembers(driver, a, index, &view, origin);
    return submitRoots(driver, a, index, &view, origin);
}

fn submitMembers(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    view: *const continuity.ImportView,
    origin: t.Origin,
) !bool {
    var submitted: usize = 0;
    for (view.bundle.?.members.items, view.local) |item, local| {
        if (submitted == members_per_step) break;
        if (local != null) continue;
        const bindings = try readyBindings(a, index, view, item) orelse continue;
        const operation = try mappedOperation(a, .member, view.digest, item.identity);
        _ = try driver.service.submit(a, operation, .{ .continuity_member = .{
            .envelope = .{
                .operation = .{ .bytes = operation },
                .stable_request = item.identity,
                .origin = origin,
            },
            .bundle = view.digest,
            .data = item.data,
            .bindings = .{ .items = bindings },
        } });
        submitted += 1;
    }
    return submitted != 0;
}

fn readyBindings(
    a: std.mem.Allocator,
    index: *const idx.Index,
    view: *const continuity.ImportView,
    item: continuity.Member,
) !?[]const t.ContinuityBinding {
    const result = try a.alloc(t.ContinuityBinding, item.data.dependencies.items.len);
    for (result, item.data.dependencies.items) |*target, dependency| target.* = .{
        .member = dependency,
        .local = view.reference(index, dependency) orelse return null,
    };
    return result;
}

fn submitRoots(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    view: *const continuity.ImportView,
    origin: t.Origin,
) !bool {
    const bundle = view.bundle.?;
    const clock_ms = try driver.clock.now(driver.clock.context);
    var submitted = false;
    for (bundle.lineages.items) |root| {
        if (try continuity.importedLineage(index, root.identity, view.digest) != null) continue;
        const input = try genesisInput(
            a,
            origin,
            bundle,
            view.digest,
            view.manifest.?,
            view.metadata.?.members.items,
            root,
            clock_ms,
        );
        _ = try driver.service.submit(a, input.envelope.operation.bytes, .{ .genesis = input });
        submitted = true;
    }
    return submitted;
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

fn pendingControlKeys(
    builder: *Builder,
    index: *const idx.Index,
    obligation: idx.Obligation,
) ![]const t.Digest {
    const a = builder.allocator;
    const head = index.head(&obligation);
    var inherited: std.ArrayList(t.Digest) = .empty;
    var boundary = head.folded_directive_ordinal;
    if (continuity.findImport(index, obligation.task)) |imported| {
        const root = continuity.lineage(imported.bundle, head.lineage).?;
        const mapped = try unmappedControls(a, index, imported, root, &inherited);
        boundary = @max(boundary, mapped);
    }
    var keys: std.ArrayList(t.Digest) = .empty;
    const folded = head.folded_directive_ordinal;
    try localControls(builder, index, obligation, folded, boundary, &keys);
    try keys.appendSlice(a, inherited.items);
    try localControls(builder, index, obligation, boundary, std.math.maxInt(u64), &keys);
    return keys.toOwnedSlice(a);
}

fn unmappedControls(
    a: std.mem.Allocator,
    index: *const idx.Index,
    imported: continuity.Imported,
    root: continuity.Lineage,
    keys: *std.ArrayList(t.Digest),
) !u64 {
    var boundary: u64 = 0;
    var owed = false;
    for (root.pending_controls.items) |key| {
        const position = try continuity.mappedControl(a, index, imported, key) orelse {
            var control = try continuity.decode(
                .directive,
                a,
                continuity.member(imported.bundle, key).?.data,
            );
            defer control.deinit();
            owed = owed or !continuity.historicalControl(control.value.body);
            try keys.append(a, key);
            continue;
        };
        if (owed) return error.ContinuityControlOrderMismatch;
        boundary = @max(boundary, index.records[position].input.directive.ordinal);
    }
    return boundary;
}

fn localControls(
    builder: *Builder,
    index: *const idx.Index,
    obligation: idx.Obligation,
    after: u64,
    through: u64,
    keys: *std.ArrayList(t.Digest),
) !void {
    for (obligation.directives) |position| {
        const record = index.records[position];
        const ordinal = record.input.directive.ordinal;
        if (ordinal <= after or ordinal > through) continue;
        const member = builder.directives.get(record.task) orelse
            return error.MissingContinuityControl;
        try keys.append(builder.allocator, builder.members.items[member].identity);
    }
}

pub const PendingControlProgress = struct {
    admitted: ?t.Id = null,
    remaining: u64 = 0,
    historical: u64 = 0,
};

pub fn admitPendingControls(
    driver: anytype,
    a: std.mem.Allocator,
    target: t.Id,
    origin: t.Origin,
) !PendingControlProgress {
    if (!driver.attached or origin != .local) return error.TransferLocalOnly;
    var index = try driver.rebuild(a);
    defer index.deinit();
    const imported = continuity.findImport(&index, target) orelse return .{};
    const root = continuity.lineage(
        imported.bundle,
        index.record(target).?.input.genesis.lineage,
    ).?;
    const owed = controlsOwed(&index, target);
    var result: PendingControlProgress = .{};
    var next: ?t.Digest = null;
    for (root.pending_controls.items) |key| {
        const item = continuity.member(imported.bundle, key).?;
        var control = try continuity.decode(.directive, a, item.data);
        defer control.deinit();
        if (!owed or continuity.historicalControl(control.value.body)) {
            result.historical += 1;
        } else if (try continuity.mappedControl(a, &index, imported, key) == null) {
            result.remaining += 1;
            if (next == null) next = key;
        }
    }
    if (next) |key| {
        var control = try continuity.decode(
            .directive,
            a,
            continuity.member(imported.bundle, key).?.data,
        );
        defer control.deinit();
        const operation = try continuity.directiveOperation(a, imported.metadata.bundle, key);
        defer a.free(operation);
        result.admitted = try driver.directiveRequest(
            a,
            operation,
            origin,
            target,
            try continuity.rebaseControl(imported, control.value.body),
            key,
        );
        result.remaining -= 1;
    }
    return result;
}

fn controlsOwed(index: *const idx.Index, target: t.Id) bool {
    const mode = index.head(index.obligation(target) orelse return false).mode;
    return mode != .cancelled and mode != .transferred;
}

pub fn pendingControlsAdmitted(a: std.mem.Allocator, index: *const idx.Index, target: t.Id) !bool {
    if (!controlsOwed(index, target)) return true;
    return continuity.controlsComplete(a, index, target, null);
}

pub fn importPending(index: anytype) bool {
    const view = index.continuity_import orelse return false;
    return view.phase != .materialized;
}

pub fn genesisPending(service: anytype, a: std.mem.Allocator, index: *const idx.Index) !bool {
    for (index.records) |record| {
        if (record.input != .genesis or record.result != null) continue;
        if (try genesisDisposition(service, a, record.task) == .runnable) return true;
    }
    return false;
}

pub fn strandedGeneses(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
) ![]const t.Id {
    var result: std.ArrayList(t.Id) = .empty;
    errdefer result.deinit(a);
    for (index.records) |record| {
        if (record.input != .genesis or record.result != null) continue;
        if (try genesisDisposition(service, a, record.task) == .stranded)
            try result.append(a, record.task);
    }
    return result.toOwnedSlice(a);
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

pub const PendingTurnProgress = @import("continuity_turn.zig").Progress;

pub fn admitPendingTurns(
    driver: anytype,
    a: std.mem.Allocator,
    origin: t.Origin,
) !PendingTurnProgress {
    return @import("continuity_turn.zig").admit(driver, a, origin);
}
