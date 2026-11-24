const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const genesis = @import("../app/genesis.zig");
const t = @import("application_types");
const fixtures = @import("contracts.zig");

const Types = struct {
    pub const application_id = "paredros.genesis.witness";
    pub const application_version = "1.0.0";
    pub const Input = t.Genesis;
    pub const Output = t.Head;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.genesis.v1";
    pub const output_schema_id = "paredros.head.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.genesis.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try genesis.emit(c), try c.schema(t.Failure));
    }
};

const Fixture = @import("native_fixture.zig").Fixture(Types, Application);

pub fn expectedFresh(input: t.Genesis) t.Head {
    return .{
        .version = 1,
        .obligation = .{ .self = {} },
        .lineage = input.lineage,
        .sequence = 0,
        .predecessor = null,
        .attempt = 0,
        .superseded = null,
        .folded_directive_ordinal = 0,
        .last_directive = null,
        .consumed = .{ .items = &.{} },
        .specification = input.specification,
        .mode = .active,
        .desired_mode = .active,
        .observed = .{ .sequence = 0, .epoch = 0, .tip = null },
        .told = .{ .sequence = 0, .epoch = 0, .tip = null },
        .last_observation = null,
        .message = activation,
        .question = null,
        .method = .{ .ordinary = {} },
        .next_due_ms = input.clock_ms,
        .clock_ms = input.clock_ms,
        .skipped_slots = 0,
        .phase = .fold,
        .previous_check_overran = false,
        .check_failure_streak = 0,
        .render_failure_streak = 0,
        .source_not_before_ms = input.clock_ms,
        .render_not_before_ms = input.clock_ms,
        .accounting = .{},
    };
}

pub const activation: t.Notification = .{
    .specification_revision = 0,
    .text = .{ .bytes = "PAREDROS is active. First source observation is pending." },
    .purpose = .{ .activation = {} },
};

test "native genesis retains exact fresh head and rejects invalid inputs across restart" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const input = fixtures.genesis();
    const task = try fixture.execute("fresh", input);
    try std.testing.expectEqualDeep(expectedFresh(input), try fixture.output(task));
    var invalid = input;
    invalid.envelope.version = 2;
    try fixture.rejected("bad-version", invalid, "unsupported_input_version");
    invalid = input;
    invalid.specification.interval_ms = 0;
    try fixture.rejected("bad-interval", invalid, "invalid_interval");
    invalid = input;
    invalid.specification.revision = 1;
    try fixture.rejected("bad-revision", invalid, "invalid_initial_revision");
    try fixture.close();
    try fixture.open();
    try std.testing.expectEqualDeep(expectedFresh(input), try fixture.output(task));
    try std.testing.expectEqual(.idle, try fixture.service.?.pump(fixture.arena.allocator()));
}

pub const question: t.Question = .{
    .identity = @splat(11),
    .condition = @splat(11),
    .specification_revision = 4,
    .source_condition = .{
        .epoch = 3,
        .base = @splat('a'),
        .tip = @splat('c'),
        .coverage = .diverged,
    },
    .choices = .{ .items = &.{.{
        .value = .{ .bytes = "accept_gap" },
        .label = .{ .bytes = "Accept explicit gap" },
    }} },
    .prompt = .{ .bytes = "Accept the gap?" },
};

fn importedInput(desired: @FieldType(t.Head, "desired_mode"), asked: bool) t.Genesis {
    var input = fixtures.genesis();
    var previous = expectedFresh(input);
    previous.obligation = .{ .task = @splat(7) };
    previous.sequence = 12;
    previous.attempt = 2;
    previous.specification.revision = 4;
    previous.observed = .{ .sequence = 9, .epoch = 3, .tip = @splat('a') };
    previous.told = .{ .sequence = 5, .epoch = 3, .tip = @splat('b') };
    previous.method = .{ .retained = .{
        .source = .{ .task = @splat(1), .digest = @splat(2) },
        .source_digest = @splat(3),
        .contract_digest = @splat(4),
        .report = .{ .task = @splat(5), .digest = @splat(6) },
        .applicability = @splat(7),
        .state = .{ .bytes = "retained-method-state" },
        .consecutive_faults = 1,
    } };
    previous.desired_mode = desired;
    previous.mode = if (desired == .cancelled) .cancelled else .transferred;
    previous.message = null;
    previous.question = if (asked) question else null;
    previous.accounting = .{ .known_calls = 7, .possible_charged_calls = 2 };
    input.clock_ms = 900;
    input.imported = .{
        .source = .{ .task = @splat(8), .digest = @splat(9) },
        .head = previous,
    };
    return input;
}

test "native genesis import resumes the prior mode and emits a pending prompt again" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const Desired = @FieldType(t.Head, "desired_mode");
    const cases = [_]struct { desired: Desired, mode: t.Mode, asked: bool, name: []const u8 }{
        .{ .desired = .active, .mode = .active, .asked = false, .name = "active-import" },
        .{ .desired = .paused, .mode = .paused, .asked = true, .name = "paused-import" },
        .{ .desired = .cancelled, .mode = .cancelled, .asked = false, .name = "cancelled-import" },
    };
    for (cases) |case| {
        const input = importedInput(case.desired, case.asked);
        const task = try fixture.execute(case.name, input);
        const result = try fixture.output(task);
        var expected = input.imported.?.head;
        expected.obligation = .{ .self = {} };
        expected.sequence = 0;
        expected.predecessor = input.imported.?.source;
        expected.attempt = 0;
        expected.superseded = null;
        expected.consumed = .{ .items = &.{} };
        expected.mode = case.mode;
        expected.clock_ms = input.clock_ms;
        expected.next_due_ms = input.clock_ms;
        expected.message = if (case.asked) .{
            .specification_revision = question.specification_revision,
            .text = question.prompt,
            .comparison = .{
                .repository = expected.specification.repository,
                .base = question.source_condition.?.base,
                .tip = question.source_condition.?.tip,
            },
            .purpose = .{ .question = .{
                .identity = question.identity,
                .choices = question.choices,
            } },
        } else null;
        try std.testing.expectEqualDeep(expected, result);
    }
}
