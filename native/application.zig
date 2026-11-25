const native = @import("protean_native");
const t = @import("application_types");
const github = @import("github_external.zig");
const model = @import("model_external.zig");
const method = @import("method_external.zig");
const experiment = @import("experiment_external.zig");

pub const Types = t;
pub const Environment = struct {
    github: ?github.Environment = null,
    model: ?model.Environment = null,
};
pub const Application = struct {
    pub const declarations: []const native.Declaration = &.{
        githubDeclaration(),
        modelDeclaration(),
        method.declaration(),
        method.codecDeclaration(),
        experiment.declaration(),
        experiment.clockDeclaration(),
    };
};

fn githubDeclaration() native.Declaration {
    var declaration = github.declaration();
    declaration.capture.?.acquire = acquireGithub;
    return declaration;
}

fn modelDeclaration() native.Declaration {
    var declaration = model.declaration();
    declaration.capture.?.acquire = acquireModel;
    return declaration;
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

fn acquireModel(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    return model.declaration().capture.?.acquire(route(ctx, "model"), bytes);
}
