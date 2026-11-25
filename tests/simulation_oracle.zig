const std = @import("std");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const schedule = @import("../app/schedule.zig");
const lifecycle = @import("../native/lifecycle.zig");

pub const Violation = struct { invariant: []const u8, detail: []const u8 };

pub const Check = struct {
    a: std.mem.Allocator,
    index: *const idx.Index,
    violation: *?Violation,

    pub fn fail(
        self: Check,
        comptime invariant: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) error{ Violation, OutOfMemory } {
        self.violation.* = .{
            .invariant = invariant,
            .detail = try std.fmt.allocPrint(self.a, format, args),
        };
        return error.Violation;
    }
};

pub fn head(record: idx.Record) ?t.Head {
    return switch (record.result orelse return null) {
        .genesis => |value| value,
        .step => |value| value.head,
        else => null,
    };
}

pub fn hex(id: t.Id) [32]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

fn directiveOf(index: *const idx.Index, task: t.Id) ?t.Directive {
    const record = index.record(task) orelse return null;
    return if (record.input == .directive) record.input.directive else null;
}

pub fn chains(check: Check) !void {
    for (check.index.obligations) |*obligation| {
        try directiveChain(check, obligation);
        var disposed: std.AutoHashMapUnmanaged(t.Id, void) = .empty;
        const first = check.index.records[obligation.chain[0]];
        try genesisHead(check, obligation, first);
        for (obligation.chain[1..], 0..) |position, previous| {
            const before = check.index.records[obligation.chain[previous]];
            const record = check.index.records[position];
            try transition(check, obligation, before, record, &disposed);
        }
    }
}

fn genesisHead(check: Check, obligation: *const idx.Obligation, record: idx.Record) !void {
    const value = head(record) orelse return check.fail("I2", "genesis without head", .{});
    const imported = record.input == .genesis and record.input.genesis.imported != null;
    const message = value.message;
    if (!imported) {
        if (message == null or message.?.purpose != .activation)
            return check.fail("A07", "genesis {s} carries no activation", .{
                hex(obligation.task),
            });
        return;
    }
    if (value.question) |question| {
        const prompt = message orelse
            return check.fail("L6", "import genesis omits the pending prompt", .{});
        if (prompt.purpose != .question or
            !std.meta.eql(prompt.purpose.question.identity, question.identity))
            return check.fail("L6", "import genesis prompt names another question", .{});
    }
}

fn directiveChain(check: Check, obligation: *const idx.Obligation) !void {
    const genesis = head(check.index.records[obligation.chain[0]]).?;
    var ordinal = genesis.folded_directive_ordinal;
    var predecessor = genesis.last_directive;
    var final: ?u64 = null;
    for (obligation.directives) |position| {
        const record = check.index.records[position];
        const directive = record.input.directive;
        if (final) |blocking|
            return check.fail("F-E", "directive {d} admitted behind final directive {d} on {s}", .{
                directive.ordinal, blocking, hex(obligation.task),
            });
        if (directive.body == .cancel or directive.body == .transfer) final = directive.ordinal;
        if (directive.ordinal != ordinal + 1)
            return check.fail("I2", "directive ordinal {d} follows {d} on {s}", .{
                directive.ordinal, ordinal, hex(obligation.task),
            });
        if (!std.meta.eql(directive.predecessor, predecessor))
            return check.fail("I2", "directive {d} names the wrong predecessor", .{
                directive.ordinal,
            });
        ordinal = directive.ordinal;
        predecessor = .{ .task = record.task, .digest = record.input_digest };
    }
}

fn transition(
    check: Check,
    obligation: *const idx.Obligation,
    before: idx.Record,
    record: idx.Record,
    disposed: *std.AutoHashMapUnmanaged(t.Id, void),
) !void {
    const previous = head(before).?;
    const next = head(record) orelse return check.fail("I2", "chain member has no head", .{});
    const reference: t.Reference = .{ .task = before.task, .digest = before.result_digest.? };
    if (next.sequence != previous.sequence + 1 or
        !std.meta.eql(next.predecessor, @as(?t.Reference, reference)))
        return check.fail("I2", "head {d} does not extend {d} on {s}", .{
            next.sequence, previous.sequence, hex(obligation.task),
        });
    if (previous.mode == .cancelled or previous.mode == .transferred)
        return check.fail("F1", "head {d} extends a final head", .{next.sequence});
    const dispositions = record.result.?.step.dispositions.items;
    try folded(check, previous, next, dispositions, disposed);
    try frontier(check, previous, next);
    try modeLaw(check, record.input.step, next);
    try modeTable(check, previous, next, dispositions);
    try accounting(check, previous, next);
    try revision(check, previous, next, dispositions);
    try answered(check, previous, dispositions);
    try skipped(check, previous, next);
    try rebased(check, record.input.step, previous, next, dispositions);
}

fn folded(
    check: Check,
    previous: t.Head,
    next: t.Head,
    dispositions: []const t.DirectiveDisposition,
    disposed: *std.AutoHashMapUnmanaged(t.Id, void),
) !void {
    var ordinal = previous.folded_directive_ordinal;
    for (dispositions) |disposition| {
        if (disposition.ordinal != ordinal + 1)
            return check.fail("I2", "disposition ordinal {d} after {d} in head {d}", .{
                disposition.ordinal, ordinal, next.sequence,
            });
        const directive = directiveOf(check.index, disposition.directive.task) orelse
            return check.fail("I1", "disposition names no directive", .{});
        if (directive.ordinal != disposition.ordinal)
            return check.fail("I1", "disposition ordinal differs from its directive", .{});
        const entry = try disposed.getOrPut(check.a, disposition.directive.task);
        if (entry.found_existing)
            return check.fail("I1", "directive {d} disposed twice", .{disposition.ordinal});
        ordinal = disposition.ordinal;
    }
    if (next.folded_directive_ordinal != ordinal)
        return check.fail("I2", "head {d} folds to {d} but disposes through {d}", .{
            next.sequence, next.folded_directive_ordinal, ordinal,
        });
}

fn frontier(check: Check, previous: t.Head, next: t.Head) !void {
    if (next.told.sequence > next.observed.sequence)
        return check.fail("I3", "told {d} exceeds observed {d} in head {d}", .{
            next.told.sequence, next.observed.sequence, next.sequence,
        });
    if (next.observed.sequence < previous.observed.sequence or
        next.told.sequence < previous.told.sequence)
        return check.fail("I3", "frontier regressed in head {d}", .{next.sequence});
    const digest = if (next.message) |message|
        if (message.purpose == .digest) message.purpose.digest else null
    else
        null;
    if (digest) |covered| {
        if (covered.prior.sequence != previous.told.sequence or
            covered.through.sequence != next.told.sequence)
            return check.fail("L1", "digest in head {d} covers {d}..{d}, told {d}->{d}", .{
                next.sequence,          covered.prior.sequence, covered.through.sequence,
                previous.told.sequence, next.told.sequence,
            });
    } else if (next.told.sequence != previous.told.sequence) {
        return check.fail("L1", "told advanced without a digest in head {d}", .{next.sequence});
    }
    const raised = if (next.question) |question|
        previous.question == null or
            !std.meta.eql(previous.question.?.identity, question.identity)
    else
        false;
    if (raised) {
        const message = next.message orelse
            return check.fail("A43", "raising head {d} carries no prompt", .{next.sequence});
        if (message.purpose != .question or !std.meta.eql(
            message.purpose.question.identity,
            next.question.?.identity,
        )) return check.fail("A43", "raising head {d} prompt mismatch", .{next.sequence});
    }
}

fn modeLaw(check: Check, step: t.Step, next: t.Head) !void {
    if (next.mode == .active) return;
    if (!step.fold_only)
        return check.fail("L4", "{s} head {d} came from a step that may perform {s}", .{
            @tagName(next.mode), next.sequence, @tagName(next.phase),
        });
    if (next.message) |message| if (message.purpose == .digest)
        return check.fail("L4", "{s} head {d} published a digest", .{
            @tagName(next.mode), next.sequence,
        });
}

fn modeTable(
    check: Check,
    previous: t.Head,
    next: t.Head,
    dispositions: []const t.DirectiveDisposition,
) !void {
    var state = previous.mode;
    for (dispositions) |disposition| {
        if (disposition.outcome != .applied) continue;
        state = lifecycle.fold(state, directiveOf(check.index, disposition.directive.task).?.body);
    }
    if (state != next.mode)
        return check.fail("M1", "head {d} mode {s}, lifecycle table gives {s}", .{
            next.sequence, @tagName(next.mode), @tagName(state),
        });
}

fn accounting(check: Check, previous: t.Head, next: t.Head) !void {
    inline for (@typeInfo(t.Accounting).@"struct".field_names) |name| {
        if (@field(next.accounting, name) < @field(previous.accounting, name))
            return check.fail("A5.2-6", "accounting {s} decreased in head {d}", .{
                name, next.sequence,
            });
    }
}

fn revision(
    check: Check,
    previous: t.Head,
    next: t.Head,
    dispositions: []const t.DirectiveDisposition,
) !void {
    var applied: u64 = 0;
    for (dispositions) |disposition| {
        if (disposition.outcome != .applied) continue;
        const body = directiveOf(check.index, disposition.directive.task).?.body;
        if (body == .amend or body == .adopt or body == .revert) applied += 1;
    }
    if (next.specification.revision != previous.specification.revision + applied)
        return check.fail("R6.3", "revision {d}->{d} with {d} applied revisions", .{
            previous.specification.revision, next.specification.revision, applied,
        });
}

fn answered(check: Check, previous: t.Head, dispositions: []const t.DirectiveDisposition) !void {
    const question = previous.question orelse return;
    for (dispositions) |disposition| {
        const body = directiveOf(check.index, disposition.directive.task).?.body;
        switch (body) {
            .answer => |answer| {
                if (!std.meta.eql(answer.question, question.identity)) return;
                for (question.choices.items) |choice| {
                    if (!std.mem.eql(u8, choice.value.bytes, answer.choice.bytes)) continue;
                    if (disposition.outcome != .applied)
                        return check.fail("F-answer", "open question answer {s} rejected: {s}", .{
                            answer.choice.bytes, rejection(disposition),
                        });
                }
                return;
            },
            .amend, .cancel, .transfer, .adopt, .revert => return,
            else => {},
        }
    }
}

fn rejection(disposition: t.DirectiveDisposition) []const u8 {
    return switch (disposition.outcome) {
        .rejected => |reason| reason.bytes,
        else => @tagName(disposition.outcome),
    };
}

pub fn slotsBetween(anchor_ms: i64, interval_ms: u64, after_ms: i64, through_ms: i64) u64 {
    if (through_ms <= after_ms or through_ms < anchor_ms) return 0;
    const interval: i128 = interval_ms;
    const last = @divFloor(@as(i128, through_ms) - anchor_ms, interval);
    const first = if (after_ms < anchor_ms)
        0
    else
        @divFloor(@as(i128, after_ms) - anchor_ms, interval) + 1;
    return @intCast(@max(0, last - first + 1));
}

fn regressed(previous: t.Head, next: t.Head) bool {
    return next.clock_regressions > previous.clock_regressions;
}

fn skipped(check: Check, previous: t.Head, next: t.Head) !void {
    const clock = next.clock_ms;
    const owed = if (regressed(previous, next))
        schedule.rebased(previous.schedule.next_due_ms, previous.clock_ms, clock) catch
            return check.fail("I6", "rebase overflow", .{})
    else
        previous.schedule.next_due_ms;
    const counted = next.skipped_slots -% previous.skipped_slots;
    if (next.skipped_slots < previous.skipped_slots)
        return check.fail("I5", "skipped slots decreased in head {d}", .{next.sequence});
    if (next.schedule.next_due_ms == owed) {
        if (counted != 0)
            return check.fail("I5", "head {d} counted {d} slots without moving due", .{
                next.sequence, counted,
            });
        return;
    }
    const spec = previous.specification;
    const expected = slotsBetween(spec.anchor_ms, spec.interval_ms, owed, clock);
    if (counted != expected)
        return check.fail("I5", "head {d} counted {d} slots, reference {d} " ++
            "(due {d}->{d}, clock {d}, anchor {d}, interval {d})", .{
            next.sequence,  counted,                   expected,
            owed,           next.schedule.next_due_ms, clock,
            spec.anchor_ms, spec.interval_ms,
        });
    const after = schedule.firstAfter(
        next.specification.anchor_ms,
        next.specification.interval_ms,
        clock,
    ) catch return check.fail("I5", "slot overflow", .{});
    const amended = next.specification.interval_ms != spec.interval_ms;
    const stays_due = amended and owed <= clock and next.schedule.next_due_ms == clock;
    if (next.schedule.next_due_ms != after and !stays_due)
        return check.fail("I5", "head {d} moved due to {d}, first slot after {d} is {d}", .{
            next.sequence, next.schedule.next_due_ms, clock, after,
        });
}

fn rebased(
    check: Check,
    step: t.Step,
    previous: t.Head,
    next: t.Head,
    dispositions: []const t.DirectiveDisposition,
) !void {
    if (!regressed(previous, next) or !step.fold_only or step.supersession != null) return;
    if (dispositions.len != 0) return;
    inline for (@typeInfo(t.Schedule).@"struct".field_names) |name| {
        const expected = schedule.rebased(
            @field(previous.schedule, name),
            previous.clock_ms,
            next.clock_ms,
        ) catch return check.fail("I6", "rebase overflow", .{});
        if (@field(next.schedule, name) != expected)
            return check.fail("I6", "head {d} {s} {d}, remaining duration gives {d}", .{
                next.sequence, name, @field(next.schedule, name), expected,
            });
    }
}

pub fn disposedAll(check: Check, obligation: *const idx.Obligation) !void {
    const current = check.index.head(obligation);
    if (obligation.directives.len == 0) return;
    const last = check.index.records[obligation.directives[obligation.directives.len - 1]];
    if (current.folded_directive_ordinal != last.input.directive.ordinal)
        return check.fail("I1", "{s} folded {d} of {d} admitted directives at rest", .{
            hex(obligation.task), current.folded_directive_ordinal, last.input.directive.ordinal,
        });
}

pub fn resting(check: Check, obligation: *const idx.Obligation, now_ms: i64) !void {
    const current = check.index.head(obligation);
    try disposedAll(check, obligation);
    if (obligation.eligible != null)
        return check.fail("I9", "{s} keeps a live step at rest", .{hex(obligation.task)});
    if (obligation.controls_pending)
        return check.fail("I9", "{s} keeps imported controls pending", .{hex(obligation.task)});
    if (current.mode != .active) return;
    if (current.check_requested)
        return check.fail("I9", "{s} keeps a requested check at rest", .{hex(obligation.task)});
    if (current.schedule.next_due_ms <= now_ms)
        return check.fail("I9", "{s} active with due {d} not after {d}", .{
            hex(obligation.task), current.schedule.next_due_ms, now_ms,
        });
    if (current.question == null and current.told.sequence != current.observed.sequence)
        return check.fail("I9", "{s} owes observations {d}..{d} without a question", .{
            hex(obligation.task), current.told.sequence, current.observed.sequence,
        });
}

pub fn turns(check: Check) !void {
    var replaced: std.AutoHashMapUnmanaged(t.Id, void) = .empty;
    for (check.index.records) |record| {
        if (record.input != .turn) continue;
        const replacement = record.input.turn.replacement orelse continue;
        try replaced.put(check.a, replacement.input.task, {});
    }
    for (check.index.records) |record| {
        if (record.input != .turn or replaced.contains(record.task)) continue;
        const result = record.result orelse
            return check.fail("L7", "turn lineage {s} ends without a reply", .{hex(record.task)});
        if (result != .turn)
            return check.fail("L7", "turn {s} ends with a non-reply", .{hex(record.task)});
    }
}
