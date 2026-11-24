const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");

pub const Error = native.values.Error || error{SystemDirective};

pub fn identifier(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .array and info.array.child == u8 and info.array.len != 0;
}

fn container(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => true,
        else => false,
    };
}

fn textual(comptime T: type) bool {
    return identifier(T) or (container(T) and @hasDecl(T, "parseText"));
}

fn narrowed(comptime T: type) bool {
    return container(T) and @hasDecl(T, "Wire");
}

pub fn hex(value: anytype) [@sizeOf(@TypeOf(value)) * 2]u8 {
    comptime std.debug.assert(identifier(@TypeOf(value)));
    return std.fmt.bytesToHex(value, .lower);
}

pub fn parse(comptime T: type, bytes: []const u8) error{InvalidIdentity}!T {
    if (comptime !identifier(T)) return T.parseText(bytes);
    if (bytes.len != @sizeOf(T) * 2) return error.InvalidIdentity;
    var value: T = undefined;
    _ = std.fmt.hexToBytes(&value, bytes) catch return error.InvalidIdentity;
    return value;
}

pub fn format(comptime T: type, a: std.mem.Allocator, value: T) std.mem.Allocator.Error![]u8 {
    if (comptime !identifier(T)) return value.formatText(a);
    return a.dupe(u8, &hex(value));
}

fn leaf(comptime T: type) bool {
    if (textual(T) or narrowed(T)) return false;
    if (c.native.wrapped(T)) return T.protean_value_kind != .vector;
    return switch (@typeInfo(T)) {
        .optional, .array, .@"struct", .@"union" => false,
        else => true,
    };
}

pub fn toJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!native.json.Value {
    if (comptime textual(T)) return native.json.string(try format(T, a, value));
    if (comptime leaf(T)) return native.values.toJson(T, a, value);
    return projectJson(T, a, value);
}

fn projectJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!native.json.Value {
    if (comptime narrowed(T)) return toJson(T.Wire, a, value.widen());
    if (comptime c.native.wrapped(T)) {
        var items: std.array_list.Managed(native.json.Value) = .init(a);
        for (value.items) |child| try items.append(try toJson(T.Child, a, child));
        return .{ .array = items };
    }
    switch (@typeInfo(T)) {
        .optional => |info| {
            const child = value orelse return .null;
            const projected = try toJson(info.child, a, child);
            if (@typeInfo(info.child) != .optional) return projected;
            var result = native.json.object();
            try native.json.put(a, &result, "tag", native.json.string("some"));
            try native.json.put(a, &result, "value", projected);
            return result;
        },
        .array => |info| {
            var items: std.array_list.Managed(native.json.Value) = .init(a);
            for (value) |child| try items.append(try toJson(info.child, a, child));
            return .{ .array = items };
        },
        .@"struct" => |info| {
            var result = native.json.object();
            inline for (info.field_names, info.field_types) |name, Field|
                try native.json.put(a, &result, name, try toJson(Field, a, @field(value, name)));
            return result;
        },
        .@"union" => |info| {
            var result = native.json.object();
            try native.json.put(a, &result, "tag", native.json.string(@tagName(value)));
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, @tagName(value), name)) try native.json.put(
                    a,
                    &result,
                    "value",
                    try toJson(Field, a, @field(value, name)),
                );
            }
            return result;
        },
        else => comptime unreachable,
    }
}

pub fn fromJson(comptime T: type, a: std.mem.Allocator, value: native.json.Value) Error!T {
    if (comptime textual(T))
        return parse(T, try native.json.text(value)) catch error.InvalidParams;
    if (comptime leaf(T)) return native.values.fromJson(T, a, value);
    return decodeJson(T, a, value);
}

fn decodeJson(comptime T: type, a: std.mem.Allocator, value: native.json.Value) Error!T {
    if (comptime narrowed(T)) return T.narrow(try fromJson(T.Wire, a, value));
    if (comptime c.native.wrapped(T)) {
        if (value != .array) return error.InvalidParams;
        const maximum: ?u64 = T.max_length;
        if (maximum) |limit| if (value.array.items.len > limit) return error.InvalidParams;
        const items = try a.alloc(T.Child, value.array.items.len);
        for (items, value.array.items) |*slot, child| slot.* = try fromJson(T.Child, a, child);
        return .{ .items = items };
    }
    switch (@typeInfo(T)) {
        .optional => |info| return try optionalFromJson(info.child, a, value),
        .array => |info| {
            if (value != .array or value.array.items.len != info.len) return error.InvalidParams;
            var result: T = undefined;
            for (&result, value.array.items) |*slot, child|
                slot.* = try fromJson(info.child, a, child);
            return result;
        },
        .@"struct" => |info| {
            if (value != .object or value.object.count() != info.field_names.len)
                return error.InvalidParams;
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| {
                const child = value.object.get(name) orelse return error.InvalidParams;
                @field(result, name) = try fromJson(Field, a, child);
            }
            return result;
        },
        .@"union" => |info| {
            if (value != .object or value.object.count() != 2) return error.InvalidParams;
            const tag = try native.json.text(value.object.get("tag") orelse
                return error.InvalidParams);
            const child = value.object.get("value") orelse return error.InvalidParams;
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, tag, name))
                    return @unionInit(T, name, try fromJson(Field, a, child));
            }
            return error.InvalidParams;
        },
        else => comptime unreachable,
    }
}

fn optionalFromJson(
    comptime Child: type,
    a: std.mem.Allocator,
    value: native.json.Value,
) Error!?Child {
    if (value == .null) return null;
    if (@typeInfo(Child) != .optional) return try fromJson(Child, a, value);
    if (value != .object or value.object.count() != 2) return error.InvalidParams;
    const tag = try native.json.text(value.object.get("tag") orelse return error.InvalidParams);
    if (!std.mem.eql(u8, tag, "some")) return error.InvalidParams;
    return try fromJson(Child, a, value.object.get("value") orelse return error.InvalidParams);
}

pub fn argument(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !T {
    if (comptime textual(T)) return parse(T, bytes);
    if (comptime @typeInfo(T) == .int) return number(T, bytes);
    const parsed = try native.json.parse(a, bytes, .{});
    return fromJson(T, a, parsed.value);
}

pub fn number(comptime T: type, bytes: []const u8) error{InvalidNumber}!T {
    return std.fmt.parseInt(T, bytes, 10) catch error.InvalidNumber;
}

pub fn printed(a: std.mem.Allocator, value: native.json.Value) ![]const u8 {
    if (value == .string) return value.string;
    return native.json.canonical(a, value);
}
