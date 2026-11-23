const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const admission = @import("admission.zig");
const configuration = @import("configuration.zig");
const continuity = @import("continuity.zig");
const transfer = @import("transfer.zig");
const restore = @import("restore.zig");

pub const Environment = struct { io: std.Io, source: transfer.Source };
pub const Export = struct { name: t.Name, snapshot: bool = false };
pub const Import = struct {
    path: c.Text(4096),
    bytes_max: ?u64 = null,
};
pub const ExportProgress = struct {
    phase: enum { finalizing, cut_pending, written },
    cut: ?t.Id = null,
    digest: ?t.Digest = null,
    name: t.Name,
};

pub fn exportBundle(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    environment: Environment,
    operation: []const u8,
    origin: t.Origin,
    request: Export,
) !ExportProgress {
    const directory = config.backup_directory orelse return error.MissingBackupDirectory;
    if (try operationAdmitted(driver, a, operation))
        try transfer.validateExportDestination(environment.io, directory, request.name.bytes)
    else
        try transfer.validateExportName(environment.io, directory, request.name.bytes);
    const stable = try admission.stableDigest(a, .{
        .request = request,
        .directory = c.Text(4096){ .bytes = directory },
    });
    const cut_operation = if (request.snapshot) operation else try derivedOperation(
        a,
        "export-cut",
        operation,
    );
    if (!request.snapshot and !try finalize(driver, a, operation, origin, stable))
        return .{ .phase = .finalizing, .name = request.name };
    const admitted = try admission.admit(driver.service, a, .{
        .operation = cut_operation,
        .kind = .continuity_cut,
        .target = null,
        .origin = origin,
        .digest = stable,
    }, ExportMaterializer(@TypeOf(driver)){
        .driver = driver,
        .source = environment.source,
        .mode = if (request.snapshot) .snapshot else .transfer,
    });
    var index = try driver.rebuild(a);
    defer index.deinit();
    const cut_task = admitted.receipt.task;
    if (index.record(cut_task).?.result == null)
        return .{ .phase = .cut_pending, .cut = cut_task, .name = request.name };
    const digest = try transfer.writeCommitted(
        a,
        environment.io,
        directory,
        request.name.bytes,
        &index,
        cut_task,
    );
    return .{ .phase = .written, .cut = cut_task, .digest = digest, .name = request.name };
}

fn operationAdmitted(driver: anytype, a: std.mem.Allocator, operation: []const u8) !bool {
    var receipt = try driver.service.operationLookup(a, operation) orelse return false;
    receipt.deinit();
    return true;
}

fn derivedOperation(a: std.mem.Allocator, prefix: []const u8, operation: []const u8) ![]const u8 {
    const digest = try admission.stableDigest(a, t.OperationId{ .bytes = operation });
    return std.fmt.allocPrint(a, "{s}:{s}", .{ prefix, std.fmt.bytesToHex(digest, .lower) });
}

fn finalize(
    driver: anytype,
    a: std.mem.Allocator,
    operation: []const u8,
    origin: t.Origin,
    digest: t.Digest,
) !bool {
    const marker = try restore.beginTransfer(driver, a, operation, origin, digest);
    var index = try driver.rebuild(a);
    defer index.deinit();
    var finished = true;
    for (index.obligations) |*obligation| {
        const head = index.head(obligation);
        if (head.mode == .cancelled or head.mode == .transferred) continue;
        finished = false;
        const pending = try transfer.admitPendingControls(driver, a, obligation.task, origin);
        if (pending.remaining != 0) continue;
        const name = try std.fmt.allocPrint(a, "transfer:{s}:{s}", .{
            std.fmt.bytesToHex(marker, .lower), std.fmt.bytesToHex(obligation.task, .lower),
        });
        _ = try driver.directive(a, name, origin, obligation.task, .transfer);
    }
    return finished;
}

fn cut(request: admission.Request, a: std.mem.Allocator, bundle: transfer.Bundle) !t.Input {
    const bytes = try c.encodeOwned(transfer.Bundle, a, bundle);
    return .{ .continuity_cut = .{
        .envelope = .{
            .operation = .{ .bytes = request.operation },
            .stable_request = request.digest,
            .origin = request.origin,
        },
        .bundle_digest = continuity.hash(bytes),
        .bytes = .{ .bytes = bytes },
    } };
}

fn ExportMaterializer(comptime Driver: type) type {
    return struct {
        driver: Driver,
        source: transfer.Source,
        mode: transfer.Mode,

        pub fn materialize(
            self: @This(),
            a: std.mem.Allocator,
            request: admission.Request,
        ) !t.Input {
            var source = self.source;
            source.clock_ms = try self.driver.clock.now(self.driver.clock.context);
            var bundle = try transfer.capture(self.driver, a, source, self.mode);
            defer bundle.deinit();
            return cut(request, a, bundle.value);
        }
    };
}

pub fn importBundle(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    environment: Environment,
    operation: []const u8,
    origin: t.Origin,
    request: Import,
) !transfer.ImportProgress {
    const stable = try admission.stableDigest(a, .{
        .request = request,
        .repository = config.repository.value(),
        .destination = config.slack.destination(),
    });
    const admitted_request: admission.Request = .{
        .operation = operation,
        .kind = .continuity_cut,
        .target = null,
        .origin = origin,
        .digest = stable,
    };
    const manifest = if (try operationAdmitted(driver, a, operation))
        (try admission.admit(driver.service, a, admitted_request, Frozen{})).receipt.task
    else
        try beginImport(driver, a, config, environment, admitted_request, request);
    var index = try driver.rebuild(a);
    defer index.deinit();
    const record = index.record(manifest).?;
    if (record.result == null) return .{
        .phase = .manifest_pending,
        .manifest = record.task,
        .members = 0,
        .obligations = try a.alloc(t.Id, 0),
    };
    var bundle = try transfer.committedBundle(a, &index, record.task);
    defer bundle.deinit();
    return transfer.importBundle(driver, a, config, origin, bundle.value);
}

fn beginImport(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    environment: Environment,
    admitted_request: admission.Request,
    request: Import,
) !t.Id {
    const maximum: ?usize = if (request.bytes_max) |value|
        std.math.cast(usize, value) orelse return error.Capacity
    else
        null;
    var bundle = try transfer.readBundle(a, environment.io, request.path.bytes, maximum);
    defer bundle.deinit();
    var index = try driver.rebuild(a);
    defer index.deinit();
    if (index.recovery_purpose == .transfer) return error.TransferredNamespace;
    const namespace = driver.service.namespace.identity;
    if (try transfer.validateImport(a, &index, config, namespace, bundle.value)) |task|
        return task;
    const input = try cut(admitted_request, a, bundle.value);
    const result = try admission.admit(driver.service, a, admitted_request, Frozen{
        .input = input,
    });
    return result.receipt.task;
}

const Frozen = struct {
    input: ?t.Input = null,

    pub fn materialize(self: Frozen, _: std.mem.Allocator, _: admission.Request) !t.Input {
        return self.input orelse error.MissingAdmittedInput;
    }
};
