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
        .delivery = null,
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

fn intent() t.DeliveryIntent {
    return .{
        .destination = contracts.specification().destination,
        .key = .{
            .lineage = @splat(2),
            .purpose = .digest,
            .identity = @splat(3),
            .generation = 1,
        },
        .payload = .{
            .obligation = @splat(4),
            .specification_revision = 6,
            .prior_sequence = 9,
            .through_sequence = 15,
            .frozen_text = .{ .bytes = "verified digest" },
            .coverage = .{ .sequence = 15, .epoch = 2, .tip = @splat('c') },
            .buttons = .{ .items = &.{button} },
            .comparison = .{
                .repository = contracts.specification().repository,
                .base = @splat('b'),
                .tip = @splat('c'),
            },
            .prompt = null,
            .supersedes = null,
        },
    };
}

const button: t.Button = .{
    .block_id = .{ .bytes = "decision" },
    .action_id = .{ .bytes = "confirm" },
    .value = .{ .bytes = "operation-a" },
    .label = .{ .bytes = "Approve" },
};
const other_button: t.Button = .{
    .block_id = button.block_id,
    .action_id = button.action_id,
    .value = .{ .bytes = "operation-b" },
    .label = button.label,
};

fn admitted() t.Delivery {
    const logical = intent();
    return .{
        .envelope = contracts.genesis().envelope,
        .destination = logical.destination,
        .key = logical.key,
        .payload = .{
            .logical = logical.payload,
            .content_digest = @splat(6),
            .marker_digest = @splat(5),
            .evidence_digest = @splat(7),
            .wire_json = .{ .bytes = "{\"text\":\"verified digest\"}" },
        },
    };
}

fn projected(value: t.Delivery) t.DeliveryIntent {
    return .{
        .destination = value.destination,
        .key = value.key,
        .payload = value.payload.logical,
    };
}

fn receipt() t.Receipt {
    return .{
        .key = intent().key,
        .destination = intent().destination,
        .timestamp = .{ .bytes = "1700000000.000001" },
        .payload_digest = admitted().payload.content_digest,
        .evidence = .{ .task = @splat(9), .digest = @splat(10) },
        .basis = .captured_response,
    };
}

fn deliveryFact() t.Settlement {
    var result = fact(8, 2, .{ .known_calls = 1, .retained_bytes = 50 });
    result.kind = .delivery;
    result.delivery = .{
        .admitted = admitted(),
        .outcome = .{ .confirmed = .{
            .timestamp = receipt().timestamp,
            .metadata_observed = true,
        } },
        .receipt = receipt(),
    };
    return result;
}

fn pendingHead() t.Head {
    var result = head();
    result.digest = .{
        .delivery = intent(),
        .hold = .uncertain_transmission,
        .not_before_ms = 500,
    };
    return result;
}

fn accounted(previous: t.Head, current: t.Settlement) t.Head {
    var result = previous;
    result.consumed = .{ .items = &.{} };
    result.accounting.known_calls += current.accounting.known_calls;
    result.accounting.retained_bytes += current.accounting.retained_bytes;
    return result;
}

test "native settlements advance only exact contiguous confirmed coverage and retain receipt" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const previous = pendingHead();
    const current = deliveryFact();
    var expected = accounted(previous, current);
    expected.consumed = .{ .items = &.{current.reference} };
    expected.told = intent().payload.coverage.?;
    expected.told_receipt = receipt();
    expected.digest = null;
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("confirmed", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    })));
    var audit = current;
    audit.kind = .audit;
    audit.delivery.?.receipt.?.basis = .history_match;
    expected.told_receipt = audit.delivery.?.receipt;
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("audit", .{
        .head = previous,
        .facts = .{ .items = &.{audit} },
    })));
}

const Mismatch = enum {
    generation,
    identity,
    destination,
    content,
    frozen_text,
    button_count,
    issue,
    comparison,
    comparison_missing,
    coverage,
    receipt_generation,
    receipt_destination,
    receipt_content,
    receipt_timestamp,
    confirmed_timestamp,
    empty_timestamp,
    missing_receipt,
    missing_coverage,
    gap,
    beyond_observed,
    reversed,
    endpoint_sequence,
    endpoint_epoch,
    endpoint_tip,
    superseded,
    stale,
    absent_intent,
};

fn mismatched(case: Mismatch, previous: *t.Head, current: *t.Settlement) void {
    const value = &current.delivery.?;
    switch (case) {
        .generation => value.admitted.key.generation += 1,
        .identity => value.admitted.key.identity = @splat(99),
        .destination => value.admitted.destination.channel = .{ .bytes = "other-channel" },
        .content => value.admitted.payload.content_digest = @splat(99),
        .frozen_text => value.admitted.payload.logical.frozen_text = .{ .bytes = "changed text" },
        .button_count => value.admitted.payload.logical.buttons = .{ .items = &.{} },
        .issue => value.admitted.payload.logical.issue = 1,
        .comparison => value.admitted.payload.logical.comparison.?.base = @splat('z'),
        .comparison_missing => value.admitted.payload.logical.comparison = null,
        .coverage => value.admitted.payload.logical.coverage.?.tip = @splat('z'),
        .receipt_generation => value.receipt.?.key.generation += 1,
        .receipt_destination => value.receipt.?.destination.operator = .{ .bytes = "other-user" },
        .receipt_content => value.receipt.?.payload_digest = @splat(99),
        .receipt_timestamp => value.receipt.?.timestamp = .{ .bytes = "1700000000.000002" },
        .confirmed_timestamp => value.outcome.confirmed.timestamp = .{ .bytes = "other-time" },
        .empty_timestamp => {
            value.receipt.?.timestamp = .{ .bytes = "" };
            value.outcome.confirmed.timestamp = .{ .bytes = "" };
        },
        .missing_receipt => value.receipt = null,
        .missing_coverage => value.admitted.payload.logical.coverage = null,
        .gap => value.admitted.payload.logical.prior_sequence = 10,
        .beyond_observed => {
            value.admitted.payload.logical.through_sequence = 19;
            value.admitted.payload.logical.coverage.?.sequence = 19;
        },
        .reversed => value.admitted.payload.logical.prior_sequence = 16,
        .endpoint_sequence => value.admitted.payload.logical.coverage.?.sequence = 14,
        .endpoint_epoch => value.admitted.payload.logical.coverage.?.epoch = 3,
        .endpoint_tip => {
            value.admitted.payload.logical.through_sequence = 18;
            value.admitted.payload.logical.coverage.?.sequence = 18;
        },
        .superseded => current.kind = .superseded,
        .stale => previous.told = .{ .sequence = 16, .epoch = 2, .tip = @splat('d') },
        .absent_intent => previous.digest = null,
    }
    switch (case) {
        .missing_coverage,
        .gap,
        .beyond_observed,
        .reversed,
        .endpoint_sequence,
        .endpoint_epoch,
        .endpoint_tip,
        => {
            previous.digest.?.delivery = projected(value.admitted);
        },
        else => {},
    }
}

test "native settlements retain unrelated superseded malformed or unproven delivery evidence" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    for (std.enums.values(Mismatch)) |case| {
        var previous = pendingHead();
        var current = deliveryFact();
        mismatched(case, &previous, &current);
        var expected = accounted(previous, current);
        expected.consumed = .{ .items = &.{current.reference} };
        const result = try fixture.output(try fixture.execute(@tagName(case), .{
            .head = previous,
            .facts = .{ .items = &.{current} },
        }));
        try std.testing.expectEqualDeep(expected, result);
    }
}

test "native settlements hold unknown and rendering faults without false frontier receipts" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var previous = pendingHead();
    previous.digest.?.hold = .none;
    var current = deliveryFact();
    current.delivery.?.outcome = .{ .indeterminate = .{ .bytes = "response-lost" } };
    current.delivery.?.receipt = null;
    var expected = accounted(previous, current);
    expected.consumed = .{ .items = &.{current.reference} };
    expected.digest.?.hold = .uncertain_transmission;
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("unknown", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    })));
    current = deliveryFact();
    current.delivery.?.outcome.confirmed.rendering_fault = true;
    expected.digest.?.hold = .rendering_fault;
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("fault", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    })));
    previous.digest.?.hold = .rendering_fault;
    current.delivery.?.outcome = .{ .indeterminate = .{ .bytes = "later-unknown" } };
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("permanent", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    })));
    current = deliveryFact();
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("held", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    })));
}

test "native settlements distinguish identical visible text with different button actions" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const previous = pendingHead();
    var current = deliveryFact();
    current.delivery.?.admitted.payload.logical.buttons = .{ .items = &.{other_button} };
    const pending = previous.digest.?.delivery.payload;
    const claimed = current.delivery.?.admitted.payload.logical;
    try std.testing.expectEqualStrings(pending.frozen_text.bytes, claimed.frozen_text.bytes);
    try std.testing.expectEqualStrings(
        pending.buttons.items[0].label.bytes,
        claimed.buttons.items[0].label.bytes,
    );
    var expected = accounted(previous, current);
    expected.consumed = .{ .items = &.{current.reference} };
    try std.testing.expectEqualDeep(expected, try fixture.output(try fixture.execute("button", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    })));
}

test "native settlements use exclusive prior sequence at the maximum frontier without overflow" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    for ([_]bool{ false, true }) |advancing| {
        var previous = pendingHead();
        previous.told.sequence = std.math.maxInt(u64) - @as(u64, @intFromBool(advancing));
        previous.observed.sequence = std.math.maxInt(u64);
        var current = deliveryFact();
        current.delivery.?.admitted.payload.logical.prior_sequence = previous.told.sequence;
        current.delivery.?.admitted.payload.logical.through_sequence = previous.observed.sequence;
        current.delivery.?.admitted.payload.logical.coverage = previous.observed;
        previous.digest.?.delivery = projected(current.delivery.?.admitted);
        var expected = accounted(previous, current);
        expected.consumed = .{ .items = &.{current.reference} };
        if (advancing) {
            expected.told = previous.observed;
            expected.told_receipt = current.delivery.?.receipt;
            expected.digest = null;
        }
        const operation = if (advancing) "last-prefix" else "empty-prefix";
        const task = try fixture.execute(operation, .{
            .head = previous,
            .facts = .{ .items = &.{current} },
        });
        try std.testing.expectEqualDeep(expected, try fixture.output(task));
    }
}

test "native settlements retry only the matching generation after pacing and Retry After" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var previous = pendingHead();
    previous.clock_ms = 1000;
    var current = deliveryFact();
    current.delivery.?.outcome = .{ .rejected = .{
        .code = .{ .bytes = "ratelimited" },
        .retryable = true,
        .retry_after = .{ .bytes = "180" },
    } };
    current.delivery.?.receipt = null;
    const result = try fixture.output(try fixture.execute("retry", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    }));
    var expected = accounted(previous, current);
    expected.consumed = .{ .items = &.{current.reference} };
    expected.digest.?.delivery.key.generation += 1;
    expected.digest.?.hold = .none;
    expected.digest.?.not_before_ms = 181_000;
    try std.testing.expectEqualDeep(expected, result);
    current.reference.revision += 1;
    current.reference.digest = @splat(11);
    current.previous_reference = result.consumed.items[0];
    current.previous_accounting = current.accounting;
    const stale = try fixture.output(try fixture.execute("retry-stale", .{
        .head = result,
        .facts = .{ .items = &.{current} },
    }));
    try std.testing.expectEqualDeep(result.digest, stale.digest);
    try std.testing.expectEqualDeep(result.told, stale.told);
}

test "native settlements preserve pacing prior deadline and permanent retry holds" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var previous = pendingHead();
    previous.clock_ms = 1000;
    previous.digest.?.not_before_ms = 90_000;
    var current = deliveryFact();
    current.delivery.?.receipt = null;
    current.delivery.?.outcome = .{ .rejected = .{
        .code = .{ .bytes = "no_transmitted_write" },
        .retryable = true,
    } };
    const retry = try fixture.output(try fixture.execute("retry-local", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    }));
    try std.testing.expectEqual(90_000, retry.digest.?.not_before_ms);
    try std.testing.expectEqual(
        previous.digest.?.delivery.key.generation + 1,
        retry.digest.?.delivery.key.generation,
    );
    previous.digest.?.not_before_ms = 0;
    current.delivery.?.outcome.rejected.retry_after = .{ .bytes = "2" };
    const paced = try fixture.output(try fixture.execute("retry-paced", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    }));
    try std.testing.expectEqual(61_000, paced.digest.?.not_before_ms);
    current.delivery.?.outcome.rejected.retryable = false;
    const permanent = try fixture.output(try fixture.execute("retry-permanent", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    }));
    try std.testing.expectEqual(.rejected, permanent.digest.?.hold);
    try std.testing.expectEqualDeep(previous.digest.?.delivery, permanent.digest.?.delivery);
    current.delivery.?.outcome.rejected.retryable = true;
    current.delivery.?.outcome.rejected.retry_after = .{ .bytes = "bad" };
    const malformed = try fixture.output(try fixture.execute("retry-malformed", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    }));
    try std.testing.expectEqualDeep(permanent.digest, malformed.digest);
}

test "native settlements retain paused delivery while authoring its safe retry generation" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var previous = pendingHead();
    previous.digest.?.hold = .paused;
    var current = deliveryFact();
    current.delivery.?.receipt = null;
    current.delivery.?.outcome = .{ .rejected = .{
        .code = .{ .bytes = "no_transmitted_write" },
        .retryable = true,
    } };
    const result = try fixture.output(try fixture.execute("retry-paused", .{
        .head = previous,
        .facts = .{ .items = &.{current} },
    }));
    try std.testing.expectEqual(.paused, result.digest.?.hold);
    try std.testing.expectEqual(
        previous.digest.?.delivery.key.generation + 1,
        result.digest.?.delivery.key.generation,
    );
    try std.testing.expectEqualDeep(previous.told, result.told);
}

const ActivationCase = enum {
    confirmed,
    no_receipt,
    changed_key,
    changed_content,
    rejected,
    unknown,
};

fn activationFact(previous: t.Head, kind: ActivationCase) t.Settlement {
    const activation = previous.activation.?;
    var result = deliveryFact();
    result.accounting = .{};
    result.delivery.?.admitted.destination = activation.destination;
    result.delivery.?.admitted.key = activation.key;
    result.delivery.?.admitted.payload.logical = activation.payload;
    result.delivery.?.receipt.?.destination = activation.destination;
    result.delivery.?.receipt.?.key = activation.key;
    switch (kind) {
        .confirmed => {},
        .no_receipt => result.delivery.?.receipt = null,
        .changed_key => {
            result.delivery.?.admitted.key.generation += 1;
            result.delivery.?.receipt.?.key = result.delivery.?.admitted.key;
        },
        .changed_content => result.delivery.?.receipt.?.payload_digest = @splat(99),
        .rejected => result.delivery.?.outcome = .{
            .rejected = .{ .code = .{ .bytes = "not_sent" }, .retryable = true },
        },
        .unknown => result.delivery.?.outcome = .{ .indeterminate = .{ .bytes = "unknown" } },
    }
    return result;
}

test "native settlements clear activation only on matching confirmed receipt" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const previous = pendingHead();
    for (std.enums.values(ActivationCase)) |kind| {
        const evidence = activationFact(previous, kind);
        const result = try fixture.output(try fixture.execute(@tagName(kind), .{
            .head = previous,
            .facts = .{ .items = &.{evidence} },
        }));
        var expected = previous;
        expected.consumed = .{ .items = &.{evidence.reference} };
        if (kind == .confirmed) expected.activation = null;
        try std.testing.expectEqualDeep(expected, result);
    }
}
