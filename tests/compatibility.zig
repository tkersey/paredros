const std = @import("std");
const native = @import("protean_native");
const compatibility = @import("../native/compatibility.zig");
const t = @import("application_types");

fn candidate() compatibility.Candidate {
    return .{
        .image = .{ .sha256 = @splat(1) },
        .runtime = @splat(2),
        .has_controller = false,
        .principal = "uid:42",
        .tenant = "T1",
        .profile = .{ .digest = @splat(3), .resources = &.{} },
    };
}

fn task() native.Namespace.AuditTaskView {
    return .{
        .task = @splat(4),
        .revision = 7,
        .terminal = false,
        .application_id = t.application_id,
        .principal = "uid:42",
        .tenant = "T1",
        .image = .{ .digest = @splat(1), .bytes = 100 },
        .profile = .{ .digest = @splat(3), .bytes = 200 },
        .resources = &.{},
        .runtime_identity = @splat(2),
        .has_controller = false,
    };
}

test "compatibility distinguishes readable terminal state from changed continuation" {
    var selected = candidate();
    try std.testing.expectEqual(
        .exact_continuation,
        std.meta.activeTag(try compatibility.classify(selected, task())),
    );
    selected.runtime = @splat(8);
    try std.testing.expectEqual(
        .runtime,
        (try compatibility.classify(selected, task())).requires_supersession,
    );
    var terminal = task();
    terminal.terminal = true;
    selected.profile = null;
    try std.testing.expectEqual(
        .terminal_reusable,
        std.meta.activeTag(try compatibility.classify(selected, terminal)),
    );
}

test "compatibility does not turn an unresolved profile into a continuation claim" {
    var selected = candidate();
    selected.profile = null;
    try std.testing.expectEqual(
        .profile_unresolved,
        std.meta.activeTag(try compatibility.classify(selected, task())),
    );
    selected.image = .{ .sha256 = @splat(9) };
    try std.testing.expectEqual(
        .image,
        (try compatibility.classify(selected, task())).requires_supersession,
    );
}

test "compatibility compares all execution resources and controller selection" {
    var retained = task();
    const resource: compatibility.Object = .{ .digest = @splat(10), .bytes = 300 };
    retained.resources = &.{resource};
    try std.testing.expectEqual(
        .resources,
        (try compatibility.classify(candidate(), retained)).requires_supersession,
    );
    var selected = candidate();
    selected.profile.?.resources = &.{resource};
    try std.testing.expectEqual(
        .exact_continuation,
        std.meta.activeTag(try compatibility.classify(selected, retained)),
    );
    var changed = resource;
    changed.bytes += 1;
    selected.profile.?.resources = &.{changed};
    try std.testing.expectEqual(
        .resources,
        (try compatibility.classify(selected, retained)).requires_supersession,
    );
    selected.has_controller = true;
    try std.testing.expectEqual(
        .controller,
        (try compatibility.classify(selected, task())).requires_supersession,
    );
}

test "compatibility rejects foreign owner even for otherwise readable terminal state" {
    var retained = task();
    retained.terminal = true;
    retained.principal = "uid:43";
    try std.testing.expectError(
        error.IncompatibleOwner,
        compatibility.classify(candidate(), retained),
    );
    retained = task();
    retained.tenant = "T2";
    try std.testing.expectError(
        error.IncompatibleOwner,
        compatibility.classify(candidate(), retained),
    );
    retained = task();
    retained.application_id = "foreign";
    try std.testing.expectError(
        error.WrongApplication,
        compatibility.classify(candidate(), retained),
    );
}
