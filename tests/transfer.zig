const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const contracts = @import("contracts.zig");
const transfer = @import("../native/transfer.zig");
const continuity = @import("../native/continuity.zig");
const configuration = @import("../native/configuration.zig");
const app = @import("../native/application.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};
const Fixture = @import("native_fixture.zig").Fixture(app.Types, Application);
const origin: t.Origin = .{ .local = .{ .uid = 501 } };

const Clock = struct {
    pub fn now(_: *anyopaque) !i64 {
        return 500;
    }
};

fn config() configuration.Config {
    const spec = contracts.specification();
    return .{
        .version = 1,
        .current_uid = 501,
        .namespace_path = "/tmp/unused-continuity",
        .control_socket_path = "/tmp/unused-continuity-socket",
        .repository = .{
            .account = spec.repository.account.bytes,
            .id = spec.repository.id,
            .owner = spec.repository.owner.bytes,
            .name = spec.repository.name.bytes,
            .ref = spec.repository.ref.bytes,
        },
        .slack = .{
            .account = spec.destination.account.bytes,
            .app = spec.destination.app.bytes,
            .workspace = spec.destination.workspace.bytes,
            .operator = spec.destination.operator.bytes,
            .channel = spec.destination.channel.bytes,
            .bot_id = "B123",
        },
    };
}

fn source(f: *Fixture) transfer.Source {
    return .{
        .namespace = f.service.?.namespace.identity,
        .build = @splat(2),
        .image = f.application.?.image_identity,
        .runtime = f.profile.runtime_identity,
        .contracts = @splat(3),
        .clock_ms = 500,
    };
}

fn finish(f: *Fixture, task: t.Id) !void {
    const a = f.arena.allocator();
    var bytes = (try f.service.?.applicationValue(a, task, .input)).?;
    defer bytes.deinit();
    var input = try c.decodeOwned(t.Input, a, bytes.bytes);
    defer input.deinit();
    const operation = switch (input.value) {
        inline else => |value| value.envelope.operation.bytes,
    };
    try std.testing.expectEqualDeep(task, try f.execute(operation, input.value));
}

fn completeAdmissions(f: *Fixture, driver: *Driver) !void {
    var index = try driver.rebuild(f.arena.allocator());
    defer index.deinit();
    for (index.records) |record| {
        if (record.result == null) try finish(f, record.task);
    }
}

fn importDone(f: *Fixture, driver: *Driver, bundle: transfer.Bundle) !void {
    const a = f.arena.allocator();
    const budget = bundle.members.items.len + bundle.lineages.items.len + 3;
    for (0..budget) |_| {
        var progress = try transfer.importBundle(driver, a, config(), origin, bundle, true);
        defer progress.deinit(a);
        if (progress.phase == .materialized) return;
        var index = try driver.rebuild(a);
        defer index.deinit();
        try std.testing.expect(try transfer.importPending(a, &index, source(f).namespace));
        try completeAdmissions(f, driver);
    }
    return error.ImportDidNotComplete;
}

fn importAll(f: *Fixture, driver: *Driver, bundle: transfer.Bundle) !t.Id {
    try importDone(f, driver, bundle);
    var index = try driver.rebuild(f.arena.allocator());
    defer index.deinit();
    return index.obligations[0].task;
}

fn verifyImported(f: *Fixture, driver: *Driver, target: t.Id) !void {
    const a = f.arena.allocator();
    var before = try driver.rebuild(a);
    try std.testing.expect(before.obligation(target).?.recovery_hold);
    try std.testing.expect(!try transfer.pendingControlsAdmitted(a, &before, target));
    try std.testing.expect(!try transfer.importPending(a, &before, source(f).namespace));
    before.deinit();
    const first = try transfer.admitPendingControls(driver, a, target, origin);
    try std.testing.expectEqual(1, first.remaining);
    try finish(f, first.admitted.?);
    const second = try transfer.admitPendingControls(driver, a, target, origin);
    try std.testing.expectEqual(0, second.remaining);
    try finish(f, second.admitted.?);
    const retry = try transfer.admitPendingControls(driver, a, target, origin);
    try std.testing.expect(retry.admitted == null);
    const step = (try driver.nextStep(a, target)).?;
    try finish(f, step);
    var after = try driver.rebuild(a);
    defer after.deinit();
    try std.testing.expect(try transfer.pendingControlsAdmitted(a, &after, target));
    const obligation = after.obligation(target).?;
    try std.testing.expectEqual(2, obligation.directives.len);
    try std.testing.expect(after.records[obligation.directives[0]].input.directive.body == .pause);
    const resumed = after.records[obligation.directives[1]].input.directive;
    try std.testing.expect(resumed.body == .@"resume");
    try std.testing.expect(after.head(obligation).recovery_hold);
    try std.testing.expect(!obligation.ordinaryDispatch());
    try std.testing.expectEqual(.active, after.head(obligation).desired_mode);
}

fn verifyCorruption(a: std.mem.Allocator, bundle: transfer.Bundle) !void {
    const bytes = try c.encodeOwned(transfer.Bundle, a, bundle);
    defer a.free(bytes);
    var changed = try c.decodeOwned(transfer.Bundle, a, bytes);
    defer changed.deinit();
    const root = &@constCast(changed.value.lineages.items)[0];
    for (@constCast(changed.value.members.items)) |*item| {
        if (!std.meta.eql(item.identity, root.head)) continue;
        var head = try continuity.decode(.head, a, item.data);
        defer head.deinit();
        head.value.clock_ms += 1;
        item.data.payload.bytes = try c.encodeOwned(t.Head, a, head.value);
        item.identity = try continuity.digest(a, t.ContinuityData, item.data);
        root.head = item.identity;
        break;
    }
    try std.testing.expectError(
        error.ContinuityPayloadMismatch,
        continuity.validate(a, changed.value),
    );
    changed.value = bundle;
    changed.value.lineages.items = try a.dupe(continuity.Lineage, bundle.lineages.items);
    @constCast(changed.value.lineages.items)[0].pending_controls.items = &.{};
    try std.testing.expectError(
        error.MissingContinuityControl,
        continuity.validate(a, changed.value),
    );
}

test "native continuity import maps pending controls once and resume retains recovery hold" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    _ = try original.directive(a, "old-pause", origin, target, .{ .pause = {} });
    _ = try original.directive(a, "old-resume", origin, target, .{ .@"resume" = {} });
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    try std.testing.expectEqual(2, bundle.value.lineages.items[0].pending_controls.items.len);
    try verifyCorruption(a, bundle.value);
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    const imported = try importAll(&to, &destination, bundle.value);
    try std.testing.expect(!std.meta.eql(imported, target));
    try std.testing.expectEqualDeep(imported, try importAll(&to, &destination, bundle.value));
    try verifyImported(&to, &destination, imported);
    var conflict = bundle.value;
    conflict.source.clock_ms += 1;
    try std.testing.expectError(error.ContinuityLineageConflict, transfer.importBundle(
        &destination,
        a,
        config(),
        origin,
        conflict,
        true,
    ));
    try verifyFiles(a, bundle.value);
}

fn verifyFiles(a: std.mem.Allocator, bundle: transfer.Bundle) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &buffer);
    const directory = buffer[0..length];
    try temporary.dir.setPermissions(std.testing.io, .fromMode(0o700));
    try transfer.validateExportDestination(std.testing.io, directory, "bundle.paredros");
    const digest = try transfer.writeSnapshot(
        a,
        std.testing.io,
        directory,
        "bundle.paredros",
        bundle,
    );
    try std.testing.expectEqualDeep(
        digest,
        try transfer.writeSnapshot(a, std.testing.io, directory, "bundle.paredros", bundle),
    );
    const path = try std.fs.path.join(a, &.{ directory, "bundle.paredros" });
    defer a.free(path);
    var read = try transfer.readBundle(a, std.testing.io, path, null);
    defer read.deinit();
    try std.testing.expect(try continuity.equal(a, transfer.Bundle, bundle, read.value));
    var changed = bundle;
    changed.source.clock_ms += 1;
    try std.testing.expectError(
        error.TransferFileConflict,
        transfer.writeSnapshot(a, std.testing.io, directory, "bundle.paredros", changed),
    );
    try std.testing.expectError(
        error.InvalidTransferPath,
        transfer.writeSnapshot(a, std.testing.io, directory, "../escape", bundle),
    );
    try temporary.dir.setPermissions(std.testing.io, .fromMode(0o755));
    try std.testing.expectError(
        error.UnsafeTransferPath,
        transfer.validateExportDestination(std.testing.io, directory, "new.paredros"),
    );
}

fn slackOrigin() t.Origin {
    const destination = contracts.specification().destination;
    return .{ .slack = .{
        .app = destination.app,
        .workspace = destination.workspace,
        .user = destination.operator,
        .channel = destination.channel,
    } };
}

fn frozenTurn(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    const prior = try driver.turn(a, "prior-complete-turn", origin, .{
        .destination = contracts.specification().destination,
        .text = .{ .bytes = "Earlier operator instruction preserved literally." },
    });
    try finish(f, prior);
    return driver.turn(a, "slack-original-event", slackOrigin(), .{
        .destination = contracts.specification().destination,
        .text = .{ .bytes = "Continue with the frozen prior evidence." },
        .ingress = .{ .stable_request = @splat(19), .timestamp = .{ .bytes = "1700000000.1" } },
    });
}

fn verifyFrozenTurn(f: *Fixture, driver: *Driver, original: t.Turn, task: t.Id) !void {
    const a = f.arena.allocator();
    var index = try driver.rebuild(a);
    defer index.deinit();
    const value = index.record(task).?.input.turn;
    try std.testing.expectEqualStrings(original.context.bytes, value.context.bytes);
    try std.testing.expectEqualStrings(original.text.bytes, value.text.bytes);
    try std.testing.expectEqualDeep(original.proposal_offers, value.proposal_offers);
    try std.testing.expectEqual(original.expected_revision, value.expected_revision);
    try std.testing.expectEqual(1, value.attempt);
    try std.testing.expectEqual(1, value.ordinal);
    try std.testing.expectEqual(.portable_import, value.continuity.?.continuation);
    try std.testing.expectEqual(1, value.context_references.items.len);
    try std.testing.expectEqualDeep(
        value.continuity.?.member.task,
        value.context_references.items[0].task,
    );
    try std.testing.expectEqualDeep(
        task,
        (try transfer.importedIngress(
            a,
            &index,
            "slack-original-event",
            slackOrigin(),
            @splat(19),
        )).?,
    );
    try std.testing.expectError(
        error.OperationConflict,
        transfer.importedIngress(a, &index, "slack-original-event", slackOrigin(), @splat(20)),
    );
    var context = try @import("../native/dialogue.zig").materialize(a, &index, .{
        .destination = contracts.specification().destination,
        .target = null,
    });
    defer context.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        context.value.text.bytes,
        "imported_prior_turn",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        context.value.text.bytes,
        "Earlier operator instruction preserved literally.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        context.value.text.bytes,
        "source_namespace",
    ) != null);
}

test "native continuity global turns preserve frozen context and ingress identity" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    const task = try frozenTurn(&from, &original);
    var before = try original.rebuild(a);
    defer before.deinit();
    const frozen = before.record(task).?.input.turn;
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    try std.testing.expectEqual(0, bundle.value.lineages.items.len);
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    try importDone(&to, &destination, bundle.value);
    var held = try destination.rebuild(a);
    const retained_task = (try transfer.importedIngress(
        a,
        &held,
        "slack-original-event",
        slackOrigin(),
        @splat(19),
    )).?;
    try std.testing.expect(held.record(retained_task).?.input == .continuity_member);
    held.deinit();
    const mapped = try transfer.admitPendingTurns(&destination, a, origin);
    try std.testing.expectEqual(0, mapped.remaining);
    try verifyFrozenTurn(&to, &destination, frozen, mapped.admitted.?);
    try finish(&to, mapped.admitted.?);
    try std.testing.expect((try transfer.admitPendingTurns(
        &destination,
        a,
        origin,
    )).admitted == null);
}

const lineage_contract = @import("../app/lineage_audit_contract.zig");
const history_evidence = @import("../native/history_evidence.zig");
const slack_audit = @import("../native/slack_audit_external.zig");
const preparation = @import("../native/delivery_prepare.zig");
const http = @import("../native/http.zig");

fn externalHistory(a: std.mem.Allocator, audit: t.LineageAudit) ![]u8 {
    var delivery = try preparation.materialize(a, .{
        .destination = audit.destination,
        .key = .{
            .lineage = audit.lineage,
            .purpose = .digest,
            .identity = @splat(71),
            .generation = 9,
        },
        .payload = .{
            .obligation = audit.obligation,
            .specification_revision = 1,
            .prior_sequence = 4,
            .through_sequence = 5,
            .frozen_text = .{ .bytes = "Later marker absent from the local delivery ledger" },
            .prompt = null,
            .supersedes = null,
            .coverage = .{ .sequence = 5, .epoch = 0, .tip = @splat('b') },
        },
    }, .{ .task = @splat(72), .digest = @splat(73) }, @splat(74), "B123");
    defer delivery.deinit();
    const wire = try std.json.parseFromSlice(
        std.json.Value,
        a,
        delivery.value.payload.wire_json.bytes,
        .{},
    );
    defer wire.deinit();
    return std.json.Stringify.valueAlloc(a, .{
        .ok = true,
        .messages = .{.{
            .type = "message",
            .app_id = audit.destination.app.bytes,
            .bot_id = "B123",
            .team = audit.destination.workspace.bytes,
            .ts = "9007199254740993.000001",
            .metadata = wire.value.object.get("metadata").?,
        }},
        .has_more = false,
        .response_metadata = .{ .next_cursor = "" },
    }, .{});
}

fn recordedHistory(a: std.mem.Allocator, prepared: []const u8) ![]u8 {
    var request = try c.decodeOwned(lineage_contract.Request, a, prepared);
    defer request.deinit();
    try std.testing.expect(request.value.audit.latest == null);
    const url = try slack_audit.lineageRequestTarget(a, request.value, "B123");
    defer a.free(url);
    try std.testing.expect(std.mem.find(u8, url, "latest=") == null);
    const body = try externalHistory(a, request.value.audit);
    defer a.free(body);
    const head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
            "X-Slack-Req-Id: transfer-lineage-page\r\n\r\n",
    );
    var reader = std.Io.Reader.fixed(body);
    var captured = try http.captureResponse(a, head, &reader, .{}, "secret-never-retained");
    defer captured.deinit();
    return slack_audit.lineageCaptureBytes(a, prepared, "B123", captured, 500);
}

fn finishHistory(f: *Fixture, task_id: t.Id) !t.Digest {
    const a = f.arena.allocator();
    var capture: ?t.Digest = null;
    for (0..4096) |_| {
        var task = try f.service.?.task(a, task_id);
        defer task.deinit();
        if (task.value.terminal()) {
            try std.testing.expectEqualStrings(
                "moving_window",
                (try f.output(task_id)).lineage_audit.inconclusive.bytes,
            );
            return capture orelse error.MissingHistoryCapture;
        }
        switch (try f.service.?.pump(a)) {
            .work => |work| {
                try std.testing.expectEqualDeep(task_id, work.task);
                try std.testing.expectEqualStrings(
                    lineage_contract.identity,
                    work.entry.declaration.identity,
                );
                try std.testing.expect(capture == null);
                const bytes = try recordedHistory(a, work.prepared orelse
                    return error.MissingPrepared);
                defer a.free(bytes);
                capture = preparation.hash(bytes);
                try f.service.?.completeWork(a, work, .{ .acquired = bytes });
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.HistoryDidNotComplete;
}

const HistoryWitness = struct {
    candidate: history_evidence.Candidate,
    observed: t.Frontier,
    told: t.Frontier,
};

fn scanHistory(f: *Fixture, driver: *Driver, target: t.Id) !HistoryWitness {
    const a = f.arena.allocator();
    const directive = try driver.directive(a, "scan-frontier", origin, target, .{
        .frontier_audit = {},
    });
    try finish(f, directive);
    try finish(f, (try driver.nextStep(a, target)).?);
    var before = try driver.rebuild(a);
    defer before.deinit();
    const previous = before.head(before.obligation(target).?);
    try std.testing.expectEqual(.active, previous.mode);
    try std.testing.expect(previous.next_due_ms <= 500);
    if (f.profile.authority.grants.len != 1) return error.UnexpectedHistoryAuthority;
    try std.testing.expectEqualStrings(lineage_contract.identity, f.profile.authority.grants[0].identity);
    const scans = try driver.audits(a, target);
    defer a.free(scans);
    if (scans.len != 1) return error.LineageScanMissing;
    const captured = try finishHistory(f, scans[0]);
    var after = try driver.rebuild(a);
    defer after.deinit();
    const page = try history_evidence.page(a, &after, target, null, 16);
    if (page.total != 1) return error.LocalLineageCandidateMissing;
    if (page.incomplete_scans != 1) return error.LocalLineageCompletenessMismatch;
    const candidate = page.candidates.items[0];
    try std.testing.expect(candidate.source_namespace == null);
    try std.testing.expectEqualDeep(scans[0], candidate.source.task);
    try std.testing.expectEqual(after.record(scans[0]).?.revision, candidate.source.revision);
    try std.testing.expectEqualDeep(captured, candidate.capture);
    try std.testing.expect(!candidate.matched_admitted_delivery);
    try std.testing.expect(candidate.requires_owner_disposition);
    const current = after.head(after.obligation(target).?);
    try std.testing.expectEqualDeep(previous.observed, current.observed);
    try std.testing.expectEqualDeep(previous.told, current.told);
    return .{ .candidate = candidate, .observed = previous.observed, .told = previous.told };
}

fn verifyTransferredHistory(
    f: *Fixture,
    driver: *Driver,
    target: t.Id,
    namespace: t.Digest,
    witness: HistoryWitness,
) !void {
    const a = f.arena.allocator();
    var index = try driver.rebuild(a);
    defer index.deinit();
    const page = try history_evidence.page(a, &index, target, null, 16);
    if (page.total != 1) return error.ImportedLineageCandidateMissing;
    if (page.scans != 1) return error.ImportedLineageScanMissing;
    if (page.incomplete_scans != 1) return error.ImportedLineageCompletenessMismatch;
    const candidate = page.candidates.items[0];
    try std.testing.expectEqualDeep(namespace, candidate.source_namespace.?);
    try std.testing.expectEqualDeep(witness.candidate.source, candidate.source);
    try std.testing.expectEqualDeep(witness.candidate.capture, candidate.capture);
    try std.testing.expectEqualDeep(witness.candidate.lineage, candidate.lineage);
    try std.testing.expectEqualStrings("9007199254740993.000001", candidate.timestamp.bytes);
    try std.testing.expectEqualStrings(witness.candidate.metadata.bytes, candidate.metadata.bytes);
    try std.testing.expect(!candidate.matched_admitted_delivery);
    try std.testing.expect(candidate.requires_owner_disposition);
    const obligation = index.obligation(target).?;
    const head = index.head(obligation);
    try std.testing.expectEqualDeep(witness.observed, head.observed);
    try std.testing.expectEqualDeep(witness.told, head.told);
    try std.testing.expect(head.recovery_hold);
    try std.testing.expect(obligation.recovery_hold);
    try std.testing.expect(!obligation.ordinaryDispatch());
}

fn resumeOrdinaryCheck(f: *Fixture, driver: *Driver, target: t.Id) !void {
    const a = f.arena.allocator();
    const task_id = (try driver.nextStep(a, target)) orelse return error.MissingDueCheck;
    var saved = (try f.service.?.applicationValue(a, task_id, .input)).?;
    defer saved.deinit();
    var input = try c.decodeOwned(t.Input, a, saved.bytes);
    defer input.deinit();
    try std.testing.expect(!input.value.step.fold_only);
    const github = @import("../app/github_contract.zig").identity;
    const grants = try a.alloc(@import("protean_native").registry.Grant, 2);
    grants[0] = f.profile.authority.grants[0];
    grants[1] = grants[0];
    grants[1].identity = github;
    f.profile.authority.grants = grants;
    f.service.?.profile.authority.grants = grants;
    for (0..4096) |_| switch (try f.service.?.pump(a)) {
        .work => |work| {
            try std.testing.expectEqualDeep(task_id, work.task);
            try std.testing.expectEqualStrings(github, work.entry.declaration.identity);
            try f.service.?.notSent(a, work);
            return;
        },
        .idle, .waiting, .progressed => {},
    };
    return error.MissingOrdinaryAcquisition;
}

test "native continuity transfers captured external lineage marker across import and reopen" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.initWithGrants(&.{lineage_contract.identity});
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    const witness = try scanHistory(&from, &original, target);
    const source_namespace = source(&from).namespace;
    var captured = try transfer.capture(&original, a, source(&from), .snapshot);
    defer captured.deinit();
    const bytes = try c.encodeOwned(transfer.Bundle, a, captured.value);
    defer a.free(bytes);
    var bundle = try c.decodeOwned(transfer.Bundle, a, bytes);
    defer bundle.deinit();
    try resumeOrdinaryCheck(&from, &original, target);
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try destination.attach(to.arena.allocator());
    defer if (destination.attached) destination.detach();
    const imported = try importAll(&to, &destination, bundle.value);
    destination.detach();
    try to.close();
    try to.open();
    destination.service = &to.service.?;
    try destination.attach(to.arena.allocator());
    try verifyTransferredHistory(&to, &destination, imported, source_namespace, witness);
}
