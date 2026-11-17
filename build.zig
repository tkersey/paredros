const std = @import("std");
const protean_build = @import("protean");
const NativeGroup = enum { authority, providers, transitions, rendering, methods, continuity };
const NativePartition = enum { first, second, third };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_tests = b.option(bool, "native-tests", "Run native owner tests") orelse false;
    const partition = b.option(NativePartition, "native-partition", "Select a continuity or transitions partition");
    if (partition != null and !native_tests)
        std.debug.panic("native-partition requires native-tests", .{});
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
    sourceTests(b, dependency, source_root, filter);
    const assets = if (native_product or crash_tests or scale_tests or
        (native_tests and test_product_assets))
        product(b, dependency)
    else
        null;
    if (native_tests) {
        const test_assets = if (test_product_assets) assets else null;
        nativeTests(b, dependency, optimize, test_assets, filter, partition);
    }
    if (crash_tests) {
        const root = nativeTestRoot(b, dependency, optimize, assets, "crash_test.zig");
        const checks = protean_build.NativeBinary.addTest(b, dependency, .{
            .use_llvm = false,
            .filters = &.{"process crash owner fixture"},
            .root_module = root,
        }, true);
        const install = b.addInstallFile(checks.path, "test-tools/paredros-crash-tests");
        b.step("build-crash-tests", "Build process-death witnesses").dependOn(&install.step);
    }
    if (scale_tests) {
        const root = nativeTestRoot(b, dependency, optimize, assets, "scale_test.zig");
        const checks = protean_build.NativeBinary.addTest(b, dependency, .{
            .use_llvm = false,
            .filters = &.{"native scale measurement"},
            .root_module = root,
        }, true);
        const install = b.addInstallFile(checks.path, "test-tools/paredros-scale");
        b.step("build-scale-tests", "Build native storage measurements").dependOn(&install.step);
    }
}

fn nativeTests(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    optimize: std.lang.Optimize,
    assets: ?ProductAssets,
    filter: ?[]const u8,
    partition: ?NativePartition,
) void {
    const selected = b.option(NativeGroup, "native-group", "Select a native diagnostic group");
    if (partition != null) {
        if (filter != null)
            std.debug.panic("native-partition cannot be combined with test-filter", .{});
        if (selected == null or (selected.? != .continuity and selected.? != .transitions))
            std.debug.panic("native-partition requires continuity or transitions native-group", .{});
    }
    const execute = b.step("test-native", "Run every selected native owner group");
    const compile = b.step("build-native-tests", "Build every selected native owner group");
    for (std.enums.values(NativeGroup)) |group| {
        if (selected != null and selected.? != group) continue;
        const name = @tagName(group);
        const path = b.fmt("native_{s}_test.zig", .{name});
        const root = nativeTestRoot(b, dependency, optimize, assets, path);
        const checks = protean_build.NativeBinary.addTest(b, dependency, .{
            .use_llvm = false,
            .filters = if (partition) |part|
                nativePartitionFilters(group, part)
            else if (filter) |value| &.{value} else &.{},
            .root_module = root,
        }, true);
        const run = checks.run(b);
        run.has_side_effects = true;
        execute.dependOn(&run.step);
        const artifact = if (partition) |part|
            b.fmt("{s}-{s}", .{ name, @tagName(part) })
        else
            name;
        const install = b.addInstallFile(
            checks.path,
            b.fmt("test-tools/native/{s}", .{artifact}),
        );
        compile.dependOn(&install.step);
    }
}

fn nativePartitionFilters(group: NativeGroup, partition: NativePartition) []const []const u8 {
    return switch (group) {
        .continuity => switch (partition) {
            .first => &.{
                "tests.native_restore.test.",
                "tests.native_recovery_control.test.",
                "tests.directive_policy.test.",
            },
            .third => &.{
                "tests.transfer.test.",
                "tests.compatibility.test.",
                "tests.contracts.test.",
                "tests.native_genesis.test.",
            },
            .second => &.{
                "tests.native_slack_owner.test.",
                "tests.native_audit_control.test.",
                "tests.control.test.",
                "tests.slack_owner.test.",
                "tests.configuration.test.",
            },
        },
        .transitions => switch (partition) {
            .first => &.{
                "tests.native_directive_chain.test.",
                "tests.directive_chain.test.",
                "tests.native_directive_policy.test.",
                "tests.directive_policy.test.",
            },
            .third => &.{
                "tests.native_phase_recovery.test.",
                "tests.phase_recovery.test.",
                "tests.step.test.",
            },
            .second => &.{
                "tests.native_settlement.test.",
                "tests.settlement.test.",
                "tests.native_revision.test.",
                "tests.revision.test.",
                "tests.native_genesis.test.",
                "tests.contracts.test.",
            },
        },
        else => unreachable,
    };
}

fn dependencyGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    enabled: bool,
) *std.Build.Dependency {
    const gcc = b.option([]const u8, "native-gcc", "GNU C compiler for the native target") orelse
        if (target.result.os.tag == .macos) "gcc-16" else "musl-gcc";
    if (!enabled) return b.dependency("protean", .{
        .target = target,
        .optimize = optimize,
        .native = false,
        .@"native-gcc" = gcc,
    });
    return b.dependency("protean", .{
        .target = target,
        .optimize = optimize,
        .@"native-gcc" = gcc,
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
    const bootstrap = protean_build.NativeBinary.addExecutable(b, dependency, .{
        .use_llvm = false,
        .name = "paredros-dependencies",
        .root_module = b.createModule(.{
            .root_source_file = dependency.path("tools/native/dependencies.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    }, false);
    const setup = bootstrap.run(b);
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

fn sourceTests(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    root: *std.Build.Module,
    filter: ?[]const u8,
) void {
    const checks = protean_build.NativeBinary.addTest(b, dependency, .{
        .use_llvm = false,
        .filters = if (filter) |value| &.{value} else &.{},
        .root_module = root,
    }, false);
    const run = checks.run(b);
    run.has_side_effects = true;
    b.step("test", "Run PAREDROS contract tests").dependOn(&run.step);
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
    const emitted = b.option(
        std.Build.LazyPath,
        "emitted-application",
        "Verified emitted application directory",
    );
    const symbols = b.option(bool, "symbols", "Retain symbols for native profiling") orelse false;
    const result = protean_build.addNativeSystem(b, dependency, .{
        .name = "paredros",
        .strip = if (symbols) false else null,
        .entry = b.path("main.zig"),
        .environment = b.path("environment.zig"),
        .application = if (emitted) |directory| .{ .emitted = .{
            .image = directory.path(b, "program.bpi3"),
            .application = directory.path(b, "application.json"),
            .types = b.path("app/types.zig"),
        } } else .{ .source = .{
            .definition = b.path("app/definition.zig"),
            .types = b.path("app/types.zig"),
        } },
    });
    if (symbols) dependency.module("protean_native").strip = false;
    const environment = result.executable.root_module.import_table.get("environment").?;
    const protean = dependency.module("protean_native_types");
    environment.addImport("protean", protean);
    environment.addImport("horos", protean.import_table.get("horos").?);
    prepareNative(b, result.executable, result.assets);
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

fn prepareNative(
    b: *std.Build,
    executable: *std.Build.Step.Compile,
    assets: protean_build.NativeAssets,
) void {
    const prepare = b.step("prepare-native", "Materialize application and native build inputs");
    for (executable.root_module.getGraph().modules) |module| {
        if (module.root_source_file) |source| source.addStepDependencies(prepare);
        for (module.link_objects.items) |object| switch (object) {
            .other_step => |linked| prepare.dependOn(&linked.step),
            .static_path => |source| source.addStepDependencies(prepare),
            else => {},
        };
    }
    const outputs = .{
        .{ assets.image, "prepared/program.bpi3" },
        .{ assets.application, "prepared/application.json" },
        .{ assets.types, "prepared/types.zig" },
    };
    inline for (outputs) |output| {
        prepare.dependOn(&b.addInstallFile(output[0], output[1]).step);
    }
}
