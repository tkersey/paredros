const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const slack = @import("slack.zig");
const configuration = @import("configuration.zig");
const commands = @import("commands.zig");
const admission = @import("admission.zig");
const idx = @import("index.zig");
const preparation = @import("delivery_prepare.zig");
const ingress_policy = @import("ingress_policy.zig");

pub const Result = union(enum) { ignored: slack.Ignore, admitted: t.Id };
const Bound = struct { record: *const idx.Record, button: t.Button };

pub fn admit(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    bytes: []const u8,
) !Result {
    if (!driver.attached) return error.DriverDetached;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var parsed = try slack.parseEnvelope(scratch, config.slack.binding(), bytes, .{
        .envelope_bytes = 128 * 1024,
    });
    defer parsed.deinit();
    switch (parsed.disposition) {
        .ignored => |reason| return .{ .ignored = reason },
        .text => |value| return .{ .admitted = try admitText(driver, scratch, config, value) },
        .interaction => |value| return .{
            .admitted = try admitInteraction(driver, scratch, config, value),
        },
    }
}

fn origin(config: configuration.Config) t.Origin {
    return .{ .slack = .{
        .app = .{ .bytes = config.slack.app },
        .workspace = .{ .bytes = config.slack.workspace },
        .user = .{ .bytes = config.slack.operator },
        .channel = .{ .bytes = config.slack.channel },
    } };
}

fn operation(a: std.mem.Allocator, identity: t.Digest) ![]const u8 {
    return std.fmt.allocPrint(a, "slack:{s}", .{std.fmt.bytesToHex(identity, .lower)});
}

fn replay(
    driver: anytype,
    a: std.mem.Allocator,
    name: []const u8,
    expected_origin: t.Origin,
    stable: t.Digest,
) !?t.Id {
    var receipt = (try driver.service.operationLookup(a, name)) orelse return null;
    defer receipt.deinit();
    var stored = (try driver.service.applicationValue(a, receipt.value.task, .input)) orelse
        return error.MissingAdmittedInput;
    defer stored.deinit();
    if (stored.encoding != .contract or !same(stored.schema_id, t.input_schema_id))
        return error.UnsupportedApplicationSchema;
    var decoded = try c.decodeOwned(t.Input, a, stored.bytes);
    defer decoded.deinit();
    const envelope = switch (decoded.value) {
        inline else => |value| value.envelope,
    };
    const retained_ingress = envelope.ingress orelse return error.OperationConflict;
    const left = try c.encodeOwned(t.Origin, a, envelope.origin);
    defer a.free(left);
    const right = try c.encodeOwned(t.Origin, a, expected_origin);
    defer a.free(right);
    if (!same(envelope.operation.bytes, name) or !same(left, right) or
        !std.meta.eql(retained_ingress.stable_request, stable)) return error.OperationConflict;
    return receipt.value.task;
}

fn template(config: configuration.Config) t.Specification {
    return .{
        .revision = 0,
        .repository = config.repository.value(),
        .destination = config.slack.destination(),
        .interval_ms = config.interval_ms,
        .anchor_ms = 0,
        .wording = .{ .bytes = "" },
        .policies = config.policies,
    };
}

fn selectedTarget(index: *const idx.Index) ?t.Id {
    var selected: ?t.Id = null;
    for (index.obligations) |*obligation| {
        const head = index.head(obligation);
        if (head.mode == .cancelled or head.mode == .transferred) continue;
        if (selected != null) return null;
        selected = obligation.task;
    }
    return selected;
}

fn admitText(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    value: slack.Text,
) !t.Id {
    const name = try operation(a, value.operation);
    defer a.free(name);
    const authenticated = origin(config);
    if (try replay(driver, a, name, authenticated, value.stable_request)) |task| return task;
    var index = try driver.rebuild(a);
    defer index.deinit();
    if (try @import("transfer.zig").importedIngress(
        a,
        &index,
        name,
        authenticated,
        value.stable_request,
    )) |task| return task;
    try ingress_policy.validate(a, &index, driver.service.namespace.identity);
    return commands.turn(driver, a, name, authenticated, .{
        .destination = config.slack.destination(),
        .text = .{ .bytes = value.text },
        .target = selectedTarget(&index),
        .genesis_template = template(config),
        .anchor_template = true,
        .ingress = .{
            .stable_request = value.stable_request,
            .timestamp = .{ .bytes = value.timestamp },
        },
    });
}

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

const knownTimestamp = @import("interaction_evidence.zig").knownTimestamp;

fn bound(
    a: std.mem.Allocator,
    index: *const idx.Index,
    config: configuration.Config,
    click: slack.Interaction,
) !?Bound {
    var found: ?Bound = null;
    for (index.records) |*record| {
        if (record.input != .delivery) continue;
        const delivery = record.input.delivery;
        for (delivery.payload.logical.buttons.items) |button| {
            if (!same(button.block_id.bytes, click.block_id) or
                !same(button.action_id.bytes, click.action_id) or
                !same(button.value.bytes, click.value)) continue;
            var prepared = try preparation.verify(
                a,
                delivery.destination,
                delivery.key,
                delivery.payload,
                config.slack.bot_id,
            );
            defer prepared.deinit();
            const timestamp = try knownTimestamp(a, record.*);
            slack.bindInteraction(a, click, prepared, .{
                .block_id = button.block_id.bytes,
                .action_id = button.action_id.bytes,
                .value = button.value.bytes,
                .label = button.label.bytes,
            }, if (timestamp) |value| value.bytes else null) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            if (found != null) return error.AmbiguousInteraction;
            found = .{ .record = record, .button = button };
        }
    }
    return found;
}

fn ingress(a: std.mem.Allocator, click: slack.Interaction, selected: ?Bound) !t.Ingress {
    return .{
        .stable_request = click.stable_request,
        .timestamp = .{ .bytes = click.action_timestamp },
        .interaction = if (selected) |value| .{
            .delivery = .{ .task = value.record.task, .digest = value.record.input_digest },
            .message_timestamp = .{ .bytes = click.message_timestamp },
            .block_id = .{ .bytes = click.block_id },
            .action_id = .{ .bytes = click.action_id },
            .value = .{ .bytes = click.value },
            .bot_id = .{ .bytes = click.origin.bot_id },
            .message = .{ .bytes = try std.json.Stringify.valueAlloc(a, click.message, .{}) },
        } else null,
    };
}

fn admitInteraction(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    click: slack.Interaction,
) !t.Id {
    const name = try operation(a, click.operation);
    defer a.free(name);
    const authenticated = origin(config);
    if (try replay(driver, a, name, authenticated, click.stable_request)) |task| return task;
    var index = try driver.rebuild(a);
    defer index.deinit();
    if (try @import("transfer.zig").importedIngress(
        a,
        &index,
        name,
        authenticated,
        click.stable_request,
    )) |task| return task;
    try ingress_policy.validate(a, &index, driver.service.namespace.identity);
    const selected = try bound(a, &index, config, click);
    const evidence = try ingress(a, click, selected);
    if (selected) |value| {
        return confirm(driver, a, &index, name, authenticated, value, evidence) catch |err| {
            if (!refusable(err)) return err;
            return refusal(driver, a, config, name, evidence, @errorName(err));
        };
    }
    return refusal(driver, a, config, name, evidence, "UnknownOrUnboundProposal");
}

fn refusable(err: anyerror) bool {
    return switch (err) {
        error.UnknownProposal,
        error.InvalidProposalIdentity,
        error.InvalidProposalTarget,
        error.FinalObligation,
        error.UnknownObligation,
        error.InvalidQuestion,
        => true,
        else => false,
    };
}

fn confirm(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    name: []const u8,
    authenticated: t.Origin,
    selected: Bound,
    evidence: t.Ingress,
) !t.Id {
    const delivery = selected.record.input.delivery;
    if (same(selected.button.action_id.bytes, "paredros.proposal.confirm.v1")) {
        const producer = delivery.envelope.origin.derived.predecessor;
        const ordinal = try proposalOrdinal(index, producer, selected.button.value.bytes);
        const offered = try commands.proposal(index, .{ .turn = producer, .ordinal = ordinal });
        if (offered.body == .directive) try ingress_policy.directive(
            a,
            index,
            offered.target orelse return error.InvalidProposalTarget,
            offered.body.directive,
        );
        return commands.confirmIngress(driver, a, name, authenticated, .{
            .turn = producer,
            .ordinal = ordinal,
        }, evidence);
    }
    if (!same(selected.button.action_id.bytes, "answer")) return error.UnknownProposal;
    const target = delivery.payload.logical.obligation orelse return error.InvalidQuestion;
    const prompt = delivery.payload.logical.prompt orelse return error.InvalidQuestion;
    const body: t.DirectiveBody = .{ .answer = .{
        .question = prompt,
        .choice = .{ .bytes = selected.button.value.bytes },
    } };
    try ingress_policy.directive(a, index, target, body);
    return driver.directiveIngress(
        a,
        name,
        authenticated,
        target,
        body,
        try admission.stableDigest(a, .{ target, body }),
        evidence,
    );
}

fn proposalOrdinal(index: *const idx.Index, reference: t.Reference, value: []const u8) !u32 {
    const record = index.record(reference.task) orelse return error.UnknownProposal;
    if (record.input != .turn or record.result_digest == null or
        !std.meta.eql(record.result_digest.?, reference.digest)) return error.UnknownProposal;
    var pieces = std.mem.splitScalar(u8, value, ':');
    const identity = pieces.next() orelse return error.UnknownProposal;
    const attempt = pieces.next() orelse return error.UnknownProposal;
    const ordinal = pieces.next() orelse return error.UnknownProposal;
    const expected = std.fmt.bytesToHex(record.input.turn.envelope.stable_request, .lower);
    if (pieces.next() != null or !same(identity, &expected))
        return error.UnknownProposal;
    if ((std.fmt.parseInt(u32, attempt, 10) catch return error.UnknownProposal) !=
        record.input.turn.attempt) return error.UnknownProposal;
    return std.fmt.parseInt(u32, ordinal, 10) catch error.UnknownProposal;
}

fn refusal(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    name: []const u8,
    evidence: t.Ingress,
    reason: []const u8,
) !t.Id {
    return commands.turn(driver, a, name, origin(config), .{
        .destination = config.slack.destination(),
        .text = .{ .bytes = "Button action was refused." },
        .ingress = evidence,
        .refusal = .{ .bytes = reason },
    });
}
