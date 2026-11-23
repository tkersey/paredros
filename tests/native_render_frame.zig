const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const frame = @import("../app/render_frame.zig");
const t = @import("application_types");
const fixtures = @import("contracts.zig");

const Types = struct {
    pub const application_id = "paredros.render-frame.witness";
    pub const application_version = "1.0.0";
    pub const Input = frame.Input;
    pub const Output = frame.Result;
    pub const Failure = t.Failure;
    pub const Answer = void;
    pub const Message = t.Message;
    pub const input_schema_id = "paredros.render-frame.witness.input.v1";
    pub const output_schema_id = "paredros.render-frame.witness.output.v1";
    pub const failure_schema_id = t.failure_schema_id;
    pub const answer_schema_id = "paredros.render-frame.witness.answer.v1";
    pub const message_schema_id = t.message_schema_id;
};

const Fixture = @import("native_fixture.zig").Fixture(
    Types,
    @import("render_frame.zig").Application,
);

fn oid(number: u32) t.Oid {
    var result: t.Oid = @splat('0');
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, number, .big);
    @memcpy(result[32..], &std.fmt.bytesToHex(bytes, .lower));
    return result;
}

fn input(commits: []const t.Commit) frame.Input {
    return .{
        .repository = fixtures.specification().repository,
        .base = oid(0),
        .tip = oid(@intCast(commits.len)),
        .observed_ms = 123456,
        .commits = .{ .items = commits },
        .prior_sequence = 7,
        .through_sequence = 11,
        .epoch = 3,
        .summary = .{ .bytes = "" },
        .highlights = .{ .items = &.{} },
    };
}

fn expectText(result: frame.Result, text: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, result.text.bytes, text) != null);
}

fn escapedCost(text: []const u8) usize {
    var total: usize = 0;
    for (text) |byte| total += switch (byte) {
        '&' => 5,
        '<', '>' => 4,
        else => 1,
    };
    return total;
}

fn expectBound(result: frame.Result) !void {
    try std.testing.expect(result.text.bytes.len <= 4000);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.text.bytes));
    try std.testing.expect(escapedCost(result.text.bytes) <= 4000);
}

fn run(fixture: *Fixture, operation: []const u8, value: frame.Input) !frame.Result {
    const task = try fixture.execute(operation, value);
    const outcome = try fixture.outcome(task);
    const kind = try native.json.text(native.json.get(outcome, "type").?);
    if (!std.mem.eql(u8, kind, "completed")) {
        const diagnostic = try std.json.Stringify.valueAlloc(
            fixture.arena.allocator(),
            outcome,
            .{},
        );
        std.debug.print("render frame {s}: {s}\n", .{ operation, diagnostic });
    }
    const result = try fixture.output(task);
    try expectBound(result);
    try std.testing.expectEqualDeep(value.repository, result.comparison.repository);
    try std.testing.expectEqual(value.base, result.comparison.base);
    try std.testing.expectEqual(value.tip, result.comparison.tip);
    return result;
}

test "native render frame retains truthful full count and oldest ordered bounded entries" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const commits = try a.alloc(t.Commit, 137);
    for (commits, 0..) |*commit, index| commit.* = .{
        .oid = oid(@intCast(index + 1)),
        .message = .{ .bytes = try std.fmt.allocPrint(a, "ordered-message-{d}", .{index + 1}) },
    };
    const result = try run(&fixture, "many-commits", input(commits));
    try std.testing.expectEqual(137, result.total_commits);
    try std.testing.expectEqual(8, result.listed_commits);
    try std.testing.expect(result.abbreviated);
    try expectText(result, "Verified commits: 137");
    try expectText(result, "Coverage: observations after 7 through 11; epoch 3");
    try expectText(result, "Listed 8 of 137; full acquired evidence retained locally.");
    for (result.listed_oids.items, 0..) |selected, index|
        try std.testing.expectEqual(oid(@intCast(index + 1)), selected);
    try std.testing.expect(std.mem.find(u8, result.text.bytes, "ordered-message-9") == null);
    var previous: usize = 0;
    for (1..9) |index| {
        const needle = try std.fmt.allocPrint(a, "ordered-message-{d}", .{index});
        const position = std.mem.find(u8, result.text.bytes, needle).?;
        try std.testing.expect(position >= previous);
        previous = position;
    }
}

test "native render frame safely abbreviates one huge Unicode commit and keeps coverage" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const a = fixture.arena.allocator();
    const message = try a.alloc(u8, 20_000);
    for (0..message.len / 4) |index| @memcpy(message[index * 4 ..][0..4], "🙂");
    const commits = [_]t.Commit{.{ .oid = oid(1), .message = .{ .bytes = message } }};
    const result = try run(&fixture, "large-unicode", input(&commits));
    try std.testing.expectEqual(1, result.total_commits);
    try std.testing.expectEqual(1, result.listed_commits);
    try std.testing.expect(result.abbreviated);
    try expectText(result, "🙂");
    try expectText(result, "...");
    try expectText(result, "Listed 1 of 1");
    try expectText(result, "Presentation abbreviated.");
}

test "native render frame drops absent highlights and accepts an acquired unlisted commit" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var commits: [10]t.Commit = undefined;
    for (&commits, 0..) |*commit, index| commit.* = .{
        .oid = oid(@intCast(index + 1)),
        .message = .{ .bytes = "message" },
    };
    var value = input(&commits);
    value.highlights = .{ .items = &.{
        .{ .oid = oid(999), .text = .{ .bytes = "invented highlight must disappear" } },
        .{ .oid = oid(10), .text = .{ .bytes = "acquired late highlight" } },
        .{ .oid = oid(998), .text = .{ .bytes = "second invention" } },
    } };
    const result = try run(&fixture, "highlight-membership", value);
    try std.testing.expectEqual(2, result.invalid_highlights);
    try expectText(result, "acquired late highlight");
    try expectText(result, "Dropped invalid highlights: 2");
    try std.testing.expect(std.mem.find(u8, result.text.bytes, "invented highlight") == null);
    try std.testing.expect(std.mem.find(u8, result.text.bytes, "second invention") == null);
    try std.testing.expectEqual(oid(8), result.listed_oids.items[7]);
}

test "native render frame budgets hostile escaping and all sections at their upper bounds" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const hostile: [1024]u8 = @splat('&');
    var commits: [8]t.Commit = undefined;
    var highlights: [8]frame.Highlight = undefined;
    for (&commits, &highlights, 0..) |*commit, *highlight, index| {
        commit.* = .{ .oid = oid(@intCast(index + 1)), .message = .{ .bytes = &hostile } };
        highlight.* = .{ .oid = commit.oid, .text = .{ .bytes = hostile[0..256] } };
    }
    var value = input(&commits);
    value.repository.owner.bytes = hostile[0..128];
    value.repository.name.bytes = hostile[0..128];
    value.repository.ref.bytes = &hostile;
    value.observed_ms = std.math.minInt(i64);
    value.prior_sequence = std.math.maxInt(u64) - 1;
    value.through_sequence = std.math.maxInt(u64);
    value.epoch = std.math.maxInt(u64);
    value.summary.bytes = &hostile;
    value.highlights.items = &highlights;
    const result = try run(&fixture, "all-section-bounds", value);
    try std.testing.expect(result.abbreviated);
    try std.testing.expectEqual(8, result.listed_commits);
    try std.testing.expectEqual(0, result.invalid_highlights);
    try expectText(result, "18446744073709551615");
    try expectText(result, "-9223372036854775808");
}

test "native render frame keeps Unicode mentions and URLs inert and flattens text controls" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    const commits = [_]t.Commit{.{
        .oid = oid(1),
        .message = .{ .bytes = "日本語🙂 <@U2> <!channel> " ++
            "https://evil.test\nspoofed frame\r\t" },
    }};
    var value = input(&commits);
    value.summary.bytes = "Model <@U3> https://untrusted.test & suggestion";
    const result = try run(&fixture, "inert-content", value);
    try expectText(result, "日本語🙂");
    try expectText(result, "<@U2> <!channel> https://evil.test spoofed frame");
    try expectText(result, "Method commentary (unverified): Model <@U3>");
    try std.testing.expect(std.mem.find(u8, result.text.bytes, "\nspoofed") == null);
    try std.testing.expect(std.mem.findScalar(u8, result.text.bytes, '\r') == null);
    try std.testing.expect(std.mem.findScalar(u8, result.text.bytes, '\t') == null);
}

test "native render frame empty evidence and invalid coverage remain explicit" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.init();
    var empty = input(&.{});
    empty.base = "0123456789ABCDEFabcdef0123456789ABCDEFab".*;
    const result = try run(&fixture, "empty", empty);
    try expectText(result, &empty.base);
    try std.testing.expectEqual(0, result.total_commits);
    try std.testing.expectEqual(0, result.listed_commits);
    try std.testing.expect(!result.abbreviated);
    try expectText(result, "Verified commits: 0");
    try expectText(result, "Listed 0 of 0");
    var invalid = input(&.{});
    invalid.prior_sequence = 12;
    try fixture.rejected("invalid-coverage", invalid, "render_invalid_coverage");
    invalid = input(&.{});
    invalid.base[0] = 'z';
    try fixture.rejected("invalid-oid", invalid, "render_invalid_oid");
    invalid = input(&.{});
    invalid.tip[39] = 0xff;
    try fixture.rejected("invalid-final-oid-byte", invalid, "render_invalid_oid");
    const commits = [_]t.Commit{.{ .oid = oid(1), .message = .{ .bytes = "commit" } }};
    invalid = input(&commits);
    invalid.prior_sequence = invalid.through_sequence;
    try fixture.rejected("empty-interval", invalid, "render_invalid_coverage");
}
