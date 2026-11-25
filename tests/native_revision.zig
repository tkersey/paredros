const std = @import("std");
const revision = @import("../app/revision.zig");
const t = @import("application_types");
const contracts = @import("contracts.zig");
const genesis = @import("native_genesis.zig");

const Types = struct {
    pub const application_id = "paredros.revision.witness";
    pub const application_version = "1.0.0";
    pub const Input = revision.Input;
    pub const Output = revision.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.revision.input.v1";
    pub const output_schema_id = "paredros.revision.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.revision.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Fixture = @import("native_fixture.zig").Fixture(Types, @import("revision.zig").Application);

fn method() t.Method {
    return .{ .retained = .{
        .source = .{ .task = @splat(1), .digest = @splat(2) },
        .source_digest = @splat(3),
        .contract_digest = @splat(4),
        .report = .{ .task = @splat(5), .digest = @splat(6) },
        .applicability = @splat(7),
        .state = .{ .bytes = "retained method state" },
        .consecutive_faults = 2,
    } };
}

fn message() t.Notification {
    return .{
        .specification_revision = 6,
        .text = .{ .bytes = "rendered digest" },
        .purpose = .{ .digest = .{
            .prior = .{ .sequence = 3, .epoch = 2, .tip = @splat('c') },
            .through = .{ .sequence = 10, .epoch = 2, .tip = @splat('b') },
        } },
    };
}

fn head() t.Head {
    var result = genesis.expectedFresh(contracts.genesis());
    result.obligation = .{ .task = @splat(8) };
    result.sequence = 28;
    result.predecessor = .{ .task = @splat(9), .digest = @splat(10) };
    result.attempt = 3;
    result.superseded = .{ .task = @splat(11), .digest = @splat(12) };
    result.folded_directive_ordinal = 20;
    result.last_directive = .{ .task = @splat(13), .digest = @splat(14) };
    result.consumed = .{ .items = &.{.{
        .task = @splat(15),
        .revision = 2,
        .digest = @splat(16),
    }} };
    result.specification.revision = 6;
    result.observed = .{ .sequence = 17, .epoch = 2, .tip = @splat('a') };
    result.told = .{ .sequence = 10, .epoch = 2, .tip = @splat('b') };
    result.last_observation = .{
        .sequence = 17,
        .epoch = 2,
        .tip = @splat('a'),
        .batch = .{ .retained = .{ .task = @splat(20), .digest = @splat(21) } },
        .coverage = .complete,
        .acquired_ms = 900,
        .provider_date = .{ .bytes = "provider-time" },
        .commit_count = 7,
    };
    result.message = message();
    result.question = .{
        .identity = @splat(22),
        .condition = @splat(23),
        .specification_revision = 6,
        .choices = .{ .items = &.{.{
            .value = .{ .bytes = "accept" },
            .label = .{ .bytes = "Accept" },
        }} },
        .prompt = .{ .bytes = "pending question" },
    };
    result.method = method();
    result.schedule.next_due_ms = 1300;
    result.clock_ms = 950;
    result.skipped_slots = 4;
    result.phase = .render;
    result.previous_check_overran = true;
    result.check_failure_streak = 2;
    result.render_failure_streak = 3;
    result.schedule.source_not_before_ms = 1400;
    result.schedule.render_not_before_ms = 1500;
    result.accounting = .{
        .known_calls = 8,
        .known_input_tokens = 1200,
        .known_output_tokens = 230,
        .retained_bytes = 5400,
        .failed_attempts = 2,
        .possible_charged_calls = 3,
    };
    return result;
}

fn amendment() t.Amendment {
    return .{
        .expected_revision = 6,
        .interval_ms = null,
        .wording = null,
        .policies = null,
        .repository_route = null,
    };
}

fn applied(
    fixture: *Fixture,
    operation: []const u8,
    previous: t.Head,
    change: revision.Change,
    expected: t.Head,
) !void {
    const task = try fixture.execute(operation, .{ .head = previous, .change = change });
    const result = try fixture.output(task);
    try std.testing.expectEqualDeep(expected, result.head);
    try std.testing.expectEqualDeep(revision.Disposition{ .applied = {} }, result.disposition);
}

fn rejected(
    fixture: *Fixture,
    operation: []const u8,
    previous: t.Head,
    change: revision.Change,
    reason: []const u8,
) !void {
    const task = try fixture.execute(operation, .{ .head = previous, .change = change });
    const result = try fixture.output(task);
    try std.testing.expectEqualDeep(previous, result.head);
    try std.testing.expectEqualStrings(reason, result.disposition.rejected.bytes);
}

test "native revisions amend selected fields and preserve responsibility" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const previous = head();
    for (0..16) |mask| {
        var change = amendment();
        var expected = previous;
        expected.specification.revision += 1;
        if (mask & 1 != 0) {
            change.interval_ms = 1;
            expected.specification.interval_ms = 1;
            expected.schedule.next_due_ms = 951;
        }
        if (mask & 2 != 0) {
            change.wording = .{ .bytes = "" };
            expected.specification.wording = change.wording.?;
        }
        if (mask & 4 != 0) {
            change.policies = .{ .phase_attempts = 5, .context_bytes = 1024 };
            expected.specification.policies = change.policies.?;
        }
        if (mask & 8 != 0) {
            change.repository_route = .{
                .owner = .{ .bytes = "renamed-owner" },
                .name = .{ .bytes = "renamed-repo" },
            };
            expected.specification.repository.owner = change.repository_route.?.owner;
            expected.specification.repository.name = change.repository_route.?.name;
            expected.question = null;
        }
        const operation = try std.fmt.allocPrint(fixture.arena.allocator(), "options-{d}", .{mask});
        try applied(&fixture, operation, previous, .{ .amend = change }, expected);
    }
    var invalid = amendment();
    invalid.interval_ms = 0;
    try rejected(&fixture, "zero-interval", previous, .{ .amend = invalid }, "invalid_interval");
    invalid = amendment();
    invalid.expected_revision = 5;
    try rejected(&fixture, "stale-amendment", previous, .{ .amend = invalid }, "stale_revision");
}

test "native revisions reject out-of-bound amendments instead of storing them" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const previous = head();
    var invalid = amendment();
    invalid.policies = .{ .notification_interval_ms = std.math.maxInt(u64) };
    try rejected(
        &fixture,
        "notification-overflow",
        previous,
        .{ .amend = invalid },
        "invalid_policy_notification_interval_ms",
    );
    invalid.policies = .{ .phase_attempts = 49 };
    try rejected(
        &fixture,
        "phase-overflow",
        previous,
        .{ .amend = invalid },
        "invalid_policy_phase_attempts",
    );
    invalid.policies = .{ .context_bytes = 255 };
    try rejected(
        &fixture,
        "context-underflow",
        previous,
        .{ .amend = invalid },
        "invalid_policy_context_bytes",
    );
    invalid = amendment();
    invalid.interval_ms = 366 * 24 * 60 * 60 * 1000 + 1;
    try rejected(&fixture, "long-interval", previous, .{ .amend = invalid }, "invalid_interval");
}

test "native revisions recompute a pending due check from the anchor when the interval changes" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var change = amendment();
    change.interval_ms = 100;
    var expected = head();
    expected.specification.revision += 1;
    expected.specification.interval_ms = 100;
    expected.schedule.next_due_ms = 1000;
    try applied(&fixture, "shorter", head(), .{ .amend = change }, expected);
    var due = head();
    due.schedule.next_due_ms = 900;
    expected = due;
    expected.specification.revision += 1;
    expected.specification.interval_ms = 100;
    expected.schedule.next_due_ms = due.clock_ms;
    try applied(&fixture, "already-due", due, .{ .amend = change }, expected);
    change.interval_ms = null;
    change.wording = .{ .bytes = "same interval" };
    expected = head();
    expected.specification.revision += 1;
    expected.specification.wording = change.wording.?;
    try applied(&fixture, "unchanged-interval", head(), .{ .amend = change }, expected);
}

test "native revisions adoption and reversion preserve history cursors deliveries and accounting" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var previous = head();
    previous.method = .{ .ordinary = {} };
    var expected = previous;
    expected.specification.revision += 1;
    expected.method = method();
    try applied(&fixture, "adopt", previous, .{ .adopt = .{
        .expected_revision = 6,
        .method = method(),
    } }, expected);
    try rejected(&fixture, "stale-adopt", expected, .{ .adopt = .{
        .expected_revision = 6,
        .method = method(),
    } }, "stale_revision");
    try rejected(&fixture, "ordinary-adopt", previous, .{ .adopt = .{
        .expected_revision = 6,
        .method = .{ .ordinary = {} },
    } }, "ordinary_adoption");
    previous = expected;
    expected.specification.revision += 1;
    expected.method = .{ .ordinary = {} };
    try applied(&fixture, "revert", previous, .{ .revert = .{ .expected_revision = 7 } }, expected);
    try rejected(
        &fixture,
        "stale-revert",
        expected,
        .{ .revert = .{ .expected_revision = 7 } },
        "stale_revision",
    );
    previous = expected;
    expected.specification.revision += 1;
    try applied(
        &fixture,
        "ordinary-revert",
        previous,
        .{ .revert = .{ .expected_revision = 8 } },
        expected,
    );
}

test "native revisions reject overflow without partial mutation in every live mode" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var index: usize = 0;
    for ([_]t.Mode{ .active, .paused }) |old_mode| {
        for ([_]u64{ 6, std.math.maxInt(u64) }) |old_revision| {
            var previous = head();
            previous.mode = old_mode;
            previous.specification.revision = old_revision;
            var amend = amendment();
            amend.expected_revision = old_revision;
            for ([_]revision.Change{
                .{ .amend = amend },
                .{ .adopt = .{ .expected_revision = old_revision, .method = method() } },
                .{ .revert = .{ .expected_revision = old_revision } },
            }) |change| {
                const operation = try std.fmt.allocPrint(
                    fixture.arena.allocator(),
                    "edge-{d}",
                    .{index},
                );
                index += 1;
                if (old_revision == std.math.maxInt(u64)) {
                    try rejected(&fixture, operation, previous, change, "revision_overflow");
                } else {
                    var expected = previous;
                    expected.specification.revision += 1;
                    if (change == .revert) expected.method = .{ .ordinary = {} };
                    try applied(&fixture, operation, previous, change, expected);
                }
            }
        }
    }
    try std.testing.expectEqual(12, index);
}
