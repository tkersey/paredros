const std = @import("std");
const c = @import("protean_contracts");
const t = @import("application_types");
const configuration = @import("configuration.zig");
const restore = @import("restore.zig");

pub const Release = struct {
    recovery: t.InputReference,
    exclusive_owner: bool,
};

pub fn validateBindings(a: std.mem.Allocator, index: anytype, config: configuration.Config) !void {
    const bound = configuration.bindings(config);
    for (index.obligations) |*obligation| {
        const head = index.head(obligation);
        if (head.mode == .cancelled or head.mode == .transferred) continue;
        const repository_matches = try equal(
            a,
            t.Repository,
            head.specification.repository,
            bound.repository,
        );
        const destination_matches = try equal(
            a,
            t.Destination,
            head.specification.destination,
            bound.destination,
        );
        if (!repository_matches or !destination_matches)
            return error.RecoveryResourceMismatch;
    }
}

fn equal(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const before = try c.encodeOwned(T, a, left);
    defer a.free(before);
    const after = try c.encodeOwned(T, a, right);
    defer a.free(after);
    return std.mem.eql(u8, before, after);
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
