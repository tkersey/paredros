const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const contracts = @import("contracts.zig");
const transfer = @import("../native/transfer.zig");
const continuity = @import("../native/continuity.zig");
const compatibility = @import("../native/compatibility.zig");
const cli = @import("../native/cli.zig");
const configuration = @import("../native/configuration.zig");
const app = @import("../native/application.zig");
const Driver = @import("../native/driver.zig").Driver(app.Types);
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};
const Fixture = @import("native_fixture.zig").Fixture(app.Types, Application);
const continuity_control = @import("../native/continuity_control.zig");
const fake = @import("github_fake.zig");
const messages = @import("../native/messages.zig");
const GithubFixture = @import("native_fixture.zig").Fixture(app.Types, fake.Application);
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
    };
}

fn source(f: anytype) transfer.Source {
    return .{
        .namespace = f.service.?.namespace.identity,
        .build = @splat(2),
        .image = compatibility.ImageDigest.of(f.assets.image),
        .runtime = f.profile.runtime_identity,
        .contracts = @splat(3),
        .clock_ms = 500,
    };
}

fn finish(f: anytype, task: t.Id) !void {
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

fn completeAdmissions(f: anytype, driver: *Driver) !void {
    var index = try driver.rebuild(f.arena.allocator());
    defer index.deinit();
    for (index.records) |record| {
        if (record.result == null) try finish(f, record.task);
    }
}

fn writeBundle(
    a: std.mem.Allocator,
    directory: std.Io.Dir,
    name: []const u8,
    bundle: transfer.Bundle,
) !void {
    try directory.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = try c.encodeOwned(transfer.Bundle, a, bundle),
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}

fn importBundle(f: anytype, driver: *Driver, bundle: transfer.Bundle) !transfer.ImportProgress {
    const a = f.arena.allocator();
    const identity = continuity.hash(try c.encodeOwned(transfer.Bundle, a, bundle));
    const name = try std.fmt.allocPrint(a, "{s}.paredros", .{
        std.fmt.bytesToHex(identity, .lower),
    });
    try writeBundle(a, f.temporary.?.dir, name, bundle);
    const file = try std.fs.path.join(a, &.{ std.fs.path.dirname(f.path).?, name });
    const operation = try std.fmt.allocPrint(a, "import:{s}", .{name});
    return fileImport(f, driver, config(), operation, file);
}

fn onlyObligation(bundle: transfer.Bundle) !continuity.Obligation {
    var found: ?continuity.Obligation = null;
    for (bundle.members.items) |item| {
        if (item != .obligation) continue;
        try std.testing.expect(found == null);
        found = item.obligation;
    }
    return found orelse error.MissingContinuityObligation;
}

fn obligationCount(bundle: transfer.Bundle) usize {
    var count: usize = 0;
    for (bundle.members.items) |item| {
        if (item == .obligation) count += 1;
    }
    return count;
}

fn importDone(f: anytype, driver: *Driver, bundle: transfer.Bundle) !void {
    const a = f.arena.allocator();
    const budget = bundle.members.items.len + 4;
    for (0..budget) |_| {
        var progress = try importBundle(f, driver, bundle);
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
    try std.testing.expect(before.obligation(target).?.controls_pending);
    try std.testing.expect(!before.obligation(target).?.ordinaryDispatch());
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
    try std.testing.expectEqual(.active, after.head(obligation).mode);
    try std.testing.expect(obligation.ordinaryDispatch());
    try std.testing.expectEqual(.active, after.head(obligation).desired_mode);
}

fn rehead(
    a: std.mem.Allocator,
    bundle: transfer.Bundle,
    comptime edit: fn (*t.Head) void,
    digested: bool,
) !transfer.Bundle {
    const changed = (try c.decodeOwned(
        transfer.Bundle,
        a,
        try c.encodeOwned(transfer.Bundle, a, bundle),
    )).value;
    for (@constCast(changed.members.items), @constCast(changed.manifest.items)) |*item, *key| {
        if (item.* != .obligation or item.obligation.state != .head) continue;
        edit(&item.obligation.state.head.head);
        if (digested) key.* = try continuity.digest(a, continuity.Member, item.*);
    }
    return changed;
}

fn later(head: *t.Head) void {
    head.clock_ms += 1;
}

fn attached(head: *t.Head) void {
    head.predecessor = .{ .task = @splat(0xee), .digest = @splat(0xef) };
}

fn verifyCorruption(a: std.mem.Allocator, bundle: transfer.Bundle) !void {
    try std.testing.expectError(
        error.ContinuityDigestMismatch,
        continuity.validate(a, try rehead(a, bundle, later, false)),
    );
    try std.testing.expectError(
        error.AttachedContinuityReference,
        continuity.validate(a, try rehead(a, bundle, attached, true)),
    );
    var listed = bundle;
    listed.manifest.items = bundle.manifest.items[1..];
    try std.testing.expectError(error.ContinuityManifestMismatch, continuity.validate(a, listed));
}

test "native continuity import maps pending controls once and resumes the prior mode" {
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
    try std.testing.expectEqual(2, (try onlyObligation(bundle.value)).controls.items.len);
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
    try std.testing.expectError(
        error.ContinuityLineageConflict,
        importBundle(&to, &destination, conflict),
    );
    try verifyFiles(&to, &destination);
}

fn verifyFiles(f: *Fixture, driver: *Driver) !void {
    const a = f.arena.allocator();
    const io = std.testing.io;
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    const name = "bundle.paredros";
    const written = try exportWritten(f, driver, settings, "file-export", name);
    const again = try exportWritten(f, driver, settings, "file-export", name);
    try std.testing.expectEqualDeep(written.digest.?, again.digest.?);
    const bytes = try backup.temporary.dir.readFileAlloc(io, name, a, .unlimited);
    try std.testing.expectEqualDeep(written.digest.?, continuity.hash(bytes));
    try backup.temporary.dir.deleteFile(io, name);
    try backup.temporary.dir.writeFile(io, .{
        .sub_path = name,
        .data = "a different bundle",
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    try std.testing.expectError(
        error.TransferFileConflict,
        exportWritten(f, driver, settings, "file-export", name),
    );
    try std.testing.expectError(
        error.InvalidTransferPath,
        exportWritten(f, driver, settings, "escape-export", "../escape"),
    );
    try backup.temporary.dir.setPermissions(io, .fromMode(0o755));
    try std.testing.expectError(
        error.UnsafeTransferPath,
        transfer.validateExportDestination(io, settings.backup_directory.?, "new.paredros"),
    );
}

fn frozenTurn(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    const prior = try driver.turn(a, "prior-complete-turn", origin, .{
        .text = .{ .bytes = "Earlier operator instruction preserved literally." },
    });
    try finish(f, prior);
    return driver.turn(a, "original-event", origin, .{
        .text = .{ .bytes = "Continue with the frozen prior evidence." },
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
        value.continuity.?.manifest.task,
        value.context_references.items[0].task,
    );
    var context = try @import("../native/dialogue.zig").materialize(a, &index, .{
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

test "native continuity global turns preserve frozen context" {
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
    try std.testing.expectEqual(0, obligationCount(bundle.value));
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

const transfer_marker = @import("../native/transfer_marker.zig");
const eligibility = @import("../native/eligibility.zig");

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

test "native continuity imported turns and new asks run as soon as import completes" {
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
    const model = @import("../app/model_contract.zig").P.identity;
    const asked = try destination.turn(a, "after-import", origin, .{
        .text = .{ .bytes = "Asked right after import." },
    });
    try std.testing.expect(try permitted(&destination, a, asked, model));
    try finish(&to, asked);
    try std.testing.expect(try destination.importedTurns(a));
    const imported = try importedTurn(a, &destination);
    try std.testing.expect(try permitted(&destination, a, imported, model));
    try finish(&to, imported);
}

fn importedTurn(a: std.mem.Allocator, driver: *Driver) !t.Id {
    var index = try driver.rebuild(a);
    defer index.deinit();
    for (index.records) |record| {
        if (record.input == .turn and record.input.turn.continuity != null) return record.task;
    }
    return error.MissingImportedTurn;
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
    expected: []const u8,
) !void {
    const bytes = try control.encode(a, .{
        .version = 1,
        .operation = .{ .bytes = operation },
        .command = command,
    });
    const reply = try control.dispatch(a, driver, config(), 501, bytes);
    const value = (try @import("protean_native").json.parse(a, reply, .{})).value.object;
    try std.testing.expectEqualStrings("rejected", value.get("status").?.string);
    try std.testing.expectEqualStrings(expected, value.get("error").?.string);
}

fn liveExperiment(f: *Fixture) !t.Id {
    const a = f.arena.allocator();
    const admitted = try f.service.?.submit(a, "live-experiment", .{ .experiment = .{
        .envelope = .{
            .operation = .{ .bytes = "live-experiment" },
            .stable_request = @splat(29),
            .origin = origin,
        },
        .campaign = @splat(30),
        .attempt = 1,
        .plan = .{ .bytes = "plan" },
        .evidence = .{ .items = &.{} },
        .live_model = true,
    } });
    return admitted.receipt.task;
}

test "native continuity refuses ingress and transfer until import materializes" {
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
    var progress = try importBundle(&to, &destination, bundle.value);
    progress.deinit(a);
    const before = try recordCount(a, &destination);
    try std.testing.expectError(
        error.ContinuityImportPending,
        transfer_marker.admit(&destination, a, "transfer-during-import", origin, @splat(3)),
    );
    try refusedCommand(a, &destination, "pending-ask", .{ .ask = .{
        .text = .{ .bytes = "status?" },
        .target = null,
    } }, "ContinuityImportPending");
    try std.testing.expectEqual(before, try recordCount(a, &destination));
    try importDone(&to, &destination, bundle.value);
    const experiment = try liveExperiment(&to);
    const model = @import("../app/model_contract.zig").P.identity;
    try std.testing.expect(try permitted(&destination, a, experiment, model));
    try std.testing.expect(try permitted(&destination, a, experiment, experiment_codec));
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
    const budget = 2 * bundle.members.items.len + 4;
    for (0..budget) |_| {
        var progress = try importBundle(f, driver, bundle);
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
    try std.testing.expectEqual(2, obligationCount(bundle.value));
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
    try std.testing.expectError(
        error.FinalObligation,
        driver.directive(a, "late-pause", origin, target, .{ .pause = {} }),
    );
    try finish(f, step);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(.cancelled, index.head(index.obligation(target).?).mode);
    return target;
}

test "native continuity refuses a control behind a pending cancel and imports none" {
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
    try std.testing.expectEqual(0, (try onlyObligation(bundle.value)).controls.items.len);
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

fn handoffFile(from: *Fixture, backup: *Backup, clock: *u8) ![]const u8 {
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    _ = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var original = hopDriver(from, clock);
    try original.attach(from.arena.allocator());
    var bundle = try transfer.capture(&original, a, source(from), .snapshot);
    defer bundle.deinit();
    try writeBundle(a, backup.temporary.dir, "handoff.paredros", bundle.value);
    original.detach();
    try from.close();
    return std.fs.path.join(a, &.{ try backup.path(), "handoff.paredros" });
}

test "native continuity control import commits one manifest for one bundle" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    var clock: u8 = 0;
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const file = try handoffFile(&from, &backup, &clock);
    try to.init();
    var destination = hopDriver(&to, &clock);
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
            "file-import",
            origin,
            .{ .path = .{ .bytes = file }, .digest = try cli.fileDigest(std.testing.io, file) },
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

fn transferWritten(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    environment: continuity_control.Environment,
) !transfer.OwnedBundle {
    const a = f.arena.allocator();
    for (0..16) |_| {
        const progress = try continuity_control.exportBundle(
            driver,
            a,
            settings,
            environment,
            "pending-transfer",
            origin,
            .{ .name = .{ .bytes = "handoff.paredros" } },
        );
        var index = try driver.rebuild(a);
        defer index.deinit();
        if (progress.phase == .written) return transfer.committedBundle(a, &index, progress.cut.?);
        try completeAdmissions(f, driver);
        for (index.obligations) |obligation| {
            if (try driver.nextStep(a, obligation.task)) |step| try finish(f, step);
        }
    }
    return error.ExportDidNotComplete;
}

test "native continuity import repeats after a configured route rename" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    var clock: u8 = 0;
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const file = try handoffFile(&from, &backup, &clock);
    try to.init();
    var destination = hopDriver(&to, &clock);
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    const manifest = try controlImport(&to, &destination, file);
    var renamed = config();
    renamed.repository.owner = "renamed-owner";
    renamed.repository.name = "renamed-name";
    var progress = try continuity_control.importBundle(
        &destination,
        a,
        renamed,
        .{ .io = std.testing.io, .source = source(&to) },
        "file-import",
        origin,
        .{ .path = .{ .bytes = file }, .digest = try cli.fileDigest(std.testing.io, file) },
    );
    defer progress.deinit(a);
    try std.testing.expectEqual(.materialized, progress.phase);
    try std.testing.expectEqualDeep(manifest, progress.manifest);
}

test "native continuity import refuses a relative path sent to the daemon" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    var clock: u8 = 0;
    var driver = hopDriver(&f, &clock);
    try driver.attach(f.arena.allocator());
    defer driver.detach();
    try std.testing.expectError(error.RelativeTransferPath, continuity_control.importBundle(
        &driver,
        f.arena.allocator(),
        config(),
        .{ .io = std.testing.io, .source = source(&f) },
        "relative-import",
        origin,
        .{ .path = .{ .bytes = "handoff.paredros" }, .digest = @splat(0) },
    ));
}

fn finishExcept(f: *Fixture, driver: *Driver, skipped: []const t.Id) !void {
    var index = try driver.rebuild(f.arena.allocator());
    defer index.deinit();
    for (index.records) |record| {
        if (record.result != null) continue;
        for (skipped) |task| {
            if (std.meta.eql(record.task, task)) break;
        } else try finish(f, record.task);
    }
}

fn strandedExport(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    stranded: []const t.Id,
    request: continuity_control.Export,
) !continuity_control.ExportProgress {
    const environment: continuity_control.Environment = .{
        .io = std.testing.io,
        .source = source(f),
    };
    for (0..16) |_| {
        const progress = try continuity_control.exportBundle(
            driver,
            f.arena.allocator(),
            settings,
            environment,
            request.name.bytes,
            origin,
            request,
        );
        if (progress.phase == .written) return progress;
        try finishExcept(f, driver, stranded);
    }
    return error.ExportDidNotComplete;
}

fn strandedBundle(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    stranded: []const t.Id,
    request: continuity_control.Export,
) !transfer.OwnedBundle {
    const a = f.arena.allocator();
    const written = try strandedExport(f, driver, settings, stranded, request);
    var index = try driver.rebuild(a);
    defer index.deinit();
    var bundle = try transfer.committedBundle(a, &index, written.cut.?);
    errdefer bundle.deinit();
    try expectPending(a, bundle.value, index.record(stranded[0]).?.input.genesis);
    try std.testing.expectEqual(null, index.record(stranded[0]).?.result);
    return bundle;
}

fn expectPending(a: std.mem.Allocator, bundle: transfer.Bundle, genesis: t.Genesis) !void {
    const carried = try onlyObligation(bundle);
    try std.testing.expectEqualDeep(genesis.lineage, carried.lineage);
    try std.testing.expect(carried.state == .genesis);
    try std.testing.expect(try continuity.equal(a, t.Envelope, genesis.envelope, carried.origin));
    try std.testing.expect(try continuity.equal(
        a,
        t.Specification,
        genesis.specification,
        carried.state.genesis,
    ));
}

fn strandedSource(f: *Fixture) !t.Id {
    try f.init();
    const genesis = contracts.genesis();
    return (try f.service.?.submit(
        f.arena.allocator(),
        genesis.envelope.operation.bytes,
        .{ .genesis = genesis },
    )).receipt.task;
}

fn editProfile(f: *Fixture) !void {
    try f.close();
    f.profile.bytes = "edited-native-test-profile";
    try f.open();
}

test "native continuity snapshot and transfer carry a genesis this build can never run" {
    var f: Fixture = .{};
    defer f.deinit();
    const stranded = try strandedSource(&f);
    try editProfile(&f);
    var clock: u8 = 0;
    var driver = hopDriver(&f, &clock);
    try driver.attach(f.arena.allocator());
    defer driver.detach();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    var snapshot = try strandedBundle(&f, &driver, settings, &.{stranded}, .{
        .name = .{ .bytes = "stranded.paredros" },
        .snapshot = true,
    });
    defer snapshot.deinit();
    var handoff = try strandedBundle(&f, &driver, settings, &.{stranded}, .{
        .name = .{ .bytes = "handoff.paredros" },
    });
    defer handoff.deinit();
    try std.testing.expectEqual(.transfer, handoff.value.mode);
}

fn fencedBeforeStranding(f: *Fixture, settings: configuration.Config) !t.Id {
    var clock: u8 = 0;
    var driver = hopDriver(f, &clock);
    try driver.attach(f.arena.allocator());
    defer driver.detach();
    const progress = try continuity_control.exportBundle(
        &driver,
        f.arena.allocator(),
        settings,
        .{ .io = std.testing.io, .source = source(f) },
        "fenced-handoff",
        origin,
        .{ .name = .{ .bytes = "handoff.paredros" } },
    );
    try std.testing.expectEqual(.finalizing, progress.phase);
    var index = try driver.rebuild(f.arena.allocator());
    defer index.deinit();
    return index.records[index.transfer_marker orelse return error.MissingTransferMarker].task;
}

test "native continuity transfer carries a genesis stranded after the fence as a fresh import" {
    var from: Fixture = .{};
    defer from.deinit();
    const stranded = try strandedSource(&from);
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    const marker = try fencedBeforeStranding(&from, settings);
    try editProfile(&from);
    const a = from.arena.allocator();
    var clock: u8 = 0;
    var original = hopDriver(&from, &clock);
    try original.attach(a);
    var snapshot = try transfer.capture(&original, a, source(&from), .snapshot);
    defer snapshot.deinit();
    const genesis = contracts.genesis();
    try expectPending(a, snapshot.value, genesis);
    var handoff = try strandedBundle(&from, &original, settings, &.{ stranded, marker }, .{
        .name = .{ .bytes = "handoff.paredros" },
    });
    defer handoff.deinit();
    original.detach();
    try from.close();
    var to: Fixture = .{};
    defer to.deinit();
    try to.init();
    var destination = hopDriver(&to, &clock);
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    const imported = try importAll(&to, &destination, handoff.value);
    var index = try destination.rebuild(a);
    defer index.deinit();
    const record = index.record(imported).?;
    try std.testing.expectEqualDeep(genesis.lineage, record.input.genesis.lineage);
    try std.testing.expect(record.input.genesis.imported.?.carried == null);
    const obligation = index.obligation(imported).?;
    try std.testing.expect(obligation.ordinaryDispatch());
    try std.testing.expectEqual(null, index.head(obligation).predecessor);
    try std.testing.expect(try destination.nextStep(a, imported) != null);
}

test "native continuity export source names the stored image digest, not the program identity" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const genesis = contracts.genesis();
    const task = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    const environment = try continuity_control.sourceEnvironment(
        std.testing.io,
        f.service.?.namespace.identity,
        &f.application.?,
        f.assets.image,
        f.profile.runtime_identity,
    );
    var saved = try f.service.?.task(a, task);
    defer saved.deinit();
    try std.testing.expect(environment.source.image.names(saved.value.image));
    try std.testing.expect(!std.meta.eql(
        environment.source.image.sha256,
        f.application.?.image_identity,
    ));
}

test "native continuity export waits for an admitted genesis that has not run" {
    var f: Fixture = .{};
    defer f.deinit();
    try f.init();
    const a = f.arena.allocator();
    const genesis = contracts.genesis();
    _ = try f.service.?.submit(a, genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var driver = hopDriver(&f, &clock);
    try driver.attach(f.arena.allocator());
    defer driver.detach();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    var settings = config();
    settings.backup_directory = try backup.path();
    const environment: continuity_control.Environment = .{
        .io = std.testing.io,
        .source = source(&f),
    };
    try std.testing.expectError(error.ContinuityGenesisPending, continuity_control.exportBundle(
        &driver,
        a,
        settings,
        environment,
        "pending-snapshot",
        origin,
        .{ .name = .{ .bytes = "pending.paredros" }, .snapshot = true },
    ));
    var bundle = try transferWritten(&f, &driver, settings, environment);
    defer bundle.deinit();
    const carried = try onlyObligation(bundle.value);
    try std.testing.expectEqual(.transferred, carried.state.head.head.mode);
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
    try std.testing.expect(!index.transferred());
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

fn importedHead(a: std.mem.Allocator, f: *Fixture, bundle: transfer.Bundle) !t.Head {
    try f.init();
    var clock: u8 = 0;
    var driver = hopDriver(f, &clock);
    try driver.attach(f.arena.allocator());
    try importDone(f, &driver, bundle);
    var index = try driver.rebuild(f.arena.allocator());
    const bytes = try c.encodeOwned(t.Head, a, index.head(&index.obligations[0]));
    index.deinit();
    driver.detach();
    try f.close();
    return (try c.decodeOwned(t.Head, a, bytes)).value;
}

fn expectEquivalent(a: std.mem.Allocator, first: transfer.Bundle, second: transfer.Bundle) !void {
    const left = try onlyObligation(first);
    const right = try onlyObligation(second);
    try std.testing.expect(try continuity.equal(a, t.Envelope, left.origin, right.origin));
    const Controls = @TypeOf(left.controls);
    try std.testing.expect(try continuity.equal(a, Controls, left.controls, right.controls));
    const Turns = @TypeOf(left.turns);
    try std.testing.expect(try continuity.equal(a, Turns, left.turns, right.turns));
    const talk = struct {
        fn of(bundle: transfer.Bundle) !continuity.Conversation {
            for (bundle.members.items) |item| if (item == .conversation) return item.conversation;
            return error.MissingContinuityConversation;
        }
    };
    const Conversation = continuity.Conversation;
    try std.testing.expect(try continuity.equal(
        a,
        Conversation,
        try talk.of(first),
        try talk.of(second),
    ));
}

test "native continuity re-export from an imported namespace equals the original bundle" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original = hopDriver(&from, &clock);
    try original.attach(a);
    _ = try original.directive(a, "chain-pause", origin, target, .{ .pause = {} });
    _ = try original.turn(a, "chain-targeted", origin, .{
        .text = .{ .bytes = "Is the branch moving?" },
        .target = target,
    });
    _ = try frozenTurn(&from, &original);
    var first = try transfer.capture(&original, a, source(&from), .snapshot);
    defer first.deinit();
    original.detach();
    try from.close();
    try to.init();
    var middle = hopDriver(&to, &clock);
    try middle.attach(to.arena.allocator());
    try importDone(&to, &middle, first.value);
    var second = try transfer.capture(&middle, a, source(&to), .snapshot);
    defer second.deinit();
    middle.detach();
    try to.close();
    try expectEquivalent(a, first.value, second.value);
    const first_bytes = try c.encodeOwned(transfer.Bundle, a, first.value);
    const second_bytes = try c.encodeOwned(transfer.Bundle, a, second.value);
    try std.testing.expect(second_bytes.len <= first_bytes.len);
    var direct: Fixture = .{};
    defer direct.deinit();
    var relayed: Fixture = .{};
    defer relayed.deinit();
    const direct_head = try importedHead(a, &direct, first.value);
    try std.testing.expectEqualDeep(direct_head, try importedHead(a, &relayed, second.value));
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
        .materialized = view.materialized,
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
    var daemon = try Daemon.init(f.arena.allocator(), driver, &server, .{
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
        if (partial and phase == .genesis_pending) break;
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
    var admitted = try importBundle(&to, &destination, bundle.value);
    admitted.deinit(a);
    destination.detach();
    try std.testing.expectEqual(.genesis_pending, try daemonImport(&to, &destination, true));
    try to.close();
    try to.open();
    destination.service = &to.service.?;
    try std.testing.expectEqual(.materialized, try daemonImport(&to, &destination, false));
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(2, index.obligations.len);
    for (index.obligations) |obligation| {
        try std.testing.expect(index.record(obligation.task).?.input.genesis.imported != null);
    }
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
    var admitted = try importBundle(&to, &destination, bundle.value);
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
    try std.testing.expect(!index.transferred());
    try std.testing.expectError(error.FileNotFound, backup.temporary.dir.statFile(
        std.testing.io,
        "early.paredros",
        .{},
    ));
}

fn fileImport(
    f: anytype,
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
        .{ .path = .{ .bytes = file }, .digest = try cli.fileDigest(std.testing.io, file) },
    );
}

fn importFixture(from: *Fixture, to: *Fixture, directory: std.Io.Dir) !transfer.OwnedBundle {
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
    try writeBundle(a, directory, "handoff.paredros", bundle.value);
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
    var bundle = try importFixture(&from, &to, backup.temporary.dir);
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
    try writeBundle(a, backup.temporary.dir, "handoff.paredros", changed);
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

test "native continuity import replays from stored state without reading its file" {
    var from: Fixture = .{};
    defer from.deinit();
    var to: Fixture = .{};
    defer to.deinit();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const directory = try backup.path();
    var bundle = try importFixture(&from, &to, backup.temporary.dir);
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
    const digest = try cli.fileDigest(std.testing.io, file);
    var progress = try fileImport(&to, &destination, config(), "stored-import", file);
    const manifest = progress.manifest;
    progress.deinit(a);
    try completeAdmissions(&to, &destination);
    try backup.temporary.dir.deleteFile(std.testing.io, "handoff.paredros");
    for ([_][]const u8{ "stored-import", "stored-retry" }) |operation| {
        var replayed = try continuity_control.importBundle(
            &destination,
            a,
            config(),
            .{ .io = std.testing.io, .source = source(&to) },
            operation,
            origin,
            .{ .path = .{ .bytes = file }, .digest = digest },
        );
        defer replayed.deinit(a);
        try std.testing.expectEqualDeep(manifest, replayed.manifest);
    }
}

test "native continuity import validates bindings after manifest admission" {
    var from: Fixture = .{};
    defer from.deinit();
    var to: Fixture = .{};
    defer to.deinit();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const directory = try backup.path();
    var bundle = try importFixture(&from, &to, backup.temporary.dir);
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
    moved.repository.id += 1;
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
    try std.testing.expectEqual(0, index.continuity_import.?.materialized);
    try std.testing.expectEqual(0, index.obligations.len);
}

fn exportAs(
    f: *Fixture,
    driver: *Driver,
    settings: configuration.Config,
    operation: []const u8,
    request: continuity_control.Export,
) !continuity_control.ExportProgress {
    return try continuity_control.exportBundle(
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
    const target = try commands.monitor(
        &original,
        a,
        "monitor-retry",
        origin,
        monitorRequest(spec),
        spec,
    );
    try finish(f, target);
    try std.testing.expectEqualDeep(
        target,
        try commands.monitor(&original, a, "monitor-retry", origin, monitorRequest(spec), spec),
    );
    var index = try original.rebuild(a);
    defer index.deinit();
    const bytes = try c.encodeOwned(t.Genesis, a, index.record(target).?.input.genesis);
    return .{
        .bundle = try transfer.capture(&original, a, source(f), .snapshot),
        .local = (try c.decodeOwned(t.Genesis, a, bytes)).value,
    };
}

fn monitorRequest(spec: t.Specification) commands.MonitorRequest {
    return .{ .wording = spec.wording, .interval_ms = spec.interval_ms };
}

fn expectOneLineage(driver: *Driver, a: std.mem.Allocator, imported: t.Id) !void {
    const spec = contracts.specification();
    try std.testing.expectEqualDeep(
        imported,
        try commands.monitor(driver, a, "monitor-retry", origin, monitorRequest(spec), spec),
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
    const spec = contracts.specification();
    try std.testing.expectError(
        error.OperationConflict,
        commands.monitor(&destination, a, "monitor-retry", origin, monitorRequest(spec), spec),
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
    _ = try destination.submit(a, "monitor-retry", .{ .genesis = source_state.local });
    try std.testing.expect(!std.meta.eql(replay, imported));
    try expectOneLineage(&destination, a, imported);
    var forked = source_state.local;
    forked.envelope.operation = .{ .bytes = "monitor-fork" };
    _ = try to.execute("monitor-fork", .{ .genesis = forked });
    try std.testing.expectError(error.CorruptState, destination.rebuild(a));
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
    return @import("../native/wire.zig").parse(t.Id, task);
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

test "native continuity control monitor add retried after import returns or conflicts" {
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
    const before = try recordCount(a, &destination);
    try std.testing.expectEqualDeep(imported, try controlTask(a, &destination, "monitor-retry"));
    try controlRefused(a, &destination, "monitor-retry", "watch more", "OperationConflict");
    try std.testing.expectEqual(before, try recordCount(a, &destination));
    _ = try destination.directive(a, "monitor-reused", origin, imported, .{ .pause = {} });
    try controlRefused(a, &destination, "monitor-reused", "watch", "OperationConflict");
    try std.testing.expectEqualDeep(imported, try controlTask(a, &destination, "monitor-retry"));
    const fresh = try controlTask(a, &destination, "monitor-fresh");
    try std.testing.expect(!std.meta.eql(imported, fresh));
}

fn hopDriver(f: *Fixture, clock: *u8) Driver {
    return .{
        .service = &f.service.?,
        .clock = .{ .context = clock, .now = Clock.now },
        .bindings = configuration.bindings(config()),
    };
}

fn admittedTurn(a: std.mem.Allocator, driver: *Driver) !t.Turn {
    var index = try driver.rebuild(a);
    defer index.deinit();
    var found: ?t.Turn = null;
    for (index.records) |record| {
        if (record.input != .turn) continue;
        try std.testing.expect(found == null);
        found = record.input.turn;
    }
    return found orelse error.MissingTurn;
}

test "native continuity third hop maps an earlier hop's unfinished targeted turn" {
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
    var original = hopDriver(&from, &clock);
    try original.attach(from.arena.allocator());
    _ = try original.turn(a, "targeted-unfinished-turn", origin, .{
        .text = .{ .bytes = "What changed on this obligation?" },
        .target = target,
    });
    var first = try transfer.capture(&original, a, source(&from), .snapshot);
    defer first.deinit();
    original.detach();
    try from.close();
    try to.init();
    var middle = hopDriver(&to, &clock);
    try middle.attach(to.arena.allocator());
    try importDone(&to, &middle, first.value);
    var second = try transfer.capture(&middle, a, source(&to), .snapshot);
    defer second.deinit();
    middle.detach();
    try to.close();
    try third.init();
    var last = hopDriver(&third, &clock);
    try last.attach(third.arena.allocator());
    defer last.detach();
    const imported = try importAll(&third, &last, second.value);
    try std.testing.expect(try last.importedTurns(a));
    try std.testing.expectEqualDeep(imported, (try admittedTurn(a, &last)).target.?);
    try std.testing.expect(!try last.importedTurns(a));
}

test "native continuity snapshot during partial control mapping keeps source order" {
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
    var original = hopDriver(&from, &clock);
    try original.attach(from.arena.allocator());
    _ = try original.directive(a, "partial-pause", origin, target, .{ .pause = {} });
    _ = try original.directive(a, "partial-resume", origin, target, .{ .@"resume" = {} });
    var first = try transfer.capture(&original, a, source(&from), .snapshot);
    defer first.deinit();
    original.detach();
    try from.close();
    try to.init();
    var middle = hopDriver(&to, &clock);
    try middle.attach(to.arena.allocator());
    const carried = try importAll(&to, &middle, first.value);
    const mapped = try transfer.admitPendingControls(&middle, a, carried, origin);
    try std.testing.expectEqual(1, mapped.remaining);
    try finish(&to, mapped.admitted.?);
    var second = try transfer.capture(&middle, a, source(&to), .snapshot);
    defer second.deinit();
    const controls = (try onlyObligation(second.value)).controls;
    try std.testing.expectEqual(2, controls.items.len);
    try std.testing.expect(try continuity.equal(
        a,
        @TypeOf(controls),
        (try onlyObligation(first.value)).controls,
        controls,
    ));
    middle.detach();
    try to.close();
    try third.init();
    var last = hopDriver(&third, &clock);
    try last.attach(third.arena.allocator());
    defer last.detach();
    try verifyImported(&third, &last, try importAll(&third, &last, second.value));
}

fn staleGenesis() t.Genesis {
    var value = secondGenesis();
    value.specification.repository.id += 1;
    return value;
}

test "native continuity import skips cancelled lineages and binds identity rather than route" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const live = contracts.genesis();
    const stale = staleGenesis();
    _ = try from.execute(live.envelope.operation.bytes, .{ .genesis = live });
    const cancelled = try from.execute(stale.envelope.operation.bytes, .{ .genesis = stale });
    var clock: u8 = 0;
    var original = hopDriver(&from, &clock);
    try original.attach(from.arena.allocator());
    _ = try original.directive(a, "stale-cancel", origin, cancelled, .{ .cancel = {} });
    try finish(&from, (try original.nextStep(a, cancelled)).?);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    var moved = config();
    moved.repository.id += 1;
    try std.testing.expectError(
        error.ContinuityResourceMismatch,
        transfer.validateBindings(bundle.value, configuration.bindings(moved)),
    );
    var renamed = config();
    renamed.repository.owner = "renamed-owner";
    renamed.repository.name = "renamed-name";
    try transfer.validateBindings(bundle.value, configuration.bindings(renamed));
    original.detach();
    try from.close();
    try to.init();
    var destination = hopDriver(&to, &clock);
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    try importDone(&to, &destination, bundle.value);
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(2, index.obligations.len);
    var modes: [2]t.Mode = undefined;
    for (&modes, index.obligations) |*mode, *obligation| mode.* = index.head(obligation).mode;
    try std.testing.expect(modes[0] == .cancelled or modes[1] == .cancelled);
    try std.testing.expect(modes[0] != .cancelled or modes[1] != .cancelled);
}

fn githubDriver(f: *GithubFixture, clock: *fake.Clock) Driver {
    return .{
        .service = &f.service.?,
        .clock = .{ .context = clock, .now = fake.Clock.now },
        .bindings = configuration.bindings(config()),
    };
}

test "native continuity import renders a digest over untold imported batches" {
    var repository: fake.Source = .{ .ahead = true };
    var from: GithubFixture = .{};
    defer from.deinit();
    from.profile.environment = &repository;
    try from.initWithGrants(&.{@import("../app/github_contract.zig").identity});
    var to: GithubFixture = .{};
    defer to.deinit();
    to.profile.environment = &repository;
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: fake.Clock = .{};
    var original = githubDriver(&from, &clock);
    try original.attach(a);
    try fake.drive(&from, (try original.nextStep(a, target)).?);
    repository.tip = 2;
    clock.now_ms = 1_000_000;
    try fake.drive(&from, (try original.nextStep(a, target)).?);
    var exported = try original.rebuild(a);
    const owed = exported.head(exported.obligation(target).?);
    try std.testing.expectEqual(1, owed.observed.sequence);
    try std.testing.expectEqual(0, owed.told.sequence);
    exported.deinit();
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    try to.initWithGrants(&.{@import("../app/github_contract.zig").identity});
    var destination = githubDriver(&to, &clock);
    try destination.attach(a);
    defer destination.detach();
    try importDone(&to, &destination, bundle.value);
    const local = blk: {
        var index = try destination.rebuild(a);
        defer index.deinit();
        break :blk index.obligations[0].task;
    };
    try fake.settle(&to, &destination, local);
    var index = try destination.rebuild(a);
    defer index.deinit();
    const head = index.head(index.obligation(local).?);
    try std.testing.expectEqual(1, head.told.sequence);
    try std.testing.expectEqual(1, head.observed.sequence);
    const page = try messages.page(a, &index, local, null, 64, null);
    const published = page.messages.items[page.messages.items.len - 1];
    try std.testing.expectEqual(.digest, published.purpose);
    try std.testing.expectEqual(0, published.prior.?.sequence);
    try std.testing.expectEqual(1, published.through.?.sequence);
    try std.testing.expectEqualDeep(@as(?t.Oid, fake.oid(2)), published.through.?.tip);
    try std.testing.expectEqual(1, published.links.items.len);
}

fn unvaluedDisposition(head: *t.Head) void {
    head.method_disposition = .{
        .source = .{ .task = @splat(0), .digest = @splat(0) },
        .source_digest = @splat(1),
        .reason = .{ .bytes = "missing" },
        .consecutive_faults = 1,
        .model_consumed = false,
        .reverted = true,
    };
}

test "native continuity member validation refuses attached references before import admission" {
    var repository: fake.Source = .{ .ahead = true };
    var from: GithubFixture = .{};
    defer from.deinit();
    from.profile.environment = &repository;
    try from.initWithGrants(&.{@import("../app/github_contract.zig").identity});
    var to: GithubFixture = .{};
    defer to.deinit();
    to.profile.environment = &repository;
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: fake.Clock = .{};
    var original = githubDriver(&from, &clock);
    try original.attach(a);
    try fake.drive(&from, (try original.nextStep(a, target)).?);
    repository.tip = 2;
    clock.now_ms = 1_000_000;
    try fake.drive(&from, (try original.nextStep(a, target)).?);
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    original.detach();
    try from.close();
    const carried = (try onlyObligation(bundle.value)).state.head;
    try std.testing.expectEqual(1, carried.batches.items.len);
    try std.testing.expectEqual(carried.head.observed.sequence, carried.batches.items[0].sequence);
    const dangling = try rehead(a, bundle.value, unvaluedDisposition, true);
    try std.testing.expectError(error.InvalidContinuityMethod, continuity.validate(a, dangling));
    const linked = try rehead(a, bundle.value, attached, true);
    try std.testing.expectError(error.AttachedContinuityReference, continuity.validate(a, linked));
    try to.initWithGrants(&.{@import("../app/github_contract.zig").identity});
    var destination = githubDriver(&to, &clock);
    try destination.attach(a);
    defer destination.detach();
    try std.testing.expectError(
        error.AttachedContinuityReference,
        importBundle(&to, &destination, linked),
    );
    var index = try destination.rebuild(a);
    defer index.deinit();
    try std.testing.expectEqual(0, index.records.len);
}

test "native continuity monitor add conflicts with a carried genesis operation across hops" {
    var first: Fixture = .{};
    defer first.deinit();
    try first.init();
    var second: Fixture = .{};
    defer second.deinit();
    var third: Fixture = .{};
    defer third.deinit();
    const a = first.arena.allocator();
    const genesis = contracts.genesis();
    const target = try first.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original = hopDriver(&first, &clock);
    try original.attach(first.arena.allocator());
    _ = try original.directive(a, "shared-operation", origin, target, .{ .pause = {} });
    var failed = contracts.genesis();
    failed.envelope.operation = .{ .bytes = "failed-operation" };
    failed.lineage = @splat(0x5a);
    failed.specification.revision = 1;
    _ = try first.execute("failed-operation", .{ .genesis = failed });
    _ = try original.submit(a, "failed-operation", .{ .genesis = failed });
    var earliest = try transfer.capture(&original, a, source(&first), .snapshot);
    defer earliest.deinit();
    original.detach();
    try first.close();
    try second.init();
    var middle = hopDriver(&second, &clock);
    try middle.attach(second.arena.allocator());
    try importDone(&second, &middle, earliest.value);
    const spec = contracts.specification();
    const request = monitorRequest(spec);
    const local = try commands.monitor(&middle, a, "shared-operation", origin, request, spec);
    try finish(&second, local);
    var carried = try transfer.capture(&middle, a, source(&second), .snapshot);
    defer carried.deinit();
    middle.detach();
    try second.close();
    try third.init();
    var last = hopDriver(&third, &clock);
    try last.attach(third.arena.allocator());
    defer last.detach();
    try importDone(&third, &last, carried.value);
    var different = spec;
    different.wording = .{ .bytes = "watch something else" };
    try std.testing.expectError(error.OperationConflict, commands.monitor(
        &last,
        a,
        "shared-operation",
        origin,
        monitorRequest(different),
        different,
    ));
    _ = try commands.monitor(&last, a, "failed-operation", origin, request, spec);
}

const method_contract = @import("../app/method_contract.zig");
const experiment_contract = @import("../app/experiment_contract.zig");
const method_external = @import("../native/method_external.zig");
const method_catalog = @import("../native/method_catalog.zig");
const Session = @import("protean_native").Session(app.Types);
const registered_source = "registered method source";

fn registration(f: *Fixture) !void {
    try f.initWithGrants(&.{
        method_contract.workspace_identity, method_contract.codec_identity,
        experiment_contract.codec_identity, experiment_contract.clock_identity,
    });
    const a = f.arena.allocator();
    const drafts = try a.alloc(experiment_contract.SourceDraft, 1);
    drafts[0] = .{
        .name = .{ .bytes = "registered" },
        .bytes = .{ .bytes = registered_source },
        .contract_digest = try method_external.contractDigest(a),
        .provenance = .{ .items = &.{} },
        .origin = .operator_supplied,
    };
    const plan: experiment_contract.Plan = .{ .construct = .{ .sources = .{ .items = drafts } } };
    const admitted = try f.service.?.submit(a, "register-source", .{ .experiment = .{
        .envelope = .{
            .operation = .{ .bytes = "register-source" },
            .stable_request = @splat(31),
            .origin = origin,
        },
        .campaign = @splat(32),
        .attempt = 0,
        .plan = .{ .bytes = try c.encodeOwned(experiment_contract.Plan, a, plan) },
        .evidence = .{ .items = &.{} },
        .live_model = false,
    } });
    var session = try Session.init(&f.service.?);
    defer session.deinit() catch @panic("registration session left busy");
    try driveRegistration(f, &session, admitted.receipt.task);
    try session.park(a);
}

fn driveRegistration(f: *Fixture, session: *Session, task: t.Id) !void {
    const a = f.arena.allocator();
    for (0..10_000) |_| {
        _ = try session.collect(a, false);
        var status = try f.service.?.task(a, task);
        defer status.deinit();
        if (status.value.terminal()) return;
        _ = try session.advance(a);
        if (session.busy()) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.RegistrationDidNotComplete;
}

fn importedReport(a: std.mem.Allocator, driver: *Driver) !t.Reference {
    var index = try driver.rebuild(a);
    defer index.deinit();
    for (index.records) |record| {
        if (record.input != .continuity_member) continue;
        return .{ .task = record.task, .digest = record.result_digest.? };
    }
    return error.MissingImportedReport;
}

fn adoptImported(f: *Fixture, driver: *Driver) !t.Id {
    const a = f.arena.allocator();
    const genesis = contracts.genesis();
    const target = try f.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    _ = try driver.submit(a, genesis.envelope.operation.bytes, .{ .genesis = genesis });
    const report = try importedReport(a, driver);
    const digest = continuity.hash(registered_source);
    const adoption: t.Input = .{ .directive = .{
        .envelope = .{
            .operation = .{ .bytes = "adopt-imported" },
            .stable_request = @splat(33),
            .origin = origin,
        },
        .obligation = target,
        .ordinal = 1,
        .predecessor = null,
        .body = .{ .adopt = .{ .expected_revision = 0, .method = .{ .retained = .{
            .source = report,
            .source_digest = digest,
            .contract_digest = try method_external.contractDigest(a),
            .report = report,
            .applicability = digest,
            .state = .{ .bytes = "" },
            .consecutive_faults = 0,
        } } } },
    } };
    _ = try f.execute("adopt-imported", adoption);
    _ = try driver.submit(a, "adopt-imported", adoption);
    try finish(f, (try driver.nextStep(a, target)).?);
    var index = try driver.rebuild(a);
    defer index.deinit();
    try std.testing.expect(index.head(index.obligation(target).?).method == .retained);
    return target;
}

fn adoptedReport(a: std.mem.Allocator, driver: *Driver) !void {
    var index = try driver.rebuild(a);
    defer index.deinit();
    const head = index.head(&index.obligations[0]);
    try std.testing.expect(head.method == .retained);
    var report = try method_catalog.report(a, &index, head.method.retained.report);
    defer report.deinit();
    try std.testing.expectEqual(.source_registration, report.value.kind);
}

fn withoutReports(a: std.mem.Allocator, bundle: transfer.Bundle) !transfer.Bundle {
    var members: std.ArrayList(continuity.Member) = .empty;
    var manifest: std.ArrayList(t.Digest) = .empty;
    for (bundle.members.items, bundle.manifest.items) |item, key| {
        if (item == .report) continue;
        try members.append(a, item);
        try manifest.append(a, key);
    }
    try std.testing.expect(members.items.len < bundle.members.items.len);
    var result = bundle;
    result.members.items = members.items;
    result.manifest.items = manifest.items;
    return result;
}

test "native continuity re-exports a method adopted from an imported report across hops" {
    var experimenter: Fixture = .{};
    defer experimenter.deinit();
    try registration(&experimenter);
    const a = experimenter.arena.allocator();
    var clock: u8 = 0;
    var original = hopDriver(&experimenter, &clock);
    try original.attach(experimenter.arena.allocator());
    var reports = try transfer.capture(&original, a, source(&experimenter), .snapshot);
    defer reports.deinit();
    original.detach();
    try experimenter.close();
    var adopter: Fixture = .{};
    defer adopter.deinit();
    try adopter.init();
    var middle = hopDriver(&adopter, &clock);
    try middle.attach(adopter.arena.allocator());
    try importDone(&adopter, &middle, reports.value);
    _ = try adoptImported(&adopter, &middle);
    var adopted = try transfer.capture(&middle, a, source(&adopter), .snapshot);
    defer adopted.deinit();
    middle.detach();
    try adopter.close();
    var carrier: Fixture = .{};
    defer carrier.deinit();
    try carrier.init();
    var third = hopDriver(&carrier, &clock);
    try third.attach(carrier.arena.allocator());
    _ = try importAll(&carrier, &third, try withoutReports(a, adopted.value));
    try adoptedReport(a, &third);
    var carried = try transfer.capture(&third, a, source(&carrier), .snapshot);
    defer carried.deinit();
    third.detach();
    try carrier.close();
    var last: Fixture = .{};
    defer last.deinit();
    try last.init();
    var fourth = hopDriver(&last, &clock);
    try fourth.attach(last.arena.allocator());
    defer fourth.detach();
    _ = try importAll(&last, &fourth, carried.value);
    try adoptedReport(a, &fourth);
}

test "native continuity import refuses a bundle beyond its byte bound before admission" {
    var from: Fixture = .{};
    defer from.deinit();
    var to: Fixture = .{};
    defer to.deinit();
    var backup = try Backup.init();
    defer backup.temporary.cleanup();
    const directory = try backup.path();
    var bundle = try importFixture(&from, &to, backup.temporary.dir);
    defer bundle.deinit();
    const a = to.arena.allocator();
    const file = try std.fs.path.join(a, &.{ directory, "handoff.paredros" });
    const size = (try backup.temporary.dir.statFile(std.testing.io, "handoff.paredros", .{})).size;
    var clock: u8 = 0;
    var destination = hopDriver(&to, &clock);
    try destination.attach(a);
    defer destination.detach();
    try std.testing.expectError(error.Capacity, continuity_control.importBundle(
        &destination,
        a,
        config(),
        .{ .io = std.testing.io, .source = source(&to) },
        "bounded-import",
        origin,
        .{
            .path = .{ .bytes = file },
            .digest = try cli.fileDigest(std.testing.io, file),
            .bytes_max = size - 1,
        },
    ));
    try std.testing.expectEqual(0, try recordCount(a, &destination));
    var progress = try continuity_control.importBundle(
        &destination,
        a,
        config(),
        .{ .io = std.testing.io, .source = source(&to) },
        "bounded-import",
        origin,
        .{
            .path = .{ .bytes = file },
            .digest = try cli.fileDigest(std.testing.io, file),
            .bytes_max = size,
        },
    );
    progress.deinit(a);
}

test "native continuity exports an obligation with live work from its latest head and controls" {
    var from: Fixture = .{};
    defer from.deinit();
    try from.init();
    var to: Fixture = .{};
    defer to.deinit();
    const a = from.arena.allocator();
    const genesis = contracts.genesis();
    const target = try from.execute(genesis.envelope.operation.bytes, .{ .genesis = genesis });
    var clock: u8 = 0;
    var original = hopDriver(&from, &clock);
    try original.attach(a);
    _ = try original.directive(a, "live-pause", origin, target, .{ .pause = {} });
    const live = (try original.nextStep(a, target)).?;
    var index = try original.rebuild(a);
    const latest = index.head(index.obligation(target).?);
    try std.testing.expect(index.record(live).?.result == null);
    index.deinit();
    var bundle = try transfer.capture(&original, a, source(&from), .snapshot);
    defer bundle.deinit();
    const carried = try onlyObligation(bundle.value);
    try std.testing.expectEqual(latest.sequence, carried.state.head.head.sequence);
    try std.testing.expectEqual(1, carried.controls.items.len);
    try std.testing.expect(carried.controls.items[0].body == .pause);
    original.detach();
    try from.close();
    try to.init();
    var destination = hopDriver(&to, &clock);
    try destination.attach(to.arena.allocator());
    defer destination.detach();
    const imported = try importAll(&to, &destination, bundle.value);
    try std.testing.expect(try destination.importedControls(a, imported));
    try finish(&to, (try admittedDirective(a, &destination)).?);
    try finish(&to, (try destination.nextStep(a, imported)).?);
    var after = try destination.rebuild(a);
    defer after.deinit();
    try std.testing.expectEqual(.paused, after.head(after.obligation(imported).?).mode);
}

fn admittedDirective(a: std.mem.Allocator, driver: *Driver) !?t.Id {
    var index = try driver.rebuild(a);
    defer index.deinit();
    for (index.records) |record| {
        if (record.input == .directive and record.result == null) return record.task;
    }
    return null;
}
