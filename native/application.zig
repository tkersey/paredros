const std = @import("std");
const native = @import("protean_native");
const cts = @import("protean_contracts");
const t = @import("application_types");
const contract = @import("../app/slack_contract.zig");
const github = @import("github_external.zig");
const slack = @import("slack_external.zig");
const history = @import("slack_audit_external.zig");
const model = @import("model_external.zig");
const method = @import("method_external.zig");
const preparation = @import("delivery_prepare.zig");

pub const notification_identity = contract.notification_identity;
pub const Types = t;
pub const Environment = struct {
    github: ?github.Environment = null,
    slack: ?slack.Environment = null,
    model: ?model.Environment = null,
};
pub const Application = struct {
    pub const declarations: []const native.Declaration = &.{
        githubDeclaration(),
        historyDeclaration(),
        modelDeclaration(),
        notificationDeclaration(),
        method.declaration(),
        method.codecDeclaration(),
        @import("experiment_external.zig").declaration(),
        @import("experiment_external.zig").clockDeclaration(),
    };
};

fn githubDeclaration() native.Declaration {
    var declaration = github.declaration();
    declaration.capture.?.acquire = acquireGithub;
    return declaration;
}

fn historyDeclaration() native.Declaration {
    var declaration = history.declaration();
    declaration.capture.?.acquire = acquireHistory;
    return declaration;
}

fn modelDeclaration() native.Declaration {
    var declaration = model.declaration();
    declaration.capture.?.acquire = acquireModel;
    return declaration;
}

fn notificationDeclaration() native.Declaration {
    var declaration = slack.declaration();
    declaration.identity = notification_identity;
    declaration.payload_schema = deliverySchema;
    declaration.capture.?.prepare = prepareDelivery;
    declaration.capture.?.acquire = acquireSlack;
    declaration.capture.?.interpret = interpretDelivery;
    return declaration;
}

fn deliverySchema(allocator: std.mem.Allocator) ![]u8 {
    return native.values.schemaBytes(t.Delivery, allocator);
}

fn route(ctx: native.Context, comptime field: []const u8) native.Context {
    var routed = ctx;
    routed.environment = null;
    if (ctx.environment) |handle| {
        const environment: *Environment = @ptrCast(@alignCast(handle));
        if (@field(environment, field)) |*selected| routed.environment = selected;
    }
    return routed;
}

fn acquireGithub(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    return github.declaration().capture.?.acquire(route(ctx, "github"), bytes);
}

fn acquireHistory(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    return history.declaration().capture.?.acquire(route(ctx, "slack"), bytes);
}

fn acquireModel(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    return model.declaration().capture.?.acquire(route(ctx, "model"), bytes);
}

fn acquireSlack(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    return slack.declaration().capture.?.acquire(route(ctx, "slack"), bytes);
}

pub fn projectDelivery(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var decoded = try cts.decodeOwned(t.Delivery, allocator, bytes);
    defer decoded.deinit();
    try preparation.verifyStored(allocator, decoded.value);
    const canonical = try cts.encodeOwned(t.Delivery, allocator, decoded.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.InvalidPayload;
    return cts.encodeOwned(contract.Request, allocator, .{
        .destination = decoded.value.destination,
        .key = decoded.value.key,
        .payload = decoded.value.payload,
    });
}

fn prepareDelivery(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    const request = try projectDelivery(ctx.allocator, bytes);
    defer ctx.allocator.free(request);
    return slack.declaration().capture.?.prepare(ctx, request);
}

fn interpretDelivery(
    ctx: native.registry.ProjectionContext,
    request: []const u8,
    prepared: []const u8,
    captured: []const u8,
) !native.registry.Projection {
    const projected = try projectDelivery(ctx.allocator, request);
    defer ctx.allocator.free(projected);
    return slack.declaration().capture.?.interpret(ctx, projected, prepared, captured);
}
