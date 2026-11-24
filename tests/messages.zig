const std = @import("std");
const Native = @import("protean_native");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const messages = @import("../native/messages.zig");
const preparation = @import("../native/delivery_prepare.zig");
const rows = @import("index.zig");
const materialize = @import("../native/materialize.zig");
const examples = @import("contracts.zig");
const c = @import("protean_contracts");
const app = @import("../native/application.zig");
const cli = @import("../native/cli.zig");
const control = @import("../native/control.zig");
const configuration = @import("../native/configuration.zig");
const github = @import("../app/github_contract.zig");
const external = @import("../native/github_external.zig");
const adapter = @import("../native/github_adapter.zig");
const http = @import("../native/http.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);

fn local(
    a: std.mem.Allocator,
    producer: t.Reference,
    purpose: @FieldType(t.DeliveryKey, "purpose"),
    identity: u8,
    obligation: ?t.Id,
    buttons: []const t.Button,
) !t.Delivery {
    const frozen = try preparation.materialize(a, .{
        .key = .{
            .lineage = @splat(8),
            .purpose = purpose,
            .identity = @splat(identity),
            .generation = 0,
        },
        .payload = .{
            .obligation = obligation,
            .specification_revision = 1,
            .prior_sequence = 0,
            .through_sequence = 0,
            .frozen_text = .{ .bytes = @tagName(purpose) },
            .prompt = if (purpose == .question) @splat(6) else null,
            .supersedes = null,
            .buttons = .{ .items = buttons },
        },
    }, producer, @splat(7));
    return frozen.value;
}

const Witness = struct { index: idx.Index, target: t.Id, rows: []const idx.Row };

const confirmed: t.Output = .{ .delivery = .{
    .confirmed = .{ .timestamp = .{ .bytes = "local" }, .metadata_observed = true },
} };

fn digest(a: std.mem.Allocator, producer: t.Reference) !t.Delivery {
    const frozen = try preparation.materialize(a, .{
        .key = .{
            .lineage = @splat(8),
            .purpose = .digest,
            .identity = @splat(9),
            .generation = 0,
        },
        .payload = .{
            .obligation = @splat(1),
            .specification_revision = 1,
            .prior_sequence = 0,
            .through_sequence = 1,
            .frozen_text = .{ .bytes = "one commit" },
            .coverage = .{ .sequence = 1, .epoch = 0, .tip = @splat('b') },
            .comparison = .{
                .repository = examples.specification().repository,
                .base = @splat('a'),
                .tip = @splat('b'),
            },
            .prompt = null,
            .supersedes = null,
        },
    }, producer, @splat(7));
    return frozen.value;
}

fn witness(a: std.mem.Allocator) !Witness {
    const initial = try rows.genesis(a);
    const first = rows.step(rows.head(), rows.ref(initial), "message-step");
    const stepped = try rows.row(a, 3, .{ .step = first }, rows.successor(first));
    const activation = try local(a, rows.ref(initial), .activation, 20, @splat(1), &.{});
    const announced = try rows.row(a, 4, .{ .delivery = activation }, confirmed);
    var failed = try rows.row(a, 5, .{ .delivery = try digest(a, rows.ref(initial)) }, null);
    failed.owner_snapshot.?.outcome = .cancelled;
    const question = try local(a, rows.ref(stepped), .question, 22, @splat(1), &.{.{
        .block_id = .{ .bytes = "source-gap" },
        .action_id = .{ .bytes = "answer" },
        .value = .{ .bytes = "accept_gap" },
        .label = .{ .bytes = "Accept explicit gap" },
    }});
    const delivered = try rows.row(a, 6, .{ .delivery = question }, confirmed);
    const foreign = try rows.row(a, 8, .{
        .delivery = try local(a, rows.ref(initial), .activation, 24, @splat(9), &.{}),
    }, null);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, &.{ foreign, delivered, failed, announced, stepped, initial });
    try all.append(a, try fold(a, all.items, 9));
    return .{
        .index = try idx.Index.init(Native, a, all.items, &.{}),
        .target = @splat(1),
        .rows = all.items,
    };
}

fn fold(a: std.mem.Allocator, all: []const idx.Row, task: u8) !idx.Row {
    var index = try idx.Index.init(Native, a, all, &.{});
    const frozen = try materialize.step(a, &index, @splat(1), 101, null);
    var output = rows.successor(frozen.value);
    var consumed: std.ArrayList(t.RevisionReference) = .empty;
    for (frozen.value.facts.items) |fact| try consumed.append(a, fact.reference);
    output.step.head.consumed.items = consumed.items;
    return rows.row(a, task, .{ .step = frozen.value }, output);
}

test "messages list an obligation's local records in stable order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const page = try messages.page(a, &observed.index, observed.target, null, 64, null);
    try std.testing.expectEqual(3, page.total);
    try std.testing.expectEqual(null, page.next);
    const items = page.messages.items;
    const Purpose = @FieldType(t.DeliveryKey, "purpose");
    const purposes = [_]Purpose{ .activation, .digest, .question };
    const states = [_]messages.State{ .delivered, .undelivered, .delivered };
    for (items, purposes, states, 1..) |item, purpose, state, ordinal| {
        try std.testing.expectEqual(ordinal, item.ordinal);
        try std.testing.expectEqual(purpose, item.purpose);
        try std.testing.expectEqual(state, item.state);
    }
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(@as(t.Id, @splat(6)), .lower),
        items[2].task.bytes,
    );
    try std.testing.expectEqualStrings("question", items[2].text.bytes);
    const folding = observed.index.record(@splat(9)).?.input.step.facts.items;
    const cancelled = for (folding) |fact| {
        if (std.meta.eql(fact.reference.task, @as(t.Id, @splat(5)))) break fact.delivery.?;
    } else return error.MissingFoldedDelivery;
    try std.testing.expect(cancelled.outcome != .confirmed);
    try std.testing.expectEqual(1, items[1].links.items.len);
    try std.testing.expect(std.mem.startsWith(
        u8,
        items[1].links.items[0].bytes,
        "https://github.com/",
    ));
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

test "messages render each choice as the local command that answers it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const config = "/srv/owner's configs/paredros.json";
    const page = try messages.page(a, &observed.index, observed.target, 2, 2, config);
    try std.testing.expectEqual(1, page.messages.items.len);
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

test "messages keep earlier ordinals when a late local message is folded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observed = try witness(a);
    const seen = try messages.page(a, &observed.index, observed.target, null, 64, null);
    try std.testing.expectEqual(3, seen.total);
    const late = try local(a, rows.ref(observed.rows[4]), .question, 25, observed.target, &.{});
    const reply = try rows.row(a, 11, .{ .delivery = late }, confirmed);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, observed.rows);
    try all.append(a, reply);
    const unfolded = try idx.Index.init(Native, a, all.items, &.{});
    const waiting = try messages.page(a, &unfolded, observed.target, seen.total, 64, null);
    try std.testing.expectEqual(0, waiting.messages.items.len);
    try std.testing.expectEqual(seen.total, waiting.total);
    try all.append(a, try fold(a, all.items, 12));
    const folded = try idx.Index.init(Native, a, all.items, &.{});
    const next = try messages.page(a, &folded, observed.target, seen.total, 64, null);
    try std.testing.expectEqual(1, next.messages.items.len);
    try std.testing.expectEqual(.question, next.messages.items[0].purpose);
    try std.testing.expectEqual(4, next.messages.items[0].ordinal);
    const again = try messages.page(a, &folded, observed.target, null, 64, null);
    for (seen.messages.items, again.messages.items[0..3]) |before, after| {
        try std.testing.expectEqualStrings(before.task.bytes, after.task.bytes);
        try std.testing.expectEqual(before.ordinal, after.ordinal);
    }
}

test "messages report each delivery by its own settled outcome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try rows.genesis(a);
    const first = rows.step(rows.head(), rows.ref(initial), "settled-step");
    const stepped = try rows.row(a, 3, .{ .step = first }, rows.successor(first));
    var rejected = try rows.row(a, 4, .{ .delivery = try digest(a, rows.ref(initial)) }, null);
    rejected.owner_snapshot.?.outcome = .cancelled;
    const notice = try local(a, rows.ref(initial), .activation, 20, @splat(1), &.{});
    const accepted = try rows.row(a, 5, .{ .delivery = notice }, confirmed);
    const unknown: t.Output = .{ .delivery = .{ .indeterminate = .{ .bytes = "unknown" } } };
    const prompt = try local(a, rows.ref(stepped), .question, 22, @splat(1), &.{});
    const uncertain = try rows.row(a, 6, .{ .delivery = prompt }, unknown);
    var all: std.ArrayList(idx.Row) = .empty;
    try all.appendSlice(a, &.{ uncertain, accepted, rejected, stepped, initial });
    try all.append(a, try fold(a, all.items, 9));
    const index = try idx.Index.init(Native, a, all.items, &.{});
    const page = try messages.page(a, &index, @splat(1), null, 64, null);
    try std.testing.expectEqual(3, page.total);
    const expected = [_]struct { task: u8, state: messages.State }{
        .{ .task = 4, .state = .undelivered },
        .{ .task = 5, .state = .delivered },
        .{ .task = 6, .state = .uncertain },
    };
    for (expected) |want| {
        const hex = std.fmt.bytesToHex(@as(t.Id, @splat(want.task)), .lower);
        const item = for (page.messages.items) |item| {
            if (std.mem.eql(u8, item.task.bytes, &hex)) break item;
        } else return error.MissingMessage;
        try std.testing.expectEqual(want.state, item.state);
    }
}

const QuestionApplication = struct {
    pub const use_product_assets = true;
    const declaration_values = declarationsValue();
    pub const declarations: []const Native.Declaration = &declaration_values;

    fn declarationsValue() [app.Application.declarations.len]Native.Declaration {
        var result: [app.Application.declarations.len]Native.Declaration = undefined;
        @memcpy(&result, app.Application.declarations);
        for (&result) |*declaration| {
            if (std.mem.eql(u8, declaration.identity, github.identity))
                declaration.capture.?.acquire = Rewritten.acquire;
        }
        return result;
    }
};
const QuestionFixture = @import("native_fixture.zig").Fixture(app.Types, QuestionApplication);

fn oid(value: u32) t.Oid {
    var bytes: t.Oid = @splat('0');
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, value, .big);
    @memcpy(bytes[32..], &std.fmt.bytesToHex(number, .lower));
    return bytes;
}

const Rewritten = struct {
    tip: u32 = 1,

    fn acquire(ctx: Native.Context, bytes: []const u8) !Native.registry.Acquisition {
        const self: *Rewritten = @ptrCast(@alignCast(ctx.environment orelse
            return error.MissingSource));
        var request = try c.decodeOwned(github.Request, ctx.allocator, bytes);
        defer request.deinit();
        var prepared = try adapter.prepare(ctx.allocator, request.value);
        defer prepared.deinit();
        const reply = try self.response(ctx.allocator, request.value);
        defer ctx.allocator.free(reply);
        const head = try std.http.Client.Response.Head.parse("HTTP/1.1 200 OK\r\n" ++
            "Date: Sun, 15 Nov 2026 00:00:00 GMT\r\nContent-Type: application/json\r\n\r\n");
        var reader = std.Io.Reader.fixed(reply);
        var captured = try http.captureResponse(ctx.allocator, head, &reader, .{}, "unused");
        defer captured.deinit();
        return .{ .captured = try external.captureBytes(ctx.allocator, prepared, captured, 100) };
    }

    fn response(self: *const Rewritten, a: std.mem.Allocator, request: github.Request) ![]u8 {
        return switch (request.phase) {
            .repository_before, .repository_after => a.dupe(u8, "{\"id\":123}"),
            .reference => std.json.Stringify.valueAlloc(a, .{
                .ref = "refs/heads/main",
                .object = .{ .type = "commit", .sha = @as([]const u8, &oid(self.tip)) },
            }, .{}),
            .page => std.json.Stringify.valueAlloc(a, .{
                .status = "diverged",
                .base_commit = .{ .sha = @as([]const u8, &oid(1)) },
                .merge_base_commit = .{ .sha = @as([]const u8, &oid(0)) },
                .ahead_by = @as(u64, 1),
                .behind_by = @as(u64, 1),
                .total_commits = @as(u64, 1),
                .commits = .{.{
                    .sha = @as([]const u8, &oid(self.tip)),
                    .commit = .{ .message = "rewritten history" },
                }},
            }, .{}),
        };
    }
};

const QuestionClock = struct {
    now_ms: i64 = 200,

    fn now(context: *anyopaque) !i64 {
        const self: *QuestionClock = @ptrCast(@alignCast(context));
        return self.now_ms;
    }
};

fn drive(f: *QuestionFixture, task: t.Id) !void {
    const a = f.arena.allocator();
    for (0..4096) |_| {
        var saved = try f.service.?.task(a, task);
        defer saved.deinit();
        if (saved.value.terminal()) return;
        switch (try f.service.?.pump(a)) {
            .work => |work| {
                const id = std.fmt.bytesToHex(work.task, .lower);
                const acquired = try work.entry.declaration.capture.?.acquire(.{
                    .allocator = a,
                    .io = .failing,
                    .authority = &f.profile.authority,
                    .task_id = &id,
                    .profile = work.profile,
                    .environment = f.profile.environment,
                }, work.prepared orelse return error.MissingPrepared);
                if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
                try f.service.?.completeWork(a, work, .{ .acquired = acquired.captured });
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.TaskDidNotComplete;
}

fn settle(f: *QuestionFixture, driver: *Driver, target: t.Id) !void {
    const a = f.arena.allocator();
    for (0..16) |_| {
        for (try driver.deliveries(a, target)) |delivery| try drive(f, delivery);
        try drive(f, (try driver.nextStep(a, target)) orelse return);
    }
    return error.StepsDidNotSettle;
}

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
}
