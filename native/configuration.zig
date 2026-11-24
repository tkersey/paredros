const std = @import("std");
const native = @import("protean_native");
const protean = @import("protean");
const c = @import("protean_contracts");
const t = @import("application_types");
const m = @import("../app/model_contract.zig");
const application = @import("application.zig");
const external = @import("model_external.zig");
const github = @import("github.zig");

pub const Grants = struct {
    github_read: bool = false,
    model: bool = false,
};
pub const Repository = struct {
    account: []const u8,
    id: u64,
    owner: []const u8,
    name: []const u8,
    ref: []const u8,

    pub fn value(self: Repository) t.Repository {
        return .{
            .account = .{ .bytes = self.account },
            .id = self.id,
            .owner = .{ .bytes = self.owner },
            .name = .{ .bytes = self.name },
            .ref = .{ .bytes = self.ref },
        };
    }
};
pub const Model = struct {
    account: []const u8,
    slug: []const u8,
    effort: m.Effort,
    siwc_bin: []const u8,
    auth_dir: []const u8,
    request_bytes: u32 = 1024 * 1024,
    response_bytes: u32 = 2 * 1024 * 1024,
    timeout_ms: u32 = 30_000,
};
pub const Config = struct {
    version: u32,
    current_uid: u32,
    namespace_path: []const u8,
    control_socket_path: []const u8,
    backup_directory: ?[]const u8 = null,
    repository: Repository,
    mode: enum { offline, live } = .offline,
    grants: Grants = .{},
    interval_ms: u64 = 900_000,
    policies: t.Policies = .{},
    model: ?Model = null,
    github_credential_file: ?[]const u8 = null,
};
pub const OwnedConfig = std.json.Parsed(Config);
pub const Bindings = struct { repository: t.Repository };
pub const tenant = "local";

pub fn bindings(config: Config) Bindings {
    return .{ .repository = config.repository.value() };
}
pub const Build = struct { runtime_identity: t.Digest, image_identity: t.Digest };

fn visible(bytes: []const u8, maximum: usize) !void {
    if (bytes.len == 0 or bytes.len > maximum) return error.InvalidConfiguration;
    for (bytes) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidConfiguration;
}

fn absolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidConfiguration;
}

fn validate(value: Config, current_uid: u32) !void {
    if (value.version != 1) return error.UnsupportedConfiguration;
    if (value.current_uid != current_uid) return error.PermissionDenied;
    try absolute(value.namespace_path);
    try absolute(value.control_socket_path);
    if (value.backup_directory) |path| try absolute(path);
    if (std.mem.eql(u8, value.namespace_path, value.control_socket_path))
        return error.InvalidConfiguration;
    if (value.interval_ms == 0) return error.InvalidConfiguration;
    const repository_names = [_][]const u8{
        value.repository.account, value.repository.owner, value.repository.name,
    };
    for (repository_names) |text| try visible(text, 128);
    try visible(value.repository.ref, 1024);
    try github.validateBinding(.{
        .repository_id = value.repository.id,
        .owner = value.repository.owner,
        .name = value.repository.name,
        .ref = value.repository.ref,
    });
    if (value.github_credential_file) |path| try absolute(path);
    if (value.model) |model| {
        try visible(model.account, 64);
        try visible(model.slug, 128);
        try absolute(model.siwc_bin);
        try absolute(model.auth_dir);
        if (model.request_bytes == 0 or model.response_bytes == 0 or model.timeout_ms == 0)
            return error.InvalidConfiguration;
    }
    if (value.mode == .live and value.grants.model and value.model == null)
        return error.MissingModelSelection;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8, current_uid: u32) !OwnedConfig {
    var parsed = try std.json.parseFromSlice(Config, a, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    try validate(parsed.value, current_uid);
    return parsed;
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8, uid: u32) !OwnedConfig {
    const bytes = try native.configuration.readFile(a, io, path, 1024 * 1024, false);
    defer a.free(bytes);
    return parse(a, bytes, uid);
}

pub const OwnedLaunch = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    config: Config = undefined,
    environment: application.Environment = .{},
    profile: native.tasks.Profile = undefined,
    model_binding: ?c.Decoded(m.Binding) = null,
    selection: ?*native.siwc.Selection = null,
    github_token: ?[]u8 = null,

    pub fn deinit(self: *OwnedLaunch) void {
        if (self.model_binding) |*binding| binding.deinit();
        if (self.selection) |selection| selection.deinit();
        if (self.github_token) |bytes| std.crypto.secureZero(u8, bytes);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

fn credential(a: std.mem.Allocator, io: std.Io, path: ?[]const u8) ![]u8 {
    const bytes = try native.configuration.readFile(
        a,
        io,
        path orelse return error.MissingCredentialReference,
        16 * 1024,
        true,
    );
    errdefer std.crypto.secureZero(u8, bytes);
    try visible(bytes, 16 * 1024);
    return bytes;
}

fn remote(self: *OwnedLaunch, io: std.Io) !?t.Digest {
    const a = self.arena.allocator();
    const config = self.config;
    if (config.mode == .offline) return null;
    if (config.grants.github_read) {
        self.github_token = try credential(a, io, config.github_credential_file);
        self.environment.github = .{ .repository = config.repository.value(), .http = .{
            .account = config.repository.account,
            .origin = "https://api.github.com",
            .token = self.github_token.?,
        } };
        _ = try self.environment.github.?.http.validate();
    }
    if (!config.grants.model) return null;
    const model = config.model orelse return error.MissingModelSelection;
    self.selection = try native.siwc.Selection.init(self.allocator, io, .{
        .account = model.account,
        .executable = model.siwc_bin,
        .auth_dir = model.auth_dir,
    });
    const status = try self.selection.?.status(null);
    if (status.phase != .ready and status.phase != .refresh_required)
        return error.ModelAccountNotReady;
    return status.binding orelse error.ModelAccountNotReady;
}

fn hash(bytes: []const u8) t.Digest {
    var digest: t.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn adaptive(a: std.mem.Allocator, config: Config) !native.json.Value {
    const model = config.model orelse return error.MissingModelSelection;
    const catalog = try external.emptyCatalog(a);
    const profile: protean.model_invocation.AdaptiveInferenceProfile = .{
        .id = .{ .bytes = "selected" },
        .model = .{ .bytes = model.slug },
        .reasoning_mode = .standard,
        .reasoning_context = .auto,
        .efforts = .{ .items = &.{model.effort} },
        .effort_update = false,
        .explicit_cache = false,
        .additional_tools = true,
        .cache_diagnostics = false,
        .opaque_family = .{ .bytes = "paredros" },
        .max_output_tokens = null,
        .request_bytes = model.request_bytes,
        .response_bytes = model.response_bytes,
        .timeout_ms = model.timeout_ms,
    };
    return native.values.toJson(m.P.AdaptivePolicy, a, .{
        .schema = .{ .bytes = m.P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://api.openai.com/v1/responses" },
        .audience = .{ .bytes = "openai" },
        .profiles = .{ .items = &.{profile} },
        .catalog = .{ .digest = hash(catalog), .bytes = catalog.len },
        .core_tools = .{ true, true },
        .permitted_tools = .{ true, true },
    });
}

pub fn profileBytes(a: std.mem.Allocator, config: Config, billing: ?t.Digest) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bytes = try std.json.Stringify.valueAlloc(scratch, .{ .paredros = .{
        .version = config.version,
        .current_uid = config.current_uid,
        .mode = config.mode,
        .grants = .{
            .github_read = config.mode == .live and config.grants.github_read,
            .model = config.mode == .live and config.grants.model,
        },
        .repository = config.repository,
        .interval_ms = config.interval_ms,
        .policies = config.policies,
        .model_account = if (billing != null)
            config.model.?.account
        else
            @as(?[]const u8, null),
    } }, .{});
    var value = try native.json.parse(scratch, bytes, .{});
    if (billing) |binding| {
        try native.json.put(scratch, &value.value, "adaptive", try adaptive(scratch, config));
        const responses = try native.values.toJson(c.ResponsesContract, scratch, .{
            .route = .chatgpt_plan_sse,
            .binding = binding,
        });
        try native.json.put(scratch, &value.value, "responses", responses);
    }
    return native.json.canonical(a, value.value);
}

fn permitted(config: Config, identity: []const u8) bool {
    const experiment = @import("../app/experiment_contract.zig");
    if (std.mem.eql(u8, identity, experiment.codec_identity) or
        std.mem.eql(u8, identity, experiment.clock_identity)) return true;
    if (std.mem.eql(u8, identity, @import("../app/method_contract.zig").workspace_identity) or
        std.mem.eql(
            u8,
            identity,
            @import("../app/method_contract.zig").codec_identity,
        )) return true;
    if (config.mode == .offline) return false;
    if (std.mem.eql(u8, identity, @import("../app/github_contract.zig").identity))
        return config.grants.github_read;
    if (std.mem.eql(u8, identity, m.P.identity)) return config.grants.model;
    return false;
}

fn finish(self: *OwnedLaunch, build: Build, billing: ?t.Digest) !void {
    const a = self.arena.allocator();
    const config = self.config;
    self.profile = .{
        .id = "paredros.launch.v1",
        .runtime_identity = build.runtime_identity,
        .bytes = try profileBytes(a, config, billing),
        .environment = &self.environment,
        .authority = .{
            .principal = try std.fmt.allocPrint(a, "uid:{d}", .{config.current_uid}),
            .tenant = tenant,
            .grants = &.{},
            .inference = billing != null,
            .disclosure = true,
        },
    };
    if (billing) |binding| {
        self.profile.resources = try a.dupe([]const u8, &.{try external.emptyCatalog(a)});
        self.environment.model = .{
            .source = .{ .chatgpt_plan = .{
                .selection = self.selection.?,
                .binding = binding,
            } },
            .approved_endpoint = "https://api.openai.com/v1/responses",
            .resources = self.profile.resources,
        };
        self.model_binding = try external.binding(
            self.allocator,
            self.profile.bytes,
            "selected",
            config.model.?.effort,
        );
    }
    const identity = try self.profile.resourceIdentity(a, build.image_identity);
    var grants: std.ArrayList(native.registry.Grant) = .empty;
    for (application.Application.declarations) |declaration| {
        if (!permitted(config, declaration.identity)) continue;
        try grants.append(
            a,
            .{
                .identity = declaration.identity,
                .resource_role = declaration.resource_role,
                .resource_identity = identity,
            },
        );
    }
    self.profile.authority.grants = try grants.toOwnedSlice(a);
    try self.profile.validate();
}

pub fn prepare(a: std.mem.Allocator, io: std.Io, config: Config, build: Build) !*OwnedLaunch {
    try validate(config, config.current_uid);
    const self = try a.create(OwnedLaunch);
    self.* = .{ .allocator = a, .arena = .init(a) };
    errdefer self.deinit();
    const bytes = try std.json.Stringify.valueAlloc(a, config, .{});
    defer a.free(bytes);
    self.config = try std.json.parseFromSliceLeaky(
        Config,
        self.arena.allocator(),
        bytes,
        .{ .allocate = .alloc_always },
    );
    const billing = try remote(self, io);
    try finish(self, build, billing);
    return self;
}
