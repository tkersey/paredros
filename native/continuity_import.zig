const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const continuity = @import("continuity.zig");

pub const Phase = enum { manifest_pending, values_pending, genesis_pending, materialized };

pub const View = struct {
    position: usize,
    digest: t.Digest,
    phase: Phase = .manifest_pending,
    bundle: ?continuity.Bundle = null,
    manifest: ?t.Reference = null,
    materialized: u64 = 0,
};

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
    if (!std.meta.eql(imported.continuity.bundle, bundle)) return error.ContinuityLineageConflict;
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
    var missing = false;
    for (try continuity.values(a, view.bundle.?)) |value| {
        if (try continuity.localReport(a, index, view.digest, value.report) == null) {
            missing = true;
        } else view.materialized += 1;
    }
    if (missing) {
        view.phase = .values_pending;
        return view;
    }
    var complete = true;
    for (view.bundle.?.members.items) |item| {
        if (item != .obligation) continue;
        const local = try importedLineage(index, item.obligation.lineage, view.digest);
        if (local != null and index.records[local.?].result != null) {
            view.materialized += 1;
        } else complete = false;
    }
    view.phase = if (complete) .materialized else .genesis_pending;
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
