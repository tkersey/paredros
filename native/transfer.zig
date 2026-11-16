const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");
const configuration = @import("configuration.zig");

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
        .delivery => |value| return deliveryLineage(index, value.key.lineage),
        .audit => |value| return deliveryLineage(index, value.delivery.key.lineage),
        .lineage_audit => |value| return deliveryLineage(index, value.lineage),
        else => null,
    };
    const source = if (target) |value| index.record(value) else null;
    if (source) |value| {
        if (value.input != .genesis) return error.InvalidContinuityTarget;
        return value.input.genesis.lineage;
    }
    return global();
}

fn deliveryLineage(index: *const idx.Index, value: t.Digest) t.Digest {
    for (index.obligations) |obligation| {
        if (std.meta.eql(index.head(&obligation).lineage, value)) return value;
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
        for (self.members.items) |old| {
            if (!std.meta.eql(old.identity, identity)) continue;
            if (!std.meta.eql(old.current, current)) return error.AmbiguousContinuityProducer;
            return identity;
        }
        try self.members.append(self.allocator, .{
            .identity = identity,
            .current = current,
            .data = data,
        });
        return identity;
    }

    fn appendRecord(self: *Builder, index: *const idx.Index, value: idx.Record) !void {
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
            .delivery => |input| {
                _ = try self.add(.delivery, lineage_id, value, try rowReference(
                    value,
                    value.result != null,
                ), .{
                    .input = input,
                    .result = if (value.result) |output| output.delivery else null,
                });
            },
            .audit => |input| {
                _ = try self.add(.audit, lineage_id, value, try rowReference(
                    value,
                    value.result != null,
                ), .{
                    .input = input,
                    .result = if (value.result) |output| output.audit else null,
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
            .experiment => |input| if (value.result) |output| {
                _ = try self.add(.method_report, global(), value, try rowReference(value, true), .{
                    .input = input,
                    .result = output.experiment,
                });
            },
            .continuity_member => |input| {
                _ = try self.addData(try rowReference(value, value.result != null), input.data);
            },
            .genesis, .continuity_cut, .restore, .lineage_audit => {},
        }
    }
};

fn cutRows(a: std.mem.Allocator, index: *const idx.Index) ![]continuity.CutRow {
    const rows = try a.alloc(continuity.CutRow, index.records.len);
    for (rows, index.records) |*row, record| {
        const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
        row.* = .{
            .task = record.task,
            .revision = record.revision,
            .input = record.input_digest,
            .result = record.result_digest,
            .event_cut = snapshot.event_cut,
        };
    }
    std.mem.sort(continuity.CutRow, rows, {}, struct {
        fn less(_: void, left: continuity.CutRow, right: continuity.CutRow) bool {
            return std.mem.order(u8, &left.task, &right.task) == .lt;
        }
    }.less);
    return rows;
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
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    var result: std.ArrayList(continuity.Member) = .empty;
    defer seen.deinit(a);
    errdefer result.deinit(a);
    for (0..members.len) |_| {
        var progress = false;
        for (members) |item| {
            if (seen.contains(item.identity)) continue;
            var ready = true;
            for (item.data.dependencies.items) |dependency| if (!seen.contains(dependency)) {
                ready = false;
                break;
            };
            if (!ready) continue;
            try result.append(a, item);
            try seen.put(a, item.identity, {});
            progress = true;
        }
        if (result.items.len == members.len) return result.toOwnedSlice(a);
        if (!progress) return error.CyclicContinuityDependency;
    }
    return result.toOwnedSlice(a);
}

pub fn prepare(
    a: std.mem.Allocator,
    index: *const idx.Index,
    source: Source,
    mode: Mode,
) !OwnedBundle {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var builder: Builder = .{ .allocator = scratch, .source = source };
    for (index.records) |record| try builder.appendRecord(index, record);
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
    return prepare(a, &index, source, mode);
}

pub fn admitCut(
    service: anytype,
    a: std.mem.Allocator,
    origin: t.Origin,
    bundle: Bundle,
) !t.Id {
    if (origin != .local) return error.TransferLocalOnly;
    try continuity.validate(a, bundle);
    const bytes = try c.encodeOwned(Bundle, a, bundle);
    defer a.free(bytes);
    const identity = continuity.hash(bytes);
    const operation = try std.fmt.allocPrint(a, "continuity-cut:{s}", .{
        std.fmt.bytesToHex(identity, .lower),
    });
    defer a.free(operation);
    const result = try service.submit(a, operation, .{ .continuity_cut = .{
        .envelope = .{
            .operation = .{ .bytes = operation },
            .stable_request = identity,
            .origin = origin,
        },
        .bundle_digest = identity,
        .bytes = .{ .bytes = bytes },
    } });
    return result.receipt.task;
}

pub const ImportProgress = struct {
    phase: enum { manifest_pending, members_pending, genesis_pending, materialized },
    manifest: t.Id,
    members: u64,
    obligations: []const t.Id,

    pub fn deinit(self: *ImportProgress, a: std.mem.Allocator) void {
        a.free(self.obligations);
        self.* = undefined;
    }
};

pub fn mappedOperation(
    a: std.mem.Allocator,
    kind: enum { member, genesis, directive, turn },
    bundle: t.Digest,
    identity: t.Digest,
) ![]u8 {
    const key = try continuity.digest(a, struct { bundle: t.Digest, identity: t.Digest }, .{
        .bundle = bundle,
        .identity = identity,
    });
    return std.fmt.allocPrint(a, "continuity-{s}:{s}", .{
        @tagName(kind), std.fmt.bytesToHex(key, .lower),
    });
}

fn byOperation(index: *const idx.Index, name: []const u8) ?*const idx.Record {
    for (index.records) |*record| {
        const envelope = switch (record.input) {
            inline else => |value| value.envelope,
        };
        if (std.mem.eql(u8, envelope.operation.bytes, name)) return record;
    }
    return null;
}

fn existingLineage(
    index: *const idx.Index,
    identity: t.Digest,
    bundle: t.Digest,
) !?*const idx.Record {
    for (index.records) |*record| {
        if (record.input != .genesis or !std.meta.eql(record.input.genesis.lineage, identity))
            continue;
        const imported = record.input.genesis.imported orelse
            return error.ContinuityLineageConflict;
        const metadata = imported.continuity orelse return error.ContinuityLineageConflict;
        if (!std.meta.eql(metadata.bundle, bundle)) return error.ContinuityLineageConflict;
        return record;
    }
    return null;
}

fn validateDestination(a: std.mem.Allocator, bundle: Bundle, config: configuration.Config) !void {
    try validateGlobalTurns(a, bundle, config);
    for (bundle.lineages.items) |root| {
        var head = try continuity.decode(.head, a, continuity.member(bundle, root.head).?.data);
        defer head.deinit();
        if (!try continuity.equal(
            a,
            t.Repository,
            head.value.specification.repository,
            config.repository.value(),
        ) or
            !try continuity.equal(
                a,
                t.Destination,
                head.value.specification.destination,
                config.slack.destination(),
            )) return error.ContinuityResourceMismatch;
    }
}

fn validateGlobalTurns(a: std.mem.Allocator, bundle: Bundle, config: configuration.Config) !void {
    for (bundle.members.items) |item| {
        if (item.data.kind != .turn or !std.meta.eql(item.data.lineage, global())) continue;
        var value = try continuity.decode(.turn, a, item.data);
        defer value.deinit();
        if (!try continuity.equal(
            a,
            t.Destination,
            value.value.input.destination,
            config.slack.destination(),
        )) return error.ContinuityResourceMismatch;
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
        .restore => {},
        else => return error.ImportTargetNotFresh,
    };
}

pub fn validateImport(
    a: std.mem.Allocator,
    index: *const idx.Index,
    config: configuration.Config,
    bundle: Bundle,
) !void {
    try continuity.validate(a, bundle);
    const identity = try continuity.digest(a, Bundle, bundle);
    var materialized = bundle.lineages.items.len != 0;
    for (bundle.lineages.items) |root| {
        const existing = try existingLineage(index, root.identity, identity);
        if (existing == null or existing.?.result == null) materialized = false;
    }
    if (materialized) return;
    try validateDestination(a, bundle, config);
    try validateFresh(index, identity);
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

fn memberBindings(
    a: std.mem.Allocator,
    data: t.ContinuityData,
    mappings: []const t.ContinuityBinding,
) ![]const t.ContinuityBinding {
    const bindings = try a.alloc(t.ContinuityBinding, data.dependencies.items.len);
    for (bindings, data.dependencies.items) |*target, identity| target.* = .{
        .member = identity,
        .local = try continuity.binding(mappings, identity),
    };
    return bindings;
}

fn memberInput(
    a: std.mem.Allocator,
    origin: t.Origin,
    bundle: t.Digest,
    member: continuity.Member,
    mappings: []const t.ContinuityBinding,
) !t.ContinuityMember {
    return .{
        .envelope = .{
            .operation = .{ .bytes = try mappedOperation(a, .member, bundle, member.identity) },
            .stable_request = member.identity,
            .origin = origin,
        },
        .bundle = bundle,
        .data = member.data,
        .bindings = .{ .items = try memberBindings(a, member.data, mappings) },
    };
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
    exclusive_owner: bool,
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
            .exclusive_owner = exclusive_owner,
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

pub fn importBundle(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    origin: t.Origin,
    bundle: Bundle,
    exclusive_owner: bool,
) !ImportProgress {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var result = try importWithArena(
        driver,
        arena.allocator(),
        config,
        origin,
        bundle,
        exclusive_owner,
    );
    result.obligations = try a.dupe(t.Id, result.obligations);
    return result;
}

fn importWithArena(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    origin: t.Origin,
    bundle: Bundle,
    exclusive_owner: bool,
) !ImportProgress {
    if (!driver.attached or origin != .local) return error.TransferLocalOnly;
    try continuity.validate(a, bundle);
    const identity = try continuity.digest(a, Bundle, bundle);
    var index = try driver.rebuild(a);
    defer index.deinit();
    var roots: std.ArrayList(t.Id) = .empty;
    var finished = true;
    for (bundle.lineages.items) |root| {
        const existing = try existingLineage(&index, root.identity, identity);
        if (existing) |record| {
            try roots.append(a, record.task);
            if (record.result == null) finished = false;
        } else finished = false;
    }
    const cut_operation = try std.fmt.allocPrint(a, "continuity-cut:{s}", .{
        std.fmt.bytesToHex(identity, .lower),
    });
    const cut_record = byOperation(&index, cut_operation);
    if (finished and bundle.lineages.items.len != 0) return .{
        .phase = .materialized,
        .manifest = (cut_record orelse return error.MissingContinuityManifest).task,
        .members = bundle.members.items.len,
        .obligations = try roots.toOwnedSlice(a),
    };
    try validateDestination(a, bundle, config);
    try validateFresh(&index, identity);
    if (cut_record == null) return .{
        .phase = .manifest_pending,
        .manifest = try admitCut(driver.service, a, origin, bundle),
        .members = 0,
        .obligations = try roots.toOwnedSlice(a),
    };
    const manifest = (try completedCut(a, cut_record.?.*, identity)) orelse return .{
        .phase = .manifest_pending,
        .manifest = cut_record.?.task,
        .members = 0,
        .obligations = try roots.toOwnedSlice(a),
    };
    return importMembers(driver, a, &index, origin, bundle, identity, manifest, exclusive_owner);
}

fn importMembers(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    origin: t.Origin,
    bundle: Bundle,
    identity: t.Digest,
    manifest: t.Reference,
    exclusive_owner: bool,
) !ImportProgress {
    var mappings: std.ArrayList(t.ContinuityBinding) = .empty;
    for (bundle.members.items) |member| {
        const input = try memberInput(a, origin, identity, member, mappings.items);
        const record = byOperation(index, input.envelope.operation.bytes);
        if (record == null) {
            _ = try driver.service.submit(
                a,
                input.envelope.operation.bytes,
                .{ .continuity_member = input },
            );
        } else if (record.?.result) |result| {
            if (record.?.input != .continuity_member or result != .continuity_member or
                !try continuity.equal(
                    a,
                    t.ContinuityMember,
                    record.?.input.continuity_member,
                    input,
                ) or
                !try continuity.equal(a, t.ContinuityMember, result.continuity_member, input))
                return error.InvalidContinuityMember;
            try mappings.append(a, .{
                .member = member.identity,
                .local = .{ .task = record.?.task, .digest = record.?.result_digest.? },
            });
            continue;
        }
        return .{
            .phase = .members_pending,
            .manifest = manifest.task,
            .members = mappings.items.len,
            .obligations = &.{},
        };
    }
    return importRoots(
        driver,
        a,
        index,
        origin,
        bundle,
        identity,
        manifest,
        mappings.items,
        exclusive_owner,
    );
}

fn importRoots(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    origin: t.Origin,
    bundle: Bundle,
    identity: t.Digest,
    manifest: t.Reference,
    mappings: []const t.ContinuityBinding,
    exclusive_owner: bool,
) !ImportProgress {
    var obligations: std.ArrayList(t.Id) = .empty;
    var pending = false;
    for (bundle.lineages.items) |root| {
        if (try existingLineage(index, root.identity, identity)) |record| {
            try obligations.append(a, record.task);
            if (record.result == null) pending = true;
            continue;
        }
        const input = try genesisInput(
            a,
            origin,
            bundle,
            identity,
            manifest,
            mappings,
            root,
            try driver.clock.now(driver.clock.context),
            exclusive_owner,
        );
        const admitted = try driver.service.submit(
            a,
            input.envelope.operation.bytes,
            .{ .genesis = input },
        );
        try obligations.append(a, admitted.receipt.task);
        return .{
            .phase = .genesis_pending,
            .manifest = manifest.task,
            .members = mappings.len,
            .obligations = try obligations.toOwnedSlice(a),
        };
    }
    return .{
        .phase = if (pending) .genesis_pending else .materialized,
        .manifest = manifest.task,
        .members = mappings.len,
        .obligations = try obligations.toOwnedSlice(a),
    };
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
        if (std.c.statx(fd, "", std.c.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &status) != 0) return error.TransferPathUnavailable;
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

pub fn writeSnapshot(
    a: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    bundle: Bundle,
) !t.Digest {
    if (bundle.mode != .snapshot) return error.UncommittedTransfer;
    try continuity.validate(a, bundle);
    const bytes = try c.encodeOwned(Bundle, a, bundle);
    defer a.free(bytes);
    return writeBytes(a, io, directory, name, bytes);
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

pub fn readBundle(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes_max: ?usize,
) !OwnedBundle {
    const bytes = try native.configuration.readFile(a, io, path, bytes_max, true);
    defer a.free(bytes);
    var bundle = try c.decodeOwned(Bundle, a, bytes);
    errdefer bundle.deinit();
    try continuity.validate(a, bundle.value);
    return bundle;
}

fn pendingControlKeys(
    builder: *Builder,
    index: *const idx.Index,
    obligation: idx.Obligation,
) ![]const t.Digest {
    const a = builder.allocator;
    var keys: std.ArrayList(t.Digest) = .empty;
    if (continuity.findImport(index, obligation.task)) |imported| {
        const root = continuity.lineage(imported.bundle, index.head(&obligation).lineage).?;
        for (root.pending_controls.items) |key| {
            if (try continuity.mappedControl(a, index, imported, key) == null)
                try keys.append(a, key);
        }
    }
    const head = index.head(&obligation);
    for (obligation.directives) |position| {
        const record = index.records[position];
        if (record.input.directive.ordinal <= head.folded_directive_ordinal) continue;
        var found = false;
        for (builder.members.items) |item| {
            if (item.data.kind == .directive and std.meta.eql(item.current.task, record.task)) {
                try keys.append(a, item.identity);
                found = true;
                break;
            }
        }
        if (!found) return error.MissingContinuityControl;
    }
    return keys.toOwnedSlice(a);
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
    var result: PendingControlProgress = .{};
    var next: ?t.Digest = null;
    for (root.pending_controls.items) |key| {
        const item = continuity.member(imported.bundle, key).?;
        var control = try continuity.decode(.directive, a, item.data);
        defer control.deinit();
        if (continuity.historicalControl(control.value.body)) {
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

pub fn pendingControlsAdmitted(a: std.mem.Allocator, index: *const idx.Index, target: t.Id) !bool {
    return continuity.controlsComplete(a, index, target, null);
}

pub fn importPending(a: std.mem.Allocator, index: *const idx.Index, namespace: t.Digest) !bool {
    for (index.records) |record| {
        if (record.input != .continuity_cut) continue;
        const cut = record.input.continuity_cut;
        if (!std.meta.eql(continuity.hash(cut.bytes.bytes), cut.bundle_digest))
            return error.ContinuityDigestMismatch;
        var bundle = try c.decodeOwned(Bundle, a, cut.bytes.bytes);
        defer bundle.deinit();
        try continuity.validate(a, bundle.value);
        if (std.meta.eql(bundle.value.source.namespace, namespace)) continue;
        for (bundle.value.members.items) |item| {
            const operation = try mappedOperation(a, .member, cut.bundle_digest, item.identity);
            defer a.free(operation);
            const admitted = byOperation(index, operation) orelse return true;
            if (admitted.result == null) return true;
        }
        for (bundle.value.lineages.items) |root| {
            const existing = try existingLineage(index, root.identity, cut.bundle_digest) orelse
                return true;
            if (existing.result == null) return true;
        }
    }
    return false;
}

pub fn validateExportDestination(io: std.Io, directory: []const u8, name: []const u8) !void {
    const opened = try openDestination(io, directory, name);
    opened.close(io);
}

pub const PendingTurnProgress = @import("continuity_turn.zig").Progress;

pub fn admitPendingTurns(
    driver: anytype,
    a: std.mem.Allocator,
    origin: t.Origin,
) !PendingTurnProgress {
    return @import("continuity_turn.zig").admit(driver, a, origin);
}

pub fn importedIngress(
    a: std.mem.Allocator,
    index: *const idx.Index,
    operation: []const u8,
    origin: t.Origin,
    stable: t.Digest,
) !?t.Id {
    return @import("continuity_turn.zig").ingress(a, index, operation, origin, stable);
}
