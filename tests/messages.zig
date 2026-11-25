const std = @import("std");
const Native = @import("protean_native");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const messages = @import("../native/messages.zig");
const rows = @import("index.zig");
const examples = @import("contracts.zig");
const app = @import("../native/application.zig");
const cli = @import("../native/cli.zig");
const control = @import("../native/control.zig");
const configuration = @import("../native/configuration.zig");
const github = @import("../app/github_contract.zig");
const fake = @import("github_fake.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);

const Witness = struct { index: idx.Index, target: t.Id };

const activation: t.Notification = .{
    .specification_revision = 0,
    .text = .{ .bytes = "activation" },
    .purpose = .{ .activation = {} },
};

fn digest() t.Notification {
    return .{
        .specification_revision = 1,
        .text = .{ .bytes = "one commit" },
        .comparison = .{
            .repository = examples.specification().repository,
            .base = @splat('a'),
            .tip = @splat('b'),
        },
        .purpose = .{ .digest = .{
            .prior = .{ .sequence = 0, .epoch = 0, .tip = @splat('a') },
            .through = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') },
        } },
    };
}

fn pendingQuestion() t.Question {
    return .{
        .identity = @splat(6),
        .condition = @splat(6),
        .specification_revision = 1,
        .choices = .{ .items = &.{.{
            .value = .{ .bytes = "accept_gap" },
            .label = .{ .bytes = "Accept explicit gap" },
        }} },
        .prompt = .{ .bytes = "question" },
    };
}

fn prompt() t.Notification {
    return .{
        .specification_revision = 1,
        .text = .{ .bytes = "question" },
        .purpose = .{ .question = .{
            .identity = @splat(6),
            .choices = pendingQuestion().choices,
        } },
    };
}

const Link = struct { row: idx.Row, head: t.Head };

fn publish(
    a: std.mem.Allocator,
    previous: Link,
    task: u8,
    message: ?t.Notification,
    asked: ?t.Question,
) !Link {
    const operation = try std.fmt.allocPrint(a, "message-step-{d}", .{task});
    const next = rows.step(previous.head, rows.ref(previous.row), operation);
    var output = rows.successor(next);
    output.step.head.message = message;
    output.step.head.question = asked;
    return .{
        .row = try rows.row(a, task, .{ .step = next }, output),
        .head = output.step.head,
    };
}

fn opening(a: std.mem.Allocator) !Link {
    var opened = rows.head();
    opened.message = activation;
    return .{
        .row = try rows.row(a, 1, .{ .genesis = examples.genesis() }, .{ .genesis = opened }),
        .head = opened,
    };
}

fn witness(a: std.mem.Allocator) !Witness {
    const initial = try opening(a);
    const first = try publish(a, initial, 3, digest(), null);
    const second = try publish(a, first, 4, null, null);
    const third = try publish(a, second, 5, prompt(), pendingQuestion());
    const all = try a.dupe(idx.Row, &.{ third.row, first.row, initial.row, second.row });
    return .{ .index = try idx.Index.init(Native, a, all, &.{}), .target = @splat(1) };
}

test "messages project each published head in chain order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const page = try messages.page(a, &observed.index, observed.target, null, 64, null);
    try std.testing.expectEqual(3, page.total);
    try std.testing.expectEqual(null, page.next);
    const items = page.messages.items;
    const purposes = [_]messages.Purpose{ .activation, .digest, .question };
    const sequences = [_]u64{ 0, 1, 3 };
    const tasks = [_]u8{ 1, 3, 5 };
    for (items, purposes, sequences, tasks, 1..) |item, purpose, sequence, task, ordinal| {
        try std.testing.expectEqual(ordinal, item.ordinal);
        try std.testing.expectEqual(purpose, item.purpose);
        try std.testing.expectEqual(sequence, item.sequence);
        try std.testing.expectEqualDeep(@as(t.Id, @splat(task)), item.task);
    }
    try std.testing.expectEqualStrings("question", items[2].text.bytes);
    try std.testing.expectEqualDeep(digest().purpose.digest.through, items[1].through.?);
    try std.testing.expectEqualDeep(digest().purpose.digest.prior, items[1].prior.?);
    try std.testing.expectEqual(1, items[1].links.items.len);
    try std.testing.expect(std.mem.startsWith(
        u8,
        items[1].links.items[0].bytes,
        "https://github.com/",
    ));
    try std.testing.expectEqual(0, items[0].links.items.len);
    _ = try Native.values.toJson(messages.Page, a, page);
}

test "messages page from a stable ordinal cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const first = try messages.page(a, &observed.index, observed.target, null, 2, null);
    try std.testing.expectEqual(2, first.messages.items.len);
    try std.testing.expectEqual(@as(?u64, 2), first.next);
    const rest = try messages.page(a, &observed.index, observed.target, first.next, 2, null);
    try std.testing.expectEqual(1, rest.messages.items.len);
    try std.testing.expectEqual(3, rest.messages.items[0].ordinal);
    try std.testing.expectEqual(null, rest.next);
    const beyond = try messages.page(a, &observed.index, observed.target, 9, 3, null);
    try std.testing.expectEqual(0, beyond.messages.items.len);
    try std.testing.expectEqual(3, beyond.total);
    try std.testing.expectError(
        error.InvalidPageLimit,
        messages.page(a, &observed.index, observed.target, null, 65, null),
    );
    try std.testing.expectError(
        error.UnknownObligation,
        messages.page(a, &observed.index, @splat(9), null, 3, null),
    );
}

test "messages render each pending choice as the local command that answers it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const config = "/srv/owner's configs/paredros.json";
    const page = try messages.page(a, &observed.index, observed.target, 2, 2, config);
    try std.testing.expectEqual(1, page.messages.items.len);
    try std.testing.expectEqualDeep(
        @as(?t.Digest, @splat(6)),
        page.messages.items[0].question,
    );
    const answer = page.messages.items[0].choices.items[0];
    try std.testing.expectEqualStrings("Accept explicit gap", answer.label.bytes);
    const expected = try std.fmt.allocPrint(
        a,
        "paredros --config '/srv/owner'\\''s configs/paredros.json' " ++
            "question answer {s} {s} accept_gap",
        .{
            std.fmt.bytesToHex(@as(t.Id, @splat(1)), .lower),
            std.fmt.bytesToHex(@as(t.Digest, @splat(6)), .lower),
        },
    );
    try std.testing.expectEqualStrings(expected, answer.command.?.bytes);
    const plain = try messages.page(a, &observed.index, observed.target, 2, 2, "/etc/p.json");
    try std.testing.expect(std.mem.startsWith(
        u8,
        plain.messages.items[0].choices.items[0].command.?.bytes,
        "paredros --config /etc/p.json question answer ",
    ));
    const unknown = try messages.page(a, &observed.index, observed.target, 2, 2, null);
    try std.testing.expectEqual(null, unknown.messages.items[0].choices.items[0].command);
}

test "messages keep earlier ordinals and drop answer commands once a later head closes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try opening(a);
    const first = try publish(a, initial, 3, digest(), null);
    const second = try publish(a, first, 4, null, null);
    const third = try publish(a, second, 5, prompt(), pendingQuestion());
    const seen_index = try idx.Index.init(
        Native,
        a,
        &.{ initial.row, first.row, second.row, third.row },
        &.{},
    );
    const seen = try messages.page(a, &seen_index, @splat(1), null, 64, "/etc/p.json");
    try std.testing.expectEqual(3, seen.total);
    const closed = try publish(a, third, 6, null, null);
    var later = digest();
    later.purpose.digest.prior = later.purpose.digest.through;
    later.purpose.digest.through.sequence = 2;
    const fourth = try publish(a, closed, 7, later, null);
    const index = try idx.Index.init(
        Native,
        a,
        &.{ fourth.row, closed.row, initial.row, first.row, second.row, third.row },
        &.{},
    );
    const again = try messages.page(a, &index, @splat(1), null, 64, "/etc/p.json");
    try std.testing.expectEqual(4, again.total);
    for (seen.messages.items, again.messages.items[0..3]) |before, after| {
        try std.testing.expectEqualDeep(before.task, after.task);
        try std.testing.expectEqual(before.ordinal, after.ordinal);
        try std.testing.expectEqual(before.sequence, after.sequence);
    }
    try std.testing.expectEqual(null, again.messages.items[2].choices.items[0].command);
    try std.testing.expectEqual(.digest, again.messages.items[3].purpose);
    try std.testing.expectEqual(5, again.messages.items[3].sequence);
}

const QuestionFixture = @import("native_fixture.zig").Fixture(app.Types, fake.Application);
const Rewritten = fake.Source;
const QuestionClock = fake.Clock;
const drive = fake.drive;
const settle = fake.settle;

fn questionConfig() configuration.Config {
    const repository = examples.specification().repository;
    return .{
        .version = 1,
        .current_uid = 501,
        .namespace_path = "/tmp/unused-question-test",
        .control_socket_path = "/tmp/unused-question-test.sock",
        .repository = .{
            .account = repository.account.bytes,
            .id = repository.id,
            .owner = repository.owner.bytes,
            .name = repository.name.bytes,
            .ref = repository.ref.bytes,
        },
    };
}

fn printedAnswer(a: std.mem.Allocator, index: *const idx.Index, target: t.Id) ![]const u8 {
    const page = try messages.page(a, index, target, null, 64, "/etc/paredros.json");
    for (page.messages.items) |item| {
        if (item.purpose != .question) continue;
        return item.choices.items[0].command.?.bytes;
    }
    return error.MissingQuestionMessage;
}

test "messages answer a check-raised question through its printed command" {
    var source: Rewritten = .{};
    var f: QuestionFixture = .{};
    defer f.deinit();
    f.profile.environment = &source;
    try f.initWithGrants(&.{github.identity});
    const a = f.arena.allocator();
    const initial = examples.genesis();
    const target = try f.execute(initial.envelope.operation.bytes, .{ .genesis = initial });
    var clock: QuestionClock = .{};
    var driver: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = &clock, .now = QuestionClock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    try settle(&f, &driver, target);
    source.tip = 2;
    clock.now_ms = 1_000_000;
    try settle(&f, &driver, target);
    var raised = try driver.rebuild(a);
    defer raised.deinit();
    const question = raised.head(raised.obligation(target).?).question.?;
    try std.testing.expectEqual(.diverged, question.source_condition.?.coverage);
    const line = try printedAnswer(a, &raised, target);
    var words: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, line, ' ');
    while (split.next()) |word| try words.append(a, word);
    try std.testing.expectEqualStrings("paredros", words.items[0]);
    const wire = try cli.request(a, words.items[3..], "printed-answer");
    const reply = try control.dispatch(a, &driver, questionConfig(), 501, wire);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"admitted\"") != null);
    const folding = (try driver.nextStep(a, target)).?;
    try drive(&f, folding);
    var answered = try driver.rebuild(a);
    defer answered.deinit();
    const head = answered.head(answered.obligation(target).?);
    try std.testing.expect(head.question == null);
    try std.testing.expectEqual(.accepted_gap, head.last_observation.?.coverage);
    try std.testing.expectEqualDeep(question.source_condition.?.tip, head.observed.tip.?);
    const dispositions = answered.record(folding).?.result.?.step.dispositions.items;
    try std.testing.expectEqual(1, dispositions.len);
    try std.testing.expectEqual(.applied, std.meta.activeTag(dispositions[0].outcome));
    const history = try messages.page(a, &answered, target, null, 64, "/etc/paredros.json");
    const prompts = history.messages.items[history.messages.items.len - 1];
    try std.testing.expectEqual(.question, prompts.purpose);
    try std.testing.expectEqual(null, prompts.choices.items[0].command);
}
