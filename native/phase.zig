const std = @import("std");
const t = @import("application_types");
const github = @import("../app/github_contract.zig");
const method = @import("../app/method_contract.zig");

pub fn attempted(record: anytype) !t.Phase {
    const snapshot = record.owner_snapshot orelse return error.MissingOwnerSnapshot;
    var phase: t.Phase = .fold;
    for (snapshot.attempts.items) |attempt| {
        const next: t.Phase = if (std.mem.eql(u8, attempt.capability.bytes, github.identity))
            .check
        else if (attempt.inference or std.mem.eql(
            u8,
            attempt.capability.bytes,
            method.workspace_identity,
        ))
            .render
        else
            continue;
        if (phase != .fold and phase != next) return error.MixedPhaseEffects;
        phase = next;
    }
    return phase;
}
