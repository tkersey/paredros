const std = @import("std");
const t = @import("application_types");
const continuity = @import("continuity.zig");

const Bundle = continuity.Bundle;
const Member = continuity.Member;

pub const Rule = union(enum) { member: t.ContinuityKind, ancestry: void };
const Entry = struct { Owner: type, field: []const u8, rule: Rule };
const rules = [_]Entry{
    .{ .Owner = t.Head, .field = "predecessor", .rule = .ancestry },
    .{ .Owner = t.Head, .field = "superseded", .rule = .ancestry },
    .{ .Owner = t.Head, .field = "last_directive", .rule = .ancestry },
    .{ .Owner = t.Head, .field = "consumed", .rule = .ancestry },
    .{ .Owner = t.Observation, .field = "batch", .rule = .{ .member = .batch } },
    .{ .Owner = Retained, .field = "source", .rule = .{ .member = .method_report } },
    .{ .Owner = Retained, .field = "report", .rule = .{ .member = .method_report } },
    .{ .Owner = t.MethodDisposition, .field = "source", .rule = .{ .member = .method_report } },
    .{ .Owner = t.RetainedMethodSource, .field = "source", .rule = .{ .member = .method_report } },
    .{ .Owner = Derived, .field = "predecessor", .rule = .ancestry },
    .{ .Owner = t.Directive, .field = "predecessor", .rule = .ancestry },
    .{ .Owner = t.TurnContinuity, .field = "member", .rule = .ancestry },
    .{ .Owner = t.TurnContinuity, .field = "original", .rule = .ancestry },
    .{ .Owner = t.TurnReplacement, .field = "input", .rule = .ancestry },
    .{ .Owner = t.TurnReplacement, .field = "reference", .rule = .ancestry },
    .{ .Owner = t.Turn, .field = "context_references", .rule = .ancestry },
    .{ .Owner = t.Experiment, .field = "evidence", .rule = .ancestry },
    .{ .Owner = continuity.ContextFact, .field = "references", .rule = .ancestry },
};
const Retained = @FieldType(t.Method, "retained");
const Derived = @FieldType(t.Origin, "derived");

fn reference(comptime T: type) bool {
    return T == t.Reference or T == t.InputReference or T == t.RevisionReference or
        T == t.PublicationReference;
}

fn contains(comptime T: type) bool {
    if (reference(T)) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_types) |F| {
            if (contains(F)) break true;
        } else false,
        .@"union" => |info| inline for (info.field_types) |F| {
            if (contains(F)) break true;
        } else false,
        .optional => |info| contains(info.child),
        .pointer => |info| contains(info.child),
        .array => |info| contains(info.child),
        else => false,
    };
}

fn classified(comptime Owner: type, comptime field: []const u8) ?Rule {
    for (rules) |entry| {
        if (entry.Owner == Owner and std.mem.eql(u8, entry.field, field)) return entry.rule;
    }
    return null;
}

pub fn visit(comptime T: type, value: T, context: anytype) !void {
    if (comptime reference(T)) @compileError("unclassified continuity reference " ++ @typeName(T));
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, F| {
            if (comptime !contains(F)) continue;
            if (comptime classified(T, name)) |rule| switch (rule) {
                .ancestry => {},
                .member => |kind| try each(F, @field(value, name), kind, context),
            } else try visit(F, @field(value, name), context);
        },
        .@"union" => switch (value) {
            inline else => |payload| try visit(@TypeOf(payload), payload, context),
        },
        .optional => if (value) |inner| try visit(@TypeOf(inner), inner, context),
        .pointer => |info| for (value) |item| try visit(info.child, item, context),
        .array => |info| for (value) |item| try visit(info.child, item, context),
        else => {},
    }
}

fn each(comptime T: type, value: T, kind: t.ContinuityKind, context: anytype) !void {
    if (T == t.PublicationReference) {
        switch (value) {
            .current => {},
            .retained => |retained| try context.reference(kind, retained),
        }
        return;
    }
    if (comptime reference(T)) return context.reference(kind, .{
        .task = value.task,
        .digest = value.digest,
    });
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, F| {
            if (comptime contains(F)) try each(F, @field(value, name), kind, context);
        },
        .optional => if (value) |inner| try each(@TypeOf(inner), inner, kind, context),
        .pointer => |info| for (value) |item| try each(info.child, item, kind, context),
        else => @compileError("unsupported continuity reference carrier " ++ @typeName(T)),
    }
}

pub const SourceKey = struct { namespace: t.Digest, task: t.Id, revision: u64 };
pub const KindKey = struct { kind: t.ContinuityKind, source: SourceKey };
pub const TaskKey = struct { namespace: t.Digest, task: t.Id };
pub const ReferenceKey = struct { kind: t.ContinuityKind, task: t.Id, digest: t.Digest };
pub const TurnKey = struct { namespace: t.Digest, task: t.Id, digest: t.Digest };
pub const Found = struct { position: usize, count: u32 };
const Positions = std.ArrayListUnmanaged(usize);
const Ordinals = std.ArrayListUnmanaged(u64);

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    bundle: Bundle,
    identities: std.AutoHashMapUnmanaged(t.Digest, usize) = .empty,
    lineages: std.AutoHashMapUnmanaged(t.Digest, usize) = .empty,
    references: std.AutoHashMapUnmanaged(ReferenceKey, Found) = .empty,
    facts: std.AutoHashMapUnmanaged(SourceKey, usize) = .empty,
    task_facts: std.AutoHashMapUnmanaged(TaskKey, usize) = .empty,
    sourced: std.AutoHashMapUnmanaged(KindKey, Found) = .empty,
    produced: std.AutoHashMapUnmanaged(t.Id, Positions) = .empty,
    turns: std.AutoHashMapUnmanaged(TurnKey, usize) = .empty,
    operations: std.StringHashMapUnmanaged(void) = .empty,
    ordinals: std.AutoHashMapUnmanaged(t.Id, Ordinals) = .empty,

    pub fn init(a: std.mem.Allocator, bundle: Bundle) !Catalog {
        var self: Catalog = .{ .arena = std.heap.ArenaAllocator.init(a), .bundle = bundle };
        errdefer self.arena.deinit();
        const scratch = self.arena.allocator();
        for (bundle.lineages.items, 0..) |root, position| {
            const entry = try self.lineages.getOrPut(scratch, root.identity);
            if (!entry.found_existing) entry.value_ptr.* = position;
        }
        for (bundle.members.items, 0..) |item, position| {
            const entry = try self.identities.getOrPut(scratch, item.identity);
            if (!entry.found_existing) entry.value_ptr.* = position;
            try self.index(scratch, item, position);
        }
        return self;
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn member(self: *const Catalog, identity: t.Digest) ?Member {
        return self.bundle.members.items[self.identities.get(identity) orelse return null];
    }

    pub fn lineage(self: *const Catalog, identity: t.Digest) ?continuity.Lineage {
        return self.bundle.lineages.items[self.lineages.get(identity) orelse return null];
    }

    pub fn producedBy(self: *const Catalog, task: t.Id) []const usize {
        return if (self.produced.get(task)) |list| list.items else &.{};
    }

    pub fn resolve(self: *const Catalog, kind: t.ContinuityKind, old: t.Reference) !t.Digest {
        const key: ReferenceKey = .{ .kind = kind, .task = old.task, .digest = old.digest };
        const found = self.references.get(key) orelse return error.MissingContinuityReference;
        if (found.count != 1) return error.AmbiguousContinuityReference;
        return self.bundle.members.items[found.position].identity;
    }

    pub fn closed(self: *const Catalog, a: std.mem.Allocator) !void {
        var listed: std.AutoHashMapUnmanaged(t.Digest, void) = .empty;
        defer listed.deinit(a);
        for (self.bundle.members.items) |item| {
            listed.clearRetainingCapacity();
            for (item.data.dependencies.items) |dependency| try listed.put(a, dependency, {});
            const context: Closure = .{ .catalog = self, .listed = &listed };
            switch (item.data.kind) {
                inline else => |kind| {
                    var decoded = try continuity.decode(kind, a, item.data);
                    defer decoded.deinit();
                    try visit(continuity.Payload(kind), decoded.value, context);
                },
            }
        }
    }

    fn index(self: *Catalog, a: std.mem.Allocator, item: Member, position: usize) !void {
        const source = item.data.source;
        const key: SourceKey = .{
            .namespace = source.namespace,
            .task = source.task,
            .revision = source.revision,
        };
        const owner = try self.produced.getOrPut(a, item.current.task);
        if (!owner.found_existing) owner.value_ptr.* = .empty;
        try owner.value_ptr.append(a, position);
        if (item.data.kind == .settlement) {
            const fact = try self.facts.getOrPut(a, key);
            if (!fact.found_existing) fact.value_ptr.* = position;
            const task = try self.task_facts.getOrPut(a, .{
                .namespace = key.namespace,
                .task = key.task,
            });
            if (!task.found_existing) task.value_ptr.* = position;
            return;
        }
        try count(&self.sourced, a, .{ .kind = item.data.kind, .source = key }, position);
        const original: t.Reference = .{ .task = source.task, .digest = source.digest };
        try self.reference(a, item, original, position);
        if (!std.meta.eql(original, item.current))
            try self.reference(a, item, item.current, position);
        if (item.data.kind == .turn) try self.turns.put(a, .{
            .namespace = source.namespace,
            .task = source.task,
            .digest = source.digest,
        }, position);
        const local = std.meta.eql(source.namespace, self.bundle.source.namespace);
        if (item.data.kind == .directive and local) try self.directive(a, item);
    }

    fn reference(
        self: *Catalog,
        a: std.mem.Allocator,
        item: Member,
        value: t.Reference,
        position: usize,
    ) !void {
        const key: ReferenceKey = .{
            .kind = item.data.kind,
            .task = value.task,
            .digest = value.digest,
        };
        const entry = try self.references.getOrPut(a, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .position = position, .count = 1 };
            return;
        }
        const prior = self.bundle.members.items[entry.value_ptr.position].identity;
        if (!std.meta.eql(prior, item.identity)) entry.value_ptr.count +|= 1;
    }

    fn directive(self: *Catalog, a: std.mem.Allocator, item: Member) !void {
        var decoded = try continuity.decode(.directive, a, item.data);
        defer decoded.deinit();
        const operation = try a.dupe(u8, decoded.value.envelope.operation.bytes);
        try self.operations.put(a, operation, {});
        const entry = try self.ordinals.getOrPut(a, decoded.value.obligation);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, decoded.value.ordinal);
    }
};

fn count(
    map: *std.AutoHashMapUnmanaged(KindKey, Found),
    a: std.mem.Allocator,
    key: KindKey,
    position: usize,
) !void {
    const entry = try map.getOrPut(a, key);
    if (entry.found_existing) {
        entry.value_ptr.count +|= 1;
    } else entry.value_ptr.* = .{ .position = position, .count = 1 };
}

const Closure = struct {
    catalog: *const Catalog,
    listed: *const std.AutoHashMapUnmanaged(t.Digest, void),

    fn reference(self: Closure, kind: t.ContinuityKind, value: t.Reference) !void {
        const identity = try self.catalog.resolve(kind, value);
        if (!self.listed.contains(identity)) return error.UnlistedContinuityReference;
    }
};
