const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const temporal = @import("../app/temporal.zig");
const mode = @import("../app/mode.zig");
const schedule = @import("../app/schedule.zig");
const t = @import("application_types");
const contracts_fixture = @import("contracts.zig");
const genesis_fixture = @import("native_genesis.zig");

const Types = struct {
    pub const application_id = "paredros.authoring.witness";
    pub const application_version = "1.0.0";
    pub const Input = union(enum) { temporal: temporal.Input, mode: mode.Input };
    pub const Output = union(enum) { temporal: i64, mode: t.Head };
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.authoring.witness.input.v1";
    pub const output_schema_id = "paredros.authoring.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.authoring.witness.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const clock = try temporal.emit(c);
        const control = try mode.emit(c);
        const entry = try c.author.function("native authored operation witness", .{
            .input = try c.schema(Types.Input),
        }, try c.schema(Types.Output), &.{});
        const b = try c.author.body(entry);
        const input = try b.parameter("input");
        const clock_case = try b.caseOf(input, "temporal");
        const mode_case = try b.caseOf(input, "mode");
        const clock_result = try clock_case.body().call(clock, .{ .input = clock_case.payload() });
        const mode_result = try mode_case.body().call(control, .{ .input = mode_case.payload() });
        const result = try b.match(input, .{
            .temporal = try clock_case.ret(try clock_case.body().variant(
                try c.schema(Types.Output),
                "temporal",
                clock_result,
            )),
            .mode = try mode_case.ret(try mode_case.body().variant(
                try c.schema(Types.Output),
                "mode",
                mode_result,
            )),
        });
        try c.author.define(entry, try b.ret(result));
        return c.author.module(entry, try c.schema(t.Failure));
    }
};

const Fixture = @import("native_fixture.zig").Fixture(Types, Application);
const TemporalCase = struct {
    input: temporal.Input,
    expected: union(enum) { value: i64, overflow, invalid_interval },
};

const temporal_cases = [_]TemporalCase{
    .{
        .input = .{ .anchor_ms = -1900, .interval_ms = 1000, .clock_ms = -1000 },
        .expected = .{ .value = -900 },
    },
    .{
        .input = .{ .anchor_ms = -1900, .interval_ms = 1000, .clock_ms = -900 },
        .expected = .{ .value = 100 },
    },
    .{
        .input = .{ .anchor_ms = 100, .interval_ms = 1000, .clock_ms = -1000 },
        .expected = .{ .value = 100 },
    },
    .{
        .input = .{ .anchor_ms = 100, .interval_ms = 1000, .clock_ms = 100 },
        .expected = .{ .value = 1100 },
    },
    .{
        .input = .{
            .anchor_ms = std.math.minInt(i64),
            .interval_ms = 1,
            .clock_ms = std.math.minInt(i64),
        },
        .expected = .{ .value = std.math.minInt(i64) + 1 },
    },
    .{
        .input = .{ .anchor_ms = std.math.minInt(i64), .interval_ms = 1, .clock_ms = 0 },
        .expected = .{ .value = 1 },
    },
    .{
        .input = .{
            .anchor_ms = std.math.minInt(i64),
            .interval_ms = 1 << 63,
            .clock_ms = std.math.minInt(i64),
        },
        .expected = .{ .value = 0 },
    },
    .{
        .input = .{
            .anchor_ms = std.math.minInt(i64),
            .interval_ms = std.math.maxInt(u64),
            .clock_ms = std.math.minInt(i64),
        },
        .expected = .{ .value = std.math.maxInt(i64) },
    },
    .{
        .input = .{
            .anchor_ms = std.math.minInt(i64),
            .interval_ms = std.math.maxInt(u64),
            .clock_ms = std.math.maxInt(i64) - 1,
        },
        .expected = .{ .value = std.math.maxInt(i64) },
    },
    .{
        .input = .{
            .anchor_ms = std.math.minInt(i64),
            .interval_ms = std.math.maxInt(u64),
            .clock_ms = std.math.maxInt(i64),
        },
        .expected = .overflow,
    },
    .{
        .input = .{ .anchor_ms = -1, .interval_ms = 1 << 63, .clock_ms = -1 },
        .expected = .{ .value = std.math.maxInt(i64) },
    },
    .{
        .input = .{ .anchor_ms = -1, .interval_ms = 1 << 63, .clock_ms = 0 },
        .expected = .{ .value = std.math.maxInt(i64) },
    },
    .{
        .input = .{ .anchor_ms = 0, .interval_ms = std.math.maxInt(u64), .clock_ms = -1 },
        .expected = .{ .value = 0 },
    },
    .{
        .input = .{ .anchor_ms = 0, .interval_ms = std.math.maxInt(u64), .clock_ms = 0 },
        .expected = .overflow,
    },
    .{
        .input = .{
            .anchor_ms = std.math.maxInt(i64),
            .interval_ms = 1,
            .clock_ms = std.math.maxInt(i64) - 1,
        },
        .expected = .{ .value = std.math.maxInt(i64) },
    },
    .{
        .input = .{
            .anchor_ms = std.math.maxInt(i64),
            .interval_ms = 1,
            .clock_ms = std.math.maxInt(i64),
        },
        .expected = .overflow,
    },
    .{
        .input = .{ .anchor_ms = 0, .interval_ms = 1, .clock_ms = std.math.maxInt(i64) },
        .expected = .overflow,
    },
    .{
        .input = .{
            .anchor_ms = std.math.maxInt(i64),
            .interval_ms = 0,
            .clock_ms = std.math.minInt(i64),
        },
        .expected = .invalid_interval,
    },
    .{
        .input = .{
            .anchor_ms = std.math.minInt(i64),
            .interval_ms = 0,
            .clock_ms = std.math.maxInt(i64),
        },
        .expected = .invalid_interval,
    },
    .{
        .input = .{ .anchor_ms = -10, .interval_ms = 3, .clock_ms = -10 },
        .expected = .{ .value = -7 },
    },
    .{
        .input = .{ .anchor_ms = -10, .interval_ms = 3, .clock_ms = -1 },
        .expected = .{ .value = 2 },
    },
    .{
        .input = .{ .anchor_ms = -10, .interval_ms = 3, .clock_ms = -11 },
        .expected = .{ .value = -10 },
    },
};

test "native authoring temporal agrees with independent schedule oracle at exact arithmetic edges" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    for (temporal_cases, 0..) |case, index| {
        const operation = try std.fmt.allocPrint(
            fixture.arena.allocator(),
            "temporal-{d}",
            .{index},
        );
        const independent = schedule.firstAfter(
            case.input.anchor_ms,
            case.input.interval_ms,
            case.input.clock_ms,
        );
        switch (case.expected) {
            .value => |value| {
                try std.testing.expectEqual(value, try independent);
                const task = try fixture.execute(operation, .{ .temporal = case.input });
                const result = try fixture.output(task);
                try std.testing.expectEqual(value, result.temporal);
            },
            .overflow => {
                try std.testing.expectError(error.ScheduleOverflow, independent);
                try fixture.rejected(operation, .{ .temporal = case.input }, "schedule_overflow");
            },
            .invalid_interval => {
                try std.testing.expectError(error.InvalidInterval, independent);
                try fixture.rejected(operation, .{ .temporal = case.input }, "invalid_interval");
            },
        }
    }
}

fn delivery() t.DeliveryIntent {
    return .{
        .destination = contracts_fixture.specification().destination,
        .key = .{
            .lineage = @splat(2),
            .purpose = .digest,
            .identity = @splat(3),
            .generation = 7,
        },
        .payload = .{
            .obligation = @splat(4),
            .specification_revision = 6,
            .prior_sequence = 10,
            .through_sequence = 17,
            .frozen_text = .{ .bytes = "pending digest" },
            .prompt = @splat(6),
            .supersedes = null,
        },
    };
}

fn populatedObservation() t.Observation {
    return .{
        .sequence = 17,
        .epoch = 2,
        .tip = @splat('a'),
        .batch = .{ .retained = .{ .task = @splat(19), .digest = @splat(20) } },
        .coverage = .complete,
        .acquired_ms = 900,
        .provider_date = .{ .bytes = "provider-time" },
        .commit_count = 7,
    };
}

fn populatedHead() t.Head {
    var head = genesis_fixture.expectedFresh(contracts_fixture.genesis());
    head.obligation = .{ .task = @splat(7) };
    head.sequence = 27;
    head.predecessor = .{ .task = @splat(8), .digest = @splat(9) };
    head.attempt = 3;
    head.superseded = .{ .task = @splat(10), .digest = @splat(11) };
    head.folded_directive_ordinal = 19;
    head.last_directive = .{ .task = @splat(12), .digest = @splat(13) };
    head.consumed = .{ .items = &.{.{ .task = @splat(14), .revision = 4, .digest = @splat(15) }} };
    head.specification.revision = 6;
    head.observed = .{ .sequence = 17, .epoch = 2, .tip = @splat('a') };
    head.told = .{ .sequence = 10, .epoch = 2, .tip = @splat('b') };
    head.told_receipt = .{
        .key = delivery().key,
        .destination = delivery().destination,
        .timestamp = .{ .bytes = "1700000000.000001" },
        .payload_digest = @splat(16),
        .evidence = .{ .task = @splat(17), .digest = @splat(18) },
        .basis = .history_match,
    };
    head.last_observation = populatedObservation();
    head.digest = .{
        .delivery = delivery(),
        .hold = .uncertain_transmission,
        .not_before_ms = 920,
    };
    head.question = .{
        .identity = @splat(21),
        .condition = @splat(22),
        .specification_revision = 6,
        .evidence = .{ .retained = .{ .task = @splat(23), .digest = @splat(24) } },
        .choices = .{ .items = &.{.{ .bytes = "accept" }} },
        .prompt = delivery(),
    };
    head.method = .{ .retained = .{
        .source = .{ .task = @splat(25), .digest = @splat(26) },
        .source_digest = @splat(27),
        .contract_digest = @splat(28),
        .report = .{ .task = @splat(29), .digest = @splat(30) },
        .applicability = @splat(31),
        .state = .{ .bytes = "retained state" },
        .consecutive_faults = 2,
    } };
    head.next_due_ms = 1300;
    head.clock_ms = 950;
    head.skipped_slots = 4;
    head.phase = .render;
    head.previous_check_overran = true;
    head.check_failure_streak = 2;
    head.render_failure_streak = 3;
    head.source_not_before_ms = 1400;
    head.render_not_before_ms = 1500;
    head.accounting = .{
        .known_calls = 8,
        .known_input_tokens = 1200,
        .known_output_tokens = 230,
        .retained_bytes = 5400,
        .failed_attempts = 2,
        .possible_charged_calls = 3,
    };
    return head;
}

fn controlledHead(previous: t.Head, control: mode.Control) t.Head {
    if (previous.mode == .cancelled or previous.mode == .transferred) return previous;
    var head = previous;
    switch (control) {
        .pause => {
            head.mode = .paused;
            head.desired_mode = .paused;
        },
        .@"resume" => {
            head.mode = if (head.recovery_hold) .paused else .active;
            head.desired_mode = .active;
        },
        .cancel => {
            head.mode = .cancelled;
            head.desired_mode = .cancelled;
        },
        .transfer => head.mode = .transferred,
    }
    return head;
}

test "native authoring modes preserve other head fields across controls holds and final states" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var index: u32 = 0;
    for ([_]t.Mode{ .active, .paused, .cancelled, .transferred }) |old_mode| {
        for ([_]bool{ false, true }) |hold| {
            for ([_]mode.Control{ .pause, .@"resume", .cancel, .transfer }) |control| {
                var previous = populatedHead();
                previous.mode = old_mode;
                previous.desired_mode = if (old_mode == .cancelled) .cancelled else .active;
                previous.recovery_hold = hold;
                const operation = try std.fmt.allocPrint(
                    fixture.arena.allocator(),
                    "mode-{d}",
                    .{index},
                );
                index += 1;
                const task = try fixture.execute(
                    operation,
                    .{ .mode = .{ .head = previous, .control = control } },
                );
                const result = try fixture.output(task);
                try std.testing.expectEqualDeep(controlledHead(previous, control), result.mode);
            }
        }
    }
    try std.testing.expectEqual(32, index);
}
