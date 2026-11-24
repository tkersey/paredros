const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");
const admission = @import("admission.zig");
const configuration = @import("configuration.zig");
const continuity = @import("continuity.zig");
const transfer = @import("transfer.zig");
const transfer_marker = @import("transfer_marker.zig");
const compatibility = @import("compatibility.zig");
const wire = @import("wire.zig");

pub const Environment = struct { io: std.Io, source: transfer.Source };

pub fn sourceEnvironment(
    io: std.Io,
    namespace: t.Digest,
    admitted: anytype,
    image: []const u8,
    runtime: t.Digest,
) !Environment {
    return .{ .io = io, .source = .{
        .namespace = namespace,
        .build = try wire.parse(t.Digest, admitted.manifest_id),
        .image = compatibility.ImageDigest.of(image),
        .runtime = runtime,
        .contracts = try wire.parse(t.Digest, admitted.protocol_schema_sha256),
        .clock_ms = 0,
    } };
}
pub const Export = struct { name: t.Name, snapshot: bool = false };
pub const Import = struct {
    path: c.Text(4096),
    digest: t.Digest,
    bytes_max: ?u64 = null,
};
pub const ExportProgress = struct {
    phase: enum { finalizing, cut_pending, written },
    operation: t.OperationId,
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
    const stable = try admission.stableDigest(a, .{
        .request = request,
        .directory = c.Text(4096){ .bytes = directory },
    });
    var index = try driver.rebuild(a);
    defer index.deinit();
    const selected = try a.dupe(u8, exportOperation(&index, operation, request.snapshot, stable));
    if (index.operations.contains(selected)) {
        try transfer.validateExportDestination(environment.io, directory, request.name.bytes);
    } else {
        if (transfer.importPending(&index)) return error.ContinuityImportPending;
        try transfer.validateExportName(environment.io, directory, request.name.bytes);
    }
    var progress: ExportProgress = .{
        .phase = .finalizing,
        .operation = .{ .bytes = selected },
        .name = request.name,
    };
    if (!request.snapshot and !try finalize(driver, a, &index, selected, origin, stable))
        return progress;
    progress.cut = try exportCut(driver, a, &index, environment.source, .{
        .operation = selected,
        .kind = .continuity_cut,
        .target = null,
        .origin = origin,
        .digest = stable,
    }, request.snapshot);
    var committed = try driver.rebuild(a);
    defer committed.deinit();
    progress.phase = .cut_pending;
    if (committed.record(progress.cut.?).?.result == null) return progress;
    progress.digest = try transfer.writeCommitted(
        a,
        environment.io,
        directory,
        request.name.bytes,
        &committed,
        progress.cut.?,
    );
    progress.phase = .written;
    return progress;
}

fn exportOperation(
    index: *const idx.Index,
    operation: []const u8,
    snapshot: bool,
    stable: t.Digest,
) []const u8 {
    if (!snapshot) {
        const marker = index.transfer_marker orelse return operation;
        return index.records[marker].input.transfer.envelope.operation.bytes;
    }
    if (index.operations.contains(operation)) return operation;
    for (index.records) |record| {
        if (record.input != .continuity_cut or record.result != null) continue;
        const envelope = record.input.continuity_cut.envelope;
        if (std.meta.eql(envelope.stable_request, stable)) return envelope.operation.bytes;
    }
    return operation;
}

fn exportCut(
    driver: anytype,
    a: std.mem.Allocator,
    index: *const idx.Index,
    source: transfer.Source,
    request: admission.Request,
    snapshot: bool,
) !t.Id {
    var selected = request;
    if (!snapshot) {
        selected.operation = try derivedOperation(a, "export-cut", request.operation);
        if (index.operations.get(selected.operation)) |position|
            return index.records[position].task;
    }
    const admitted = try admission.admit(driver.service, a, selected, ExportMaterializer(
        @TypeOf(driver),
    ){
        .driver = driver,
        .source = source,
        .mode = if (snapshot) .snapshot else .transfer,
    });
    return admitted.receipt.task;
}

fn derivedOperation(a: std.mem.Allocator, prefix: []const u8, operation: []const u8) ![]const u8 {
    const digest = try admission.stableDigest(a, t.OperationId{ .bytes = operation });
    return std.fmt.allocPrint(a, "{s}:{s}", .{ prefix, std.fmt.bytesToHex(digest, .lower) });
}

fn finalize(
    driver: anytype,
    a: std.mem.Allocator,
    fenced: *const idx.Index,
    operation: []const u8,
    origin: t.Origin,
    digest: t.Digest,
) !bool {
    const marker = if (fenced.transfer_marker) |position|
        fenced.records[position].task
    else
        try transfer_marker.admit(driver, a, operation, origin, digest);
    var index = try driver.rebuild(a);
    defer index.deinit();
    var finished = !try transfer.genesisPending(driver.service, a, &index);
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
    if (!driver.attached or origin != .local) return error.TransferLocalOnly;
    if (!std.fs.path.isAbsolute(request.path.bytes)) return error.RelativeTransferPath;
    const admitted_request: admission.Request = .{
        .operation = operation,
        .kind = .continuity_cut,
        .target = null,
        .origin = origin,
        .digest = try admission.stableDigest(a, request),
    };
    var index = try driver.rebuild(a);
    defer index.deinit();
    const view = index.continuity_import;
    if (index.operations.contains(operation)) {
        _ = try admission.admit(driver.service, a, admitted_request, Frozen{});
        try storedBindings(a, config, &index);
    } else if (view != null and std.meta.eql(view.?.digest, request.digest)) {
        try storedBindings(a, config, &index);
    } else {
        if (index.transferred()) return error.TransferredNamespace;
        try beginImport(driver, a, config, environment.io, &index, admitted_request, request);
    }
    return transfer.importProgress(driver, a);
}

fn storedBindings(
    a: std.mem.Allocator,
    config: configuration.Config,
    index: *const idx.Index,
) !void {
    const view = index.continuity_import orelse return error.MissingContinuityManifest;
    const stored = index.records[view.position].input.continuity_cut.bytes.bytes;
    var bundle = try c.decodeBorrowed(transfer.Bundle, a, stored);
    defer bundle.deinit();
    try transfer.validateBindings(a, bundle.value, configuration.bindings(config));
}

fn beginImport(
    driver: anytype,
    a: std.mem.Allocator,
    config: configuration.Config,
    io: std.Io,
    index: *const idx.Index,
    request: admission.Request,
    selected: Import,
) !void {
    const maximum: ?usize = if (selected.bytes_max) |value|
        std.math.cast(usize, value) orelse return error.Capacity
    else
        null;
    const bytes = try native.configuration.readFile(a, io, selected.path.bytes, maximum, true);
    defer a.free(bytes);
    if (!std.meta.eql(continuity.hash(bytes), selected.digest)) return error.BundleDigestMismatch;
    var bundle = try c.decodeOwned(transfer.Bundle, a, bytes);
    defer bundle.deinit();
    const namespace = driver.service.namespace.identity;
    if (try transfer.validateImport(a, index, config, namespace, bundle.value) != null)
        return error.ContinuityImportConflict;
    const input = try cut(request, a, bundle.value);
    _ = try admission.admit(driver.service, a, request, Frozen{ .input = input });
}

const Frozen = struct {
    input: ?t.Input = null,

    pub fn materialize(self: Frozen, _: std.mem.Allocator, _: admission.Request) !t.Input {
        return self.input orelse error.MissingAdmittedInput;
    }
};
