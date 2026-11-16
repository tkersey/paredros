const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const horos = @import("horos");
const t = @import("application_types");
const m = @import("../app/model_contract.zig");
const index = @import("index.zig");

pub const Object = struct { digest: t.Digest, bytes: u64 };
pub const Value = struct {
    schema_id: c.Utf8,
    encoding: index.Encoding,
    reference: Object,
};
pub const Usage = struct { input_tokens: ?u64, output_tokens: ?u64 };
pub const Capture = struct {
    disposition: enum { complete, definitely_not_sent, unknown },
    response: ?Object,
    reply: ?Object,
    output_tokens: ?u64,
};
pub const Attempt = struct {
    id: t.Digest,
    occurrence: t.Digest,
    capability: c.Utf8,
    inference: bool,
    request: Object,
    prepared: ?Object,
    capture: ?Capture,
    usage: ?Usage,
};
pub const Snapshot = struct {
    version: u32 = 1,
    task: t.Id,
    revision: u64,
    event_cut: u64,
    outcome: enum { progressed, yielded, requested, completed, failed, cancelled },
    input: Value,
    result: ?Value,
    profile: Object,
    inference_attempts: u64,
    inference_request_bytes: u64,
    inference_output_tokens: u64,
    evidence_bytes: u64,
    attempts: c.Vector(Attempt, null),
    unknown_calls: c.Vector(t.Digest, null),
    accounting: t.Accounting,
};
pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,
    bytes: []const u8,
    reference: t.RevisionReference,

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const AttemptEvidence = struct {
    id: t.Digest,
    response: ?[]const u8,
    reply: ?[]const u8,
};
pub const Evidence = struct {
    status: ?native.tasks.Status = null,
    input: index.Value,
    result: ?index.Value,
    profile_bytes: []const u8,
    attempts: []const AttemptEvidence,
};
pub const LoadedSnapshot = struct {
    snapshot: OwnedSnapshot,
    evidence: Evidence,

    pub fn deinit(self: *LoadedSnapshot) void {
        self.snapshot.deinit();
        self.* = undefined;
    }
};
pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    snapshots: []const LoadedSnapshot,
    next: ?t.Id,

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn object(value: anytype) Object {
    return .{ .digest = value.digest, .bytes = value.bytes };
}

fn application(value: native.tasks.ApplicationValue) Value {
    return .{
        .schema_id = .{ .bytes = value.schema_id },
        .encoding = switch (value.encoding) {
            .contract => .contract,
            .json => .json,
        },
        .reference = object(value.reference),
    };
}

pub fn row(loaded: LoadedSnapshot) index.Row {
    return .{
        .input = loaded.evidence.input,
        .result = loaded.evidence.result,
        .owner_snapshot = loaded.snapshot.value,
        .owner_evidence = loaded.evidence,
    };
}

fn rowValue(value: native.tasks.ApplicationValue) index.Value {
    return .{
        .task = value.task,
        .revision = value.revision,
        .digest = value.reference.digest,
        .schema_id = value.schema_id,
        .encoding = switch (value.encoding) {
            .contract => .contract,
            .json => .json,
        },
        .bytes = value.bytes,
    };
}

pub fn copyEvidence(a: std.mem.Allocator, evidence: Evidence) !Evidence {
    const input = try copyValue(a, evidence.input);
    errdefer freeValue(a, input);
    const result = if (evidence.result) |value| try copyValue(a, value) else null;
    errdefer if (result) |value| freeValue(a, value);
    const profile = try a.dupe(u8, evidence.profile_bytes);
    errdefer a.free(profile);
    const attempts = try a.alloc(AttemptEvidence, evidence.attempts.len);
    errdefer a.free(attempts);
    var copied: usize = 0;
    errdefer for (attempts[0..copied]) |attempt| freeAttempt(a, attempt);
    for (attempts, evidence.attempts) |*target, source| {
        target.* = try copyAttempt(a, source);
        copied += 1;
    }
    return .{ .status = evidence.status, .input = input, .result = result, .profile_bytes = profile, .attempts = attempts };
}

fn copyValue(a: std.mem.Allocator, value: index.Value) !index.Value {
    var result = value;
    result.schema_id = try a.dupe(u8, value.schema_id);
    errdefer a.free(result.schema_id);
    result.bytes = try a.dupe(u8, value.bytes);
    return result;
}

fn freeValue(a: std.mem.Allocator, value: index.Value) void {
    a.free(value.schema_id);
    a.free(value.bytes);
}

fn copyAttempt(a: std.mem.Allocator, value: AttemptEvidence) !AttemptEvidence {
    const response = if (value.response) |bytes| try a.dupe(u8, bytes) else null;
    errdefer if (response) |bytes| a.free(bytes);
    return .{
        .id = value.id,
        .response = response,
        .reply = if (value.reply) |bytes| try a.dupe(u8, bytes) else null,
    };
}

fn freeAttempt(a: std.mem.Allocator, value: AttemptEvidence) void {
    if (value.response) |bytes| a.free(bytes);
    if (value.reply) |bytes| a.free(bytes);
}

pub fn load(service: anytype, a: std.mem.Allocator, task: t.Id, page_limit: u32) !LoadedSnapshot {
    if (page_limit == 0) return error.InvalidPageLimit;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var owner = try service.task(scratch, task);
    defer owner.deinit();
    const saved = owner.value;
    const input = (try service.applicationValue(scratch, task, .input)) orelse
        return error.MissingInput;
    const result = try service.applicationValue(scratch, task, .result);
    if (input.revision != saved.revision or (result != null and
        result.?.revision != saved.revision)) return error.StaleRevision;
    const frozen = try service.frozenInputs(scratch, task);
    const attempts = try loadAttempts(
        service,
        scratch,
        task,
        saved.revision,
        page_limit,
        frozen.profile,
    );
    var value: Snapshot = .{
        .task = task,
        .revision = saved.revision,
        .event_cut = saved.event_high,
        .outcome = switch (saved.outcome_kind) {
            inline else => |outcome| @field(@FieldType(Snapshot, "outcome"), @tagName(outcome)),
        },
        .input = application(input),
        .result = if (result) |selected| application(selected) else null,
        .profile = object(saved.profile),
        .inference_attempts = saved.inference_attempts,
        .inference_request_bytes = saved.inference_request_bytes,
        .inference_output_tokens = saved.inference_output_tokens,
        .evidence_bytes = saved.evidence_bytes,
        .attempts = .{ .items = attempts.values },
        .unknown_calls = .{ .items = &.{} },
        .accounting = .{},
    };
    const derived = try accounting(scratch, value);
    value.accounting = derived.value;
    value.unknown_calls.items = derived.unknown;
    var final = try service.task(scratch, task);
    defer final.deinit();
    if (final.value.revision != saved.revision) return error.StaleRevision;
    const bytes = try c.encodeOwned(Snapshot, scratch, value);
    return .{ .snapshot = .{
        .arena = arena,
        .value = value,
        .bytes = bytes,
        .reference = .{ .task = task, .revision = saved.revision, .digest = index.digest(bytes) },
    }, .evidence = .{
        .status = try service.status(scratch, saved),
        .input = rowValue(input),
        .result = if (result) |selected| rowValue(selected) else null,
        .profile_bytes = frozen.profile,
        .attempts = attempts.evidence,
    } };
}

pub fn loadPage(
    service: anytype,
    a: std.mem.Allocator,
    task_after: ?t.Id,
    task_limit: u32,
    attempt_limit: u32,
) !Page {
    if (task_limit == 0 or attempt_limit == 0) return error.InvalidPageLimit;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var page = try service.taskPage(scratch, task_after, task_limit);
    defer page.deinit();
    const snapshots = try scratch.alloc(LoadedSnapshot, page.tasks.len);
    for (page.tasks, snapshots) |task, *snapshot| {
        snapshot.* = try load(service, scratch, task, attempt_limit);
    }
    return .{ .arena = arena, .snapshots = snapshots, .next = page.next };
}

const Attempts = struct { values: []const Attempt, evidence: []const AttemptEvidence };
fn loadAttempts(
    service: anytype,
    a: std.mem.Allocator,
    task: t.Id,
    revision: u64,
    limit: u32,
    profile: []const u8,
) !Attempts {
    var entries: std.ArrayList(Attempt) = .empty;
    var evidence: std.ArrayList(AttemptEvidence) = .empty;
    var after: ?t.Digest = null;
    while (true) {
        var page = try service.attemptPage(a, task, revision, after, limit);
        defer page.deinit();
        for (page.attempts) |attempt| {
            if (entries.items.len > 0 and std.mem.order(
                u8,
                &entries.items[entries.items.len - 1].id,
                &attempt.id,
            ) != .lt) return error.InvalidAttemptOrder;
            const response = try service.attemptValue(a, task, revision, attempt.id, .response);
            const reply = try service.attemptValue(a, task, revision, attempt.id, .reply);
            const raw: AttemptEvidence = .{
                .id = attempt.id,
                .response = if (response) |part| part.bytes else null,
                .reply = if (reply) |part| part.bytes else null,
            };
            var value: Attempt = .{
                .id = attempt.id,
                .occurrence = attempt.occurrence,
                .capability = .{ .bytes = try a.dupe(u8, attempt.capability) },
                .inference = attempt.inference,
                .request = object(attempt.request),
                .prepared = if (attempt.prepared) |selected| object(selected) else null,
                .capture = if (attempt.capture) |capture| .{
                    .disposition = switch (capture.disposition) {
                        .complete => .complete,
                        .definitely_not_sent => .definitely_not_sent,
                        .unknown => .unknown,
                    },
                    .response = if (capture.response) |ref| object(ref) else null,
                    .reply = if (capture.reply) |ref| object(ref) else null,
                    .output_tokens = capture.output_tokens,
                } else null,
                .usage = null,
            };
            value.usage = try observedUsage(a, profile, value, raw);
            try entries.append(a, value);
            try evidence.append(a, raw);
        }
        const next = page.next orelse break;
        if (after) |previous| if (std.mem.order(u8, &previous, &next) != .lt)
            return error.InvalidAttemptOrder;
        after = next;
    }
    return .{ .values = try entries.toOwnedSlice(a), .evidence = try evidence.toOwnedSlice(a) };
}

fn count(value: ?native.json.Value) ?u64 {
    const selected = value orelse return null;
    if (selected != .number_string) return null;
    return native.json.numberInteger(u64, selected.number_string) catch null;
}

const UsageObservation = union(enum) { unavailable, observed: ?Usage };

fn rawUsage(a: std.mem.Allocator, profile: []const u8, bytes: []const u8) !UsageObservation {
    var raw = c.decodeOwned(native.responses.Raw, a, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .unavailable,
    };
    defer raw.deinit();
    const contract = native.responses.route.read(a, profile) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .unavailable,
    };
    const decoded = native.responses.decode(a, contract, raw.value) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .unavailable,
    };
    if (decoded.failure) |failure| if (failure.kind == .http_status)
        return .{ .observed = null };
    const usage = native.json.get(decoded.body, "usage") orelse return .{ .observed = null };
    if (usage != .object) return .{ .observed = null };
    return .{ .observed = .{
        .input_tokens = count(native.json.get(usage, "input_tokens")),
        .output_tokens = count(native.json.get(usage, "output_tokens")),
    } };
}

fn observedUsage(
    a: std.mem.Allocator,
    profile: []const u8,
    attempt: Attempt,
    evidence: AttemptEvidence,
) !?Usage {
    if (!attempt.inference or !std.mem.eql(u8, attempt.capability.bytes, m.P.identity)) return null;
    const capture = attempt.capture orelse return null;
    const bytes = evidence.response orelse return null;
    const result = switch (try rawUsage(a, profile, bytes)) {
        .unavailable => return null,
        .observed => |value| value,
    };
    if (evidence.reply) |reply_bytes| {
        var invocation = try horos.data.invocation.decode(
            horos.data.invocation.Result,
            a,
            reply_bytes,
        );
        defer invocation.deinit();
        var reply = try c.decodeOwned(m.P.AdaptiveResult, a, invocation.value.value);
        defer reply.deinit();
        const normalized: ?Usage = if (reply.value.usage) |usage| .{
            .input_tokens = usage.input_tokens,
            .output_tokens = usage.output_tokens,
        } else null;
        if (!std.meta.eql(normalized, result)) return error.UsageMismatch;
    }
    if (capture.output_tokens) |tokens| {
        if (result == null or result.?.output_tokens != tokens) return error.UsageMismatch;
    }
    return result;
}

const Accounting = struct { value: t.Accounting, unknown: []const t.Digest };
fn accounting(a: std.mem.Allocator, value: Snapshot) !Accounting {
    var result: t.Accounting = .{
        .retained_bytes = value.evidence_bytes,
        .failed_attempts = @intFromBool(value.outcome == .failed),
    };
    var unknown: std.ArrayList(t.Digest) = .empty;
    for (value.attempts.items) |attempt| {
        if (!attempt.inference) continue;
        var possible = true;
        if (attempt.capture) |capture| {
            possible = capture.disposition != .definitely_not_sent;
            if (capture.disposition == .complete)
                result.known_calls = try std.math.add(u64, result.known_calls, 1);
        }
        const usage = attempt.usage;
        if (usage) |observed| {
            if (observed.input_tokens) |tokens| result.known_input_tokens =
                try std.math.add(u64, result.known_input_tokens, tokens);
            if (observed.output_tokens) |tokens| result.known_output_tokens =
                try std.math.add(u64, result.known_output_tokens, tokens);
        }
        if (possible and (usage == null or usage.?.input_tokens == null or
            usage.?.output_tokens == null)) try unknown.append(a, attempt.id);
    }
    result.possible_charged_calls = @intCast(unknown.items.len);
    return .{ .value = result, .unknown = try unknown.toOwnedSlice(a) };
}

fn validate(a: std.mem.Allocator, value: Snapshot) !void {
    if (value.version != 1) return error.UnsupportedSnapshot;
    if (value.input.encoding != .contract) return error.UnsupportedEncoding;
    if (value.result) |result| {
        if (result.encoding != .json or (value.outcome != .completed and value.outcome != .failed))
            return error.UnsupportedEncoding;
    }
    for (value.attempts.items, 0..) |attempt, position| {
        if (position > 0 and std.mem.order(
            u8,
            &value.attempts.items[position - 1].id,
            &attempt.id,
        ) != .lt) return error.InvalidAttemptOrder;
        if (attempt.capture) |capture| {
            if (attempt.prepared == null or
                (capture.disposition == .complete) != (capture.response != null) or
                (capture.reply != null and capture.disposition != .complete) or
                (capture.output_tokens != null and capture.reply == null))
                return error.InvalidCapture;
        }
        if (attempt.usage != null and (!attempt.inference or attempt.capture == null or
            attempt.capture.?.disposition != .complete)) return error.InvalidUsage;
    }
    const derived = try accounting(a, value);
    if (!std.meta.eql(derived.value, value.accounting) or
        !std.mem.eql(t.Digest, derived.unknown, value.unknown_calls.items))
        return error.AccountingMismatch;
}

pub fn decodeFrozen(
    a: std.mem.Allocator,
    reference: t.RevisionReference,
    bytes: []const u8,
) !OwnedSnapshot {
    if (!std.meta.eql(index.digest(bytes), reference.digest)) return error.DigestMismatch;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    const decoded = try c.decodeOwned(Snapshot, scratch, bytes);
    const value = decoded.value;
    if (!std.meta.eql(reference.task, value.task) or reference.revision != value.revision)
        return error.RevisionMismatch;
    try validate(scratch, value);
    const encoded = try c.encodeOwned(Snapshot, scratch, value);
    if (!std.mem.eql(u8, encoded, bytes)) return error.NoncanonicalSnapshot;
    return .{ .arena = arena, .value = value, .bytes = encoded, .reference = reference };
}

pub const Admission = struct { input: t.InputReference, fact_index: u32 };
pub fn loadAdmitted(
    service: anytype,
    a: std.mem.Allocator,
    admitted: Admission,
    reference: t.RevisionReference,
) !OwnedSnapshot {
    var input = (try service.applicationValue(a, admitted.input.task, .input)) orelse
        return error.MissingInput;
    defer input.deinit();
    if (input.encoding != .contract or !std.mem.eql(u8, input.schema_id, t.input_schema_id) or
        !std.meta.eql(input.reference.digest, admitted.input.digest)) return error.WrongAdmission;
    var decoded = try c.decodeOwned(t.Input, a, input.bytes);
    defer decoded.deinit();
    if (decoded.value != .step) return error.WrongAdmission;
    const facts = decoded.value.step.facts.items;
    if (admitted.fact_index >= facts.len) return error.WrongAdmission;
    const fact = facts[admitted.fact_index];
    if (!std.meta.eql(fact.reference, reference)) return error.WrongAdmission;
    return decodeFrozen(a, reference, fact.owner_snapshot.bytes);
}

pub fn verifySettlement(
    fact: t.Settlement,
    snapshot: OwnedSnapshot,
    previous: ?OwnedSnapshot,
) !void {
    if (!std.meta.eql(fact.reference, snapshot.reference) or
        !std.mem.eql(u8, fact.owner_snapshot.bytes, snapshot.bytes) or
        !std.meta.eql(fact.accounting, snapshot.value.accounting)) return error.InvalidSettlement;
    if (previous) |before| {
        if (fact.previous_reference == null or
            !std.meta.eql(fact.previous_reference.?, before.reference) or
            !std.meta.eql(fact.previous_accounting, before.value.accounting) or
            !std.meta.eql(before.reference.task, snapshot.reference.task) or
            before.reference.revision >= snapshot.reference.revision)
            return error.InvalidPreviousSettlement;
    } else if (fact.previous_reference != null or
        !std.meta.eql(fact.previous_accounting, t.Accounting{}))
        return error.InvalidPreviousSettlement;
}
