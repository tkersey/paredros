const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const idx = @import("../native/index.zig");
const native = @import("protean_native");
const retained = @import("../native/retained.zig");
const continuity = @import("../native/continuity.zig");
const evidence = @import("../native/history_evidence.zig");
const external = @import("../native/slack_audit_external.zig");
const contract = @import("../app/lineage_audit_contract.zig");
const preparation = @import("../native/delivery_prepare.zig");
const examples = @import("contracts.zig");
const a = std.testing.allocator;

const Fixture = struct {
    index: idx.Index,
    audit: t.LineageAudit,
    captured: []u8,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var genesis = examples.genesis();
        genesis.specification.destination = destination;
        const audit = scan(genesis);
        const request: contract.Request = .{ .audit = audit, .pages = .{ .items = &.{} } };
        const bytes = try c.encodeOwned(contract.Request, allocator, request);
        const message = try historyBody(allocator, genesis.lineage);
        const captured = try c.encodeOwned(external.Capture, allocator, .{ .response = .{
            .bot_id = .{ .bytes = "B1" },
            .evidence = .{
                .request_digest = preparation.hash(bytes),
                .target = .{ .bytes = try external.lineageRequestTarget(allocator, request, "B1") },
                .status = 200,
                .body = .{ .bytes = message },
                .body_digest = preparation.hash(message),
                .captured_ms = 200_000,
                .provider_date = null,
                .request_id = null,
                .link = null,
                .etag = null,
                .retry_after = null,
                .rate_remaining = null,
                .rate_reset = null,
            },
        } });
        const records = try allocator.alloc(idx.Record, 2);
        records[0] = genesisRecord(genesis);
        records[1] = try auditRecord(allocator, audit, bytes, captured);
        const obligations = try allocator.alloc(idx.Obligation, 1);
        obligations[0] = .{
            .task = @splat(1),
            .chain = &.{0},
            .directives = &.{},
            .eligible = null,
            .folded_mode = .active,
            .effective_mode = .active,
            .recovery_hold = true,
        };
        var index: idx.Index = .{
            .arena = arena,
            .records = records,
            .obligations = obligations,
            .tasks = .empty,
            .recovery_hold = true,
        };
        for (records, 0..) |record, position| try index.tasks.put(allocator, record.task, position);
        return .{ .index = index, .audit = audit, .captured = captured };
    }
};
const destination: t.Destination = .{
    .account = .{ .bytes = "slack-test" },
    .app = .{ .bytes = "A1" },
    .workspace = .{ .bytes = "T1" },
    .operator = .{ .bytes = "U1" },
    .channel = .{ .bytes = "D1" },
};

fn scan(genesis: t.Genesis) t.LineageAudit {
    return .{
        .envelope = genesis.envelope,
        .obligation = @splat(1),
        .predecessor = .{ .task = @splat(1), .digest = @splat(2) },
        .lineage = genesis.lineage,
        .destination = genesis.specification.destination,
        .oldest = .{ .bytes = "0.000000" },
        .latest = .{ .bytes = "200.000000" },
        .page_limit = 4,
    };
}

fn genesisRecord(genesis: t.Genesis) idx.Record {
    var head = @import("native_genesis.zig").expectedFresh(genesis);
    head.obligation = .{ .task = @splat(1) };
    head.recovery_hold = true;
    return .{
        .task = @splat(1),
        .revision = 1,
        .input_digest = @splat(1),
        .result_digest = @splat(2),
        .input = .{ .genesis = genesis },
        .result = .{ .genesis = head },
        .selected = true,
    };
}

fn historyBody(allocator: std.mem.Allocator, lineage: t.Digest) ![]u8 {
    var delivery = try preparation.materialize(allocator, .{
        .destination = destination,
        .key = .{ .lineage = lineage, .purpose = .digest, .identity = @splat(7), .generation = 3 },
        .payload = .{
            .obligation = @splat(1),
            .specification_revision = 1,
            .prior_sequence = 4,
            .through_sequence = 5,
            .frozen_text = .{ .bytes = "Later external digest" },
            .prompt = null,
            .supersedes = null,
            .coverage = .{ .sequence = 5, .epoch = 0, .tip = @splat('b') },
        },
    }, .{ .task = @splat(9), .digest = @splat(10) }, @splat(11), "B1");
    defer delivery.deinit();
    const wire = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        delivery.value.payload.wire_json.bytes,
        .{},
    );
    defer wire.deinit();
    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = true,
        .messages = .{.{
            .type = "message",
            .app_id = "A1",
            .bot_id = "B1",
            .team = "T1",
            .ts = "150.0",
            .metadata = wire.value.object.get("metadata").?,
        }},
        .has_more = false,
        .response_metadata = .{ .next_cursor = "" },
    }, .{});
}

fn auditRecord(
    allocator: std.mem.Allocator,
    audit: t.LineageAudit,
    request: []const u8,
    captured: []const u8,
) !idx.Record {
    const input = try c.encodeOwned(t.Input, allocator, .{ .lineage_audit = audit });
    const input_ref: retained.Value = .{
        .schema_id = .{ .bytes = t.input_schema_id },
        .encoding = .contract,
        .reference = .{ .digest = preparation.hash(input), .bytes = input.len },
    };
    const attempts = try allocator.alloc(retained.Attempt, 1);
    attempts[0] = .{
        .id = @splat(5),
        .occurrence = @splat(6),
        .capability = .{ .bytes = contract.identity },
        .inference = false,
        .request = .{
            .digest = preparation.hash("retained invocation envelope"),
            .bytes = "retained invocation envelope".len,
        },
        .prepared = .{ .digest = preparation.hash(request), .bytes = request.len },
        .capture = .{
            .disposition = .complete,
            .response = .{ .digest = preparation.hash(captured), .bytes = captured.len },
            .reply = null,
            .output_tokens = null,
        },
        .usage = null,
    };
    const responses = try allocator.alloc(retained.AttemptEvidence, 1);
    responses[0] = .{ .id = @splat(5), .response = captured, .reply = null };
    return .{
        .task = @splat(3),
        .revision = 1,
        .input_digest = input_ref.reference.digest,
        .result_digest = null,
        .input = .{ .lineage_audit = audit },
        .result = null,
        .owner_snapshot = .{
            .task = @splat(3),
            .revision = 1,
            .event_cut = 1,
            .outcome = .requested,
            .input = input_ref,
            .result = null,
            .profile = .{ .digest = @splat(0), .bytes = 0 },
            .inference_attempts = 0,
            .inference_request_bytes = 0,
            .inference_output_tokens = 0,
            .evidence_bytes = captured.len,
            .attempts = .{ .items = attempts },
            .unknown_calls = .{ .items = &.{} },
            .accounting = .{ .retained_bytes = captured.len },
        },
        .owner_evidence = .{
            .input = .{
                .task = @splat(3),
                .revision = 1,
                .digest = input_ref.reference.digest,
                .schema_id = t.input_schema_id,
                .encoding = .contract,
                .bytes = input,
            },
            .result = null,
            .profile_bytes = "",
            .attempts = responses,
        },
    };
}

test "captured later marker is an external candidate without changing retained frontiers" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = fixture.index.head(&fixture.index.obligations[0]);
    const page = try evidence.page(allocator, &fixture.index, null, null, 16);
    try std.testing.expectEqual(1, page.total);
    try std.testing.expectEqual(1, page.scans);
    try std.testing.expectEqual(0, page.incomplete_scans);
    try std.testing.expect(!page.candidates.items[0].matched_admitted_delivery);
    try std.testing.expect(page.candidates.items[0].requires_owner_disposition);
    try std.testing.expectEqualStrings("150.0", page.candidates.items[0].timestamp.bytes);
    try std.testing.expectEqualSlices(
        u8,
        &fixture.audit.lineage,
        &page.candidates.items[0].lineage,
    );
    try std.testing.expectEqualDeep(before, fixture.index.head(&fixture.index.obligations[0]));
    try std.testing.expect(fixture.index.recovery_hold);
    const after = try evidence.page(allocator, &fixture.index, null, 1, 16);
    try std.testing.expectEqual(0, after.candidates.items.len);
    try std.testing.expectEqual(1, after.total);
}

test "history projection requires the prepared payload and authenticated captured bytes" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const snapshot = &fixture.index.records[1].owner_snapshot.?;
    const attempts = try allocator.dupe(retained.Attempt, snapshot.attempts.items);
    snapshot.attempts.items = attempts;
    const prepared = attempts[0].prepared;
    attempts[0].prepared = null;
    const absent = try evidence.page(allocator, &fixture.index, null, null, 16);
    try std.testing.expectEqual(0, absent.total);
    try std.testing.expectEqual(1, absent.incomplete_scans);
    attempts[0].prepared = prepared;
    attempts[0].prepared.?.digest[0] ^= 1;
    const altered = try evidence.page(allocator, &fixture.index, null, null, 16);
    try std.testing.expectEqual(0, altered.total);
    try std.testing.expectEqual(1, altered.incomplete_scans);
    attempts[0].prepared = prepared;
    fixture.captured[fixture.captured.len - 1] ^= 1;
    const page = try evidence.page(allocator, &fixture.index, null, null, 16);
    try std.testing.expectEqual(0, page.total);
    try std.testing.expectEqual(1, page.incomplete_scans);
    try std.testing.expect(fixture.index.recovery_hold);
}

fn importedEvidence(allocator: std.mem.Allocator, record: idx.Record) !continuity.Imported {
    const snapshot = record.owner_snapshot.?;
    const raw = record.owner_evidence.?;
    const data: t.ContinuityData = .{
        .lineage = @splat(0),
        .kind = .settlement,
        .schema = .{ .bytes = continuity.schema(.settlement) },
        .source = .{
            .namespace = @splat(12),
            .build = @splat(13),
            .task = record.task,
            .revision = record.revision,
            .schema = .{ .bytes = "paredros.owner.snapshot.v1" },
            .digest = try continuity.digest(allocator, retained.Snapshot, snapshot),
        },
        .payload = .{ .bytes = try c.encodeOwned(continuity.SourceFact, allocator, .{
            .snapshot = snapshot,
            .input = .{
                .schema = .{ .bytes = raw.input.schema_id },
                .encoding = .contract,
                .bytes = .{ .bytes = raw.input.bytes },
            },
            .result = null,
            .attempts = .{ .items = &.{.{
                .id = raw.attempts[0].id,
                .response = .{ .bytes = raw.attempts[0].response.? },
                .reply = null,
            }} },
        }) },
        .dependencies = .{ .items = &.{} },
    };
    try continuity.validateData(allocator, data);
    const members = try allocator.alloc(continuity.Member, 1);
    members[0] = .{
        .identity = try continuity.digest(allocator, t.ContinuityData, data),
        .current = .{ .task = @splat(14), .digest = @splat(15) },
        .data = data,
    };
    return .{
        .obligation = @splat(1),
        .bundle = .{
            .source = .{
                .namespace = @splat(12),
                .build = @splat(13),
                .image = @splat(16),
                .runtime = @splat(17),
                .contracts = @splat(18),
                .clock_ms = 200_000,
            },
            .mode = .snapshot,
            .cut = .{ .items = &.{} },
            .cut_digest = @splat(19),
            .lineages = .{ .items = &.{} },
            .members = .{ .items = members },
            .archive_boundary = .{ .bytes = "captured history witness" },
        },
        .metadata = .{
            .bundle = @splat(20),
            .manifest = members[0].current,
            .source_namespace = @splat(12),
            .source_cut = @splat(19),
            .members = .{ .items = &.{} },
        },
    };
}

test "encoded continuity source evidence preserves external candidate provenance" {
    var fixture = try Fixture.init();
    defer fixture.index.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = try evidence.page(allocator, &fixture.index, null, null, 16);
    const imported = try importedEvidence(allocator, fixture.index.records[1]);
    const encoded = try c.encodeOwned(continuity.Bundle, allocator, imported.bundle);
    var decoded = try c.decodeOwned(continuity.Bundle, allocator, encoded);
    defer decoded.deinit();
    var restored = imported;
    restored.bundle = decoded.value;
    fixture.index.imports = &.{restored};
    fixture.index.records = fixture.index.records[0..1];
    const after = try evidence.page(allocator, &fixture.index, @splat(1), null, 16);
    try std.testing.expectEqual(1, after.total);
    try std.testing.expectEqual(0, after.incomplete_scans);
    try std.testing.expectEqualDeep(
        before.candidates.items[0].source,
        after.candidates.items[0].source,
    );
    try std.testing.expectEqualDeep(
        before.candidates.items[0].capture,
        after.candidates.items[0].capture,
    );
    try std.testing.expectEqualStrings(
        before.candidates.items[0].metadata.bytes,
        after.candidates.items[0].metadata.bytes,
    );
    try std.testing.expectEqualDeep(
        @as(t.Digest, @splat(12)),
        after.candidates.items[0].source_namespace.?,
    );
    try std.testing.expect(after.candidates.items[0].requires_owner_disposition);
    try std.testing.expect(fixture.index.recovery_hold);
}
