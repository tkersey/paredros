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
        var progress = try transfer.importBundle(driver, a, config(), origin, bundle);
        defer progress.deinit(a);
        if (progress.phase == .materialized) return;
        var index = try driver.rebuild(a);
        defer index.deinit();
        try std.testing.expect(transfer.importPending(&index));
        try completeAdmissions(f, driver);
        _ = try driver.importStep(a);
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
    try std.testing.expect(!transfer.importPending(&before));
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
        .bindings = configuration.bindings(config()),
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
        .bindings = configuration.bindings(config()),
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
        .bindings = configuration.bindings(config()),
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
        .bindings = configuration.bindings(config()),
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
    const waiting = try transfer.admitPendingTurns(&destination, a, origin);
    try std.testing.expect(waiting.admitted == null);
    try std.testing.expectEqual(1, waiting.remaining);
    try releaseImport(&to, &destination);
    const mapped = try transfer.admitPendingTurns(&destination, a, origin);
    try std.testing.expectEqual(0, mapped.remaining);
    try verifyFrozenTurn(&to, &destination, frozen, mapped.admitted.?);
    try finish(&to, mapped.admitted.?);
    try std.testing.expect((try transfer.admitPendingTurns(
        &destination,
        a,
        origin,
    )).admitted == null);
    try importDone(&to, &destination, bundle.value);
}

const restore = @import("../native/restore.zig");
const eligibility = @import("../native/eligibility.zig");

fn releaseImport(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    const boundary = try restore.begin(driver, a, "import-ownership", origin);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expect(index.import_hold and index.recovery_hold);
    const reference: t.InputReference = .{
        .task = boundary,
        .digest = index.record(boundary).?.input_digest,
    };
    _ = try restore.release(driver, a, "import-release", origin, reference, true);
}

fn permitted(driver: *Driver, a: std.mem.Allocator, task: t.Id, capability: []const u8) !bool {
    var index = try driver.rebuild(a);
    defer index.deinit();
    return eligibility.permits(&index, .{
        .task = task,
        .identity = @splat(9),
        .kind = .acquisition,
        .capability = capability,
    });
}

fn replyAdmitted(driver: *Driver, a: std.mem.Allocator, turn: t.Id) !bool {
    const replies = try driver.turnDeliveries(a);
    defer a.free(replies);
    var index = try driver.rebuild(a);
    defer index.deinit();
    const wanted = index.record(turn).?.input.turn.envelope.stable_request;
    for (replies) |task| {
        if (std.meta.eql(index.record(task).?.input.delivery.key.identity, wanted)) return true;
    }
    return false;
}

fn heldAsk(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    const task = try driver.turn(a, "slack-held-event", slackOrigin(), .{
        .destination = contracts.specification().destination,
        .text = .{ .bytes = "Asked before the exclusive ownership release." },
        .ingress = .{ .stable_request = @splat(23), .timestamp = .{ .bytes = "1700000001.1" } },
    });
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expect(index.import_hold and !index.recovery_hold);
    return task;
}

test "native continuity imported output waits for the exclusive ownership release" {
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
        .bindings = configuration.bindings(config()),
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    _ = try frozenTurn(&from, &original);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    try importDone(&to, &destination, bundle.value);
    try expectImportHold(a, &destination, true);
    const model = @import("../app/model_contract.zig").P.identity;
    const asked = try heldAsk(&to, &destination);
    try std.testing.expect(!try permitted(&destination, a, asked, model));
    try std.testing.expect(!try destination.importedTurns(a));
    try finish(&to, asked);
    try std.testing.expect(!try replyAdmitted(&destination, a, asked));
    try releaseImport(&to, &destination);
    try expectImportHold(a, &destination, false);
    try std.testing.expect(try permitted(&destination, a, asked, model));
    try std.testing.expect(try destination.importedTurns(a));
    var index = try destination.rebuild(a);
    const imported = (try transfer.importedIngress(
        a,
        &index,
        "slack-original-event",
        slackOrigin(),
        @splat(19),
    )).?;
    try std.testing.expect(index.record(imported).?.input == .turn);
    index.deinit();
    try std.testing.expect(try permitted(&destination, a, imported, model));
    try finish(&to, imported);
    try std.testing.expect(try replyAdmitted(&destination, a, imported));
}

const control = @import("../native/control.zig");
const experiment_codec = @import("../app/experiment_contract.zig").codec_identity;

fn recordCount(a: std.mem.Allocator, driver: *Driver) !usize {
    var index = try driver.rebuild(a);
    defer index.deinit();
    return index.records.len;
}

fn refusedCommand(
    a: std.mem.Allocator,
    driver: *Driver,
    operation: []const u8,
    command: @FieldType(control.Request, "command"),
) !void {
    const bytes = try control.encode(a, .{
        .version = 1,
        .operation = .{ .bytes = operation },
        .command = command,
    });
    const reply = try control.dispatch(a, driver, config(), 501, bytes);
    const value = (try @import("protean_native").json.parse(a, reply, .{})).value.object;
    try std.testing.expectEqualStrings("rejected", value.get("status").?.string);
    try std.testing.expectEqualStrings("ContinuityImportHeld", value.get("error").?.string);
}

fn refusedOutputIngress(a: std.mem.Allocator, driver: *Driver) !void {
    const before = try recordCount(a, driver);
    try refusedCommand(a, driver, "held-ask", .{ .ask = .{
        .text = .{ .bytes = "status?" },
        .target = null,
    } });
    try refusedCommand(a, driver, "held-monitor", .{ .monitor_add = .{
        .wording = .{ .bytes = "watch" },
        .interval_ms = null,
    } });
    try std.testing.expectEqual(before, try recordCount(a, driver));
}

fn heldExperiment(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    const admitted = try f.service.?.submit(a, "held-live-experiment", .{ .experiment = .{
        .envelope = .{
            .operation = .{ .bytes = "held-live-experiment" },
            .stable_request = @splat(29),
            .origin = origin,
        },
        .campaign = @splat(30),
        .attempt = 1,
        .plan = .{ .bytes = "plan" },
        .evidence = .{ .items = &.{} },
        .live_model = true,
    } });
    const model = @import("../app/model_contract.zig").P.identity;
    try std.testing.expect(!try permitted(driver, a, admitted.receipt.task, model));
    try std.testing.expect(try permitted(driver, a, admitted.receipt.task, experiment_codec));
    return admitted.receipt.task;
}

test "native continuity refuses boundaries until materialized and output ingress until released" {
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
        .bindings = configuration.bindings(config()),
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    _ = try frozenTurn(&from, &original);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    var progress = try transfer.importBundle(&destination, a, config(), origin, bundle.value);
    progress.deinit(a);
    const before = try recordCount(a, &destination);
    try std.testing.expectError(
        error.ContinuityImportPending,
        restore.begin(&destination, a, "boundary-during-import", origin),
    );
    try std.testing.expectEqual(before, try recordCount(a, &destination));
    try importDone(&to, &destination, bundle.value);
    try refusedOutputIngress(a, &destination);
    const experiment = try heldExperiment(&to, &destination);
    try releaseImport(&to, &destination);
    try expectImportHold(a, &destination, false);
    const model = @import("../app/model_contract.zig").P.identity;
    try std.testing.expect(try permitted(&destination, a, experiment, model));
}

fn expectImportHold(a: std.mem.Allocator, driver: *Driver, expected: bool) !void {
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(expected, index.import_hold);
}

fn secondGenesis() t.Genesis {
    var value = contracts.genesis();
    value.envelope.operation = .{ .bytes = "local-genesis-second" };
    value.envelope.stable_request = @splat(9);
    value.lineage = @splat(10);
    return value;
}

fn importInterleaved(f: *Fixture, driver: *Driver, bundle: transfer.Bundle) !void {
    const a = f.arena.allocator();
    const budget = bundle.members.items.len + 2 * bundle.lineages.items.len + 3;
    for (0..budget) |_| {
        var progress = try transfer.importBundle(driver, a, config(), origin, bundle);
        defer progress.deinit(a);
        if (progress.phase == .materialized) return;
        try completeAdmissions(f, driver);
        _ = try driver.importStep(a);
        try completeAdmissions(f, driver);
        var index = try driver.rebuild(a);
        defer index.deinit();
        for (index.obligations) |obligation| {
            _ = try transfer.admitPendingControls(driver, a, obligation.task, origin);
        }
        try completeAdmissions(f, driver);
    }
    return error.ImportDidNotComplete;
}

test "native continuity import completes every lineage while imported obligations act" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const first = contracts.genesis();
    const second = secondGenesis();
    const targets = [_]t.Id{
        try from.execute(first.envelope.operation.bytes, .{ .genesis = first }),
        try from.execute(second.envelope.operation.bytes, .{ .genesis = second }),
    };
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    _ = try original.directive(a, "old-pause-first", origin, targets[0], .{ .pause = {} });
    _ = try original.directive(a, "old-pause-second", origin, targets[1], .{ .pause = {} });
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    try std.testing.expectEqual(2, bundle.value.lineages.items.len);
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    try importInterleaved(&to, &destination, bundle.value);
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(2, index.obligations.len);
    try std.testing.expect(!transfer.importPending(&index));
}

fn cancelledWithLateControl(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    const genesis = contracts.genesis();
    const target = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    try driver.attach(a);
    _ = try driver.directive(a, "old-cancel", origin, target, .{ .cancel = {} });
    const step = (try driver.nextStep(a, target)).?;
    _ = try driver.directive(a, "late-pause", origin, target, .{ .pause = {} });
    try finish(f, step);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(.cancelled, index.head(index.obligation(target).?).mode);
    return target;
}

test "native continuity import keeps controls under a cancelled head historical" {
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
        .bindings = configuration.bindings(config()),
    };
    defer if (original.attached) original.detach();
    _ = try cancelledWithLateControl(&from, &original);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    try std.testing.expectEqual(1, bundle.value.lineages.items[0].pending_controls.items.len);
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    const imported = try importAll(&to, &destination, bundle.value);
    const progress = try transfer.admitPendingControls(&destination, a, imported, origin);
    try std.testing.expect(progress.admitted == null);
    try std.testing.expect(!try destination.importedControls(a, imported));
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expect(try transfer.pendingControlsAdmitted(a, &index, imported));
    try std.testing.expectEqual(.cancelled, index.head(index.obligation(imported).?).mode);
}

const continuity_control = @import("../native/continuity_control.zig");

const Backup = struct {
    temporary: std.testing.TmpDir,
    buffer: [4096]u8 = undefined,
    length: usize = 0,

    fn init() !Backup {
        var value: Backup = .{ .temporary = std.testing.tmpDir(.{}) };
        try value.temporary.dir.setPermissions(std.testing.io, .fromMode(0o700));
        return value;
    }

    fn path(self: *Backup) ![]const u8 {
        self.length = try self.temporary.dir.realPath(std.testing.io, &self.buffer);
        return self.buffer[0..self.length];
    }
};

test "native continuity control import commits one manifest for one bundle" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    _ = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try original.attach(a);
    defer if (original.attached) original.detach();
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const directory = try backup.path();
    _ = try transfer.writeSnapshot(a, std.testing.io, directory, "handoff.paredros", bundle.value);
    const file = try std.fs.path.join(a, &.{ directory, "handoff.paredros" });
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    const manifest = try controlImport(&to, &destination, file);
    var index = try destination.rebuild(a);
    defer index.deinit();
    var cuts: usize = 0;
    for (index.records) |record| {
        if (record.input == .continuity_cut) cuts += 1;
    }
    try std.testing.expectEqual(1, cuts);
    try std.testing.expect(index.record(manifest).?.input == .continuity_cut);
}

fn controlImport(f: *Fixture, driver: *Driver, file: []const u8) !t.Id {
    const a = f.arena.allocator();
    const environment: continuity_control.Environment = .{
        .io = std.testing.io,
        .source = source(f),
    };
    var manifest: ?t.Id = null;
    for (0..16) |_| {
        var progress = try continuity_control.importBundle(
            driver,
            a,
            config(),
            environment,
            "legacy-import",
            origin,
            .{ .path = .{ .bytes = file } },
        );
        defer progress.deinit(a);
        if (manifest) |known| try std.testing.expectEqualDeep(known, progress.manifest);
        manifest = progress.manifest;
        if (progress.phase == .materialized) return progress.manifest;
        try completeAdmissions(f, driver);
        _ = try driver.importStep(a);
    }
    return error.ImportDidNotComplete;
}

test "native continuity export refuses an occupied name before fencing the source" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const genesis = contracts.genesis();
    const target = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var driver: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try driver.attach(a);
    defer driver.detach();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    try backup.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "handoff.paredros",
        .data = "an earlier handoff",
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    var settings = config();
    settings.backup_directory = try backup.path();
    const environment: continuity_control.Environment = .{
        .io = std.testing.io,
        .source = source(&f),
    };
    for ([_]bool{ false, true }) |snapshot| {
        try std.testing.expectError(error.TransferFileConflict, continuity_control.exportBundle(
            &driver,
            a,
            settings,
            environment,
            if (snapshot) "occupied-snapshot" else "occupied-transfer",
            origin,
            .{ .name = .{ .bytes = "handoff.paredros" }, .snapshot = snapshot },
        ));
    }
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expect(index.recovery_purpose == null);
    try std.testing.expectEqual(1, index.records.len);
    try std.testing.expectEqual(.active, index.head(index.obligation(target).?).mode);
}

fn exportWritten(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    operation: []const u8,
    name: []const u8,
) !continuity_control.ExportProgress {
    const a = f.arena.allocator();
    const environment: continuity_control.Environment = .{
        .io = std.testing.io,
        .source = source(f),
    };
    for (0..16) |_| {
        const progress = try continuity_control.exportBundle(
            driver,
            a,
            settings,
            environment,
            operation,
            origin,
            .{ .name = .{ .bytes = name }, .snapshot = true },
        );
        if (progress.phase == .written) return progress;
        try completeAdmissions(f, driver);
    }
    return error.ExportDidNotComplete;
}

test "native continuity repeated snapshot exports do not embed earlier cuts" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const genesis = contracts.genesis();
    _ = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var driver: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(a);
    defer driver.detach();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    var sizes: [3]u64 = undefined;
    for (&sizes, [_][]const u8{ "nightly-1", "nightly-2", "nightly-3" }) |*size, name| {
        _ = try exportWritten(&f, &driver, settings, name, name);
        size.* = (try backup.temporary.dir.statFile(std.testing.io, name, .{})).size;
    }
    try std.testing.expectEqual(sizes[0], sizes[1]);
    try std.testing.expectEqual(sizes[0], sizes[2]);
}

fn verifyCarried(driver: *Driver, a: std.mem.Allocator, bundle: transfer.Bundle) !void {
    var index = try driver.rebuild(a);
    defer index.deinit();
    const manifest = index.records[index.continuity_import.?.position].task;
    for (bundle.cut.items) |row| try std.testing.expect(!std.meta.eql(row.task, manifest));
    var carried: usize = 0;
    for (bundle.members.items) |item| {
        if (item.data.kind == .settlement) if (index.record(item.data.source.task)) |record| {
            try std.testing.expect(record.input != .continuity_cut);
            try std.testing.expect(record.input != .continuity_member);
        };
        const producer = index.record(item.current.task).?;
        if (producer.input == .continuity_member) carried += 1;
    }
    try std.testing.expectEqual(index.continuity_import.?.members, carried);
}

fn importTurnChain(f: *Fixture, driver: *Driver, bundle: transfer.Bundle) !void {
    const a = f.arena.allocator();
    try importDone(f, driver, bundle);
    try releaseImport(f, driver);
    const mapped = try transfer.admitPendingTurns(driver, a, origin);
    try finish(f, mapped.admitted.?);
}

test "native continuity re-export carries imported members once without earlier bundles" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    var third: Fixture = .{};
    defer third.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    _ = try original.directive(a, "chain-pause", origin, target, .{ .pause = {} });
    _ = try frozenTurn(&from, &original);
    var first = try transfer.capture(&original, a, source(&from), .snapshot);
    defer first.deinit();
    original.detach();
    try from.close();
    try to.init();
    var middle: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try middle.attach(to.arena.allocator());
    try importTurnChain(&to, &middle, first.value);
    var second = try transfer.capture(&middle, a, source(&to), .snapshot);
    defer second.deinit();
    const first_bytes = try c.encodeOwned(transfer.Bundle, a, first.value);
    const second_bytes = try c.encodeOwned(transfer.Bundle, a, second.value);
    try std.testing.expect(second_bytes.len < 3 * first_bytes.len);
    try verifyCarried(&middle, a, second.value);
    middle.detach();
    try to.close();
    try third.init();
    var last: Driver = .{
        .service = &third.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try last.attach(third.arena.allocator());
    defer last.detach();
    const imported = try importAll(&third, &last, second.value);
    var index = try last.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(1, index.obligations.len);
    try std.testing.expectEqualDeep(imported, index.obligations[0].task);
    try std.testing.expect(!transfer.importPending(&index));
}

const daemon_module = @import("../native/daemon.zig");
const Daemon = daemon_module.Daemon(app.Types);
const socket = @import("../native/control_socket.zig");

const NoControl = struct {
    fn call(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: *Driver,
        _: u32,
        _: []const u8,
    ) ![]const u8 {
        return error.UnexpectedControl;
    }
};

fn importView(driver: *Driver) !?continuity.ImportView {
    var index = try driver.rebuild(std.testing.allocator);
    defer index.deinit();
    const view = index.continuity_import orelse return null;
    return .{
        .position = view.position,
        .digest = view.digest,
        .phase = view.phase,
        .members = view.members,
    };
}

fn daemonImport(f: *Fixture, driver: *Driver, partial: bool) !continuity.ImportPhase {
    const path = try std.fs.path.join(f.arena.allocator(), &.{
        std.testing.TmpDir.parent_dir_path, &f.temporary.?.sub_path, "control",
    });
    var server = try socket.Server.init(std.testing.allocator, path, .{
        .operator_uid = socket.currentUid(),
    });
    defer server.deinit();
    var frame = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame.deinit();
    var context: u8 = 0;
    var daemon = try Daemon.init(frame.allocator(), driver, &server, .{
        .context = &context,
        .call = NoControl.call,
    }, .{});
    var phase: continuity.ImportPhase = .manifest_pending;
    for (0..20_000) |_| {
        _ = frame.reset(.retain_capacity);
        _ = try daemon.poll(frame.allocator(), 0);
        const view = (try importView(driver)).?;
        phase = view.phase;
        if (phase == .materialized) break;
        if (partial and phase == .members_pending and view.members != 0) break;
    }
    daemon.beginStop(0);
    for (0..10_000) |_| {
        _ = frame.reset(.retain_capacity);
        const result = try daemon.poll(frame.allocator(), 0);
        if (result == .stopped or result == .stopped_unclean) break;
    } else return error.DaemonDidNotStop;
    try daemon.deinit();
    return phase;
}

test "native continuity daemon materializes an admitted import across restart" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const first = contracts.genesis();
    const second = secondGenesis();
    const targets = [_]t.Id{
        try from.execute(first.envelope.operation.bytes, .{ .genesis = first }),
        try from.execute(second.envelope.operation.bytes, .{ .genesis = second }),
    };
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    _ = try original.directive(a, "daemon-pause-first", origin, targets[0], .{ .pause = {} });
    _ = try original.directive(a, "daemon-pause-second", origin, targets[1], .{ .pause = {} });
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    var admitted = try transfer.importBundle(&destination, a, config(), origin, bundle.value);
    admitted.deinit(a);
    destination.detach();
    try std.testing.expectEqual(.members_pending, try daemonImport(&to, &destination, true));
    try to.close();
    try to.open();
    destination.service = &to.service.?;
    try std.testing.expectEqual(.materialized, try daemonImport(&to, &destination, false));
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(2, index.obligations.len);
    try std.testing.expectEqual(2, index.imports.len);
    try std.testing.expect(!transfer.importPending(&index));
}

test "native continuity export refuses while an import is incomplete" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    _ = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    var admitted = try transfer.importBundle(&destination, a, config(), origin, bundle.value);
    admitted.deinit(a);
    try completeAdmissions(&to, &destination);
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    const environment: continuity_control.Environment = .{
        .io = std.testing.io,
        .source = source(&to),
    };
    for ([_]bool{ false, true }) |snapshot| {
        try std.testing.expectError(error.ContinuityImportPending, continuity_control.exportBundle(
            &destination,
            a,
            settings,
            environment,
            if (snapshot) "pending-snapshot" else "pending-transfer",
            origin,
            .{ .name = .{ .bytes = "early.paredros" }, .snapshot = snapshot },
        ));
    }
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expect(index.recovery_purpose == null);
    try std.testing.expectError(error.FileNotFound, backup.temporary.dir.statFile(
        std.testing.io,
        "early.paredros",
        .{},
    ));
}

fn fileImport(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    operation: []const u8,
    file: []const u8,
) !transfer.ImportProgress {
    return continuity_control.importBundle(
        driver,
        f.arena.allocator(),
        settings,
        .{ .io = std.testing.io, .source = source(f) },
        operation,
        origin,
        .{ .path = .{ .bytes = file } },
    );
}

fn importFixture(from: *Fixture, to: *Fixture, directory: []const u8) !transfer.OwnedBundle {
    const a = from.arena.allocator();
    try from.init();
    const genesis = contracts.genesis();
    _ = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    const bundle = try transfer.capture(&original, a, source(from), .snapshot);
    _ = try transfer.writeSnapshot(a, std.testing.io, directory, "handoff.paredros", bundle.value);
    original.detach();
    try from.close();
    try to.init();
    return bundle;
}

test "native continuity import operation conflicts when its file changes" {
    var from: Fixture = .{};
    defer from.deinit();
    var to: Fixture = .{};
    defer to.deinit();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const directory = try backup.path();
    var bundle = try importFixture(&from, &to, directory);
    defer bundle.deinit();
    const a = to.arena.allocator();
    const file = try std.fs.path.join(a, &.{ directory, "handoff.paredros" });
    var clock: u8 = 0;
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try destination.attach(a);
    defer destination.detach();
    var progress = try fileImport(&to, &destination, config(), "same-import", file);
    progress.deinit(a);
    try completeAdmissions(&to, &destination);
    try backup.temporary.dir.deleteFile(std.testing.io, "handoff.paredros");
    var changed = bundle.value;
    changed.source.clock_ms += 1;
    _ = try transfer.writeSnapshot(a, std.testing.io, directory, "handoff.paredros", changed);
    try std.testing.expectError(
        error.OperationConflict,
        fileImport(&to, &destination, config(), "same-import", file),
    );
    var index = try destination.rebuild(a);
    defer index.deinit();
    var cuts: usize = 0;
    for (index.records) |record| {
        if (record.input == .continuity_cut) cuts += 1;
    }
    try std.testing.expectEqual(1, cuts);
}

test "native continuity import validates destination after manifest admission" {
    var from: Fixture = .{};
    defer from.deinit();
    var to: Fixture = .{};
    defer to.deinit();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const directory = try backup.path();
    var bundle = try importFixture(&from, &to, directory);
    defer bundle.deinit();
    const a = to.arena.allocator();
    const file = try std.fs.path.join(a, &.{ directory, "handoff.paredros" });
    var clock: u8 = 0;
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try destination.attach(a);
    defer destination.detach();
    var progress = try fileImport(&to, &destination, config(), "bound-import", file);
    progress.deinit(a);
    try completeAdmissions(&to, &destination);
    var moved = config();
    moved.slack.channel = "D999";
    for ([_][]const u8{ "bound-import", "rebound-import" }) |operation| {
        try std.testing.expectError(
            error.ContinuityResourceMismatch,
            fileImport(&to, &destination, moved, operation, file),
        );
    }
    destination.bindings = configuration.bindings(moved);
    try std.testing.expect(!try destination.importStep(a));
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(0, index.continuity_import.?.members);
    try std.testing.expectEqual(0, index.obligations.len);
}

const delivery_target = @import("../native/delivery_target.zig");

fn pendingGenesis(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    for (0..64) |_| {
        var index = try driver.rebuild(a);
        defer index.deinit();
        if (index.continuity_import.?.phase == .genesis_pending) break;
        _ = try driver.importStep(a);
        try completeAdmissions(f, driver);
    } else return error.ImportDidNotAdvance;
    try std.testing.expect(try driver.importStep(a));
    for (0..4096) |_| {
        var index = try driver.rebuild(std.testing.allocator);
        defer index.deinit();
        var pending: ?t.Id = null;
        var completed: usize = 0;
        for (index.records) |record| {
            if (record.input != .genesis) continue;
            if (record.result == null) pending = record.task else completed += 1;
        }
        if (completed == 2) return error.BothGenesesCompleted;
        if (completed == 1) return pending orelse error.MissingPendingGenesis;
        switch (try f.service.?.pump(a)) {
            .work => |work| {
                try f.service.?.notSent(a, work);
                return error.UnexpectedExternalWork;
            },
            .idle, .waiting, .progressed => {},
        }
    }
    return error.GenesisDidNotComplete;
}

test "native continuity delivery target ignores lineages whose genesis is pending" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const first = contracts.genesis();
    const second = secondGenesis();
    const targets = [_]t.Id{
        try from.execute(first.envelope.operation.bytes, .{ .genesis = first }),
        try from.execute(second.envelope.operation.bytes, .{ .genesis = second }),
    };
    var clock: u8 = 0;
    var original: Driver = .{
        .service = &from.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try original.attach(a);
    for (targets) |target| try std.testing.expectEqual(1, (try original.deliveries(a, target)).len);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    try to.init();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    var admitted = try transfer.importBundle(&destination, a, config(), origin, bundle.value);
    admitted.deinit(a);
    try completeAdmissions(&to, &destination);
    const pending = try pendingGenesis(&to, &destination);
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(1, index.imports.len);
    try std.testing.expectEqual(1, index.obligations.len);
    const lineage = index.record(pending).?.input.genesis.lineage;
    var checked: usize = 0;
    for (bundle.value.members.items) |item| {
        if (item.data.kind != .delivery or !std.meta.eql(item.data.lineage, lineage)) continue;
        var delivery = try continuity.decode(.delivery, a, item.data);
        defer delivery.deinit();
        _ = delivery_target.auditTarget(&index, delivery.value.input);
        checked += 1;
    }
    try std.testing.expect(checked != 0);
    _ = try destination.nextStep(a, index.obligations[0].task);
}

fn exportAs(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    operation: []const u8,
    request: continuity_control.Export,
) !continuity_control.ExportProgress {
    return continuity_control.exportBundle(
        driver,
        f.arena.allocator(),
        settings,
        .{ .io = std.testing.io, .source = source(f) },
        operation,
        origin,
        request,
    );
}

test "native continuity export retries resume the pending cut for one name" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const genesis = contracts.genesis();
    _ = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var driver: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
    };
    try driver.attach(f.arena.allocator());
    defer driver.detach();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    const request: continuity_control.Export = .{
        .name = .{ .bytes = "retry.paredros" },
        .snapshot = true,
    };
    const started = try exportAs(&f, &driver, settings, "snapshot-first", request);
    try std.testing.expectEqual(.cut_pending, started.phase);
    const retried = try exportAs(&f, &driver, settings, "snapshot-retry", request);
    try std.testing.expectEqualDeep(started.cut, retried.cut);
    try std.testing.expectEqualStrings("snapshot-first", retried.operation.bytes);
    try completeAdmissions(&f, &driver);
    const written = try exportWritten(&f, &driver, settings, "snapshot-first", "retry.paredros");
    try std.testing.expectEqualDeep(started.cut, written.cut);
    try std.testing.expectError(
        error.TransferFileConflict,
        exportAs(&f, &driver, settings, "snapshot-again", request),
    );
    const fenced = try exportAs(&f, &driver, settings, "transfer-first", .{
        .name = .{ .bytes = "first.paredros" },
    });
    try std.testing.expectEqual(.finalizing, fenced.phase);
    const resumed = try exportAs(&f, &driver, settings, "transfer-renamed", .{
        .name = .{ .bytes = "renamed.paredros" },
    });
    try std.testing.expectEqualStrings("transfer-first", resumed.operation.bytes);
}

const commands = @import("../native/commands.zig");
const Monitored = struct { bundle: transfer.OwnedBundle, local: t.Genesis };

fn monitoredSource(f: *Fixture, clock: *u8) !Monitored {
    const a = f.arena.allocator();
    var original: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try original.attach(a);
    defer original.detach();
    const spec = contracts.specification();
    const target = try commands.monitor(&original, a, "monitor-retry", origin, spec);
    try finish(f, target);
    try std.testing.expectEqualDeep(
        target,
        try commands.monitor(&original, a, "monitor-retry", origin, spec),
    );
    var index = try original.rebuild(a);
    defer index.deinit();
    const bytes = try c.encodeOwned(t.Genesis, a, index.record(target).?.input.genesis);
    return .{
        .bundle = try transfer.capture(&original, a, source(f), .snapshot),
        .local = (try c.decodeOwned(t.Genesis, a, bytes)).value,
    };
}

fn expectOneLineage(driver: *Driver, a: std.mem.Allocator, imported: t.Id) !void {
    try std.testing.expectEqualDeep(
        imported,
        try commands.monitor(driver, a, "monitor-retry", origin, contracts.specification()),
    );
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(1, index.obligations.len);
    try std.testing.expectEqualDeep(imported, index.obligations[0].task);
}

test "native continuity monitor add retried after import returns the imported obligation" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    var clock: u8 = 0;
    var source_state = try monitoredSource(&from, &clock);
    defer source_state.bundle.deinit();
    try from.close();
    try to.init();
    const a = to.arena.allocator();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(a);
    defer destination.detach();
    const imported = try importAll(&to, &destination, source_state.bundle.value);
    try expectOneLineage(&destination, a, imported);
    try expectOneLineage(&destination, a, imported);
    try std.testing.expect(try to.service.?.operationLookup(a, "monitor-retry") == null);
    _ = try destination.directive(a, "monitor-retry", origin, imported, .{ .pause = {} });
    try std.testing.expectError(
        error.OperationConflict,
        commands.monitor(&destination, a, "monitor-retry", origin, contracts.specification()),
    );
}

test "native continuity rebuild keeps the imported lineage over an exact local replay" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    var clock: u8 = 0;
    var source_state = try monitoredSource(&from, &clock);
    defer source_state.bundle.deinit();
    try from.close();
    try to.init();
    const a = to.arena.allocator();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(a);
    defer destination.detach();
    const imported = try importAll(&to, &destination, source_state.bundle.value);
    const replay = try to.execute("monitor-retry", .{ .genesis = source_state.local });
    try std.testing.expect(!std.meta.eql(replay, imported));
    try expectOneLineage(&destination, a, imported);
    var forked = source_state.local;
    forked.envelope.operation = .{ .bytes = "monitor-fork" };
    _ = try to.execute("monitor-fork", .{ .genesis = forked });
    try std.testing.expectError(error.DuplicateLineage, destination.rebuild(a));
}

fn controlMonitor(
    a: std.mem.Allocator,
    driver: *Driver,
    operation: []const u8,
    wording: []const u8,
) !@import("protean_native").json.Value {
    const bytes = try control.encode(a, .{
        .version = 1,
        .operation = .{ .bytes = operation },
        .command = .{ .monitor_add = .{ .wording = .{ .bytes = wording }, .interval_ms = null } },
    });
    const reply = try control.dispatch(a, driver, config(), 501, bytes);
    return (try @import("protean_native").json.parse(a, reply, .{})).value;
}

fn controlTask(a: std.mem.Allocator, driver: *Driver, operation: []const u8) !t.Id {
    const reply = (try controlMonitor(a, driver, operation, "watch")).object;
    try std.testing.expectEqualStrings("admitted", reply.get("status").?.string);
    const task = reply.get("data").?.object.get("task").?.string;
    return @import("../native/cli.zig").hex(t.Id, task);
}

fn controlRefused(
    a: std.mem.Allocator,
    driver: *Driver,
    operation: []const u8,
    wording: []const u8,
    expected: []const u8,
) !void {
    const reply = (try controlMonitor(a, driver, operation, wording)).object;
    try std.testing.expectEqualStrings("rejected", reply.get("status").?.string);
    try std.testing.expectEqualStrings(expected, reply.get("error").?.string);
}

fn controlSource(f: *Fixture, clock: *u8) !transfer.OwnedBundle {
    const a = f.arena.allocator();
    var original: Driver = .{
        .service = &f.service.?,
        .clock = .{ .context = clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try original.attach(a);
    defer original.detach();
    const target = try controlTask(a, &original, "monitor-retry");
    try finish(f, target);
    return transfer.capture(&original, a, source(f), .snapshot);
}

test "native continuity control monitor add retried under the import hold returns the import" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    var clock: u8 = 0;
    var bundle = try controlSource(&from, &clock);
    defer bundle.deinit();
    try from.close();
    try to.init();
    const a = to.arena.allocator();
    var destination: Driver = .{
        .service = &to.service.?,
        .clock = .{ .context = &clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
    try destination.attach(a);
    defer destination.detach();
    const imported = try importAll(&to, &destination, bundle.value);
    try expectImportHold(a, &destination, true);
    const before = try recordCount(a, &destination);
    try std.testing.expectEqualDeep(imported, try controlTask(a, &destination, "monitor-retry"));
    try controlRefused(a, &destination, "monitor-retry", "watch more", "ContinuityImportHeld");
    try controlRefused(a, &destination, "monitor-fresh", "watch", "ContinuityImportHeld");
    try std.testing.expectEqual(before, try recordCount(a, &destination));
    _ = try destination.directive(a, "monitor-reused", origin, imported, .{ .pause = {} });
    try controlRefused(a, &destination, "monitor-reused", "watch", "OperationConflict");
    try std.testing.expectEqualDeep(imported, try controlTask(a, &destination, "monitor-retry"));
    try expectImportHold(a, &destination, true);
}
