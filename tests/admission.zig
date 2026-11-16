const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const admission = @import("../native/admission.zig");
const fixture = @import("contracts.zig");

const Store = struct {
    a: std.mem.Allocator,
    operation: ?[]u8 = null,
    bytes: ?[]u8 = null,
    calls: u32 = 0,
    task: t.Id = @splat(42),

    const Receipt = struct {
        value: struct { task: t.Id },
        pub fn deinit(_: *Receipt) void {}
    };
    const Input = struct {
        a: std.mem.Allocator,
        bytes: []u8,
        schema_id: []const u8 = t.input_schema_id,
        encoding: enum { contract } = .contract,

        pub fn deinit(self: *Input) void {
            self.a.free(self.bytes);
        }
    };

    fn deinit(self: *Store) void {
        if (self.bytes) |bytes| self.a.free(bytes);
        if (self.operation) |operation| self.a.free(operation);
    }

    pub fn operationLookup(self: *Store, _: std.mem.Allocator, operation: []const u8) !?Receipt {
        if (self.operation) |saved| {
            if (std.mem.eql(u8, saved, operation)) return .{ .value = .{ .task = self.task } };
        }
        return null;
    }

    pub fn applicationValue(self: *Store, a: std.mem.Allocator, task: t.Id, _: enum { input }) !?Input {
        if (!std.meta.eql(task, self.task)) return error.InvalidTask;
        const bytes = self.bytes orelse return null;
        return .{ .a = a, .bytes = try a.dupe(u8, bytes) };
    }

    pub fn submit(self: *Store, a: std.mem.Allocator, operation: []const u8, value: t.Input) !struct {
        task: t.Id,
        replayed: bool,
    } {
        const bytes = try c.encodeOwned(t.Input, a, value);
        defer a.free(bytes);
        if (self.bytes) |saved| {
            if (!std.mem.eql(u8, self.operation.?, operation) or !std.mem.eql(u8, saved, bytes))
                return error.OperationConflict;
            return .{ .task = self.task, .replayed = true };
        }
        const saved_operation = try self.a.dupe(u8, operation);
        errdefer self.a.free(saved_operation);
        self.bytes = try self.a.dupe(u8, bytes);
        self.operation = saved_operation;
        self.calls += 1;
        return .{ .task = self.task, .replayed = false };
    }
};

const Materializer = struct {
    calls: u32 = 0,
    clock_ms: i64 = 100,

    pub fn materialize(self: *Materializer, _: std.mem.Allocator, requested: admission.Request) !t.Input {
        self.calls += 1;
        var value = fixture.genesis();
        value.clock_ms = self.clock_ms;
        value.envelope = .{
            .operation = .{ .bytes = requested.operation },
            .origin = requested.origin,
            .stable_request = requested.digest,
        };
        return .{ .genesis = value };
    }
};

fn request() admission.Request {
    return .{
        .operation = "caller-retained-id",
        .kind = .genesis,
        .target = null,
        .origin = .{ .local = .{ .uid = 501 } },
        .digest = @splat(7),
    };
}

test "admission replay reuses frozen context without invoking materialization again" {
    const a = std.testing.allocator;
    var store: Store = .{ .a = a };
    defer store.deinit();
    var first: Materializer = .{};
    const accepted = try admission.admit(&store, a, request(), &first);
    try std.testing.expect(!accepted.replayed);
    var restarted: Materializer = .{ .clock_ms = 999 };
    const replay = try admission.admit(&store, a, request(), &restarted);
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqual(accepted.task, replay.task);
    try std.testing.expectEqual(1, store.calls);
    try std.testing.expectEqual(1, first.calls);
    try std.testing.expectEqual(0, restarted.calls);
    var saved = try c.decodeOwned(t.Input, a, store.bytes.?);
    defer saved.deinit();
    try std.testing.expectEqual(100, saved.value.genesis.clock_ms);
}

test "admission conflicting kind target origin and stable request cannot replay" {
    const a = std.testing.allocator;
    var store: Store = .{ .a = a };
    defer store.deinit();
    var materializer: Materializer = .{};
    const original = request();
    _ = try admission.admit(&store, a, original, &materializer);
    for (0..4) |change| {
        var changed = original;
        switch (change) {
            0 => changed.kind = .turn,
            1 => changed.target = @splat(1),
            2 => changed.origin = .{ .local = .{ .uid = 502 } },
            3 => changed.digest[0] ^= 1,
            else => unreachable,
        }
        try std.testing.expectError(error.OperationConflict, admission.admit(
            &store,
            a,
            changed,
            &materializer,
        ));
    }
    try std.testing.expectEqual(1, store.calls);
    try std.testing.expectEqual(1, materializer.calls);
}

test "admission retains a committed input through allocation failure during replay" {
    const a = std.testing.allocator;
    var store: Store = .{ .a = a };
    defer store.deinit();
    var materializer: Materializer = .{};
    _ = try admission.admit(&store, a, request(), &materializer);
    try std.testing.checkAllAllocationFailures(a, replayWithAllocator, .{&store});
    try std.testing.expectEqual(1, store.calls);
}

fn replayWithAllocator(a: std.mem.Allocator, store: *Store) !void {
    var materializer: Materializer = .{ .clock_ms = 500 };
    const result = try admission.admit(store, a, request(), &materializer);
    try std.testing.expect(result.replayed);
    try std.testing.expectEqual(0, materializer.calls);
}
