const std = @import("std");
const native = @import("protean_native");
const configuration = @import("../native/configuration.zig");
const application = @import("../native/application.zig");
const external = @import("../native/model_external.zig");
const a = std.testing.allocator;
const build: configuration.Build = .{
    .runtime_identity = @splat(12),
    .image_identity = @splat(34),
};

fn fixture() configuration.Config {
    return .{
        .version = 1,
        .current_uid = 42,
        .namespace_path = "/tmp/unused-paredros-namespace",
        .control_socket_path = "/tmp/unused-paredros-control",
        .repository = .{
            .account = "github-owner",
            .id = 100,
            .owner = "owner",
            .name = "repository",
            .ref = "refs/heads/main",
        },
        .slack = .{
            .account = "slack-owner",
            .app = "A100",
            .workspace = "T100",
            .operator = "U100",
            .channel = "D100",
            .bot_id = "B100",
        },
    };
}

fn encoded(value: configuration.Config) ![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

fn expectLocalGrants(launch: *const configuration.OwnedLaunch) !void {
    const identities = [_][]const u8{
        "paredros.method.workspace.v1",
        "paredros.method.codec.v1",
        "paredros.experiment.codec.v1",
        "paredros.experiment.clock.v1",
    };
    try std.testing.expectEqual(identities.len, launch.profile.authority.grants.len);
    for (identities) |identity| {
        var matches: usize = 0;
        for (launch.profile.authority.grants) |grant| {
            if (std.mem.eql(u8, identity, grant.identity)) matches += 1;
        }
        try std.testing.expectEqual(1, matches);
    }
}

test "configuration closed schema validates uid version and bindings" {
    const bytes = try encoded(fixture());
    defer a.free(bytes);
    var parsed = try configuration.parse(a, bytes, 42);
    defer parsed.deinit();
    try std.testing.expectEqual(.offline, parsed.value.mode);
    try std.testing.expect(!parsed.value.grants.model);
    try std.testing.expectError(error.PermissionDenied, configuration.parse(a, bytes, 43));
    const unknown = try std.fmt.allocPrint(
        a,
        "{s},\"token\":\"forbidden\"}}",
        .{bytes[0 .. bytes.len - 1]},
    );
    defer a.free(unknown);
    try std.testing.expectError(error.UnknownField, configuration.parse(a, unknown, 42));
    const duplicate = try std.fmt.allocPrint(
        a,
        "{s},\"version\":1}}",
        .{bytes[0 .. bytes.len - 1]},
    );
    defer a.free(duplicate);
    try std.testing.expectError(error.DuplicateField, configuration.parse(a, duplicate, 42));
    var changed = fixture();
    changed.version = 2;
    const unsupported = try encoded(changed);
    defer a.free(unsupported);
    try std.testing.expectError(
        error.UnsupportedConfiguration,
        configuration.parse(a, unsupported, 42),
    );
    changed = fixture();
    changed.control_socket_path = "relative";
    const relative = try encoded(changed);
    defer a.free(relative);
    try std.testing.expectError(error.InvalidConfiguration, configuration.parse(a, relative, 42));
    changed = fixture();
    changed.slack.channel = "C100";
    const channel = try encoded(changed);
    defer a.free(channel);
    try std.testing.expectError(error.InvalidBinding, configuration.parse(a, channel, 42));
}

fn withModel() configuration.Config {
    var config = fixture();
    config.model = .{
        .account = "owner",
        .slug = "test-model",
        .effort = .medium,
        .siwc_bin = "/definitely-does-not-exist/siwc",
        .auth_dir = "/definitely-does-not-exist/credentials",
    };
    return config;
}

test "configuration offline skips all credentials and helper execution" {
    var config = withModel();
    config.grants = .{
        .github_read = true,
        .slack_history = true,
        .slack_write = true,
        .model = true,
    };
    config.github_credential_file = "/definitely-does-not-exist/github";
    config.slack_bot_credential_file = "/definitely-does-not-exist/bot";
    config.slack_app_credential_file = "/definitely-does-not-exist/app";
    const launch = try configuration.prepare(a, std.testing.io, config, build);
    defer launch.deinit();
    try std.testing.expect(launch.environment.github == null);
    try std.testing.expect(launch.environment.slack == null);
    try std.testing.expect(launch.environment.model == null);
    try std.testing.expect(launch.model_binding == null and launch.selection == null);
    try std.testing.expect(launch.slack_app_token == null);
    try std.testing.expect(!launch.profile.authority.inference);
    try expectLocalGrants(launch);
    const identity = try launch.profile.resourceIdentity(a, build.image_identity);
    for (launch.profile.authority.grants) |grant| {
        try std.testing.expectEqualSlices(u8, &identity, &grant.resource_identity);
        var matching = false;
        for (application.Application.declarations) |declaration| {
            if (!std.mem.eql(u8, grant.identity, declaration.identity)) continue;
            matching = true;
            try std.testing.expectEqualStrings(declaration.resource_role, grant.resource_role);
        }
        try std.testing.expect(matching);
    }
    try std.testing.expect(std.mem.indexOf(u8, launch.profile.bytes, "does-not-exist") == null);
}

test "configuration model policy binds opaque registration without helper IO" {
    const config = withModel();
    const bytes = try configuration.profileBytes(a, config, @splat(7));
    defer a.free(bytes);
    var binding = try external.binding(a, bytes, "selected", .medium);
    defer binding.deinit();
    try std.testing.expectEqualStrings("test-model", binding.value.profile.model.bytes);
    try std.testing.expectEqual(.chatgpt_plan_sse, binding.value.responses.route);
    try std.testing.expectEqualSlices(
        u8,
        &@as([32]u8, @splat(7)),
        &binding.value.responses.binding.?,
    );
    try std.testing.expect(std.mem.indexOf(u8, bytes, "does-not-exist") == null);
    try std.testing.expectError(
        error.UnsupportedEffort,
        external.binding(a, bytes, "selected", .high),
    );
}

test "configuration account selection does not grant live remote roles" {
    var config = withModel();
    config.mode = .live;
    const launch = try configuration.prepare(a, std.testing.io, config, build);
    defer launch.deinit();
    try expectLocalGrants(launch);
    try std.testing.expect(launch.selection == null);
    config.grants.github_read = true;
    try std.testing.expectError(
        error.MissingCredentialReference,
        configuration.prepare(a, std.testing.io, config, build),
    );
}

test "configuration identity excludes credential references and includes repository binding" {
    var config = fixture();
    const first = try configuration.prepare(a, std.testing.io, config, build);
    defer first.deinit();
    config.github_credential_file = "/private/refreshed-token";
    const second = try configuration.prepare(a, std.testing.io, config, build);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.profile.bytes, second.profile.bytes);
    config.repository.id += 1;
    const third = try configuration.prepare(a, std.testing.io, config, build);
    defer third.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.profile.bytes, third.profile.bytes));
}

fn privateFile(directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try directory.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0o600));
    try file.writeStreamingAll(std.testing.io, bytes);
}

test "configuration private files feed only selected live roles and stay out of identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/credential", .{path_buffer[0..length]});
    defer a.free(path);
    try privateFile(temporary.dir, "credential", "fake-private-token-one");
    var config = fixture();
    config.current_uid = @import("../native/control_socket.zig").currentUid();
    config.mode = .live;
    config.grants = .{ .github_read = true, .slack_history = true, .slack_write = true };
    config.github_credential_file = path;
    config.slack_bot_credential_file = path;
    const first = try configuration.prepare(a, std.testing.io, config, build);
    defer first.deinit();
    try std.testing.expectEqual(7, first.profile.authority.grants.len);
    try std.testing.expectEqualStrings(
        "fake-private-token-one",
        first.environment.github.?.http.token,
    );
    try std.testing.expectEqualStrings(
        "https://api.github.com",
        first.environment.github.?.http.origin,
    );
    try std.testing.expectEqualStrings("https://slack.com", first.environment.slack.?.http.origin);
    try std.testing.expect(std.mem.indexOf(u8, first.profile.bytes, "fake-private-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.profile.bytes, path) == null);
    try privateFile(temporary.dir, "credential", "fake-private-token-two");
    const second = try configuration.prepare(a, std.testing.io, config, build);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.profile.bytes, second.profile.bytes);
    try std.testing.expectEqualStrings(
        "fake-private-token-two",
        second.environment.slack.?.http.token,
    );
    const first_identity = try first.profile.resourceIdentity(a, build.image_identity);
    const second_identity = try second.profile.resourceIdentity(a, build.image_identity);
    try std.testing.expectEqualSlices(u8, &first_identity, &second_identity);
    try privateFile(temporary.dir, "credential", "invalid\ntoken");
    try std.testing.expectError(
        error.InvalidConfiguration,
        configuration.prepare(a, std.testing.io, config, build),
    );
}

test "configuration unsafe credential permissions fail before transport setup" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try privateFile(temporary.dir, "credential", "fake-private-token");
    const file = try temporary.dir.openFile(std.testing.io, "credential", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0o644));
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/credential", .{path_buffer[0..length]});
    defer a.free(path);
    var config = fixture();
    config.mode = .live;
    config.grants.github_read = true;
    config.github_credential_file = path;
    try std.testing.expectError(
        error.UnsafeCredentialFile,
        configuration.prepare(a, std.testing.io, config, build),
    );
}

test "configuration offline profile permits authenticated local owner reads" {
    const Fixture = @import("product_fixture.zig").Fixture;
    var owner: Fixture = .{};
    defer owner.deinit();
    try owner.init();
    const launch = try configuration.prepare(a, std.testing.io, fixture(), .{
        .runtime_identity = owner.profile.runtime_identity,
        .image_identity = owner.application.?.image_identity,
    });
    defer launch.deinit();
    try owner.close();
    owner.profile = launch.profile;
    defer owner.close() catch |err| std.debug.panic("owner close: {s}", .{@errorName(err)});
    try owner.open();
    var page = try owner.service.?.taskPage(a, null, 16);
    defer page.deinit();
    try std.testing.expectEqual(0, page.tasks.len);
    try expectLocalGrants(launch);
    try std.testing.expect(launch.environment.github == null and launch.environment.slack == null);
    try std.testing.expect(launch.environment.model == null);
}
