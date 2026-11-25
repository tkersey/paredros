const c = @import("protean_contracts");
const t = @import("application_types");

pub const identity = "paredros.github.read.v1";
pub const Metadata = struct {
    base: t.Oid,
    merge_base: t.Oid,
    ahead_by: u64,
    behind_by: u64,
    total_commits: u64,
};
pub const Page = struct {
    base: t.Oid,
    tip: t.Oid,
    ordinal: u64,
    url: ?c.Utf8,
    metadata: ?Metadata,
    seen: c.Vector(t.Oid, null),
};
pub const Request = struct {
    repository: t.Repository,
    phase: union(enum) {
        repository_before: void,
        reference: void,
        page: Page,
        repository_after: void,
    },
};
pub const Failure = enum {
    unavailable,
    permission,
    rate_limit,
    binding,
    malformed,
    unsupported_object,
    incomplete,
    behind,
    diverged,
    unretained,
};
pub const Reply = union(enum) {
    repository: t.ReadEvidence,
    reference: struct { tip: t.Oid, evidence: t.ReadEvidence },
    page: struct {
        metadata: Metadata,
        commits: c.Vector(t.Commit, null),
        next: ?c.Utf8,
        evidence: t.ReadEvidence,
    },
    rejected: struct { reason: Failure, evidence: ?t.ReadEvidence },
};
