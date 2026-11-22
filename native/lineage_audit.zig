const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const admission = @import("admission.zig");
const continuity = @import("continuity.zig");

fn operation(a: std.mem.Allocator, source: t.Reference, target: t.Id) ![]u8 {
    const key = .{ .source = source, .target = target };
    return std.fmt.allocPrint(a, "lineage-audit:{s}", .{
        std.fmt.bytesToHex(try admission.stableDigest(a, key), .lower),
    });
}

pub fn stableDigest(a: std.mem.Allocator, value: t.LineageAudit) !t.Digest {
    return admission.stableDigest(a, .{
        .obligation = value.obligation,
        .predecessor = value.predecessor,
        .lineage = value.lineage,
        .destination = value.destination,
        .oldest = value.oldest,
        .latest = value.latest,
        .page_limit = value.page_limit,
    });
}

pub fn admit(
    service: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    source: t.Reference,
) !t.Id {
    const name = try operation(a, source, target);
    defer a.free(name);
    if (try service.operationLookup(a, name)) |found| {
        var receipt = found;
        defer receipt.deinit();
        var saved = (try service.applicationValue(a, receipt.value.task, .input)) orelse
            return error.MissingAdmittedInput;
        defer saved.deinit();
        if (saved.encoding != .contract or !std.mem.eql(u8, saved.schema_id, t.input_schema_id))
            return error.UnsupportedApplicationSchema;
        var input = try c.decodeOwned(t.Input, a, saved.bytes);
        defer input.deinit();
        if (input.value != .lineage_audit or
            !try permits(a, index, input.value.lineage_audit)) return error.OperationConflict;
        return receipt.value.task;
    }
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    const position = obligation.chain[obligation.chain.len - 1];
    const head = index.head(obligation);
    var value: t.LineageAudit = .{
        .envelope = .{
            .operation = .{ .bytes = name },
            .stable_request = @splat(0),
            .origin = .{ .derived = .{ .predecessor = source } },
        },
        .obligation = target,
        .predecessor = index.reference(position),
        .lineage = head.lineage,
        .destination = head.specification.destination,
        .oldest = .{ .bytes = "0.000000" },
        .latest = null,
        .page_limit = head.specification.policies.history_page_limit,
    };
    value.envelope.stable_request = try stableDigest(a, value);
    if (!try permits(a, index, value)) return error.UnauthorizedLineageAudit;
    return (try service.submit(a, name, .{ .lineage_audit = value })).receipt.task;
}

pub fn permits(a: std.mem.Allocator, index: *const idx.Index, value: t.LineageAudit) !bool {
    if (value.envelope.origin != .derived or value.envelope.version != 1) return false;
    const obligation = index.obligation(value.obligation) orelse return false;
    const source = value.envelope.origin.derived.predecessor;
    if (!try authorized(index, obligation, source)) return false;
    var previous: ?t.Head = null;
    for (obligation.chain) |position| {
        if (!std.meta.eql(index.reference(position), value.predecessor)) continue;
        const output = index.records[position].result.?;
        previous = if (output == .genesis) output.genesis else output.step.head;
    }
    const head = previous orelse return false;
    if (!std.meta.eql(head.lineage, value.lineage) or
        !try continuity.equal(
            a,
            t.Destination,
            head.specification.destination,
            value.destination,
        ) or
        value.page_limit != head.specification.policies.history_page_limit or
        value.page_limit == 0 or !std.mem.eql(u8, value.oldest.bytes, "0.000000")) return false;
    if (value.latest != null) return false;
    if (!std.meta.eql(value.envelope.stable_request, try stableDigest(a, value))) return false;
    const expected = try operation(a, source, value.obligation);
    defer a.free(expected);
    return std.mem.eql(u8, expected, value.envelope.operation.bytes);
}

fn authorized(
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    source: t.Reference,
) !bool {
    const record = index.record(source.task) orelse return false;
    if (record.result_digest == null or record.result == null or
        !std.meta.eql(record.result_digest.?, source.digest)) return false;
    if (try @import("audit_control.zig").recoverySource(index, obligation)) |recovery|
        if (std.meta.eql(source, recovery)) return true;
    if (record.input != .step or record.result.? != .step or !record.selected) return false;
    var related = false;
    for (obligation.chain) |position|
        if (std.meta.eql(index.records[position].task, record.task)) {
            related = true;
        };
    if (!related) return false;
    for (record.result.?.step.audit_requests.items) |request|
        if (request == .frontier) return true;
    return false;
}
