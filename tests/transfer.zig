const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const contracts = @import("contracts.zig");
const transfer = @import("../native/transfer.zig");
const continuity = @import("../native/continuity.zig");
const configuration = @import("../native/configuration.zig");
const app = @import("../native/application.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);
const Fixture = @import("product_fixture.zig").Fixture;
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
