const c = @import("protean_contracts");
const t = @import("application_types");

pub const identity = "paredros.slack.history.v1";
pub const CapturedPage = struct { bot_id: t.Name, evidence: t.ReadEvidence };
pub const Pages = c.Vector(CapturedPage, null);
pub const Request = struct { audit: t.Audit, pages: Pages };
pub const Reply = union(enum) { next: CapturedPage, done: t.AuditResult };
