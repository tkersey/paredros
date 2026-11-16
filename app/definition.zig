const protean = @import("protean");
const t = @import("application_types");
const application = @import("application.zig");
const github = @import("github_contract.zig");
const history = @import("audit_contract.zig");
const model = @import("model_contract.zig");
const slack = @import("slack_contract.zig");
const method = @import("method_contract.zig");

pub const System = protean.system(.{
    .InitialArgs = t.Input,
    .Result = t.Output,
    .Failure = t.Failure,
    .application = application.Application,
});
pub const resources = .{};
pub const capabilities = .{
    .{ .identity = github.identity, .resource_role = "read" },
    .{ .identity = history.identity, .resource_role = "read" },
    .{ .identity = model.P.identity, .resource_role = "inference" },
    .{ .identity = slack.notification_identity, .resource_role = "write" },
    .{ .identity = method.workspace_identity, .resource_role = "workspace" },
    .{ .identity = method.codec_identity, .resource_role = "frozen" },
    .{ .identity = @import("experiment_contract.zig").codec_identity, .resource_role = "frozen" },
    .{ .identity = @import("experiment_contract.zig").clock_identity, .resource_role = "measurement" },
};
