const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const retained = @import("retained.zig");
const native = @import("protean_native");
const import_view = @import("continuity_import.zig");

pub const ImportView = import_view.View;
pub const ImportPhase = import_view.Phase;
pub const prepareImport = import_view.prepare;
pub const importedLineage = import_view.importedLineage;
pub const mappedOperation = import_view.mappedOperation;

pub const Source = struct {
    namespace: t.Digest,
    build: t.Digest,
    image: t.Digest,
    runtime: t.Digest,
    contracts: t.Digest,
    clock_ms: i64,
};
pub const CutRow = struct {
    task: t.Id,
    revision: u64,
    input: t.Digest,
    result: ?t.Digest,
    event_cut: u64,
};
pub const Member = struct {
    identity: t.Digest,
    current: t.Reference,
    data: t.ContinuityData,
};
pub const Lineage = struct {
    identity: t.Digest,
    obligation: t.Id,
    source_head: t.Reference,
    head: t.Digest,
    pending_controls: c.Vector(t.Digest, null),
};
pub const Bundle = struct {
    version: u32 = 1,
    source: Source,
    mode: enum { snapshot, transfer },
    cut: c.Vector(CutRow, null),
    cut_digest: t.Digest,
    lineages: c.Vector(Lineage, null),
    members: c.Vector(Member, null),
    archive_boundary: c.Text(1024),
};
pub const TurnFact = struct { input: t.Turn, result: ?t.TurnResult };
pub const DeliveryFact = struct { input: t.Delivery, result: ?t.DeliveryOutcome };
pub const AuditFact = struct { input: t.Audit, result: ?t.AuditResult };
pub const ExperimentFact = struct { input: t.Experiment, result: t.ExperimentResult };
pub const ContextFact = struct {
    text: c.Text(256 * 1024),
    references: c.Vector(t.RevisionReference, 128),
};
pub const Value = struct {
    schema: t.Name,
    encoding: enum { contract, json },
    bytes: c.Bytes(null),
};
pub fn sourceInput(a: std.mem.Allocator, value: Value) !t.Input {
    if (!std.mem.eql(u8, value.schema.bytes, t.input_schema_id))
        return error.UnsupportedContinuityInput;
    return switch (value.encoding) {
        .contract => (try c.decodeOwned(t.Input, a, value.bytes.bytes)).value,
        .json => try native.values.fromJson(
            t.Input,
            a,
            (try native.json.parseAsset(a, value.bytes.bytes, value.bytes.bytes.len)).value,
        ),
    };
}

pub const SourceAttempt = struct {
    id: t.Digest,
    response: ?c.Bytes(null),
    reply: ?c.Bytes(null),
};
pub const SourceFact = struct {
    snapshot: retained.Snapshot,
    input: Value,
    result: ?Value,
    attempts: c.Vector(SourceAttempt, null),
};
pub const Portable = struct {
    bundle: Bundle,
    metadata: t.ContinuityImport,
};

pub const Imported = struct {
    obligation: t.Id,
    bundle: Bundle,
    metadata: t.ContinuityImport,
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

pub fn schema(kind: t.ContinuityKind) []const u8 {
    return switch (kind) {
        inline else => |value| "paredros.continuity." ++ @tagName(value) ++ ".v1",
    };
}

pub fn Payload(comptime kind: t.ContinuityKind) type {
    return switch (kind) {
        .head => t.Head,
        .batch => t.Batch,
        .directive => t.Directive,
        .turn => TurnFact,
        .delivery => DeliveryFact,
        .audit => AuditFact,
        .settlement => SourceFact,
        .method_source => t.RetainedMethodSource,
        .method_report => ExperimentFact,
        .context => ContextFact,
    };
}

pub fn decode(
    comptime kind: t.ContinuityKind,
    a: std.mem.Allocator,
    data: t.ContinuityData,
) !c.Decoded(Payload(kind)) {
    if (data.version != 1 or data.kind != kind or
        !std.mem.eql(u8, data.schema.bytes, schema(kind))) return error.UnsupportedContinuitySchema;
    return c.decodeOwned(Payload(kind), a, data.payload.bytes);
}

fn valueMatches(value: Value, original: retained.Value) bool {
    return std.mem.eql(u8, value.schema.bytes, original.schema_id.bytes) and
        std.mem.eql(u8, @tagName(value.encoding), @tagName(original.encoding)) and
        value.bytes.bytes.len == original.reference.bytes and
        std.meta.eql(hash(value.bytes.bytes), original.reference.digest);
}

fn captureMatches(bytes: ?c.Bytes(null), original: ?retained.Object) bool {
    if (bytes == null or original == null) return bytes == null and original == null;
    return bytes.?.bytes.len == original.?.bytes and
        std.meta.eql(hash(bytes.?.bytes), original.?.digest);
}

fn verifySourceFact(a: std.mem.Allocator, data: t.ContinuityData, value: SourceFact) !void {
    const snapshot = value.snapshot;
    if (snapshot.version != 1 or !std.meta.eql(snapshot.task, data.source.task) or
        snapshot.revision != data.source.revision or
        !std.meta.eql(try digest(a, retained.Snapshot, snapshot), data.source.digest) or
        !valueMatches(value.input, snapshot.input)) return error.InvalidContinuityFact;
    if ((value.result == null) != (snapshot.result == null)) return error.InvalidContinuityFact;
    if (value.result) |result| if (!valueMatches(result, snapshot.result.?))
        return error.InvalidContinuityFact;
    if (snapshot.attempts.items.len != value.attempts.items.len)
        return error.InvalidContinuityFact;
    for (snapshot.attempts.items, value.attempts.items) |attempt, evidence| {
        if (!std.meta.eql(attempt.id, evidence.id)) return error.InvalidContinuityFact;
        const response = if (attempt.capture) |capture| capture.response else null;
        const reply = if (attempt.capture) |capture| capture.reply else null;
        if (!captureMatches(evidence.response, response) or !captureMatches(evidence.reply, reply))
            return error.InvalidContinuityCapture;
    }
    const bytes = try c.encodeOwned(retained.Snapshot, a, snapshot);
    defer a.free(bytes);
    var verified = try retained.decodeFrozen(a, .{
        .task = data.source.task,
        .revision = data.source.revision,
        .digest = data.source.digest,
    }, bytes);
    defer verified.deinit();
}

pub fn validateData(a: std.mem.Allocator, data: t.ContinuityData) !void {
    switch (data.kind) {
        inline else => |kind| {
            var parsed = try decode(kind, a, data);
            defer parsed.deinit();
            if (kind == .head and !std.meta.eql(parsed.value.lineage, data.lineage))
                return error.ContinuityLineageMismatch;
            if (kind == .settlement) try verifySourceFact(a, data, parsed.value);
            if (kind == .method_source and
                !std.meta.eql(hash(parsed.value.bytes.bytes), parsed.value.source_digest))
                return error.InvalidContinuityMethod;
            if (kind == .method_report and
                (!std.meta.eql(parsed.value.input.campaign, parsed.value.result.campaign) or
                    parsed.value.input.attempt != parsed.value.result.attempt))
                return error.InvalidContinuityMethod;
        },
    }
}

pub fn member(bundle: Bundle, identity: t.Digest) ?Member {
    for (bundle.members.items) |item| if (std.meta.eql(item.identity, identity)) return item;
    return null;
}

pub fn lineage(bundle: Bundle, identity: t.Digest) ?Lineage {
    for (bundle.lineages.items) |item| if (std.meta.eql(item.identity, identity)) return item;
    return null;
}

pub fn validate(a: std.mem.Allocator, bundle: Bundle) !void {
    if (bundle.version != 1 or bundle.archive_boundary.bytes.len == 0)
        return error.UnsupportedContinuityBundle;
    if (!std.meta.eql(try digest(a, @TypeOf(bundle.cut), bundle.cut), bundle.cut_digest))
        return error.ContinuityCutMismatch;
    var previous: ?t.Id = null;
    for (bundle.cut.items) |row| {
        if (previous) |old| if (std.mem.order(u8, &old, &row.task) != .lt)
            return error.InvalidContinuityCut;
        previous = row.task;
    }
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    defer seen.deinit(a);
    for (bundle.members.items) |item| {
        if (!std.meta.eql(try digest(a, t.ContinuityData, item.data), item.identity))
            return error.ContinuityDigestMismatch;
        if (seen.contains(item.identity)) return error.DuplicateContinuityMember;
        for (item.data.dependencies.items, 0..) |dependency, i| {
            if (!seen.contains(dependency)) return error.MissingContinuityDependency;
            for (item.data.dependencies.items[0..i]) |old|
                if (std.meta.eql(old, dependency)) return error.DuplicateContinuityDependency;
        }
        try validateData(a, item.data);
        try seen.put(a, item.identity, {});
    }
    try validateLineages(a, bundle);
    try validateCut(a, bundle);
    try @import("continuity_turn.zig").validateBundle(a, bundle);
}

fn validateCut(a: std.mem.Allocator, bundle: Bundle) !void {
    var facts: std.AutoHashMapUnmanaged(t.Id, CutRow) = .empty;
    defer facts.deinit(a);
    for (bundle.members.items) |item| {
        if (item.data.kind != .settlement or
            !std.meta.eql(item.data.source.namespace, bundle.source.namespace)) continue;
        var decoded = try decode(.settlement, a, item.data);
        defer decoded.deinit();
        const value = decoded.value.snapshot;
        const entry = try facts.getOrPut(a, value.task);
        if (entry.found_existing) return error.DuplicateContinuityFact;
        entry.value_ptr.* = .{
            .task = value.task,
            .revision = value.revision,
            .input = value.input.reference.digest,
            .result = if (value.result) |result| result.reference.digest else null,
            .event_cut = value.event_cut,
        };
    }
    try validateCoverage(a, bundle, &facts);
    try validateResponsibilities(a, bundle);
    try validateProducers(a, bundle);
}

fn validateCoverage(
    a: std.mem.Allocator,
    bundle: Bundle,
    facts: *const std.AutoHashMapUnmanaged(t.Id, CutRow),
) !void {
    var carriers: std.AutoHashMapUnmanaged(t.Id, CutRow) = .empty;
    defer carriers.deinit(a);
    for (bundle.cut.items) |row| {
        const fact = facts.get(row.task) orelse {
            try carriers.put(a, row.task, row);
            continue;
        };
        if (!std.meta.eql(row, fact)) return error.ContinuityCutMismatch;
    }
    if (facts.count() + carriers.count() != bundle.cut.items.len)
        return error.IncompleteContinuityCut;
    var carried: std.AutoHashMapUnmanaged(t.Id, void) = .empty;
    defer carried.deinit(a);
    for (bundle.members.items) |item| {
        if (facts.get(item.current.task)) |producer| {
            if (!std.meta.eql(item.current.digest, producer.input) and
                (producer.result == null or !std.meta.eql(item.current.digest, producer.result.?)))
                return error.ContinuityProducerMismatch;
            continue;
        }
        const carrier = carriers.get(item.current.task) orelse
            return error.MissingContinuityProducer;
        if (std.meta.eql(item.data.source.namespace, bundle.source.namespace) or
            carrier.result == null or !std.meta.eql(item.current.digest, carrier.result.?))
            return error.ContinuityProducerMismatch;
        try carried.put(a, item.current.task, {});
    }
    if (carried.count() != carriers.count()) return error.IncompleteContinuityCut;
}

fn validateResponsibilities(a: std.mem.Allocator, bundle: Bundle) !void {
    for (bundle.members.items) |item| {
        if (item.data.kind != .settlement or
            !std.meta.eql(item.data.source.namespace, bundle.source.namespace)) continue;
        var source = try decode(.settlement, a, item.data);
        defer source.deinit();
        if (!std.mem.eql(u8, source.value.input.schema.bytes, t.input_schema_id) or
            source.value.input.encoding != .contract) return error.UnsupportedContinuityInput;
        var input = try c.decodeOwned(t.Input, a, source.value.input.bytes.bytes);
        defer input.deinit();
        switch (input.value) {
            .directive => |value| try retainedInput(a, bundle, item, .directive, value),
            .turn => |value| try retainedInput(a, bundle, item, .turn, value),
            .delivery => |value| try retainedInput(a, bundle, item, .delivery, value),
            .audit => |value| try retainedInput(a, bundle, item, .audit, value),
            else => {},
        }
    }
}

fn retainedInput(
    a: std.mem.Allocator,
    bundle: Bundle,
    source: Member,
    comptime kind: t.ContinuityKind,
    expected: anytype,
) !void {
    var count: usize = 0;
    for (bundle.members.items) |item| {
        if (item.data.kind != kind or
            !std.meta.eql(item.data.source.namespace, source.data.source.namespace) or
            !std.meta.eql(item.data.source.task, source.data.source.task) or
            item.data.source.revision != source.data.source.revision) continue;
        var value = try decode(kind, a, item.data);
        defer value.deinit();
        const admitted = if (kind == .directive) value.value else value.value.input;
        if (!try equal(a, @TypeOf(expected), expected, admitted))
            return error.ContinuityResponsibilityMismatch;
        count += 1;
    }
    if (count != 1) return error.MissingContinuityResponsibility;
}

fn validateLineages(a: std.mem.Allocator, bundle: Bundle) !void {
    var roots: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    defer roots.deinit(a);
    for (bundle.lineages.items) |root| {
        const entry = try roots.getOrPut(a, root.identity);
        if (entry.found_existing) return error.DuplicateContinuityLineage;
        const selected = member(bundle, root.head) orelse return error.MissingContinuityHead;
        if (!std.meta.eql(selected.current, root.source_head) or
            !std.meta.eql(selected.data.lineage, root.identity))
            return error.ContinuityLineageMismatch;
        var head = try decode(.head, a, selected.data);
        defer head.deinit();
        if (bundle.mode == .transfer and head.value.mode != .transferred and
            head.value.mode != .cancelled) return error.SourceNotTransferred;
        try validatePending(a, bundle, root, head.value);
    }
    for (bundle.members.items) |item| {
        if (!std.meta.eql(item.data.lineage, @as(t.Digest, @splat(0))) and
            !roots.contains(item.data.lineage)) return error.OrphanContinuityMember;
    }
}

pub fn binding(values: []const t.ContinuityBinding, identity: t.Digest) !t.Reference {
    var result: ?t.Reference = null;
    for (values) |value| {
        if (!std.meta.eql(value.member, identity)) continue;
        if (result != null) return error.DuplicateContinuityBinding;
        result = value.local;
    }
    return result orelse error.MissingContinuityBinding;
}

pub fn mapReference(
    bundle: Bundle,
    mappings: []const t.ContinuityBinding,
    kind: t.ContinuityKind,
    old: t.Reference,
) !t.Reference {
    var found: ?t.Digest = null;
    for (bundle.members.items) |item| {
        if (item.data.kind != kind) continue;
        const original: t.Reference = .{
            .task = item.data.source.task,
            .digest = item.data.source.digest,
        };
        if (!std.meta.eql(item.current, old) and !std.meta.eql(original, old)) continue;
        if (found != null and !std.meta.eql(found.?, item.identity))
            return error.AmbiguousContinuityReference;
        found = item.identity;
    }
    return binding(mappings, found orelse return error.MissingContinuityReference);
}

pub fn rebaseHead(
    bundle: Bundle,
    mappings: []const t.ContinuityBinding,
    original: t.Head,
) !t.Head {
    var head = original;
    if (head.last_observation) |*observation| if (observation.batch) |*batch| {
        if (batch.* == .retained)
            batch.retained = try mapReference(bundle, mappings, .batch, batch.retained);
    };
    if (head.question) |*question| if (question.evidence == .retained) {
        question.evidence.retained = try mapReference(
            bundle,
            mappings,
            .batch,
            question.evidence.retained,
        );
    };
    if (head.told_receipt) |*receipt| {
        receipt.evidence = if (receipt.basis == .bound_interaction)
            mapReference(bundle, mappings, .turn, receipt.evidence) catch |err| switch (err) {
                error.MissingContinuityReference => try mapReference(
                    bundle,
                    mappings,
                    .directive,
                    receipt.evidence,
                ),
                else => return err,
            }
        else
            try mapReference(bundle, mappings, if (receipt.basis == .captured_response)
                .delivery
            else
                .audit, receipt.evidence);
    }
    if (head.method == .retained) {
        head.method.retained.source = try mapReference(
            bundle,
            mappings,
            .method_report,
            head.method.retained.source,
        );
        head.method.retained.report = try mapReference(
            bundle,
            mappings,
            .method_report,
            head.method.retained.report,
        );
    }
    if (head.method_disposition) |*disposition|
        disposition.source = try mapReference(bundle, mappings, .method_report, disposition.source);
    return head;
}

pub fn prepareImports(a: std.mem.Allocator, index: anytype) ![]const Imported {
    var result: std.ArrayList(Imported) = .empty;
    for (index.records) |record| {
        if (record.input != .genesis) continue;
        const genesis = record.input.genesis;
        const imported = genesis.imported orelse continue;
        const metadata = imported.continuity orelse return error.UnprovenContinuityImport;
        const bundle = try importedBundle(index, metadata);
        const root = lineage(bundle, genesis.lineage) orelse
            return error.MissingContinuityLineage;
        if (!std.meta.eql(root.source_head, imported.source))
            return error.ContinuityAncestryMismatch;
        var head = try decode(.head, a, member(bundle, root.head).?.data);
        defer head.deinit();
        const rebased = try rebaseHead(bundle, metadata.members.items, head.value);
        if (!try equal(a, t.Head, imported.head, rebased) or
            !try equal(a, t.Specification, genesis.specification, rebased.specification))
            return error.ContinuityHeadMismatch;
        if (record.result == null) continue;
        try result.append(a, .{
            .obligation = record.task,
            .bundle = bundle,
            .metadata = metadata,
        });
    }
    return result.toOwnedSlice(a);
}

fn importedBundle(index: anytype, metadata: t.ContinuityImport) !Bundle {
    const view = index.continuity_import orelse return error.MissingContinuityManifest;
    const expected = view.metadata orelse return error.IncompleteContinuityImport;
    const bundle = view.bundle.?;
    if (!std.meta.eql(metadata.bundle, view.digest) or
        !std.meta.eql(metadata.source_namespace, bundle.source.namespace) or
        !std.meta.eql(metadata.source_cut, bundle.cut_digest))
        return error.ContinuityCutMismatch;
    const record = index.record(metadata.manifest.task) orelse
        return error.MissingContinuityManifest;
    if (record.input != .continuity_cut or record.result_digest == null or
        !std.meta.eql(record.result_digest.?, metadata.manifest.digest) or
        !std.meta.eql(record.input.continuity_cut.bundle_digest, view.digest))
        return error.InvalidContinuityManifest;
    if (metadata.members.items.len != expected.members.items.len)
        return error.IncompleteContinuityImport;
    for (metadata.members.items, expected.members.items) |left, right| {
        if (!std.meta.eql(left, right)) return error.ContinuityBindingMismatch;
    }
    return bundle;
}

pub fn findImport(index: anytype, obligation: t.Id) ?Imported {
    for (index.imports) |item| if (std.meta.eql(item.obligation, obligation)) return item;
    return null;
}

fn boundMember(value: Imported, local: t.Reference) ?Member {
    for (value.metadata.members.items) |entry| {
        if (std.meta.eql(entry.local, local)) return member(value.bundle, entry.member);
    }
    return null;
}

pub fn resolve(
    index: anytype,
    obligation: ?t.Id,
    local: t.Reference,
    kind: t.ContinuityKind,
) !t.ContinuityData {
    for (index.imports) |entry| {
        if (obligation) |target| if (!std.meta.eql(entry.obligation, target)) continue;
        const selected = boundMember(entry, local) orelse continue;
        if (selected.data.kind != kind) return error.WrongContinuityKind;
        if (obligation) |target| {
            const root = index.record(target).?.input.genesis;
            if (!std.meta.eql(root.lineage, selected.data.lineage))
                return error.ForeignContinuityMember;
        }
        return selected.data;
    }
    return error.UnprovenContinuityMember;
}

pub fn rebaseFrom(
    index: anytype,
    container: t.Reference,
    kind: t.ContinuityKind,
    original: t.Reference,
) !t.Reference {
    for (index.imports) |entry| {
        if (boundMember(entry, container) == null) continue;
        return mapReference(entry.bundle, entry.metadata.members.items, kind, original);
    }
    return error.UnprovenContinuityMember;
}

pub fn historicalControl(body: t.DirectiveBody) bool {
    return body == .transfer or body == .recovery_hold or body == .recovery_release;
}

pub fn directiveOperation(a: std.mem.Allocator, bundle: t.Digest, identity: t.Digest) ![]u8 {
    const key = try digest(a, struct { bundle: t.Digest, identity: t.Digest }, .{
        .bundle = bundle,
        .identity = identity,
    });
    return std.fmt.allocPrint(a, "continuity-directive:{s}", .{
        std.fmt.bytesToHex(key, .lower),
    });
}

pub fn mappedControl(
    a: std.mem.Allocator,
    index: anytype,
    imported: Imported,
    key: t.Digest,
) !?usize {
    const operation = try directiveOperation(a, imported.metadata.bundle, key);
    defer a.free(operation);
    const item = member(imported.bundle, key) orelse return error.MissingContinuityControl;
    var original = try decode(.directive, a, item.data);
    defer original.deinit();
    const body = try rebaseControl(imported, original.value.body);
    const stable = try @import("admission.zig").stableDigest(a, .{
        .operation = t.OperationId{ .bytes = operation },
        .request = key,
    });
    for (index.records, 0..) |record, position| {
        const envelope = switch (record.input) {
            inline else => |value| value.envelope,
        };
        if (!std.mem.eql(u8, envelope.operation.bytes, operation)) continue;
        if (record.input != .directive or
            !std.meta.eql(record.input.directive.obligation, imported.obligation) or
            !std.meta.eql(envelope.stable_request, stable) or envelope.origin != .local or
            !try equal(a, t.DirectiveBody, body, record.input.directive.body))
            return error.InvalidMappedContinuityControl;
        return position;
    }
    return null;
}

pub fn rebaseControl(imported: Imported, original: t.DirectiveBody) !t.DirectiveBody {
    var body = original;
    if (body == .adopt and body.adopt.method == .retained) {
        const mappings = imported.metadata.members.items;
        const method = &body.adopt.method.retained;
        method.source = try mapReference(imported.bundle, mappings, .method_report, method.source);
        method.report = try mapReference(imported.bundle, mappings, .method_report, method.report);
    }
    return body;
}

pub fn controlsComplete(
    a: std.mem.Allocator,
    index: anytype,
    target: t.Id,
    folded_ordinal: ?u64,
) !bool {
    const imported = findImport(index, target) orelse return true;
    const genesis = index.record(target).?.input.genesis;
    const root = lineage(imported.bundle, genesis.lineage).?;
    for (root.pending_controls.items) |key| {
        const item = member(imported.bundle, key) orelse return error.MissingContinuityControl;
        var control = try decode(.directive, a, item.data);
        defer control.deinit();
        if (historicalControl(control.value.body)) continue;
        const position = try mappedControl(a, index, imported, key) orelse return false;
        if (folded_ordinal) |ordinal|
            if (index.records[position].input.directive.ordinal > ordinal) return false;
    }
    return true;
}

pub fn sourceOutput(a: std.mem.Allocator, value: ?Value) !?t.Output {
    const result = value orelse return null;
    if (std.mem.eql(u8, result.schema.bytes, t.failure_schema_id)) return null;
    if (!std.mem.eql(u8, result.schema.bytes, t.output_schema_id))
        return error.UnsupportedContinuityOutput;
    return switch (result.encoding) {
        .contract => (try c.decodeOwned(t.Output, a, result.bytes.bytes)).value,
        .json => try native.values.fromJson(
            t.Output,
            a,
            (try native.json.parseAsset(a, result.bytes.bytes, result.bytes.bytes.len)).value,
        ),
    };
}

fn samePayload(
    a: std.mem.Allocator,
    item: Member,
    comptime kind: t.ContinuityKind,
    value: Payload(kind),
) !void {
    var decoded = try decode(kind, a, item.data);
    defer decoded.deinit();
    if (!try equal(a, Payload(kind), decoded.value, value))
        return error.ContinuityPayloadMismatch;
}

fn producedPayload(a: std.mem.Allocator, item: Member, input: t.Input, output: ?t.Output) !void {
    if (input == .continuity_member) {
        if (!try equal(a, t.ContinuityData, input.continuity_member.data, item.data))
            return error.ContinuityPayloadMismatch;
        return;
    }
    switch (item.data.kind) {
        .head => {
            const result = output orelse return error.MissingContinuityResult;
            const head = switch (result) {
                .genesis => |value| value,
                .step => |value| value.head,
                else => return error.ContinuityProducerMismatch,
            };
            try samePayload(a, item, .head, head);
        },
        .batch => {
            const result = output orelse return error.MissingContinuityResult;
            if (result != .step) return error.ContinuityProducerMismatch;
            try samePayload(a, item, .batch, result.step.batch orelse
                return error.MissingContinuityBatch);
        },
        .directive => {
            if (input != .directive) return error.ContinuityProducerMismatch;
            try samePayload(a, item, .directive, input.directive);
        },
        inline .turn, .delivery, .audit => |kind| {
            if (!std.mem.eql(u8, @tagName(input), @tagName(kind)))
                return error.ContinuityProducerMismatch;
            try samePayload(a, item, kind, .{
                .input = @field(input, @tagName(kind)),
                .result = if (output) |value| @field(value, @tagName(kind)) else null,
            });
        },
        .method_report => {
            if (input != .experiment or output == null or output.? != .experiment)
                return error.ContinuityProducerMismatch;
            try samePayload(a, item, .method_report, .{
                .input = input.experiment,
                .result = output.?.experiment,
            });
        },
        .method_source, .context => return error.UnsupportedContinuityProducer,
        .settlement => return error.InvalidContinuityFact,
    }
}

fn validateProducers(a: std.mem.Allocator, bundle: Bundle) !void {
    for (bundle.members.items) |source| {
        if (source.data.kind != .settlement or
            !std.meta.eql(source.data.source.namespace, bundle.source.namespace)) continue;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const fact = try decode(.settlement, scratch, source.data);
        const input = try c.decodeOwned(t.Input, scratch, fact.value.input.bytes.bytes);
        const output = try sourceOutput(scratch, fact.value.result);
        if (output) |value| if (!std.mem.eql(u8, @tagName(input.value), @tagName(value)))
            return error.ContinuityProducerMismatch;
        for (bundle.members.items) |item| {
            if (!std.meta.eql(item.current.task, source.data.source.task) or
                (item.data.kind == .settlement and
                    std.meta.eql(item.data.source.namespace, bundle.source.namespace))) continue;
            if (input.value != .continuity_member and
                (!std.meta.eql(item.data.source.namespace, bundle.source.namespace) or
                    !std.meta.eql(item.data.source.task, item.current.task) or
                    item.data.source.revision != fact.value.snapshot.revision or
                    !std.meta.eql(item.data.source.digest, item.current.digest)))
                return error.ContinuityProvenanceMismatch;
            try producedPayload(scratch, item, input.value, output);
        }
    }
}

fn currentInput(a: std.mem.Allocator, bundle: Bundle, task: t.Id) !t.Input {
    for (bundle.members.items) |item| {
        if (item.data.kind != .settlement or
            !std.meta.eql(item.data.source.namespace, bundle.source.namespace) or
            !std.meta.eql(item.data.source.task, task)) continue;
        const fact = try decode(.settlement, a, item.data);
        return (try c.decodeOwned(t.Input, a, fact.value.input.bytes.bytes)).value;
    }
    return error.MissingContinuityFact;
}

const Inherited = struct { start: usize = 0, end: usize = 0 };

fn foreignBlock(bundle: Bundle, keys: []const t.Digest) !Inherited {
    var block: ?Inherited = null;
    for (keys, 0..) |key, i| {
        const item = member(bundle, key) orelse return error.MissingContinuityControl;
        if (std.meta.eql(item.data.source.namespace, bundle.source.namespace)) continue;
        if (block) |*found| {
            if (found.end != i) return error.ContinuityControlOrderMismatch;
            found.end = i + 1;
        } else block = .{ .start = i, .end = i + 1 };
    }
    return block orelse .{};
}

fn inheritedPending(a: std.mem.Allocator, bundle: Bundle, root: Lineage) !Inherited {
    const input = try currentInput(a, bundle, root.obligation);
    if (input != .genesis) return error.ContinuityLineageMismatch;
    const keys = root.pending_controls.items;
    const block = try foreignBlock(bundle, keys);
    if (block.start == block.end) return block;
    const imported = input.genesis.imported orelse return error.ContinuityControlOrderMismatch;
    const metadata = imported.continuity orelse return error.UnprovenContinuityImport;
    for (keys[block.start..block.end]) |key| {
        if (try locallyAdmitted(a, bundle, metadata.bundle, key))
            return error.ContinuityControlOrderMismatch;
    }
    return block;
}

fn locallyAdmitted(a: std.mem.Allocator, bundle: Bundle, imported: t.Digest, key: t.Digest) !bool {
    const operation = try directiveOperation(a, imported, key);
    for (bundle.members.items) |item| {
        if (item.data.kind != .directive or
            !std.meta.eql(item.data.source.namespace, bundle.source.namespace)) continue;
        const control = try decode(.directive, a, item.data);
        if (std.mem.eql(u8, control.value.envelope.operation.bytes, operation)) return true;
    }
    return false;
}

fn validatePending(a: std.mem.Allocator, bundle: Bundle, root: Lineage, head: t.Head) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const inherited = try inheritedPending(scratch, bundle, root);
    var ordinal = head.folded_directive_ordinal;
    for (root.pending_controls.items, 0..) |key, i| {
        const item = member(bundle, key) orelse return error.MissingContinuityControl;
        if (!std.meta.eql(item.data.lineage, root.identity))
            return error.ContinuityLineageMismatch;
        for (root.pending_controls.items[0..i]) |old|
            if (std.meta.eql(old, key)) return error.DuplicateContinuityControl;
        const control = try decode(.directive, scratch, item.data);
        if (i >= inherited.start and i < inherited.end) continue;
        ordinal = try std.math.add(u64, ordinal, 1);
        if (!std.meta.eql(control.value.obligation, root.obligation) or
            control.value.ordinal != ordinal or
            !std.meta.eql(item.data.source.namespace, bundle.source.namespace))
            return error.ContinuityControlOrderMismatch;
    }
    var count: usize = inherited.end - inherited.start;
    for (bundle.members.items) |item| {
        if (item.data.kind != .directive or
            !std.meta.eql(item.data.source.namespace, bundle.source.namespace)) continue;
        const control = try decode(.directive, scratch, item.data);
        if (std.meta.eql(control.value.obligation, root.obligation) and
            control.value.ordinal > head.folded_directive_ordinal) count += 1;
    }
    if (count != root.pending_controls.items.len) return error.MissingContinuityControl;
}

pub fn preparePortable(a: std.mem.Allocator, index: anytype) ![]const Portable {
    const view = index.continuity_import orelse return &.{};
    const metadata = view.metadata orelse return &.{};
    const result = try a.alloc(Portable, 1);
    result[0] = .{ .bundle = view.bundle.?, .metadata = metadata };
    return result;
}

pub fn portableMember(index: anytype, local: t.Reference, kind: t.ContinuityKind) !struct {
    portable: Portable,
    member: Member,
} {
    for (index.portable) |portable| {
        for (portable.metadata.members.items) |mapping| {
            if (!std.meta.eql(mapping.local, local)) continue;
            const found = member(portable.bundle, mapping.member) orelse
                return error.MissingContinuityMember;
            if (found.data.kind != kind) return error.WrongContinuityKind;
            return .{ .portable = portable, .member = found };
        }
    }
    return error.UnprovenContinuityMember;
}

pub fn importedTarget(index: anytype, portable: Portable, identity: t.Digest) !t.Id {
    if (lineage(portable.bundle, identity) == null) return error.MissingContinuityTarget;
    for (index.imports) |imported| {
        if (std.meta.eql(imported.metadata.bundle, portable.metadata.bundle) and
            std.meta.eql(index.record(imported.obligation).?.input.genesis.lineage, identity))
            return imported.obligation;
    }
    return error.MissingContinuityTarget;
}
