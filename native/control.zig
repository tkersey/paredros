const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const t = @import("application_types");
const configuration = @import("configuration.zig");
const commands = @import("commands.zig");
const idx = @import("index.zig");
const experiments = @import("experiments.zig");
const recovery_control = @import("recovery_control.zig");
const continuity_control = @import("continuity_control.zig");
const transfer = @import("transfer.zig");
const restore = @import("restore.zig");
const ingress_policy = @import("ingress_policy.zig");

pub const frame_bytes_max: u32 = 4 * 1024 * 1024;

pub const Request = struct {
    version: u32,
    operation: ?t.OperationId,
    command: union(enum) {
        status: struct { after: ?t.Id, limit: u32 },
        monitor_add: struct { wording: t.Text, interval_ms: ?u64 },
        monitor_show: t.Id,
        monitor_directives: struct { target: t.Id, after: ?u64, limit: u32 },
        directive: struct { target: t.Id, body: t.DirectiveBody },
        ask: struct { text: t.Text, target: ?t.Id },
        proposal_confirm: commands.ProposalSelector,
        proposal_show: commands.ProposalSelector,
        experiment_run: experiments.Request,
        experiment_show: t.Digest,
        task_show: t.Id,
        delivery_show: t.DeliveryKey,
        audit_delivery: t.DeliveryKey,
        method_show: t.Id,
        recovery_status: void,
        recovery_candidates: struct { after: ?u64, limit: u32 },
        recovery_begin: void,
        recovery_release: recovery_control.Release,
        transfer_export: continuity_control.Export,
        transfer_import: continuity_control.Import,
    },
};

pub fn encode(a: std.mem.Allocator, request: Request) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return native.json.canonical(a, try native.values.toJson(Request, arena.allocator(), request));
}

pub fn dispatch(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
) ![]const u8 {
    return dispatchWithEnvironment(a, driver, config, uid, bytes, null);
}

pub fn dispatchWithEnvironment(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
    environment: ?continuity_control.Environment,
) ![]const u8 {
    return dispatchWithIndex(a, driver, config, uid, bytes, environment, null);
}

pub fn dispatchWithIndex(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
    environment: ?continuity_control.Environment,
    index: ?*const idx.Index,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const response = execute(scratch, driver, config, uid, bytes, environment, index) catch |err|
        try rejected(scratch, err);
    return frame(a, response) catch |err|
        frame(a, try rejected(scratch, err));
}

fn frame(a: std.mem.Allocator, value: native.json.Value) ![]u8 {
    const limits: native.json.Limits = .{ .bytes = frame_bytes_max };
    if (!try native.json.fits(a, value, limits)) return error.Capacity;
    return native.json.canonicalBounded(a, value, frame_bytes_max);
}

fn rejected(a: std.mem.Allocator, err: anyerror) !native.json.Value {
    var value = envelope();
    try native.json.put(a, &value, "schema", native.json.string("paredros.control.v1"));
    try native.json.put(a, &value, "status", native.json.string("rejected"));
    try native.json.put(a, &value, "error", native.json.string(@errorName(err)));
    return value;
}

fn envelope() native.json.Value {
    return native.json.object();
}

fn reply(
    a: std.mem.Allocator,
    disposition: []const u8,
    data: native.json.Value,
) !native.json.Value {
    var value = envelope();
    try native.json.put(a, &value, "schema", native.json.string("paredros.control.v1"));
    try native.json.put(a, &value, "status", native.json.string(disposition));
    try native.json.put(a, &value, "data", data);
    return value;
}

fn operation(request: Request) ![]const u8 {
    const value = (request.operation orelse return error.MissingOperationId).bytes;
    if (value.len == 0) return error.InvalidOperationId;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidOperationId;
    return value;
}

fn execute(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    uid: u32,
    bytes: []const u8,
    environment: ?continuity_control.Environment,
    validated: ?*const idx.Index,
) !native.json.Value {
    if (uid != config.current_uid) return error.PermissionDenied;
    var parsed = try native.json.parse(a, bytes, .{ .bytes = frame_bytes_max });
    defer parsed.deinit();
    const request = try native.values.fromJson(Request, a, parsed.value);
    if (request.version != 1) return error.UnsupportedProtocol;
    const origin: t.Origin = .{ .local = .{ .uid = uid } };
    if (readOnly(request)) {
        if (validated) |index| return inspect(a, index, request, try driver.clock.now(driver.clock.context));
        var index = try driver.rebuild(a);
        defer index.deinit();
        return inspect(a, &index, request, try driver.clock.now(driver.clock.context));
    }
    const operation_id = try operation(request);
    if (request.command != .transfer_export and request.command != .transfer_import and
        request.command != .audit_delivery)
        try admissionOpen(a, driver, operation_id);
    var response = if (request.command == .transfer_export or request.command == .transfer_import)
        try continuityCommand(a, driver, config, origin, request, environment)
    else
        try admitted(a, try admitCommand(a, driver, config, origin, request, operation_id));
    try native.json.put(a, &response, "operation", native.json.string(operation_id));
    return response;
}

fn readOnly(request: Request) bool {
    return switch (request.command) {
        .status,
        .monitor_show,
        .monitor_directives,
        .task_show,
        .delivery_show,
        .method_show,
        .proposal_show,
        .experiment_show,
        .recovery_status,
        .recovery_candidates,
        => true,
        else => false,
    };
}

fn admissionOpen(a: std.mem.Allocator, driver: anytype, operation_id: []const u8) !void {
    if (try driver.service.operationLookup(a, operation_id)) |found| {
        var receipt = found;
        defer receipt.deinit();
        return;
    }
    var index = try driver.rebuild(a);
    defer index.deinit();
    try ingress_policy.validate(a, &index, driver.service.namespace.identity);
}

fn admitCommand(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    origin: t.Origin,
    request: Request,
    operation_id: []const u8,
) !t.Id {
    switch (request.command) {
        .monitor_add => |value| return commands.monitor(
            driver,
            a,
            operation_id,
            origin,
            try specification(config, value.wording, value.interval_ms),
        ),
        .directive => |value| {
            try validateDirective(a, driver, config, operation_id, value.target, value.body);
            return driver.directive(a, operation_id, origin, value.target, value.body);
        },
        .ask => |value| return driver.turn(
            a,
            operation_id,
            origin,
            .{
                .destination = config.slack.destination(),
                .text = value.text,
                .target = value.target,
                .anchor_template = true,
                .genesis_template = try specification(config, .{ .bytes = "" }, null),
            },
        ),
        .experiment_run => |value| return experiments.admit(
            driver,
            a,
            operation_id,
            origin,
            value,
        ),
        .proposal_confirm => |value| return confirmProposal(
            a,
            driver,
            config,
            operation_id,
            origin,
            value,
        ),
        .recovery_begin => return restore.begin(driver, a, operation_id, origin),
        .audit_delivery => |value| return @import("audit_control.zig").request(
            driver,
            a,
            operation_id,
            origin,
            value,
        ),
        .recovery_release => |value| return recovery_control.release(
            a,
            driver,
            config,
            operation_id,
            origin,
            value,
        ),
        else => return error.InvalidMutation,
    }
}

fn validateDirective(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    operation_id: []const u8,
    target: t.Id,
    body: t.DirectiveBody,
) !void {
    if (try driver.service.operationLookup(a, operation_id)) |found| {
        var receipt = found;
        defer receipt.deinit();
        return;
    }
    var index = try driver.rebuild(a);
    defer index.deinit();
    try ingress_policy.directive(a, &index, target, body);
    if (body == .recovery_release)
        try recovery_control.validateBindings(a, &index, config);
}

fn continuityCommand(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    origin: t.Origin,
    request: Request,
    environment: ?continuity_control.Environment,
) !native.json.Value {
    const context = environment orelse return error.ContinuityEnvironmentUnavailable;
    const operation_id = try operation(request);
    switch (request.command) {
        .transfer_export => |value| {
            const result = try continuity_control.exportBundle(
                driver,
                a,
                config,
                context,
                operation_id,
                origin,
                value,
            );
            return reply(
                a,
                if (result.phase == .written) "observed" else "admitted",
                try native.values.toJson(continuity_control.ExportProgress, a, result),
            );
        },
        .transfer_import => |value| {
            var result = try continuity_control.importBundle(
                driver,
                a,
                config,
                context,
                operation_id,
                origin,
                value,
            );
            defer result.deinit(a);
            const value_type = struct {
                phase: @FieldType(transfer.ImportProgress, "phase"),
                manifest: t.Id,
                members: u64,
                obligations: c.Vector(t.Id, null),
            };
            const data = try native.values.toJson(value_type, a, .{
                .phase = result.phase,
                .manifest = result.manifest,
                .members = result.members,
                .obligations = .{ .items = result.obligations },
            });
            return reply(a, if (result.phase == .materialized) "observed" else "admitted", data);
        },
        else => return error.InvalidContinuityCommand,
    }
}

fn confirmProposal(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    operation_id: []const u8,
    origin: t.Origin,
    selector: commands.ProposalSelector,
) !t.Id {
    var index = try driver.rebuild(a);
    defer index.deinit();
    const confirmation = try commands.resolveProposal(&index, selector);
    const selected = try commands.proposal(&index, confirmation);
    if (selected.body == .directive) try validateDirective(
        a,
        driver,
        config,
        operation_id,
        selected.target orelse return error.InvalidProposalTarget,
        selected.body.directive,
    );
    return driver.confirm(a, operation_id, origin, confirmation);
}

fn proposal(
    a: std.mem.Allocator,
    index: *const idx.Index,
    selector: commands.ProposalSelector,
) !native.json.Value {
    const confirmation = try commands.resolveProposal(index, selector);
    return native.values.toJson(t.Proposal, a, try commands.proposal(index, confirmation));
}

fn specification(
    config: configuration.Config,
    wording: t.Text,
    interval: ?u64,
) !t.Specification {
    const interval_ms = interval orelse config.interval_ms;
    if (interval_ms == 0) return error.InvalidInterval;
    return .{
        .revision = 0,
        .repository = config.repository.value(),
        .destination = config.slack.destination(),
        .interval_ms = interval_ms,
        .anchor_ms = 0,
        .wording = wording,
        .policies = config.policies,
    };
}

fn admitted(a: std.mem.Allocator, task_id: t.Id) !native.json.Value {
    var data = native.json.object();
    try native.json.put(a, &data, "task", native.json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(task_id, .lower)),
    ));
    return reply(a, "admitted", data);
}

fn inspect(
    a: std.mem.Allocator,
    index: *const idx.Index,
    request: Request,
    clock_ms: i64,
) !native.json.Value {
    const data = switch (request.command) {
        .status => |value| try status(a, index, clock_ms, value.after, value.limit),
        .monitor_show => |id| try monitor(a, index, id, clock_ms),
        .monitor_directives => |page| try pendingDirectives(a, index, page.target, page.after, page.limit),
        .task_show => |id| try task(a, index, id),
        .method_show => |id| try native.values.toJson(t.Method, a, index.head(
            index.obligation(id) orelse return error.UnknownObligation,
        ).method),
        .delivery_show => |key| try deliveries(a, index, key),
        .proposal_show => |value| try proposal(a, index, value),
        .experiment_show => |value| try campaign(a, index, value),
        .recovery_status => try recoveryStatus(a, index),
        .recovery_candidates => |value| try native.values.toJson(
            @import("history_evidence.zig").Page,
            a,
            try @import("history_evidence.zig").page(a, index, null, value.after, value.limit),
        ),
        else => return error.InvalidReadCommand,
    };
    return reply(a, "observed", data);
}

fn recoveryStatus(a: std.mem.Allocator, index: *const idx.Index) !native.json.Value {
    var result = try native.values.toJson(struct {
        recovery: ?t.InputReference,
        recovery_hold: bool,
        restore_cut: c.Vector(t.InputReference, null),
        recovery_purpose: ?t.RestorePurpose,
    }, a, .{
        .recovery = index.recovery,
        .recovery_hold = index.recovery_hold,
        .restore_cut = .{ .items = index.restore_cut },
        .recovery_purpose = index.recovery_purpose,
    });
    const history = @import("history_evidence.zig");
    try native.json.put(a, &result, "external_history", try native.values.toJson(
        history.Page,
        a,
        try history.page(a, index, null, null, 16),
    ));
    return result;
}

fn campaign(a: std.mem.Allocator, index: *const idx.Index, id: t.Digest) !native.json.Value {
    var observed = try experiments.campaign(a, index, id);
    defer observed.deinit();
    return native.values.toJson(experiments.Campaign, a, observed.value);
}

fn status(
    a: std.mem.Allocator,
    index: *const idx.Index,
    clock_ms: i64,
    after: ?t.Id,
    limit: u32,
) !native.json.Value {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    const ordered = try a.dupe(idx.Obligation, index.obligations);
    std.mem.sort(idx.Obligation, ordered, {}, struct {
        fn less(_: void, left: idx.Obligation, right: idx.Obligation) bool {
            return std.mem.order(u8, &left.task, &right.task) == .lt;
        }
    }.less);
    var items: std.array_list.Managed(native.json.Value) = .init(a);
    var next: ?t.Id = null;
    for (ordered) |obligation| {
        if (after) |previous| if (std.mem.order(u8, &obligation.task, &previous) != .gt) continue;
        if (items.items.len == limit) break;
        try items.append(try monitor(a, index, obligation.task, clock_ms));
        next = obligation.task;
    }
    var result = native.json.object();
    try native.json.put(a, &result, "obligations", .{ .array = items });
    try native.json.put(a, &result, "next", if (items.items.len == limit)
        try native.values.toJson(?t.Id, a, next)
    else
        .null);
    try native.json.put(
        a,
        &result,
        "task_count",
        try native.values.toJson(u64, a, index.records.len),
    );
    try native.json.put(a, &result, "clock_ms", try native.values.toJson(i64, a, clock_ms));
    return result;
}

fn monitor(
    a: std.mem.Allocator,
    index: *const idx.Index,
    id: t.Id,
    clock_ms: i64,
) !native.json.Value {
    const obligation = index.obligation(id) orelse return error.UnknownObligation;
    const head = index.head(obligation);
    var result = native.json.object();
    try native.json.put(a, &result, "id", native.json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
    ));
    try native.json.put(a, &result, "head", try native.values.toJson(t.Head, a, head));
    try native.json.put(
        a,
        &result,
        "effective_mode",
        native.json.string(@tagName(obligation.effective_mode)),
    );
    try native.json.put(
        a,
        &result,
        "ordinary_dispatch",
        .{ .bool = obligation.ordinaryDispatch() },
    );
    const age: ?u64 = if (head.last_observation) |check| if (clock_ms >= check.acquired_ms)
        @intCast(@as(i128, clock_ms) - check.acquired_ms)
    else
        null else null;
    try native.json.put(a, &result, "source_age_ms", try native.values.toJson(?u64, a, age));
    const reconciliation = try @import("reconciliation.zig").inspect(a, index, id);
    try native.json.put(a, &result, "reconciliation", native.json.string(
        @tagName(reconciliation.capability),
    ));
    try native.json.put(a, &result, "reconciliation_evidence", try native.values.toJson(
        @TypeOf(reconciliation),
        a,
        reconciliation,
    ));
    try appendPending(a, index, obligation, null, 16, &result);
    return result;
}

fn pendingDirectives(
    a: std.mem.Allocator,
    index: *const idx.Index,
    id: t.Id,
    after: ?u64,
    limit: u32,
) !native.json.Value {
    const obligation = index.obligation(id) orelse return error.UnknownObligation;
    var result = native.json.object();
    try appendPending(a, index, obligation, after, limit, &result);
    return result;
}

fn appendPending(
    a: std.mem.Allocator,
    index: *const idx.Index,
    obligation: *const idx.Obligation,
    after: ?u64,
    limit: u32,
    result: *native.json.Value,
) !void {
    if (limit == 0 or limit > 64) return error.InvalidPageLimit;
    const folded = index.head(obligation).folded_directive_ordinal;
    var total: u64 = 0;
    for (obligation.directives) |position| {
        if (index.records[position].input.directive.ordinal > folded) total += 1;
    }
    try native.json.put(a, result, "pending_directives_total", try native.values.toJson(u64, a, total));
    try native.json.put(a, result, "folded_directive_ordinal", try native.values.toJson(u64, a, folded));
    var pending: std.array_list.Managed(native.json.Value) = .init(a);
    var cursor = @max(after orelse folded, folded);
    var more = false;
    for (obligation.directives) |position| {
        const directive = index.records[position].input.directive;
        if (directive.ordinal <= cursor) continue;
        if (pending.items.len == limit) {
            more = true;
            break;
        }
        try pending.append(try native.values.toJson(t.Directive, a, directive));
        try native.json.put(a, result, "pending_directives", .{ .array = pending });
        try native.json.put(a, result, "pending_directives_next", try native.values.toJson(u64, a, directive.ordinal));
        if (!try native.json.fits(a, try reply(a, "observed", result.*), .{ .bytes = frame_bytes_max })) {
            _ = pending.pop();
            if (pending.items.len == 0) return error.Capacity;
            more = true;
            break;
        }
        cursor = directive.ordinal;
    }
    try native.json.put(a, result, "pending_directives", .{ .array = pending });
    try native.json.put(a, result, "pending_directives_next", try native.values.toJson(?u64, a, if (more) cursor else null));
}

fn task(a: std.mem.Allocator, index: *const idx.Index, id: t.Id) !native.json.Value {
    const record = try currentTask(index, id);
    var result = native.json.object();
    try native.json.put(a, &result, "requested_id", native.json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
    ));
    try native.json.put(a, &result, "id", native.json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(record.task, .lower)),
    ));
    try native.json.put(a, &result, "input", try native.values.toJson(t.Input, a, record.input));
    try native.json.put(
        a,
        &result,
        "result",
        try native.values.toJson(?t.Output, a, record.result),
    );
    try native.json.put(
        a,
        &result,
        "result_digest",
        try native.values.toJson(?t.Digest, a, record.result_digest),
    );
    try native.json.put(a, &result, "superseded", .{ .bool = record.superseded });
    const owner_status = if (record.owner_evidence) |evidence| evidence.status else null;
    const retry_pending = record.input == .turn and record.input.turn.attempt < 2 and
        record.result == null and (owner_status == .failed or owner_status == .cancelled or
        owner_status == .unknown);
    try native.json.put(a, &result, "retry_pending", .{ .bool = retry_pending });
    try native.json.put(a, &result, "task_status", if (owner_status) |value|
        native.json.string(@tagName(value))
    else
        .null);
    if (record.owner_snapshot) |snapshot| {
        try native.json.put(a, &result, "outcome", native.json.string(@tagName(snapshot.outcome)));
        try native.json.put(
            a,
            &result,
            "accounting",
            try native.values.toJson(t.Accounting, a, snapshot.accounting),
        );
    }
    return result;
}

fn currentTask(index: *const idx.Index, id: t.Id) !*const idx.Record {
    var record = index.record(id) orelse return error.UnknownTask;
    for (0..3) |_| {
        if (record.input != .turn or !record.superseded) return record;
        var child: ?*const idx.Record = null;
        for (index.records) |*candidate| {
            if (candidate.input != .turn) continue;
            const replacement = candidate.input.turn.replacement orelse continue;
            if (!std.meta.eql(replacement.input.task, record.task)) continue;
            if (child != null) return error.ConflictingTurnSuccessor;
            child = candidate;
        }
        record = child orelse return error.MissingTurnSuccessor;
    }
    return error.InvalidTurnAttempt;
}

fn deliveries(
    a: std.mem.Allocator,
    index: *const idx.Index,
    key: t.DeliveryKey,
) !native.json.Value {
    var items: std.array_list.Managed(native.json.Value) = .init(a);
    for (index.records) |record| {
        if (record.input != .delivery or !std.meta.eql(record.input.delivery.key, key)) continue;
        try items.append(try task(a, index, record.task));
    }
    if (items.items.len == 0) return error.UnknownDelivery;
    return .{ .array = items };
}
