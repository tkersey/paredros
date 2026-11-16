const t = @import("application_types");
const audit = @import("audit_contract.zig");

pub const identity = "paredros.slack.lineage-history.v1";
pub const CapturedPage = audit.CapturedPage;
pub const Pages = audit.Pages;
pub const Request = struct { audit: t.LineageAudit, pages: Pages };
pub const Reply = union(enum) { next: CapturedPage, done: t.LineageAuditResult };
