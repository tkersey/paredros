const std = @import("std");
const settlement = @import("../app/settlement.zig");
const t = @import("application_types");
const genesis = @import("native_genesis.zig");
const contracts = @import("contracts.zig");

const Types = struct {
    pub const application_id = "paredros.settlement.witness";
    pub const application_version = "1.0.0";
    pub const Input = settlement.Input;
    pub const Output = t.Head;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.settlement.input.v1";
    pub const output_schema_id = "paredros.settlement.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.settlement.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};
const Fixture = @import("native_fixture.zig").Fixture(Types, @import("settlement.zig").Application);

fn fact(identity: u8, revision: u64, delta: t.Accounting) t.Settlement {
    return .{
        .reference = .{
            .task = @splat(identity),
            .revision = revision,
            .digest = @splat(identity),
        },
        .kind = .superseded,
        .accounting = delta,
    };
}

fn head() t.Head {
    var result = genesis.expectedFresh(contracts.genesis());
    result.specification.revision = 6;
    result.observed = .{ .sequence = 18, .epoch = 2, .tip = @splat('a') };
    result.told = .{ .sequence = 9, .epoch = 1, .tip = @splat('b') };
    result.accounting = .{
        .known_calls = 7,
        .known_input_tokens = 110,
        .known_output_tokens = 13,
        .retained_bytes = 800,
        .failed_attempts = 2,
        .possible_charged_calls = 3,
    };
    return result;
}

test "native settlements consume revisions once and retain known and possible charges" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var previous = head();
    previous.consumed = .{ .items = &.{fact(1, 3, .{}).reference} };
    const first = fact(2, 4, .{
        .known_calls = 2,
        .known_input_tokens = 11,
        .known_output_tokens = 3,
        .retained_bytes = 90,
        .failed_attempts = 1,
        .possible_charged_calls = 2,
    });
    var second = fact(2, 5, first.accounting);
    second.accounting.retained_bytes += 6;
    second.accounting.known_output_tokens += 1;
    second.previous_reference = first.reference;
    second.previous_accounting = first.accounting;
    const result = try fixture.output(try fixture.execute("accounting", .{
        .head = previous,
        .facts = .{ .items = &.{ first, second } },
    }));
    var expected = previous;
    expected.consumed = .{ .items = &.{ first.reference, second.reference } };
    expected.accounting = .{
        .known_calls = 9,
        .known_input_tokens = 121,
        .known_output_tokens = 17,
        .retained_bytes = 896,
        .failed_attempts = 3,
        .possible_charged_calls = 5,
    };
    try std.testing.expectEqualDeep(expected, result);
    expected.consumed = .{ .items = &.{} };
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("empty", .{
        .head = result,
        .facts = .{ .items = &.{} },
    })));
}

test "native settlements reject repeated identities equivocation and prior transition reuse" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const first = fact(2, 4, .{ .known_calls = 1 });
    try fixture.rejected("duplicate", .{
        .head = head(),
        .facts = .{ .items = &.{ first, first } },
    }, "duplicate_settlement");
    var conflict = first;
    conflict.reference.digest = @splat(9);
    conflict.accounting.known_calls = 8;
    try fixture.rejected("equivocation", .{
        .head = head(),
        .facts = .{ .items = &.{ first, conflict } },
    }, "duplicate_settlement");
    var previous = head();
    previous.consumed = .{ .items = &.{first.reference} };
    try fixture.rejected("previous", .{
        .head = previous,
        .facts = .{ .items = &.{first} },
    }, "previous_settlement");
}

test "native settlements check overflow in every accounting dimension" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    inline for (comptime std.meta.fieldNames(t.Accounting)) |field| {
        var previous = head();
        @field(previous.accounting, field) = std.math.maxInt(u64);
        var delta: t.Accounting = .{};
        @field(delta, field) = 1;
        try fixture.rejected(field, .{
            .head = previous,
            .facts = .{ .items = &.{fact(1, 1, delta)} },
        }, "accounting_overflow");
    }
}

test "native settlements resolve exact prior possible charges without hiding other unknowns" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var resolved = fact(2, 5, .{ .known_calls = 2, .known_input_tokens = 30 });
    resolved.previous_reference = fact(2, 4, .{}).reference;
    resolved.previous_accounting = .{ .possible_charged_calls = 2 };
    const previous = head();
    var expected = previous;
    expected.consumed = .{ .items = &.{resolved.reference} };
    expected.accounting.known_calls += 2;
    expected.accounting.known_input_tokens += 30;
    expected.accounting.possible_charged_calls = 1;
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("resolve", .{
        .head = previous,
        .facts = .{ .items = &.{resolved} },
    })));
    resolved.previous_accounting.possible_charged_calls = 4;
    try fixture.rejected("underflow", .{
        .head = previous,
        .facts = .{ .items = &.{resolved} },
    }, "unknown_charge_underflow");
}

test "native settlements require coherent previous revisions and monotone known counters" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var current = fact(2, 5, .{ .known_calls = 2 });
    current.previous_accounting = .{ .known_calls = 1 };
    try fixture.rejected("missing-previous", .{
        .head = head(),
        .facts = .{ .items = &.{current} },
    }, "invalid_previous_accounting");
    for ([_]t.RevisionReference{
        fact(3, 4, .{}).reference, fact(2, 5, .{}).reference, fact(2, 6, .{}).reference,
    }, 0..) |reference, index| {
        current.previous_reference = reference;
        const operation = try std.fmt.allocPrint(fixture.arena.allocator(), "prior-{d}", .{index});
        try fixture.rejected(operation, .{
            .head = head(),
            .facts = .{ .items = &.{current} },
        }, "invalid_previous_accounting");
    }
    inline for (.{
        "known_calls",    "known_input_tokens", "known_output_tokens",
        "retained_bytes", "failed_attempts",
    }) |field| {
        current = fact(2, 5, .{});
        current.previous_reference = fact(2, 4, .{}).reference;
        @field(current.previous_accounting, field) = 2;
        @field(current.accounting, field) = 1;
        try fixture.rejected(field, .{
            .head = head(),
            .facts = .{ .items = &.{current} },
        }, "accounting_regression");
    }
}
