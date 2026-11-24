const std = @import("std");
const t = @import("application_types");
const configuration = @import("configuration.zig");
const restore = @import("restore.zig");

pub const Release = struct {
    recovery: t.InputReference,
    exclusive_owner: bool,
};

pub fn validateBindings(_: std.mem.Allocator, index: anytype, config: configuration.Config) !void {
    const bound = configuration.bindings(config);
    for (index.obligations) |*obligation| {
        const head = index.head(obligation);
        if (head.mode == .cancelled or head.mode == .transferred) continue;
        if (!bound.admits(head.specification.repository)) return error.RecoveryResourceMismatch;
    }
}

pub fn validateNewRelease(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    operation: []const u8,
) !void {
    if (try driver.service.operationLookup(a, operation)) |found| {
        var receipt = found;
        defer receipt.deinit();
        return;
    }
    var index = try driver.rebuild(a);
    defer index.deinit();
    try validateBindings(a, &index, config);
}

pub fn release(
    a: std.mem.Allocator,
    driver: anytype,
    config: configuration.Config,
    operation: []const u8,
    origin: t.Origin,
    request: Release,
) !t.Id {
    try validateNewRelease(a, driver, config, operation);
    return restore.release(
        driver,
        a,
        operation,
        origin,
        request.recovery,
        request.exclusive_owner,
    );
}
