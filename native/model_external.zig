const std = @import("std");
const native = @import("protean_native");
const c = @import("protean_contracts");
const m = @import("../app/model_contract.zig");

pub const Adapter = native.adaptive_responses.Adapter(m.P);
pub const Admission = native.adaptive_responses.Admission(m.P);
pub const Environment = native.responses.Environment;
pub const Raw = native.responses.Raw;

pub fn declaration() native.Declaration {
    return Adapter.declaration();
}

pub fn emptyCatalog(a: std.mem.Allocator) ![]u8 {
    return c.encodeOwned(m.P.AdaptiveCatalog, a, .{ .skills = .{ .items = &.{} } });
}

fn hash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn binding(
    a: std.mem.Allocator,
    profile_bytes: []const u8,
    profile_id: []const u8,
    effort: m.Effort,
) !c.Decoded(m.Binding) {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const policy = try Admission.policy(scratch, profile_bytes);
    const route = try native.responses.route.read(scratch, profile_bytes);
    const catalog = try emptyCatalog(scratch);
    if (!std.meta.eql(policy.core_tools, [2]bool{ true, true }) or
        !std.meta.eql(policy.permitted_tools, [2]bool{ true, true }) or
        policy.catalog.bytes != catalog.len or
        !std.meta.eql(policy.catalog.digest, hash(catalog))) return error.IncompatibleModelPolicy;
    for (policy.profiles.items) |profile| {
        if (!std.mem.eql(u8, profile.id.bytes, profile_id)) continue;
        try native.responses.route.admitProfile(route.route, profile);
        var allowed = false;
        for (profile.efforts.items) |available| allowed = allowed or available == effort;
        if (!allowed) return error.UnsupportedEffort;
        const encoded = try c.encodeOwned(m.Binding, scratch, .{
            .policy = hash(profile_bytes),
            .selection = .{
                .profile_id = profile.id,
                .profile_digest = try Admission.profileDigest(scratch, profile),
                .effective_effort = effort,
                .control_revision = 0,
            },
            .profile = profile,
            .catalog = policy.catalog,
            .responses = route,
        });
        return c.decodeOwned(m.Binding, a, encoded);
    }
    return error.UnknownInferenceProfile;
}
