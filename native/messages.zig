const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("index.zig");
const cli = @import("cli.zig");
const wire = @import("wire.zig");

pub const Purpose = std.meta.Tag(@FieldType(t.Notification, "purpose"));
pub const Choice = struct {
    label: t.Name,
    value: t.Name,
    command: ?c.Text(4096),
};
pub const Message = struct {
    ordinal: u64,
    sequence: u64,
    task: t.Id,
    purpose: Purpose,
    specification_revision: u64,
    prior: ?t.Frontier,
    through: ?t.Frontier,
    question: ?t.Digest,
    text: t.Text,
    links: c.Vector(c.Text(4096), 1),
    choices: c.Vector(Choice, 8),
};
pub const Page = struct {
    messages: c.Vector(Message, 64),
    total: u64,
    next: ?u64,
};

pub fn page(
    a: std.mem.Allocator,
    index: *const idx.Index,
    target: t.Id,
    after: ?u64,
    limit: u32,
    config_path: ?[]const u8,
) !Page {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    const obligation = index.obligation(target) orelse return error.UnknownObligation;
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(a);
    for (obligation.chain) |position| {
        if (head(index.records[position]).message != null) try positions.append(a, position);
    }
    const pending = index.head(obligation).question;
    const total: u64 = positions.items.len;
    const start: usize = @intCast(@min(after orelse 0, total));
    const end = @min(positions.items.len, start + limit);
    const items = try a.alloc(Message, end - start);
    for (items, positions.items[start..end], start + 1..) |*item, position, ordinal| {
        const record = index.records[position];
        item.* = try message(a, record, target, ordinal, pending, config_path);
    }
    return .{
        .messages = .{ .items = items },
        .total = total,
        .next = if (end < positions.items.len) end else null,
    };
}

fn head(record: idx.Record) t.Head {
    return switch (record.result.?) {
        .genesis => |value| value,
        .step => |value| value.head,
        else => unreachable,
    };
}

fn route(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(a);
    const alphabet = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') {
            try encoded.append(a, byte);
        } else try encoded.appendSlice(a, &.{ '%', alphabet[byte >> 4], alphabet[byte & 15] });
    }
    return encoded.toOwnedSlice(a);
}

pub fn comparisonLink(a: std.mem.Allocator, comparison: t.Comparison) !?[]const u8 {
    for (comparison.base, comparison.tip) |base, tip|
        if (!std.ascii.isHex(base) or !std.ascii.isHex(tip)) return null;
    const owner = try route(a, comparison.repository.owner.bytes);
    defer a.free(owner);
    const name = try route(a, comparison.repository.name.bytes);
    defer a.free(name);
    return try std.fmt.allocPrint(a, "https://github.com/{s}/{s}/compare/{s}...{s}", .{
        owner, name, comparison.base, comparison.tip,
    });
}

fn command(
    a: std.mem.Allocator,
    config_path: ?[]const u8,
    obligation: t.Id,
    question: t.Digest,
    value: t.Name,
) !?c.Text(4096) {
    const path = config_path orelse return null;
    const target = wire.hex(obligation);
    const identity = wire.hex(question);
    const line = try cli.commandLine(a, path, &.{
        "question", "answer", &target, &identity, value.bytes,
    });
    return if (line.len <= 4096) .{ .bytes = line } else null;
}

fn message(
    a: std.mem.Allocator,
    record: idx.Record,
    owner: t.Id,
    ordinal: u64,
    pending: ?t.Question,
    config_path: ?[]const u8,
) !Message {
    const selected = head(record);
    const value = selected.message.?;
    const link = if (value.comparison) |comparison| try comparisonLink(a, comparison) else null;
    const links = try a.alloc(c.Text(4096), @intFromBool(link != null));
    if (link) |url| links[0] = .{ .bytes = url };
    var result: Message = .{
        .ordinal = ordinal,
        .sequence = selected.sequence,
        .task = record.task,
        .purpose = value.purpose,
        .specification_revision = value.specification_revision,
        .prior = null,
        .through = null,
        .question = null,
        .text = value.text,
        .links = .{ .items = links },
        .choices = .{ .items = &.{} },
    };
    switch (value.purpose) {
        .activation => {},
        .digest => |covered| {
            result.prior = covered.prior;
            result.through = covered.through;
        },
        .question => |asked| {
            result.question = asked.identity;
            const open = if (pending) |question|
                std.meta.eql(question.identity, asked.identity)
            else
                false;
            const choices = try a.alloc(Choice, asked.choices.items.len);
            for (choices, asked.choices.items) |*choice, offered| choice.* = .{
                .label = offered.label,
                .value = offered.value,
                .command = if (open)
                    try command(a, config_path, owner, asked.identity, offered.value)
                else
                    null,
            };
            result.choices = .{ .items = choices };
        },
    }
    return result;
}
