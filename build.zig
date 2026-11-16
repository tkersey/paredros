const std = @import("std");
const protean_build = @import("protean");
const NativeGroup = enum { authority, providers, transitions, rendering, methods, continuity };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_tests = b.option(bool, "native-tests", "Run native owner tests") orelse false;
    const crash_tests = b.option(bool, "crash-tests", "Build process-death witnesses") orelse false;
    const scale_tests = b.option(bool, "scale-tests", "Build native storage measurements") orelse false;
    const native_product = b.option(
        bool,
        "native",
        "Build the PAREDROS executable",
    ) orelse false;
    const test_product_assets = b.option(
        bool,
        "test-product-assets",
        "Generate product assets for native test fixtures",
    ) orelse true;
    const enabled = native_tests or native_product or crash_tests or scale_tests;
    const dependency = dependencyGraph(b, target, optimize, enabled);
    setupInputs(b, dependency);
    const filter = b.option([]const u8, "test-filter", "Select a focused diagnostic");
    const host_protean = dependency.module("protean_host_authoring");
    const host_contracts = dependency.module("protean_contracts_host");
    const host_types = typesModule(b, b.graph.host, optimize, host_protean, host_contracts);
    const source_root = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "application_types", .module = host_types },
            .{ .name = "protean_contracts", .module = host_contracts },
            .{ .name = "protean", .module = host_protean },
            .{ .name = "horos", .module = dependency.module("horos_host_authoring") },
        },
    });
    _ = testStep(b, source_root, filter, "test", "Run PAREDROS contract tests");
    const assets = if (native_product or crash_tests or scale_tests or
        (native_tests and test_product_assets))
        product(b, dependency)
    else
        null;
    if (native_tests) {
        const test_assets = if (test_product_assets) assets else null;
        nativeTests(b, dependency, optimize, test_assets, filter);
    }
    if (crash_tests) {
        const root = nativeTestRoot(b, dependency, optimize, assets, "crash_test.zig");
        const checks = b.addTest(.{
            .filters = &.{"process crash owner fixture"},
            .root_module = root,
        });
        const install = b.addInstallFile(checks.getEmittedBin(), "test-tools/paredros-crash-tests");
        b.step("build-crash-tests", "Build process-death witnesses").dependOn(&install.step);
    }
    if (scale_tests) {
        const root = nativeTestRoot(b, dependency, optimize, assets, "scale_test.zig");
        const checks = b.addTest(.{
            .filters = &.{"native scale measurement"},
            .root_module = root,
        });
        const install = b.addInstallFile(checks.getEmittedBin(), "test-tools/paredros-scale");
        b.step("build-scale-tests", "Build native storage measurements").dependOn(&install.step);
    }
}

fn nativeTests(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    optimize: std.lang.Optimize,
    assets: ?ProductAssets,
    filter: ?[]const u8,
) void {
    const selected = b.option(NativeGroup, "native-group", "Select a native diagnostic group");
    const execute = b.step("test-native", "Run every selected native owner group");
    const compile = b.step("build-native-tests", "Build every selected native owner group");
    for (std.enums.values(NativeGroup)) |group| {
        if (selected != null and selected.? != group) continue;
        const name = @tagName(group);
        const path = b.fmt("native_{s}_test.zig", .{name});
        const root = nativeTestRoot(b, dependency, optimize, assets, path);
        const checks = b.addTest(.{
            .filters = if (filter) |value| &.{value} else &.{},
            .root_module = root,
        });
        const run = b.addRunArtifact(checks);
        run.has_side_effects = true;
        execute.dependOn(&run.step);
        const install = b.addInstallFile(
            checks.getEmittedBin(),
            b.fmt("test-tools/native/{s}", .{name}),
        );
        compile.dependOn(&install.step);
    }
}

fn dependencyGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    enabled: bool,
) *std.Build.Dependency {
    if (!enabled) return b.dependency("protean", .{
        .target = target,
        .optimize = optimize,
        .native = false,
    });
    return b.dependency("protean", .{
        .target = target,
        .optimize = optimize,
        .@"kosmos-source" = b.option(
            std.Build.LazyPath,
            "kosmos-source",
            "Admitted Kosmos source",
        ) orelse b.path(".protean-native/inputs/kosmos"),
        .@"sqlite-source" = b.option(
            std.Build.LazyPath,
            "sqlite-source",
            "Admitted SQLite source",
        ) orelse b.path(".protean-native/inputs/sqlite"),
    });
}

fn setupInputs(b: *std.Build, dependency: *std.Build.Dependency) void {
    const bootstrap = b.addExecutable(.{
        .name = "paredros-dependencies",
        .root_module = b.createModule(.{
            .root_source_file = dependency.path("tools/native/dependencies.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const setup = b.addRunArtifact(bootstrap);
    setup.addArg("setup");
    setup.addFileArg2(dependency.path("conformance/protean/dependencies.lock.json"), .{});
    setup.addFileArg2(dependency.path("conformance/protean/native-dependencies.lock.json"), .{});
    setup.addDirectoryArg2(b.path(".protean-native/inputs"), .{ .make_absolute = true });
    setup.addFileArg2(.zig_exe, .{ .make_absolute = true });
    if (b.option(bool, "setup-offline", "Verify already acquired build inputs") orelse false)
        setup.addArg("--offline");
    setup.has_side_effects = true;
    b.step("setup", "Acquire and authenticate pinned native build inputs").dependOn(&setup.step);
}

fn typesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    protean: *std.Build.Module,
    contracts: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("app/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protean", .module = protean },
            .{ .name = "protean_contracts", .module = contracts },
        },
    });
}

fn testStep(
    b: *std.Build,
    root: *std.Build.Module,
    filter: ?[]const u8,
    name: []const u8,
    description: []const u8,
) *std.Build.Step.Compile {
    const checks = b.addTest(.{
        .filters = if (filter) |value| &.{value} else &.{},
        .root_module = root,
    });
    const run = b.addRunArtifact(checks);
    run.has_side_effects = true;
    b.step(name, description).dependOn(&run.step);
    return checks;
}

fn nativeTestRoot(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    optimize: std.lang.Optimize,
    assets: ?ProductAssets,
    path: []const u8,
) *std.Build.Module {
    const native = dependency.module("protean_native");
    const target = native.resolved_target.?;
    const protean = dependency.module("protean_native_types");
    const contracts = dependency.module("protean_native_contracts");
    const types = typesModule(b, target, optimize, protean, contracts);
    const root = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug and !(if (assets) |value| value.symbols else false),
        .imports = &.{
            .{ .name = "application_types", .module = types },
            .{ .name = "protean_native", .module = native },
            .{ .name = "protean_contracts", .module = contracts },
            .{ .name = "protean", .module = protean },
            .{ .name = "horos", .module = protean.import_table.get("horos").? },
        },
    });
    if (assets) |selected| {
        root.addAnonymousImport("test_application_image", .{ .root_source_file = selected.image });
        root.addAnonymousImport("test_application_metadata", .{
            .root_source_file = selected.application,
        });
        root.addAnonymousImport("test_application_manifest", .{
            .root_source_file = selected.manifest,
        });
    }
    return root;
}

const ProductAssets = struct {
    image: std.Build.LazyPath,
    application: std.Build.LazyPath,
    manifest: std.Build.LazyPath,
    symbols: bool,
};

fn product(b: *std.Build, dependency: *std.Build.Dependency) ProductAssets {
    const result = protean_build.addNativeSystem(b, dependency, .{
        .name = "paredros",
        .entry = b.path("main.zig"),
        .environment = b.path("environment.zig"),
        .application = .{ .source = .{
            .definition = b.path("app/definition.zig"),
            .types = b.path("app/types.zig"),
        } },
    });
    const symbols = b.option(bool, "symbols", "Retain symbols for native profiling") orelse false;
    if (symbols) {
        result.executable.root_module.strip = false;
        dependency.module("protean_native").strip = false;
    }
    const environment = result.executable.root_module.import_table.get("environment").?;
    const protean = dependency.module("protean_native_types");
    environment.addImport("protean", protean);
    environment.addImport("horos", protean.import_table.get("horos").?);
    b.addNamedLazyPath("paredros-image", result.assets.image);
    b.addNamedLazyPath("paredros-application", result.assets.application);
    b.addNamedLazyPath("paredros-manifest", result.manifest);
    return .{
        .image = result.assets.image,
        .application = result.assets.application,
        .manifest = result.manifest,
        .symbols = symbols,
    };
}
