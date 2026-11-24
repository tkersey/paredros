const std = @import("std");
const native = @import("protean_native");
const driver_module = @import("driver.zig");
const socket = @import("control_socket.zig");
const control_protocol = @import("control.zig");
const t = @import("application_types");
const Index = @import("index.zig").Index;

pub const Config = struct {
    controls_per_poll: u32 = 8,
    obligations_per_poll: u32 = 8,
    stop_grace_ms: u32 = 30_000,
};
pub const Progress = enum { idle, progressed, stopped, stopped_unclean, force_exit_required };

pub fn Daemon(comptime Types: type) type {
    return struct {
        const Self = @This();
        const Driver = driver_module.Driver(Types);
        const Schedule = union(enum) {
            retained,
            import_turns,
            recover_turns,
            select_obligation,
            import_controls: t.Id,
            step: t.Id,
        };
        pub const Handler = struct {
            context: *anyopaque,
            observation: ?struct {
                on_start: bool = true,
                enabled: *const fn () bool,
                read_only: ?*const fn (std.mem.Allocator, []const u8) bool = null,
                call: *const fn (
                    *anyopaque,
                    std.mem.Allocator,
                    *Driver,
                    u32,
                    []const u8,
                    *const Index,
                ) anyerror![]const u8,
            } = null,
            call: *const fn (
                *anyopaque,
                std.mem.Allocator,
                *Driver,
                u32,
                []const u8,
            ) anyerror![]const u8,
        };

        driver: *Driver,
        server: *socket.Server,
        control: Handler,
        config: Config,
        session: native.Session(Types),
        cursor: usize = 0,
        scheduling: Schedule = .retained,
        stop_started_ms: ?i64 = null,
        stop_expired: bool = false,
        parked: bool = false,

        pub fn init(
            a: std.mem.Allocator,
            driver: *Driver,
            server: *socket.Server,
            control: Handler,
            config: Config,
        ) !Self {
            if (config.controls_per_poll == 0 or config.obligations_per_poll == 0)
                return error.InvalidConfig;
            var session = try native.Session(Types).init(driver.service);
            var index = driver.attachIndexed(a) catch |err| {
                try session.deinit();
                return err;
            };
            defer index.deinit();
            var result: Self = .{
                .driver = driver,
                .server = server,
                .control = control,
                .config = config,
                .session = session,
            };
            if (control.observation) |observer| {
                if (observer.on_start and observer.enabled()) {
                    var frame = std.heap.ArenaAllocator.init(a);
                    defer frame.deinit();
                    _ = result.controlOne(frame.allocator(), &index, null) catch |err| {
                        try result.deinit();
                        return err;
                    };
                }
            }
            return result;
        }

        pub fn deinit(self: *Self) !void {
            if (self.session.busy()) return error.Busy;
            try self.session.deinit();
            self.driver.detach();
            self.* = undefined;
        }

        pub fn beginStop(self: *Self, monotonic_ms: i64) void {
            if (self.stop_started_ms != null) return;
            self.stop_started_ms = monotonic_ms;
            self.driver.detach();
        }

        const ScheduledRead = struct { daemon: *Self, handled: bool = false };

        pub fn poll(self: *Self, a: std.mem.Allocator, monotonic_ms: i64) !Progress {
            if (self.stop_started_ms) |started| return self.stop(a, monotonic_ms, started);
            const handled_controls = try self.controls(a);
            const completion = try self.session.collect(a, false);
            var read: ScheduledRead = .{ .daemon = self };
            const scheduled = blk: {
                if (self.control.observation) |observer| {
                    if (handled_controls < self.config.controls_per_poll and
                        observer.read_only != null and observer.enabled())
                        self.driver.after_rebuild = .{
                            .context = &read,
                            .observe = readWhileScheduling,
                        };
                }
                defer self.driver.after_rebuild = null;
                break :blk try self.schedule(a);
            };
            const advanced = !self.session.busy() and try self.session.advance(a) == .progressed;
            return if (handled_controls != 0 or read.handled or scheduled or
                completion != .none or advanced)
                .progressed
            else
                .idle;
        }

        fn controls(self: *Self, a: std.mem.Allocator) !u32 {
            var handled: u32 = 0;
            while (handled < self.config.controls_per_poll) : (handled += 1) {
                if (!try self.controlOne(a, null, null)) break;
            }
            return handled;
        }

        fn readWhileScheduling(
            context: *anyopaque,
            a: std.mem.Allocator,
            index: *const Index,
        ) !void {
            const read: *ScheduledRead = @ptrCast(@alignCast(context));
            const observer = read.daemon.control.observation.?;
            if (observer.enabled()) read.handled = try read.daemon.controlOne(a, index, .{
                .allocator = a,
                .permits = observer.read_only.?,
            });
        }

        fn controlOne(
            self: *Self,
            a: std.mem.Allocator,
            attachment: ?*const Index,
            selection: ?socket.Selection,
        ) !bool {
            var request = (try self.server.pollSelected(selection)) orelse return false;
            defer request.deinit();
            const handler = self.control;
            const response = if (attachment) |index|
                try handler.observation.?.call(
                    handler.context,
                    a,
                    self.driver,
                    request.uid,
                    request.bytes,
                    index,
                )
            else
                try handler.call(handler.context, a, self.driver, request.uid, request.bytes);
            self.server.respond(request.token, response) catch |err| switch (err) {
                error.StaleConnection => {},
                error.FrameTooLarge => try self.server.respond(
                    request.token,
                    control_protocol.capacity_rejection,
                ),
                else => return err,
            };
            return true;
        }

        fn schedule(self: *Self, a: std.mem.Allocator) !bool {
            switch (self.scheduling) {
                .retained => {
                    const resumed = try self.driver.resumeRetained(
                        a,
                        self.config.obligations_per_poll,
                    );
                    self.scheduling = .import_turns;
                    return resumed != 0;
                },
                .import_turns => {
                    const imported = try self.driver.importedTurns(a);
                    self.scheduling = .recover_turns;
                    return imported;
                },
                .recover_turns => {
                    const replacements = try self.driver.recoverTurns(
                        a,
                        self.config.obligations_per_poll,
                    );
                    defer a.free(replacements);
                    self.scheduling = .select_obligation;
                    return replacements.len != 0;
                },
                .select_obligation => {
                    var index = try self.driver.rebuild(a);
                    defer index.deinit();
                    if (index.obligations.len == 0) {
                        self.scheduling = .retained;
                        return false;
                    }
                    self.cursor %= index.obligations.len;
                    const target = index.obligations[self.cursor].task;
                    self.cursor = (self.cursor + 1) % index.obligations.len;
                    self.scheduling = .{ .import_controls = target };
                    return false;
                },
                .import_controls => |target| {
                    const changed = try self.driver.importedControls(a, target);
                    self.scheduling = .{ .step = target };
                    return changed;
                },
                .step => |target| {
                    const changed = try self.driver.nextStep(a, target) != null;
                    self.scheduling = .retained;
                    return changed;
                },
            }
        }

        fn stop(self: *Self, a: std.mem.Allocator, now_ms: i64, started: i64) !Progress {
            if (self.parked) return if (self.stop_expired) .stopped_unclean else .stopped;
            const elapsed = @as(i128, now_ms) - @as(i128, started);
            self.stop_expired = self.stop_expired or
                (self.session.busy() and elapsed >= self.config.stop_grace_ms);
            _ = try self.session.collect(a, self.stop_expired);
            if (self.session.busy()) return if (self.stop_expired)
                .force_exit_required
            else
                .idle;
            try self.session.park(a);
            self.parked = true;
            return if (self.stop_expired) .stopped_unclean else .stopped;
        }
    };
}
