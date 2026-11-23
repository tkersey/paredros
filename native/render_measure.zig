const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const m = @import("../app/model_contract.zig");
const words = @import("../app/render_text.zig");

const BatchFact = @FieldType(t.Step, "batches").Child;
const context_capacity = @FieldType(m.Input, "context").max_length.?;
const commit_fixed = words.commit_lead.len + @typeInfo(t.Oid).array.len +
    words.commit_size.len + words.commit_end.len;
const batch_fixed = words.batch.len + words.epoch.len + words.acquired.len + words.task.len +
    words.digest.len + words.batch_end.len;

pub const Kind = enum { ordinary, retained };

pub const Prefix = struct {
    kind: Kind,
    bound: u64,
    wire_bound: u64,
    used: u64,
    wire: u64 = 0,
    count: u64 = 0,

    pub fn init(kind: Kind, specification: t.Specification, state: []const u8) !Prefix {
        const wire_bound = specification.policies.render_input_bytes;
        return switch (kind) {
            .ordinary => .{
                .kind = kind,
                .bound = contextLimit(specification.policies),
                .wire_bound = wire_bound,
                .used = try lead(specification),
            },
            .retained => .{
                .kind = kind,
                .bound = wire_bound,
                .wire_bound = wire_bound,
                .used = try std.math.add(u64, natural(state.len), state.len),
            },
        };
    }

    pub fn forHead(head: t.Head) !Prefix {
        return switch (head.method) {
            .ordinary => init(.ordinary, head.specification, ""),
            .retained => |selected| init(.retained, head.specification, selected.state.bytes),
        };
    }

    pub fn add(self: *Prefix, a: std.mem.Allocator, fact: BatchFact) !void {
        const wire = try encoded(a, fact);
        self.count = try std.math.add(u64, self.count, 1);
        self.wire = try std.math.add(u64, self.wire, wire);
        self.used = try std.math.add(u64, self.used, switch (self.kind) {
            .ordinary => try projected(fact),
            .retained => wire,
        });
    }

    pub fn total(self: Prefix) !u64 {
        const framing = if (self.kind == .retained) natural(self.count) else 0;
        return std.math.add(u64, self.used, framing);
    }

    pub fn wireTotal(self: Prefix) !u64 {
        return std.math.add(u64, self.wire, natural(self.count));
    }

    pub fn oversized(self: Prefix) !bool {
        return try self.total() > self.bound;
    }

    pub fn crowded(self: Prefix) !bool {
        return try self.oversized() or try self.wireTotal() > self.wire_bound;
    }
};

pub fn contextLimit(policies: t.Policies) u64 {
    return @min(policies.render_input_bytes, policies.context_bytes, context_capacity);
}

fn lead(specification: t.Specification) !u64 {
    const wording = specification.wording.bytes.len;
    const fixed = words.instruction.len + words.instruction_end.len + words.repository.len +
        words.ref.len + words.lead_end.len;
    var total: u64 = fixed + decimal(wording) + decimal(specification.repository.id);
    total = try std.math.add(u64, total, wording);
    return std.math.add(u64, total, specification.repository.ref.bytes.len);
}

fn projected(fact: BatchFact) !u64 {
    const batch = fact.value;
    var total: u64 = batch_fixed + decimal(batch.sequence) + decimal(batch.epoch) +
        decimal(batch.acquired_ms) + identity(&fact.reference.task) +
        identity(&fact.reference.digest);
    for (batch.commits.items) |commit| {
        const message = commit.message.bytes.len;
        total = try std.math.add(u64, total, commit_fixed + decimal(message));
        total = try std.math.add(u64, total, message);
    }
    return total;
}

fn encoded(a: std.mem.Allocator, fact: BatchFact) !u64 {
    const bytes = try c.encodeOwned(BatchFact, a, fact);
    defer a.free(bytes);
    return bytes.len;
}

fn identity(bytes: []const u8) u64 {
    std.debug.assert(bytes.len > 0);
    var total: u64 = words.identity_open.len + words.identity_close.len +
        (bytes.len - 1) * words.identity_separator.len;
    for (bytes) |byte| total += decimal(byte);
    return total;
}

fn decimal(value: anytype) u64 {
    return std.fmt.count("{d}", .{value});
}

fn natural(value: u64) u64 {
    var total: u64 = 1;
    var rest = value >> 7;
    while (rest != 0) : (rest >>= 7) total += 1;
    return total;
}
