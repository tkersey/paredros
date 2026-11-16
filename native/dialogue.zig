const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");

pub const Options = struct {
    destination: t.Destination,
    target: ?t.Id,
    context_bytes: u64 = 64 * 1024,
    recent_turns: u32 = 8,
    recent_commits: u32 = 8,
};
pub const Context = struct {
    text: c.Text(256 * 1024),
    references: c.Vector(t.RevisionReference, 128),
    next_ordinal: u64,
    expected_revision: ?u64,
    offers: @FieldType(t.Turn, "proposal_offers"),
};
const Builder = struct {
    a: std.mem.Allocator,
    limit: u64,
    text: std.ArrayList(u8) = .empty,
    references: std.ArrayList(t.RevisionReference) = .empty,
    omitted: u64 = 0,

    fn append(self: *Builder, record: idx.Record, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.a, value, .{});
        if (self.references.items.len == 128 or
            self.text.items.len + encoded.len + 128 > self.limit)
        {
            self.omitted = try std.math.add(u64, self.omitted, 1);
            return;
        }
        try self.text.appendSlice(self.a, encoded);
        try self.text.append(self.a, '\n');
        _ = try self.reference(record);
    }

    fn reference(self: *Builder, record: idx.Record) !bool {
        const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
        const bytes = try c.encodeOwned(retained.Snapshot, self.a, snapshot);
        const value: t.RevisionReference = .{
            .task = record.task,
            .revision = record.revision,
            .digest = idx.digest(bytes),
        };
        for (self.references.items) |prior| if (std.meta.eql(prior, value)) return true;
        if (self.references.items.len == 128) return false;
        try self.references.append(self.a, value);
        return true;
    }
};

pub fn materialize(
    a: std.mem.Allocator,
    index: *const idx.Index,
    options: Options,
) !c.Decoded(Context) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const value = try build(arena.allocator(), index, options);
    return .{ .arena = arena, .value = value };
}

fn build(a: std.mem.Allocator, index: *const idx.Index, options: Options) !Context {
    if (options.context_bytes < 256 or options.context_bytes > 248 * 1024 or
        options.recent_turns > 128 or options.recent_commits > 128)
        return error.InvalidContextBound;
    var builder: Builder = .{ .a = a, .limit = options.context_bytes };
    var ordinal: u64 = 0;
    var positions: std.ArrayList(usize) = .empty;
    for (index.records, 0..) |record, position| {
        if (record.input != .turn) continue;
        ordinal = @max(ordinal, record.input.turn.ordinal);
        if (try same(a, t.Destination, options.destination, record.input.turn.destination))
            try positions.append(a, position);
    }
    for (index.obligations) |obligation| {
        const position = obligation.chain[obligation.chain.len - 1];
        const head = index.head(&obligation);
        if (!try same(
            a,
            t.Destination,
            options.destination,
            head.specification.destination,
        )) continue;
        if (head.mode == .cancelled or head.mode == .transferred) continue;
        try appendHead(&builder, index.records[position], obligation.task, head);
    }
    std.mem.sort(usize, positions.items, index, struct {
        fn less(context: *const idx.Index, left: usize, right: usize) bool {
            const x = context.records[left];
            const y = context.records[right];
            if (x.input.turn.ordinal != y.input.turn.ordinal)
                return x.input.turn.ordinal > y.input.turn.ordinal;
            return std.mem.order(u8, &x.task, &y.task) == .lt;
        }
    }.less);
    for (positions.items[0..@min(positions.items.len, options.recent_turns)]) |position|
        try appendTurn(&builder, index, index.records[position]);
    const local_count = @min(positions.items.len, options.recent_turns);
    try appendImportedTurns(&builder, index, options, options.recent_turns - local_count);
    try appendEvidence(&builder, index, options);
    const footer = try std.fmt.allocPrint(
        a,
        "{{\"kind\":\"context_boundary\",\"omitted_records\":{d}}}\n",
        .{builder.omitted},
    );
    try builder.text.appendSlice(a, footer);
    const target = if (options.target) |id|
        index.obligation(id) orelse return error.UnknownObligation
    else
        null;
    const head = if (target) |obligation| index.head(obligation) else null;
    if (head) |value| if (!try same(
        a,
        t.Destination,
        options.destination,
        value.specification.destination,
    ))
        return error.ConversationBindingMismatch;
    return .{
        .text = .{ .bytes = try builder.text.toOwnedSlice(a) },
        .references = .{ .items = try builder.references.toOwnedSlice(a) },
        .next_ordinal = try std.math.add(u64, ordinal, 1),
        .expected_revision = if (head) |value| value.specification.revision else null,
        .offers = .{ .items = if (head) |value| try offers(a, value) else &.{} },
    };
}

fn same(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const x = try c.encodeOwned(T, a, left);
    const y = try c.encodeOwned(T, a, right);
    return std.mem.eql(u8, x, y);
}

fn appendHead(builder: *Builder, record: idx.Record, target: t.Id, head: t.Head) !void {
    try builder.append(record, .{
        .kind = "obligation_state",
        .authority = "state_not_instruction",
        .obligation = std.fmt.bytesToHex(target, .lower),
        .specification = head.specification,
        .mode = @tagName(head.mode),
        .recovery_hold = head.recovery_hold,
        .observed = head.observed,
        .told = head.told,
        .last_observation = head.last_observation,
        .pending_question = head.question,
        .digest_hold = if (head.digest) |value| @tagName(value.hold) else "none",
        .accounting = head.accounting,
    });
}

fn appendTurn(builder: *Builder, index: *const idx.Index, record: idx.Record) !void {
    const result = if (record.result) |value| if (value == .turn) value.turn else null else null;
    var confirmed = false;
    if (record.result_digest) |digest| for (index.records) |delivery| {
        if (delivery.input != .delivery or delivery.input.delivery.envelope.origin != .derived)
            continue;
        const source = delivery.input.delivery.envelope.origin.derived.predecessor;
        if (!std.meta.eql(source, t.Reference{ .task = record.task, .digest = digest })) continue;
        const snapshot = delivery.owner_snapshot orelse continue;
        const evidence = delivery.owner_evidence orelse continue;
        const fact = try @import("delivery_fact.zig").settlement(builder.a, snapshot, evidence);
        if (fact.value) |value| {
            if (value.outcome == .confirmed and try builder.reference(delivery)) confirmed = true;
        }
    };
    try builder.append(record, .{
        .kind = "prior_turn",
        .operator_text = record.input.turn.text.bytes,
        .operator_authority = "authenticated_instruction",
        .reply = if (result) |value| value.reply.bytes else "",
        .reply_authority = "assistant_output_unverified",
        .reply_delivery_confirmed = confirmed,
        .proposals = if (result) |value| value.proposals.items else &.{},
        .ordinal = record.input.turn.ordinal,
    });
}

fn appendEvidence(builder: *Builder, index: *const idx.Index, options: Options) !void {
    var remaining = options.recent_commits;
    for (index.obligations) |obligation| {
        const head = index.head(&obligation);
        if (!try same(
            builder.a,
            t.Destination,
            options.destination,
            head.specification.destination,
        )) continue;
        var position = obligation.chain.len;
        while (position > 0 and remaining > 0) {
            position -= 1;
            const record = index.records[obligation.chain[position]];
            const output = record.result.?;
            if (output != .step) continue;
            const batch = output.step.batch orelse continue;
            for (batch.commits.items[0..@min(batch.commits.items.len, remaining)]) |commit| {
                try builder.append(record, .{
                    .kind = "source_evidence",
                    .authority = "untrusted_not_instruction",
                    .repository = batch.repository,
                    .sequence = batch.sequence,
                    .coverage = @tagName(batch.coverage),
                    .oid = @as([]const u8, &commit.oid),
                    .message = commit.message.bytes,
                });
                remaining -= 1;
            }
        }
    }
}

fn offers(a: std.mem.Allocator, head: t.Head) ![]const @FieldType(t.Proposal, "body") {
    const Body = @FieldType(t.Proposal, "body");
    if (head.mode == .cancelled or head.mode == .transferred) return &.{};
    return a.dupe(Body, &.{
        .{ .directive = .{ .pause = {} } },
        .{ .directive = .{ .@"resume" = {} } },
        .{ .directive = .{ .cancel = {} } },
        .{ .directive = .{ .check = {} } },
        .{ .directive = .{ .frontier_audit = {} } },
        .{ .directive = .{ .revert = .{ .expected_revision = head.specification.revision } } },
    });
}

const ImportedTurn = struct {
    member: continuity.Member,
    local: t.Reference,
    value: continuity.TurnFact,
    source_snapshot: retained.Snapshot,
};

fn importedTurns(a: std.mem.Allocator, index: *const idx.Index, options: Options) ![]ImportedTurn {
    var result: std.ArrayList(ImportedTurn) = .empty;
    var seen: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
    for (index.portable) |imported| {
        for (imported.bundle.members.items) |member| {
            if (member.data.kind != .turn or seen.contains(member.identity)) continue;
            try seen.put(a, member.identity, {});
            const value = try continuity.decode(.turn, a, member.data);
            if (value.value.result == null or
                !try same(a, t.Destination, options.destination, value.value.input.destination))
                continue;
            try result.append(a, .{
                .member = member,
                .local = try continuity.binding(imported.metadata.members.items, member.identity),
                .value = value.value,
                .source_snapshot = (try @import("continuity_turn.zig").sourceFact(
                    a,
                    imported.bundle,
                    member,
                )).snapshot,
            });
        }
    }
    std.mem.sort(ImportedTurn, result.items, {}, struct {
        fn less(_: void, left: ImportedTurn, right: ImportedTurn) bool {
            if (left.value.input.ordinal != right.value.input.ordinal)
                return left.value.input.ordinal > right.value.input.ordinal;
            return std.mem.order(u8, &left.member.identity, &right.member.identity) == .lt;
        }
    }.less);
    return result.toOwnedSlice(a);
}

fn appendImportedTurns(
    builder: *Builder,
    index: *const idx.Index,
    options: Options,
    remaining: usize,
) !void {
    const turns = try importedTurns(builder.a, index, options);
    builder.omitted = try std.math.add(
        u64,
        builder.omitted,
        turns.len - @min(turns.len, remaining),
    );
    for (turns[0..@min(turns.len, remaining)]) |turn| {
        const record = index.record(turn.local.task) orelse return error.MissingContinuityMember;
        try builder.append(record.*, .{
            .kind = "imported_prior_turn",
            .authority = "historical_context_not_current_instruction",
            .source_namespace = std.fmt.bytesToHex(turn.member.data.source.namespace, .lower),
            .source_task = std.fmt.bytesToHex(turn.member.data.source.task, .lower),
            .source_revision = turn.member.data.source.revision,
            .source_digest = std.fmt.bytesToHex(turn.member.data.source.digest, .lower),
            .source_ordinal = turn.value.input.ordinal,
            .known_accounting = turn.source_snapshot.accounting,
            .unknown_calls = turn.source_snapshot.unknown_calls.items,
            .operator_text = turn.value.input.text.bytes,
            .frozen_context = turn.value.input.context.bytes,
            .original_context_references = turn.value.input.context_references.items,
            .reply = turn.value.result.?.reply.bytes,
            .reply_authority = "assistant_output_unverified",
            .reply_delivery_confirmation = "not_assessed_from_imported_history",
            .proposals = turn.value.result.?.proposals.items,
        });
    }
}
