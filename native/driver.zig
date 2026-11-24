const std = @import("std");
const c = @import("protean_contracts");
const native = @import("protean_native");
const t = @import("application_types");
const idx = @import("index.zig");
const catalog = @import("catalog.zig");
const admission = @import("admission.zig");
const materialize = @import("materialize.zig");
const eligibility = @import("eligibility.zig");
const recovery = @import("recovery.zig");
const commands = @import("commands.zig");
const configuration = @import("configuration.zig");
const bounds = @import("../app/bounds.zig");

pub const Clock = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) anyerror!i64,
};
pub const Fatal = error{
    StorageUnavailable,
    CorruptState,
    OutOfMemory,
    DriverDetached,
    ClockOutOfRange,
};
pub const Work = enum { controls, step, turn, retained, import };
pub const Part = enum { controls, step };
pub const Key = struct { item: t.Id, work: Work };
pub const Fault = idx.Fault;
pub const fault_retry_ms: i64 = 1_000;
pub const fault_retry_max_ms: i64 = 60_000;
pub const Faults = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    items: std.AutoHashMapUnmanaged(Key, Fault) = .empty,

    pub fn deinit(self: *Faults) void {
        self.items.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn latest(self: *const Faults, item: t.Id) ?Fault {
        var found: ?Fault = null;
        inline for (.{ Work.controls, Work.step }) |work| {
            if (self.items.get(.{ .item = item, .work = work })) |fault| {
                if (found == null or fault.at_ms > found.?.at_ms) found = fault;
            }
        }
        return found;
    }

    fn ready(self: *const Faults, key: Key, now_ms: i64) bool {
        const fault = self.items.get(key) orelse return true;
        return now_ms >= fault.retry_ms or now_ms < fault.at_ms;
    }

    fn record(self: *Faults, key: Key, reason: []const u8, now_ms: i64) !void {
        const entry = try self.items.getOrPut(self.allocator, key);
        const failures = if (entry.found_existing) entry.value_ptr.failures +| 1 else 1;
        const shift: u6 = @intCast(@min(failures - 1, 6));
        const delay = @min(fault_retry_ms << shift, fault_retry_max_ms);
        entry.value_ptr.* = .{
            .reason = reason,
            .at_ms = now_ms,
            .failures = failures,
            .retry_ms = now_ms +| delay,
        };
    }
};

pub fn split(err: anyerror) Fatal![]const u8 {
    inline for (@typeInfo(Fatal).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return @field(Fatal, name);
    }
    return @errorName(err);
}

pub fn Driver(comptime Types: type) type {
    return struct {
        const Self = @This();
        service: *native.tasks.Service(Types),
        clock: Clock,
        model: ?t.ModelBinding = null,
        bindings: ?configuration.Bindings = null,
        page_limit: u32 = 128,
        attached: bool = false,
        faults: Faults = .{},
        after_rebuild: ?struct {
            context: *anyopaque,
            observe: *const fn (*anyopaque, std.mem.Allocator, *const idx.Index) anyerror!void,
        } = null,

        pub fn attach(self: *Self, a: std.mem.Allocator) !void {
            var index = try self.attachIndexed(a);
            index.deinit();
        }

        pub fn attachIndexed(self: *Self, a: std.mem.Allocator) !idx.Index {
            if (self.attached) return error.AlreadyAttached;
            self.service.dispatch_gate = .held;
            const index = try self.rebuild(a);
            self.service.dispatch_gate = .{ .selected = .{
                .context = self,
                .permits = dispatch,
            } };
            self.attached = true;
            return index;
        }

        pub fn detach(self: *Self) void {
            self.service.dispatch_gate = .held;
            self.attached = false;
        }

        pub fn rebuild(self: *Self, a: std.mem.Allocator) !idx.Index {
            var index = catalog.rebuild(self.service, a, self.page_limit) catch |err| {
                _ = try split(err);
                return error.CorruptState;
            };
            errdefer index.deinit();
            for (index.obligations) |*obligation| obligation.fault = self.faults.latest(obligation.task);
            if (self.after_rebuild) |observer| {
                self.after_rebuild = null;
                try observer.observe(observer.context, a, &index);
            }
            return index;
        }

        fn dispatch(
            context: *anyopaque,
            a: std.mem.Allocator,
            request: native.tasks.DispatchRequest,
        ) !bool {
            const self: *Self = @ptrCast(@alignCast(context));
            var index = try self.rebuild(a);
            defer index.deinit();
            return eligibility.permits(&index, request);
        }

        pub fn genesis(
            self: *Self,
            a: std.mem.Allocator,
            operation: []const u8,
            origin: t.Origin,
            specification: t.Specification,
        ) !t.Id {
            return commands.genesis(self, a, operation, origin, specification);
        }

        pub fn turn(
            self: *Self,
            a: std.mem.Allocator,
            operation: []const u8,
            origin: t.Origin,
            request: commands.TurnRequest,
        ) !t.Id {
            return commands.turn(self, a, operation, origin, request);
        }

        pub fn guarded(
            self: *Self,
            key: Key,
            comptime T: type,
            comptime work: anytype,
            args: anytype,
        ) Fatal!?T {
            const now_ms = self.clock.now(self.clock.context) catch return error.ClockOutOfRange;
            if (!self.faults.ready(key, now_ms)) return null;
            const result: T = @call(.auto, work, args) catch |err| {
                try self.faults.record(key, try split(err), now_ms);
                return null;
            };
            _ = self.faults.items.remove(key);
            return result;
        }

        pub fn recoverTurns(self: *Self, a: std.mem.Allocator, limit: u32) ![]t.Id {
            return @import("conversation_recovery.zig").advance(self, a, limit);
        }

        pub fn resumeRetained(self: *Self, a: std.mem.Allocator, limit: u32) !u32 {
            return @import("continuation_recovery.zig").advance(self, a, limit);
        }

        pub fn importTurns(self: *Self, a: std.mem.Allocator) Fatal!bool {
            const key: Key = .{ .item = @splat(0), .work = .import };
            return (try self.guarded(key, bool, importedTurns, .{ self, a })) orelse false;
        }

        pub fn importStep(self: *Self, a: std.mem.Allocator) !bool {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            return @import("transfer.zig").advanceImport(self, a, &index);
        }

        pub fn importedTurns(self: *Self, a: std.mem.Allocator) !bool {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            const transfer = @import("transfer.zig");
            if (transfer.importPending(&index)) return transfer.advanceImport(self, a, &index);
            if (index.transferred() or index.portable.len == 0) return false;
            const manifest = index.record(index.portable[0].metadata.manifest.task) orelse
                return error.MissingContinuityManifest;
            if (manifest.input != .continuity_cut) return error.InvalidContinuityManifest;
            const progress = try transfer.admitPendingTurns(
                self,
                a,
                manifest.input.continuity_cut.envelope.origin,
            );
            return progress.admitted != null;
        }

        pub fn importedControls(self: *Self, a: std.mem.Allocator, target: t.Id) !bool {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            const record = index.record(target) orelse return error.UnknownObligation;
            if (record.input != .genesis) return error.UnknownObligation;
            if (record.input.genesis.imported == null) return false;
            const progress = try @import("transfer.zig").admitPendingControls(
                self,
                a,
                target,
                record.input.genesis.envelope.origin,
            );
            return progress.admitted != null;
        }

        pub fn directive(
            self: *Self,
            a: std.mem.Allocator,
            operation: []const u8,
            origin: t.Origin,
            target: t.Id,
            body: t.DirectiveBody,
        ) !t.Id {
            if (!self.attached or origin == .derived) return error.UnauthenticatedDirective;
            const stable: struct { target: t.Id, body: t.DirectiveBody } = .{
                .target = target,
                .body = body,
            };
            return self.directiveRequest(
                a,
                operation,
                origin,
                target,
                body,
                try admission.stableDigest(a, stable),
            );
        }

        pub fn directiveRequest(
            self: *Self,
            a: std.mem.Allocator,
            operation: []const u8,
            origin: t.Origin,
            target: t.Id,
            body: t.DirectiveBody,
            digest: t.Digest,
        ) !t.Id {
            if (!self.attached or origin == .derived) return error.UnauthenticatedDirective;
            const request: admission.Request = .{
                .operation = operation,
                .kind = .directive,
                .target = target,
                .origin = origin,
                .digest = try admission.directiveDigest(a, operation, digest),
            };
            const result = try admission.admit(
                self.service,
                a,
                request,
                DirectiveMaterializer{ .driver = self, .body = body },
            );
            return result.receipt.task;
        }

        const DirectiveMaterializer = struct {
            driver: *Self,
            body: t.DirectiveBody,

            pub fn materialize(
                self: @This(),
                a: std.mem.Allocator,
                request: admission.Request,
            ) !t.Input {
                var index = try self.driver.rebuild(a);
                defer index.deinit();
                const obligation = index.obligation(request.target.?) orelse
                    return error.UnknownObligation;
                const head = index.head(obligation);
                if (obligation.effective_mode == .cancelled or
                    obligation.effective_mode == .transferred) return error.FinalObligation;
                if (self.body == .amend) try admission.amendment(self.body.amend);
                if (self.body == .adopt)
                    try @import("method_catalog.zig").adoption(a, &index, self.body.adopt.method);
                var ordinal = head.folded_directive_ordinal;
                var predecessor = head.last_directive;
                if (obligation.directives.len > 0) {
                    const latest_position = obligation.directives.len - 1;
                    const latest = index.records[obligation.directives[latest_position]];
                    ordinal = latest.input.directive.ordinal;
                    predecessor = .{ .task = latest.task, .digest = latest.input_digest };
                }
                return .{ .directive = .{
                    .envelope = .{
                        .operation = .{ .bytes = request.operation },
                        .stable_request = request.digest,
                        .origin = request.origin,
                    },
                    .obligation = request.target.?,
                    .ordinal = try std.math.add(u64, ordinal, 1),
                    .predecessor = predecessor,
                    .body = self.body,
                } };
            }
        };

        pub fn advance(self: *Self, a: std.mem.Allocator, target: t.Id, part: Part) Fatal!bool {
            if (!self.attached) return error.DriverDetached;
            return switch (part) {
                .controls => (try self.guarded(
                    .{ .item = target, .work = .controls },
                    bool,
                    importedControls,
                    .{ self, a, target },
                )) orelse false,
                .step => ((try self.guarded(
                    .{ .item = target, .work = .step },
                    ?t.Id,
                    nextStep,
                    .{ self, a, target },
                )) orelse null) != null,
            };
        }

        pub fn nextStep(self: *Self, a: std.mem.Allocator, target: t.Id) !?t.Id {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            const obligation = index.obligation(target) orelse return error.UnknownObligation;
            const transferred_controls = try @import("transfer.zig").pendingControlsAdmitted(
                a,
                &index,
                target,
            );
            if (!transferred_controls) return null;
            const clock_ms = try self.clock.now(self.clock.context);
            if (!bounds.instant(clock_ms)) return error.ClockOutOfRange;
            if (obligation.eligible != null) return recovery.advance(
                self.service,
                a,
                &index,
                obligation,
                clock_ms,
                self.model,
                self.page_limit,
            );
            const head = index.head(obligation);
            if (head.mode == .cancelled or head.mode == .transferred) return null;
            if (!needsStep(&index, obligation, clock_ms)) return null;
            var frozen = try materialize.step(a, &index, target, clock_ms, self.model);
            defer frozen.deinit();
            const admitted = try self.service.submit(
                a,
                frozen.value.envelope.operation.bytes,
                .{ .step = frozen.value },
            );
            return admitted.receipt.task;
        }
    };
}

pub fn needsStep(index: *const idx.Index, obligation: *const idx.Obligation, clock_ms: i64) bool {
    const head = index.head(obligation);
    if (@as(i128, head.clock_ms) - clock_ms >
        head.specification.policies.clock_regression_tolerance_ms) return true;
    for (obligation.directives) |position|
        if (index.records[position].input.directive.ordinal > head.folded_directive_ordinal)
            return true;
    for (index.records) |record| {
        if (record.input == .step) continue;
        const target = materialize.factTarget(record) orelse continue;
        if (!std.meta.eql(target, obligation.task)) continue;
        if (materialize.unsettled(obligation, record)) return true;
    }
    if (!obligation.ordinaryDispatch()) return false;
    const schedule = head.schedule;
    const scheduled = clock_ms >= schedule.next_due_ms and clock_ms >= schedule.source_not_before_ms;
    if ((head.check_requested or scheduled) and clock_ms >= schedule.provider_not_before_ms)
        return true;
    return head.observed.sequence > head.told.sequence and
        clock_ms >= schedule.render_not_before_ms;
}
