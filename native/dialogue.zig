const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const retained = @import("retained.zig");
const continuity = @import("continuity.zig");

pub const Options = struct {
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
        if (!record.superseded) try positions.append(a, position);
    }
    for (index.obligations) |obligation| {
        const position = obligation.chain[obligation.chain.len - 1];
        const head = index.head(&obligation);
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
        try appendTurn(&builder, index.records[position]);
    const local_count = @min(positions.items.len, options.recent_turns);
    try appendImportedTurns(&builder, index, options.recent_turns - local_count);
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
    return .{
        .text = .{ .bytes = try builder.text.toOwnedSlice(a) },
        .references = .{ .items = try builder.references.toOwnedSlice(a) },
        .next_ordinal = try std.math.add(u64, ordinal, 1),
        .expected_revision = if (head) |value| value.specification.revision else null,
        .offers = .{ .items = if (head) |value| try offers(a, value) else &.{} },
    };
}

fn appendHead(builder: *Builder, record: idx.Record, target: t.Id, head: t.Head) !void {
    try builder.append(record, .{
        .kind = "obligation_state",
        .authority = "state_not_instruction",
        .obligation = std.fmt.bytesToHex(target, .lower),
        .specification = head.specification,
        .mode = @tagName(head.mode),
        .observed = head.observed,
        .told = head.told,
        .last_observation = head.last_observation,
        .pending_question = head.question,
        .accounting = head.accounting,
    });
}

fn appendTurn(builder: *Builder, record: idx.Record) !void {
    const result = if (record.result) |value| if (value == .turn) value.turn else null else null;
    try builder.append(record, .{
        .kind = "prior_turn",
        .operator_text = record.input.turn.text.bytes,
        .operator_authority = "authenticated_instruction",
        .reply = if (result) |value| value.reply.bytes else "",
        .reply_authority = "assistant_output_unverified",
        .proposals = if (result) |value| value.proposals.items else &.{},
        .ordinal = record.input.turn.ordinal,
    });
}

fn appendEvidence(builder: *Builder, index: *const idx.Index, options: Options) !void {
    var remaining = options.recent_commits;
    for (index.obligations) |obligation| {
        const mode = index.head(&obligation).mode;
        if (mode == .cancelled or mode == .transferred) continue;
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
        .{ .directive = .{ .revert = .{ .expected_revision = head.specification.revision } } },
    });
}

fn importedTurns(index: *const idx.Index) []const continuity.Turn {
    const view = index.continuity_import orelse return &.{};
    const bundle = view.bundle orelse return &.{};
    for (bundle.members.items) |item| {
        if (item == .conversation) return item.conversation.tail.items;
    }
    return &.{};
}

fn appendImportedTurns(
    builder: *Builder,
    index: *const idx.Index,
    remaining: usize,
) !void {
    const turns = importedTurns(index);
    const shown = @min(turns.len, remaining);
    builder.omitted = try std.math.add(u64, builder.omitted, turns.len - shown);
    if (shown == 0) return;
    const record = index.records[index.continuity_import.?.position];
    for (0..shown) |offset| {
        const turn = turns[turns.len - 1 - offset];
        try builder.append(record, .{
            .kind = "imported_prior_turn",
            .authority = "historical_context_not_current_instruction",
            .source_namespace = std.fmt.bytesToHex(turn.namespace, .lower),
            .source_ordinal = turn.input.ordinal,
            .known_accounting = turn.accounting,
            .operator_text = turn.input.text.bytes,
            .frozen_context = turn.input.context.bytes,
            .reply = turn.result.?.reply.bytes,
            .reply_authority = "assistant_output_unverified",
            .proposals = turn.result.?.proposals.items,
        });
    }
}
