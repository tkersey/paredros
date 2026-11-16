const std = @import("std");
const t = @import("application_types");
const idx = @import("index.zig");
const continuity = @import("continuity.zig");

pub const Capability = enum { pending, qualified, degraded };

pub const Evidence = struct {
    source_namespace: ?t.Digest,
    task: t.Id,
    revision: u64,
    outcome: enum { found, not_observed, inconclusive, metadata_missing },
};
pub const View = struct {
    capability: Capability = .pending,
    previously_qualified: bool = false,
    readback_order: enum { unknown } = .unknown,
    successful_readback: ?Evidence = null,
    failed_readback: ?Evidence = null,
    send_metadata_missing: ?Evidence = null,

    fn observe(self: *View, evidence: Evidence) void {
        switch (evidence.outcome) {
            .found => self.successful_readback = evidence,
            .not_observed, .inconclusive => self.failed_readback = evidence,
            .metadata_missing => self.send_metadata_missing = evidence,
        }
    }
};

pub fn capability(a: std.mem.Allocator, index: *const idx.Index, target: t.Id) !Capability {
    return (try inspect(a, index, target)).capability;
}

pub fn inspect(a: std.mem.Allocator, index: *const idx.Index, target: t.Id) !View {
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    const head = index.head(obligation);
    var result: View = .{};
    for (index.records) |record| {
        if (try classify(a, head, record.input, record.result)) |outcome| result.observe(.{
            .source_namespace = null,
            .task = record.task,
            .revision = record.revision,
            .outcome = outcome,
        });
    }
    for (index.imports) |imported| {
        if (!std.meta.eql(imported.obligation, target)) continue;
        for (imported.bundle.members.items) |member| {
            if (member.data.kind != .settlement) continue;
            var source = try continuity.decode(.settlement, a, member.data);
            defer source.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const scratch = arena.allocator();
            const input = try @import("history_evidence.zig").sourceInput(scratch, source.value.input);
            const output = try continuity.sourceOutput(scratch, source.value.result);
            if (try classify(scratch, head, input, output)) |outcome| result.observe(.{
                .source_namespace = member.data.source.namespace,
                .task = source.value.snapshot.task,
                .revision = source.value.snapshot.revision,
                .outcome = outcome,
            });
        }
    }
    result.previously_qualified = result.successful_readback != null;
    result.capability = if (result.failed_readback != null) .degraded else if (result.previously_qualified)
        .qualified
    else if (result.send_metadata_missing != null) .degraded else .pending;
    return result;
}

fn classify(
    a: std.mem.Allocator,
    head: t.Head,
    input: t.Input,
    output: ?t.Output,
) !?@FieldType(Evidence, "outcome") {
    const delivery = switch (input) {
        .delivery => |value| value,
        .audit => |value| value.delivery,
        else => return null,
    };
    if (delivery.key.purpose != .activation or !std.meta.eql(delivery.key.lineage, head.lineage) or
        !try continuity.equal(a, t.Destination, delivery.destination, head.specification.destination))
        return null;
    const outcome = output orelse return null;
    if (input == .delivery and outcome == .delivery) return switch (outcome.delivery) {
        .confirmed => |value| if (value.metadata_observed) null else .metadata_missing,
        else => null,
    };
    if (input == .audit and outcome == .audit) return switch (outcome.audit) {
        .found => .found,
        .not_observed => .not_observed,
        .inconclusive => .inconclusive,
    };
    return null;
}
