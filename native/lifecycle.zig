const std = @import("std");
const t = @import("application_types");

pub fn Table(comptime State: type, comptime Event: type) type {
    return struct {
        pub const Transition = struct { from: State, on: Event, to: State };
        resting: []const State,
        ordinary: []const Event,
        transitions: []const Transition,

        pub fn next(comptime self: @This(), state: State, event: Event) ?State {
            inline for (self.transitions) |item| {
                if (item.from == state and item.on == event) return item.to;
            }
            return null;
        }

        pub fn rests(comptime self: @This(), state: State) bool {
            inline for (self.resting) |item| if (item == state) return true;
            return false;
        }

        fn ordinaryEvent(comptime self: @This(), event: Event) bool {
            for (self.ordinary) |item| if (item == event) return true;
            return false;
        }

        pub fn verify(comptime self: @This()) void {
            @setEvalBranchQuota(100_000);
            const states = std.enums.values(State);
            var reaches: [states.len]bool = undefined;
            for (states, &reaches) |state, *reach| reach.* = self.rests(state);
            for (0..states.len) |_| {
                for (self.transitions) |item| {
                    if (!self.ordinaryEvent(item.on)) continue;
                    if (reaches[@backingInt(item.to)]) reaches[@backingInt(item.from)] = true;
                }
            }
            for (states, reaches) |state, reach| if (!reach)
                @compileError("lifecycle state " ++ @tagName(state) ++ " cannot reach rest");
            for (self.transitions, 0..) |item, position| {
                for (self.transitions[position + 1 ..]) |other| {
                    if (other.from == item.from and other.on == item.on)
                        @compileError("lifecycle transition " ++ @tagName(item.from) ++
                            " on " ++ @tagName(item.on) ++ " is ambiguous");
                }
            }
        }
    };
}

pub const Control = enum { pause, @"resume", cancel, transfer };

pub const mode: Table(t.Mode, Control) = .{
    .resting = &.{ .active, .paused, .cancelled, .transferred },
    .ordinary = &.{ .pause, .@"resume", .cancel, .transfer },
    .transitions = &.{
        .{ .from = .active, .on = .pause, .to = .paused },
        .{ .from = .active, .on = .@"resume", .to = .active },
        .{ .from = .active, .on = .cancel, .to = .cancelled },
        .{ .from = .active, .on = .transfer, .to = .transferred },
        .{ .from = .paused, .on = .pause, .to = .paused },
        .{ .from = .paused, .on = .@"resume", .to = .active },
        .{ .from = .paused, .on = .cancel, .to = .cancelled },
        .{ .from = .paused, .on = .transfer, .to = .transferred },
    },
};

pub fn final(state: t.Mode) bool {
    inline for (comptime std.enums.values(Control)) |event| {
        if (mode.next(state, event) != null) return false;
    }
    return true;
}

pub fn control(body: t.DirectiveBody) ?Control {
    return switch (body) {
        .pause => .pause,
        .@"resume" => .@"resume",
        .cancel => .cancel,
        .transfer => .transfer,
        else => null,
    };
}

pub fn fold(state: t.Mode, body: t.DirectiveBody) t.Mode {
    const event = control(body) orelse return state;
    return mode.next(state, event) orelse state;
}

pub const Controls = enum { settled, pending, faulted };
pub const ControlEvent = enum { admit, fold, fault, retry_due };
pub const controls: Table(Controls, ControlEvent) = .{
    .resting = &.{.settled},
    .ordinary = &.{ .admit, .fold, .fault, .retry_due },
    .transitions = &.{
        .{ .from = .settled, .on = .admit, .to = .pending },
        .{ .from = .pending, .on = .admit, .to = .pending },
        .{ .from = .pending, .on = .fold, .to = .settled },
        .{ .from = .pending, .on = .fault, .to = .faulted },
        .{ .from = .faulted, .on = .admit, .to = .faulted },
        .{ .from = .faulted, .on = .retry_due, .to = .pending },
    },
};

pub const Export = enum { idle, finalizing, cut_pending, written };
pub const ExportEvent = enum { request, finalize, cut, restart };
pub const transfer_export: Table(Export, ExportEvent) = .{
    .resting = &.{ .idle, .written },
    .ordinary = &.{ .request, .finalize, .cut },
    .transitions = &.{
        .{ .from = .idle, .on = .request, .to = .finalizing },
        .{ .from = .finalizing, .on = .request, .to = .finalizing },
        .{ .from = .finalizing, .on = .finalize, .to = .cut_pending },
        .{ .from = .finalizing, .on = .restart, .to = .finalizing },
        .{ .from = .cut_pending, .on = .request, .to = .written },
        .{ .from = .cut_pending, .on = .cut, .to = .written },
        .{ .from = .cut_pending, .on = .restart, .to = .cut_pending },
        .{ .from = .written, .on = .request, .to = .written },
    },
};

pub const Import = enum {
    absent,
    manifest_pending,
    values_pending,
    genesis_pending,
    materialized,
};
pub const ImportEvent = enum { request, value, genesis, restart };
pub const continuity_import: Table(Import, ImportEvent) = .{
    .resting = &.{ .absent, .materialized },
    .ordinary = &.{ .request, .value, .genesis },
    .transitions = &.{
        .{ .from = .absent, .on = .request, .to = .manifest_pending },
        .{ .from = .manifest_pending, .on = .request, .to = .values_pending },
        .{ .from = .values_pending, .on = .value, .to = .genesis_pending },
        .{ .from = .values_pending, .on = .request, .to = .values_pending },
        .{ .from = .values_pending, .on = .restart, .to = .values_pending },
        .{ .from = .genesis_pending, .on = .genesis, .to = .materialized },
        .{ .from = .genesis_pending, .on = .request, .to = .genesis_pending },
        .{ .from = .genesis_pending, .on = .restart, .to = .genesis_pending },
        .{ .from = .materialized, .on = .request, .to = .materialized },
    },
};

pub const Turn = enum { admitted, retrying, failing, replied };
pub const TurnEvent = enum { reply, model_failure, incompatible, author_failure };
pub const turn: Table(Turn, TurnEvent) = .{
    .resting = &.{.replied},
    .ordinary = &.{ .reply, .model_failure, .incompatible, .author_failure },
    .transitions = &.{
        .{ .from = .admitted, .on = .reply, .to = .replied },
        .{ .from = .admitted, .on = .model_failure, .to = .retrying },
        .{ .from = .admitted, .on = .incompatible, .to = .admitted },
        .{ .from = .retrying, .on = .reply, .to = .replied },
        .{ .from = .retrying, .on = .model_failure, .to = .failing },
        .{ .from = .retrying, .on = .incompatible, .to = .retrying },
        .{ .from = .failing, .on = .author_failure, .to = .replied },
        .{ .from = .failing, .on = .incompatible, .to = .failing },
    },
};

pub const Question = enum { none, pending, answered, closed };
pub const QuestionEvent = enum { raise, answer, amend, move_repository, cancel };
pub const question: Table(Question, QuestionEvent) = .{
    .resting = &.{ .none, .answered, .closed },
    .ordinary = &.{ .raise, .answer, .amend, .move_repository, .cancel },
    .transitions = &.{
        .{ .from = .none, .on = .raise, .to = .pending },
        .{ .from = .pending, .on = .answer, .to = .answered },
        .{ .from = .pending, .on = .amend, .to = .pending },
        .{ .from = .pending, .on = .move_repository, .to = .closed },
        .{ .from = .pending, .on = .cancel, .to = .closed },
        .{ .from = .answered, .on = .raise, .to = .pending },
        .{ .from = .closed, .on = .raise, .to = .pending },
    },
};

pub const Fault = enum { clear, faulted };
pub const FaultEvent = enum { failure, success, retry_due, restart };
pub const fault: Table(Fault, FaultEvent) = .{
    .resting = &.{.clear},
    .ordinary = &.{ .failure, .success, .retry_due },
    .transitions = &.{
        .{ .from = .clear, .on = .failure, .to = .faulted },
        .{ .from = .clear, .on = .success, .to = .clear },
        .{ .from = .faulted, .on = .failure, .to = .faulted },
        .{ .from = .faulted, .on = .success, .to = .clear },
        .{ .from = .faulted, .on = .restart, .to = .clear },
    },
};

comptime {
    mode.verify();
    controls.verify();
    transfer_export.verify();
    continuity_import.verify();
    turn.verify();
    question.verify();
    fault.verify();
}
