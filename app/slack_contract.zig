const t = @import("application_types");

pub const identity = "agent.notification.slack.v1";
pub const notification_identity = "agent.notification.deliver.v1.slack";
pub const Request = struct {
    destination: t.Destination,
    key: t.DeliveryKey,
    payload: t.DeliveryPayload,
};
pub const Reply = t.DeliveryOutcome;
