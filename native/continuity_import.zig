const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const continuity = @import("continuity.zig");

pub const Phase = enum { manifest_pending, members_pending, genesis_pending, materialized };

pub const View = struct {
    position: usize,
    digest: t.Digest,
    phase: Phase = .manifest_pending,
    bundle: ?continuity.Bundle = null,
    manifest: ?t.Reference = null,
    local: []const ?usize = &.{},
    positions: std.AutoHashMapUnmanaged(t.Digest, usize) = .empty,
    members: u64 = 0,
    metadata: ?t.ContinuityImport = null,

    pub fn reference(self: *const View, index: anytype, identity: t.Digest) ?t.Reference {
        const position = self.local[self.positions.get(identity) orelse return null] orelse
            return null;
        const record = index.records[position];
        return .{ .task = record.task, .digest = record.result_digest orelse return null };
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

pub fn bundleSource(a: std.mem.Allocator, bytes: []const u8) !continuity.Source {
    const Prefix = struct { version: u32, source: continuity.Source };
    var consumed: usize = 0;
    var prefix = try c.decodePrefixOwned(Prefix, a, bytes, &consumed);
    defer prefix.deinit();
    if (prefix.value.version != 1) return error.UnsupportedContinuityBundle;
    return prefix.value.source;
}

pub fn importedLineage(index: anytype, identity: t.Digest, bundle: t.Digest) !?usize {
    const position = index.lineages.get(identity) orelse return null;
    const imported = index.records[position].input.genesis.imported orelse
        return error.ContinuityLineageConflict;
    const metadata = imported.continuity orelse return error.ContinuityLineageConflict;
    if (!std.meta.eql(metadata.bundle, bundle)) return error.ContinuityLineageConflict;
    return position;
}

pub fn prepare(a: std.mem.Allocator, index: anytype) !?View {
    const position = try manifest(a, index) orelse return null;
    const record = index.records[position];
    const cut = record.input.continuity_cut;
    var view: View = .{ .position = position, .digest = cut.bundle_digest };
    const output = record.result orelse return view;
    if (output != .continuity_cut or record.result_digest == null or
        !std.meta.eql(output.continuity_cut.bundle_digest, cut.bundle_digest) or
        !std.mem.eql(u8, output.continuity_cut.bytes.bytes, cut.bytes.bytes))
        return error.InvalidContinuityManifest;
    if (!std.meta.eql(continuity.hash(cut.bytes.bytes), cut.bundle_digest))
        return error.ContinuityDigestMismatch;
    view.bundle = (try c.decodeBorrowed(continuity.Bundle, a, cut.bytes.bytes)).value;
    view.manifest = .{ .task = record.task, .digest = record.result_digest.? };
    try mapMembers(a, index, &view);
    view.phase = if (view.metadata == null)
        .members_pending
    else if (try lineagesComplete(index, view))
        .materialized
    else
        .genesis_pending;
    return view;
}

fn manifest(a: std.mem.Allocator, index: anytype) !?usize {
    var found: ?usize = null;
    for (index.records, 0..) |record, position| {
        if (record.input != .continuity_cut) continue;
        const cut = record.input.continuity_cut;
        const source = try bundleSource(a, cut.bytes.bytes);
        if (index.namespace) |own| if (std.meta.eql(source.namespace, own)) continue;
        if (found) |first| {
            const selected = index.records[first];
            if (!std.meta.eql(selected.input.continuity_cut.bundle_digest, cut.bundle_digest))
                return error.ContinuityImportConflict;
            if (selected.result != null or record.result == null) continue;
        }
        found = position;
    }
    return found;
}

fn mapMembers(a: std.mem.Allocator, index: anytype, view: *View) !void {
    const bundle = view.bundle.?;
    const local = try a.alloc(?usize, bundle.members.items.len);
    const mappings = try a.alloc(t.ContinuityBinding, bundle.members.items.len);
    view.local = local;
    for (bundle.members.items, local, mappings, 0..) |item, *slot, *mapping, i| {
        try view.positions.put(a, item.identity, i);
        slot.* = try memberRecord(a, index, view.digest, item);
        const position = slot.* orelse continue;
        const record = index.records[position];
        const result = record.result_digest orelse continue;
        try verifyBindings(index, view, item, record.input.continuity_member);
        mapping.* = .{
            .member = item.identity,
            .local = .{ .task = record.task, .digest = result },
        };
        view.members += 1;
    }
    if (view.members != bundle.members.items.len) return;
    view.metadata = .{
        .bundle = view.digest,
        .manifest = view.manifest.?,
        .source_namespace = bundle.source.namespace,
        .source_cut = bundle.cut_digest,
        .members = .{ .items = mappings },
    };
}

fn memberRecord(
    a: std.mem.Allocator,
    index: anytype,
    bundle: t.Digest,
    item: continuity.Member,
) !?usize {
    const operation = try mappedOperation(a, .member, bundle, item.identity);
    const position = index.operations.get(operation) orelse return null;
    const record = index.records[position];
    if (record.input != .continuity_member) return error.InvalidContinuityMember;
    const input = record.input.continuity_member;
    if (!std.meta.eql(input.bundle, bundle) or
        !std.meta.eql(input.envelope.stable_request, item.identity) or
        !std.meta.eql(try continuity.digest(a, t.ContinuityData, input.data), item.identity))
        return error.InvalidContinuityMember;
    if (record.result) |output| {
        if (output != .continuity_member or
            !std.meta.eql(output.continuity_member.envelope.stable_request, item.identity))
            return error.InvalidContinuityMember;
    }
    return position;
}

fn verifyBindings(
    index: anytype,
    view: *const View,
    item: continuity.Member,
    input: t.ContinuityMember,
) !void {
    const dependencies = item.data.dependencies.items;
    if (input.bindings.items.len != dependencies.len) return error.InvalidContinuityMember;
    for (input.bindings.items, dependencies) |bound, dependency| {
        const expected = view.reference(index, dependency) orelse
            return error.ContinuityBindingMismatch;
        if (!std.meta.eql(bound.member, dependency) or !std.meta.eql(bound.local, expected))
            return error.ContinuityBindingMismatch;
    }
}

fn lineagesComplete(index: anytype, view: View) !bool {
    var complete = true;
    for (view.bundle.?.lineages.items) |root| {
        const position = try importedLineage(index, root.identity, view.digest) orelse {
            complete = false;
            continue;
        };
        if (index.records[position].result == null) complete = false;
    }
    return complete;
}
