const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");
const external = @import("slack_audit_external.zig");
const slack = @import("slack.zig");
const preparation = @import("delivery_prepare.zig");

pub const Candidate = struct {
    source_namespace: ?t.Digest,
    source: t.RevisionReference,
    capture: t.Digest,
    lineage: t.Digest,
    timestamp: t.Timestamp,
    metadata: c.Text(8192),
    matched_admitted_delivery: bool,
    requires_owner_disposition: bool,
};
pub const Page = struct {
    candidates: c.Vector(Candidate, 64),
    total: u64,
    next: ?u64,
    scans: u64,
    incomplete_scans: u64,
};
const Collector = struct {
    allocator: std.mem.Allocator,
    index: *const idx.Index,
    after: u64,
    limit: u32,
    target: ?t.Id,
    values: std.ArrayList(Candidate) = .empty,
    total: u64 = 0,
    scans: u64 = 0,
    incomplete: u64 = 0,

    fn observation(
        self: *Collector,
        namespace: ?t.Digest,
        snapshot: retained.Snapshot,
        capture: t.Digest,
        lineage: t.Digest,
        value: slack.HistoryObservation,
    ) !void {
        self.total += 1;
        if (self.total <= self.after or self.values.items.len >= self.limit) return;
        const a = self.allocator;
        const encoded = try std.json.Stringify.valueAlloc(a, value.metadata, .{});
        const known = try retainedIntent(a, self.index, value.metadata);
        try self.values.append(a, .{
            .source_namespace = namespace,
            .source = .{
                .task = snapshot.task,
                .revision = snapshot.revision,
                .digest = try continuity.digest(a, retained.Snapshot, snapshot),
            },
            .capture = capture,
            .lineage = lineage,
            .timestamp = .{ .bytes = try a.dupe(u8, value.timestamp) },
            .metadata = .{ .bytes = encoded },
            .matched_admitted_delivery = known,
            .requires_owner_disposition = !known,
        });
    }
};

pub fn sourceInput(a: std.mem.Allocator, value: continuity.Value) !t.Input {
    if (!std.mem.eql(u8, value.schema.bytes, t.input_schema_id))
        return error.UnsupportedContinuityInput;
    return switch (value.encoding) {
        .contract => (try c.decodeOwned(t.Input, a, value.bytes.bytes)).value,
        .json => try native.values.fromJson(t.Input, a, (try native.json.parseAsset(a, value.bytes.bytes, value.bytes.bytes.len)).value),
    };
}

pub fn page(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: ?t.Id,
    after: ?u64,
    limit: u32,
) !Page {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    var collector: Collector = .{
        .allocator = a,
        .index = index,
        .after = after orelse 0,
        .limit = limit,
        .target = target,
    };
    errdefer collector.values.deinit(a);
    for (index.records) |record| {
        if (record.input != .audit and record.input != .lineage_audit) continue;
        if (record.owner_snapshot == null or record.owner_evidence == null) {
            collector.scans += 1;
            collector.incomplete += 1;
            continue;
        }
        const snapshot = record.owner_snapshot.?;
        const evidence = record.owner_evidence.?;
        try collect(&collector, null, record.input, snapshot, evidence.attempts);
    }
    try imported(&collector);
    return .{
        .candidates = .{ .items = try collector.values.toOwnedSlice(a) },
        .total = collector.total,
        .next = if (collector.total > collector.after and
            collector.total - collector.after > collector.limit)
            collector.after + collector.limit
        else
            null,
        .scans = collector.scans,
        .incomplete_scans = collector.incomplete,
    };
}

fn imported(collector: *Collector) !void {
    var arena = std.heap.ArenaAllocator.init(collector.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.AutoHashMap(t.Digest, void) = .init(a);
    for (collector.index.imports) |entry| {
        if (collector.target) |target| if (!std.meta.eql(entry.obligation, target)) continue;
        for (entry.bundle.members.items) |member| {
            if (member.data.kind != .settlement) continue;
            const key = try continuity.digest(a, @TypeOf(member.data.source), member.data.source);
            const prior = try seen.getOrPut(key);
            if (prior.found_existing) continue;
            var member_arena = std.heap.ArenaAllocator.init(a);
            defer member_arena.deinit();
            const scratch = member_arena.allocator();
            const source = try continuity.decode(.settlement, scratch, member.data);
            const input = try sourceInput(scratch, source.value.input);
            if (input != .audit and input != .lineage_audit) continue;
            const attempts = try scratch.alloc(retained.AttemptEvidence, source.value.attempts.items.len);
            for (attempts, source.value.attempts.items) |*dest, saved| dest.* = .{
                .id = saved.id,
                .response = if (saved.response) |value| value.bytes else null,
                .reply = if (saved.reply) |value| value.bytes else null,
            };
            try collect(collector, member.data.source.namespace, input, source.value.snapshot, attempts);
        }
    }
}

fn collect(
    collector: *Collector,
    namespace: ?t.Digest,
    input: t.Input,
    snapshot: retained.Snapshot,
    attempts: []const retained.AttemptEvidence,
) !void {
    const lineage = switch (input) {
        .audit => |value| value.delivery.key.lineage,
        .lineage_audit => |value| value.lineage,
        else => return,
    };
    if (collector.target) |target| {
        const obligation = collector.index.obligation(target) orelse return error.UnknownObligation;
        if (!std.meta.eql(collector.index.head(obligation).lineage, lineage)) return;
    }
    collector.scans += 1;
    const complete = (switch (input) {
        .audit => |value| walk(false, collector, namespace, value, snapshot, attempts),
        .lineage_audit => |value| walk(true, collector, namespace, value, snapshot, attempts),
        else => unreachable,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    if (!complete) collector.incomplete += 1;
}

fn walk(
    comptime lineage_only: bool,
    collector: *Collector,
    namespace: ?t.Digest,
    audit: if (lineage_only) t.LineageAudit else t.Audit,
    snapshot: retained.Snapshot,
    attempts: []const retained.AttemptEvidence,
) !bool {
    const Contract = if (lineage_only) @import("../app/lineage_audit_contract.zig") else @import("../app/audit_contract.zig");
    var arena = std.heap.ArenaAllocator.init(collector.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pages: std.ArrayList(@import("../app/audit_contract.zig").CapturedPage) = .empty;
    var history: ?slack.HistoryAudit = null;
    defer if (history) |*value| value.deinit();
    for (0..audit.page_limit) |_| {
        const request: Contract.Request = .{ .audit = audit, .pages = .{ .items = pages.items } };
        const bytes = try c.encodeOwned(Contract.Request, a, request);
        const response = (try captured(a, snapshot, attempts, Contract.identity, bytes)) orelse
            return false;
        if (response.value != .response) return false;
        const next = response.value.response;
        if (history == null) history = if (lineage_only)
            try external.replayLineage(a, request, next.bot_id.bytes)
        else
            try external.replayDelivery(a, request, next.bot_id.bytes);
        const offset = history.?.observations.items.len;
        if (lineage_only) try external.ingestLineage(a, &history.?, request, next) else try external.ingestDelivery(a, &history.?, request, next);
        for (history.?.observations.items[offset..]) |value| try collector.observation(
            namespace,
            snapshot,
            response.digest,
            if (lineage_only) audit.lineage else audit.delivery.key.lineage,
            value,
        );
        if (history.?.reason != null) return false;
        if (history.?.complete) return audit.latest != null;
        try pages.append(a, next);
    }
    return false;
}

const Captured = struct { value: external.Capture, digest: t.Digest };

fn captured(
    a: std.mem.Allocator,
    snapshot: retained.Snapshot,
    evidence: []const retained.AttemptEvidence,
    identity: []const u8,
    request: []const u8,
) !?Captured {
    const digest = preparation.hash(request);
    var found: ?Captured = null;
    for (snapshot.attempts.items) |attempt| {
        const prepared = attempt.prepared orelse continue;
        if (!std.mem.eql(u8, attempt.capability.bytes, identity) or
            !std.meta.eql(prepared.digest, digest) or prepared.bytes != request.len) continue;
        const capture = attempt.capture orelse continue;
        if (capture.disposition != .complete) continue;
        const reference = capture.response orelse continue;
        for (evidence) |item| {
            if (!std.meta.eql(item.id, attempt.id)) continue;
            const bytes = item.response orelse return error.MissingHistoryCapture;
            if (bytes.len != reference.bytes or
                !std.meta.eql(preparation.hash(bytes), reference.digest))
                return error.InvalidHistoryCapture;
            const decoded = try c.decodeOwned(external.Capture, a, bytes);
            const request_digest = switch (decoded.value) {
                .response => |value| value.evidence.request_digest,
                .rejected => |value| value.request_digest,
            };
            if (!std.meta.eql(request_digest, digest)) return error.InvalidHistoryCapture;
            if (found) |prior| {
                if (!std.meta.eql(prior.digest, reference.digest)) return error.AmbiguousHistoryCapture;
            } else found = .{ .value = decoded.value, .digest = reference.digest };
        }
    }
    return found;
}

fn retainedIntent(a: std.mem.Allocator, index: *const idx.Index, metadata: std.json.Value) !bool {
    for (index.records) |record| {
        if (record.input == .delivery and try matches(a, record.input.delivery, metadata)) return true;
    }
    for (index.imports) |entry| for (entry.bundle.members.items) |member| {
        if (member.data.kind != .delivery) continue;
        var saved = try continuity.decode(.delivery, a, member.data);
        defer saved.deinit();
        if (try matches(a, saved.value.input, metadata)) return true;
    };
    return false;
}

fn matches(a: std.mem.Allocator, delivery: t.Delivery, metadata: std.json.Value) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, delivery.payload.wire_json.bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const expected = parsed.value.object.get("metadata") orelse return error.InvalidPayload;
    return slack.equalJson(expected, metadata);
}
