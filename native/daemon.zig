const std = @import("std");
const native = @import("protean_native");
const driver_module = @import("driver.zig");
const socket = @import("control_socket.zig");
const t = @import("application_types");

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
            turn_deliveries,
            select_obligation,
            import_controls: t.Id,
            step: t.Id,
            deliveries: t.Id,
            audits: t.Id,
        };
        pub const Handler = struct {
            context: *anyopaque,
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
            driver.attach(a) catch |err| {
                try session.deinit();
                return err;
            };
            return .{
                .driver = driver,
                .server = server,
                .control = control,
                .config = config,
                .session = session,
            };
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

        pub fn poll(self: *Self, a: std.mem.Allocator, monotonic_ms: i64) !Progress {
            if (self.stop_started_ms) |started| return self.stop(a, monotonic_ms, started);
            const handled_controls = try self.controls(a);
            const completion = try self.session.collect(a, false);
            const scheduled = try self.schedule(a);
            const advanced = !self.session.busy() and try self.session.advance(a) == .progressed;
            return if (handled_controls or scheduled or completion != .none or advanced)
                .progressed
            else
                .idle;
        }

        fn controls(self: *Self, a: std.mem.Allocator) !bool {
            var changed = false;
            for (0..self.config.controls_per_poll) |_| {
                var request = (try self.server.pollNext()) orelse break;
                defer request.deinit();
                const response = try self.control.call(
                    self.control.context,
                    a,
                    self.driver,
                    request.uid,
                    request.bytes,
                );
                self.server.respond(request.token, response) catch |err| switch (err) {
                    error.StaleConnection => {},
                    else => return err,
                };
                changed = true;
            }
            return changed;
        }

        fn schedule(self: *Self, a: std.mem.Allocator) !bool {
            switch (self.scheduling) {
                .retained => {
                    const resumed = try self.driver.resumeRetained(a, self.config.obligations_per_poll);
                    self.scheduling = .import_turns;
                    return resumed != 0;
                },
                .import_turns => {
                    const imported = try self.driver.importedTurns(a);
                    self.scheduling = .recover_turns;
                    return imported;
                },
                .recover_turns => {
                    const replacements = try self.driver.recoverTurns(a, self.config.obligations_per_poll);
                    defer a.free(replacements);
                    self.scheduling = .turn_deliveries;
                    return replacements.len != 0;
                },
                .turn_deliveries => {
                    const changed = try self.outputs(a, .turns);
                    self.scheduling = .select_obligation;
                    return changed;
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
                    self.scheduling = .{ .deliveries = target };
                    return changed;
                },
                .deliveries => |target| {
                    const changed = try self.outputs(a, .{ .deliveries = target });
                    self.scheduling = .{ .audits = target };
                    return changed;
                },
                .audits => |target| {
                    const changed = try self.outputs(a, .{ .audits = target });
                    self.scheduling = .retained;
                    return changed;
                },
            }
        }

        fn outputs(
            self: *Self,
            a: std.mem.Allocator,
            selection: union(enum) { turns, deliveries: t.Id, audits: t.Id },
        ) !bool {
            var index = try self.driver.rebuild(a);
            defer index.deinit();
            const tasks = switch (selection) {
                .turns => try self.driver.turnDeliveries(a),
                .deliveries => |target| try self.driver.deliveries(a, target),
                .audits => |target| try self.driver.audits(a, target),
            };
            defer a.free(tasks);
            for (tasks) |task| if (index.record(task) == null) return true;
            return false;
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
