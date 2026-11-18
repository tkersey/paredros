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
const outbound = @import("outbound.zig");

pub const Clock = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) anyerror!i64,
};

pub fn Driver(comptime Types: type) type {
    return struct {
        const Self = @This();
        service: *native.tasks.Service(Types),
        clock: Clock,
        model: ?t.ModelBinding = null,
        page_limit: u32 = 128,
        attached: bool = false,
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
            var index = try catalog.rebuild(self.service, a, self.page_limit);
            errdefer index.deinit();
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
            return eligibility.permits(a, &index, request, try self.clock.now(self.clock.context));
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

        pub fn confirm(
            self: *Self,
            a: std.mem.Allocator,
            operation: []const u8,
            origin: t.Origin,
            confirmation: commands.Confirmation,
        ) !t.Id {
            return commands.confirm(self, a, operation, origin, confirmation);
        }

        pub fn recoverTurns(self: *Self, a: std.mem.Allocator, limit: u32) ![]t.Id {
            return @import("conversation_recovery.zig").advance(self, a, limit);
        }

        pub fn resumeRetained(self: *Self, a: std.mem.Allocator, limit: u32) !u32 {
            return @import("continuation_recovery.zig").advance(self, a, limit);
        }

        pub fn importedTurns(self: *Self, a: std.mem.Allocator) !bool {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            if (index.recovery_purpose == .transfer or index.portable.len == 0) return false;
            const transfer = @import("transfer.zig");
            const importing = try transfer.importPending(
                a,
                &index,
                self.service.namespace.identity,
            );
            if (importing) return false;
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

        pub fn turnDeliveries(self: *Self, a: std.mem.Allocator) ![]t.Id {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            return outbound.admitTurnDeliveries(self.service, a, &index);
        }

        pub fn deliveries(self: *Self, a: std.mem.Allocator, target: t.Id) ![]t.Id {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            return outbound.admitDeliveries(
                self.service,
                a,
                &index,
                target,
                try self.clock.now(self.clock.context),
            );
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

        pub fn audits(self: *Self, a: std.mem.Allocator, target: t.Id) ![]t.Id {
            if (!self.attached) return error.DriverDetached;
            var index = try self.rebuild(a);
            defer index.deinit();
            return outbound.admitAudits(
                self.service,
                a,
                &index,
                target,
                try self.clock.now(self.clock.context),
            );
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
            return self.directiveIngress(a, operation, origin, target, body, digest, null);
        }

        pub fn directiveIngress(
            self: *Self,
            a: std.mem.Allocator,
            operation: []const u8,
            origin: t.Origin,
            target: t.Id,
            body: t.DirectiveBody,
            digest: t.Digest,
            ingress: ?t.Ingress,
        ) !t.Id {
            if (!self.attached or origin == .derived) return error.UnauthenticatedDirective;
            const request: admission.Request = .{
                .operation = operation,
                .kind = .directive,
                .target = target,
                .origin = origin,
                .digest = try admission.stableDigest(a, .{
                    .operation = t.OperationId{ .bytes = operation },
                    .request = digest,
                }),
                .ingress = ingress,
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
                if (head.mode == .cancelled or head.mode == .transferred)
                    return error.FinalObligation;
                try @import("restore.zig").validateDirective(
                    &index,
                    request.target.?,
                    self.body,
                    request.origin,
                );
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
                        .ingress = request.ingress,
                    },
                    .obligation = request.target.?,
                    .ordinal = try std.math.add(u64, ordinal, 1),
                    .predecessor = predecessor,
                    .body = self.body,
                } };
            }
        };

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
        const evidence = @import("interaction_evidence.zig").target(index, record);
        const target = evidence orelse switch (record.input) {
            .delivery => |value| @import("delivery_target.zig").resolve(index, value),
            .audit => |value| @import("delivery_target.zig").resolve(index, value.delivery),
            .turn => |value| value.target,
            else => continue,
        };
        if (target == null or !std.meta.eql(target.?, obligation.task)) continue;
        if (record.input == .audit and record.result == null) continue;
        if (!materialize.readyFact(record)) continue;
        var consumed = false;
        for (obligation.chain) |position| {
            const output = index.records[position].result.?;
            const prior = if (output == .genesis) output.genesis else output.step.head;
            for (prior.consumed.items) |fact|
                if (std.meta.eql(fact.task, record.task) and fact.revision == record.revision) {
                    consumed = true;
                };
        }
        if (!consumed) return true;
    }
    if (!obligation.ordinaryDispatch()) return false;
    if (clock_ms >= head.next_due_ms and clock_ms >= head.source_not_before_ms) return true;
    return head.digest == null and head.observed.sequence > head.told.sequence and
        clock_ms >= head.render_not_before_ms;
}
