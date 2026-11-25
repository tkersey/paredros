const std = @import("std");
const protean_build = @import("protean");
const NativeGroup = enum {
    authority,
    providers,
    transitions,
    rendering,
    methods,
    continuity,
    simulation,
};
const NativePartition = enum { first, second, third, fourth, fifth };

pub fn build(b: *std.Build) void {
    qualifyStep(b);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_tests = b.option(bool, "native-tests", "Run native owner tests") orelse false;
    const partition = b.option(
        NativePartition,
        "native-partition",
        "Select a continuity, transitions or simulation partition",
    );
    if (partition != null and !native_tests)
        std.debug.panic("native-partition requires native-tests", .{});
    const crash_tests = b.option(bool, "crash-tests", "Build process-death witnesses") orelse false;
    const scale_tests = b.option(
        bool,
        "scale-tests",
        "Build native storage measurements",
    ) orelse false;
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
    const check_recovery = b.option(
        bool,
        "check-recovery",
        "Include the GitHub capture and reopen witness in check",
    ) orelse false;
    const enabled = native_tests or native_product or crash_tests or scale_tests or check_recovery;
    const dependency = dependencyGraph(b, target, optimize, enabled);
    setupInputs(b, dependency);
    if (enabled) stabilizeClangObjects(b, dependency);
    const filter = b.option([]const u8, "test-filter", "Select a focused diagnostic");
    hostSteps(b, dependency, optimize, filter, check_recovery);
    const assets = if (native_product or crash_tests or scale_tests or
        (native_tests and test_product_assets))
        product(b, dependency)
    else
        null;
    if (native_tests) {
        const test_assets = if (test_product_assets) assets else null;
        nativeTests(b, dependency, optimize, test_assets, filter, partition);
    }
    if (crash_tests) witnessStep(
        b,
        nativeTestRoot(b, dependency, optimize, assets, "crash_test.zig"),
        "process crash owner fixture",
        "test-tools/paredros-crash-tests",
        "build-crash-tests",
        "Build process-death witnesses",
    );
    if (scale_tests) witnessStep(
        b,
        nativeTestRoot(b, dependency, optimize, assets, "scale_test.zig"),
        "native scale measurement",
        "test-tools/paredros-scale",
        "build-scale-tests",
        "Build native storage measurements",
    );
}

fn hostSteps(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    optimize: std.lang.Optimize,
    filter: ?[]const u8,
    check_recovery: bool,
) void {
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
    testStep(b, source_root, filter, b.step("test", "Run PAREDROS contract tests"));
    checkStep(b, dependency, optimize, host_types, host_contracts, check_recovery);
}

fn qualifyStep(b: *std.Build) void {
    const qualify = b.addSystemCommand(&.{ "uv", "run", "--no-project", "python" });
    qualify.addFileArg2(b.path("tests/qualify.py"), .{ .make_absolute = true });
    qualify.addFileArg2(.zig_exe, .{ .make_absolute = true });
    qualify.addPassthruArgs();
    qualify.setCwd(b.path("."));
    qualify.has_side_effects = true;
    b.step("qualify", "Run full offline qualification on this host").dependOn(&qualify.step);
}

fn checkStep(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    optimize: std.lang.Optimize,
    host_types: *std.Build.Module,
    host_contracts: *std.Build.Module,
    check_recovery: bool,
) void {
    const check = b.step(
        "check",
        "Check GitHub provider protocols (add -Dcheck-recovery=true for capture/reopen)",
    );
    const checked = b.addSystemCommand(&.{ "echo", if (check_recovery)
        "Passed GitHub provider protocol checks and the native GitHub " ++
            "capture/reopen witness."
    else
        "Passed GitHub provider protocol checks. For native GitHub " ++
            "capture/reopen, run zig build check -Dcheck-recovery=true." });
    checked.has_side_effects = true;
    check.dependOn(&checked.step);
    const provider_root = b.createModule(.{
        .root_source_file = b.path("provider_check.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "application_types", .module = host_types },
            .{ .name = "protean_contracts", .module = host_contracts },
        },
    });
    testStep(b, provider_root, null, &checked.step);
    if (check_recovery) {
        const recovery = nativeTestRoot(b, dependency, optimize, null, "native_providers_test.zig");
        testStep(
            b,
            recovery,
            "native GitHub multipage capture survives restart before interpretation " ++
                "without refetch",
            &checked.step,
        );
    }
}

fn witnessStep(
    b: *std.Build,
    root: *std.Build.Module,
    comptime filter: []const u8,
    install_path: []const u8,
    step_name: []const u8,
    description: []const u8,
) void {
    const checks = addPlatformTest(b, .{
        .filters = &.{filter},
        .root_module = root,
    });
    const install = b.addInstallFile(checks.getEmittedBin(), install_path);
    b.step(step_name, description).dependOn(&install.step);
}

fn nativeTests(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    optimize: std.lang.Optimize,
    assets: ?ProductAssets,
    filter: ?[]const u8,
    partition: ?NativePartition,
) void {
    const selected = b.option([]const NativeGroup, "native-group", "Select native owner groups");
    if (partition != null) {
        if (filter != null)
            std.debug.panic("native-partition cannot be combined with test-filter", .{});
        const single = if (selected) |groups| groups.len == 1 else false;
        const partitioned = single and switch (selected.?[0]) {
            .continuity, .transitions => @backingInt(partition.?) < 3,
            .simulation => true,
            else => false,
        };
        if (!partitioned) std.debug.panic(
            "native-partition requires one continuity, transitions or simulation native-group",
            .{},
        );
    }
    const execute = b.step("test-native", "Run every selected native owner group");
    const compile = b.step("build-native-tests", "Build every selected native owner group");
    const runner = b.addInstallFile(
        dependency.path("tools/native/qualification_tests.mjs"),
        "test-tools/native/qualification_tests.mjs",
    );
    compile.dependOn(&runner.step);
    for (std.enums.values(NativeGroup)) |group| {
        if (selected) |groups| {
            if (std.mem.indexOfScalar(NativeGroup, groups, group) == null) continue;
        }
        const name = @tagName(group);
        const path = b.fmt("native_{s}_test.zig", .{name});
        const root = nativeTestRoot(b, dependency, optimize, assets, path);
        if (group == .simulation)
            root.addOptions("simulation_options", simulationOptions(b, partition));
        const checks = addPlatformTest(b, .{
            .filters = if (partition) |part|
                nativePartitionFilters(group, part)
            else if (filter) |value| &.{value} else &.{},
            .root_module = root,
        });
        const run = b.addRunArtifact(checks);
        if (checks.test_runner != null) run.expectExitCode(0);
        run.has_side_effects = true;
        execute.dependOn(&run.step);
        const artifact = if (partition) |part|
            b.fmt("{s}-{s}", .{ name, @tagName(part) })
        else
            name;
        const install = b.addInstallFile(
            checks.getEmittedBin(),
            b.fmt("test-tools/native/{s}", .{artifact}),
        );
        compile.dependOn(&install.step);
    }
}

fn simulationOptions(b: *std.Build, partition: ?NativePartition) *std.Build.Step.Options {
    const values = b.addOptions();
    const all_pins: u64 = std.math.maxInt(u64);
    const pins = if (partition) |part| @as(u64, 1) << @backingInt(part) else all_pins;
    values.addOption(u64, "pins", pins);
    values.addOption(?u64, "seed", b.option(u64, "simulation-seed", "Replay one simulation seed"));
    values.addOption(u64, "seeds", b.option(
        u64,
        "simulation-seeds",
        "Run this many consecutive simulation seeds after the pinned ones",
    ) orelse 0);
    values.addOption(u64, "first", b.option(
        u64,
        "simulation-first",
        "First consecutive simulation seed",
    ) orelse 1);
    values.addOption(u64, "events", b.option(
        u64,
        "simulation-events",
        "Events generated per simulation seed",
    ) orelse 60);
    values.addOption(bool, "progress", b.option(
        bool,
        "simulation-progress",
        "Print each simulation seed's timing",
    ) orelse false);
    values.addOption(u64, "hops_max", 2);
    values.addOption(u64, "rest_rounds", 400);
    return values;
}

fn nativePartitionFilters(group: NativeGroup, partition: NativePartition) []const []const u8 {
    return switch (group) {
        .simulation => switch (partition) {
            .first => &.{},
            else => &.{"simulation holds every invariant across the selected seeds"},
        },
        .continuity => switch (partition) {
            .first => &.{"tests.transfer.test."},
            .third => &.{
                "tests.compatibility.test.",
                "tests.contracts.test.",
                "tests.native_genesis.test.",
                "tests.directive_policy.test.",
            },
            .second => &.{
                "tests.control.test.",
                "tests.configuration.test.",
            },
            .fourth, .fifth => unreachable,
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
            .fourth, .fifth => unreachable,
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
    const native_direct = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and
        (target.query.isNative() or target.result.abi == .musl);
    if (!enabled) return b.dependency("protean", .{
        .target = target,
        .optimize = optimize,
        .@"native-direct" = native_direct,
        .native = false,
    });
    return b.dependency("protean", .{
        .target = target,
        .optimize = optimize,
        .@"native-direct" = native_direct,
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

fn useLlvm(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .macos and target.result.cpu.arch == .aarch64;
}

fn addPlatformTest(b: *std.Build, options: std.Build.TestOptions) *std.Build.Step.Compile {
    var selected = options;
    selected.use_llvm = useLlvm(selected.root_module.resolved_target.?);
    return b.addTest(selected);
}

fn setupInputs(b: *std.Build, dependency: *std.Build.Dependency) void {
    const bootstrap = b.addExecutable(.{
        .use_llvm = useLlvm(b.graph.host),
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
    step: *std.Build.Step,
) void {
    const checks = addPlatformTest(b, .{
        .filters = if (filter) |value| &.{value} else &.{},
        .root_module = root,
    });
    const run = b.addRunArtifact(checks);
    if (checks.test_runner != null) run.expectExitCode(0);
    run.has_side_effects = true;
    step.dependOn(&run.step);
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
        .single_threaded = false,
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

// WriteFiles names its output directory by content but can replace identical
// files there. Cache the copy by that directory so Zig sees stable link inputs.
fn stableFile(
    b: *std.Build,
    content_directory: std.Build.LazyPath,
    name: []const u8,
) std.Build.LazyPath {
    const copy = b.addSystemCommand(&.{ "cp", name });
    copy.setCwd(content_directory);
    return copy.addOutputFileArg2(name, .{ .make_absolute = true });
}

fn stabilizeClangObjects(b: *std.Build, dependency: *std.Build.Dependency) void {
    const inputs = dependency.namedLazyPath("native-clang-inputs");
    for (dependency.module("protean_native").link_objects.items) |linked| {
        if (linked != .other_step or !std.mem.eql(
            u8,
            linked.other_step.name,
            "protean-native-c",
        )) continue;
        for (linked.other_step.root_module.link_objects.items) |*object| {
            if (object.* != .static_path or object.static_path != .generated) continue;
            const path = object.static_path.generated;
            if (path.index != inputs.generated.index or path.up != 0) continue;
            if (std.mem.eql(
                u8,
                path.sub_path,
                "sqlite3.o",
            ) or std.mem.eql(u8, path.sub_path, "native_c.o")) {
                object.static_path = stableFile(b, inputs, path.sub_path);
            }
        }
    }
}

fn product(b: *std.Build, dependency: *std.Build.Dependency) ProductAssets {
    const emitted = b.option(
        std.Build.LazyPath,
        "emitted-application",
        "Verified emitted application directory",
    );
    const result = protean_build.addNativeSystem(b, dependency, .{
        .name = "paredros",
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
    result.executable.use_llvm = useLlvm(result.executable.root_module.resolved_target.?);
    result.executable.root_module.single_threaded = false;
    const symbols = b.option(bool, "symbols", "Retain symbols for native profiling") orelse false;
    if (symbols) {
        result.executable.root_module.strip = false;
        dependency.module("protean_native").strip = false;
    }
    const environment = result.executable.root_module.import_table.get("environment").?;
    const protean = dependency.module("protean_native_types");
    environment.addImport("protean", protean);
    environment.addImport("horos", protean.import_table.get("horos").?);
    const manifest_files = b.addWriteFiles();
    _ = manifest_files.addCopyFile(result.manifest, "manifest.json");
    const manifest = stableFile(b, manifest_files.getDirectory(), "manifest.json");
    result.executable.root_module.import_table.get("native_manifest").?.root_source_file = manifest;
    const source = if (emitted == null) result.assets else sourceAssets(b, dependency);
    emittedSteps(b, source, emitted orelse b.path("app/emitted"));
    b.addNamedLazyPath("paredros-image", result.assets.image);
    b.addNamedLazyPath("paredros-application", result.assets.application);
    b.addNamedLazyPath("paredros-manifest", manifest);
    return .{
        .image = result.assets.image,
        .application = result.assets.application,
        .manifest = manifest,
        .symbols = symbols,
    };
}

fn sourceAssets(b: *std.Build, dependency: *std.Build.Dependency) protean_build.NativeAssets {
    const install = b.getInstallStep();
    const source = protean_build.addNativeSystem(b, dependency, .{
        .name = "paredros-source",
        .environment = b.path("environment.zig"),
        .application = .{ .source = .{
            .definition = b.path("app/definition.zig"),
            .types = b.path("app/types.zig"),
        } },
    });
    std.debug.assert(install.dependencies.pop() == &source.install.step);
    return source.assets;
}

fn emittedSteps(
    b: *std.Build,
    source: protean_build.NativeAssets,
    selected: std.Build.LazyPath,
) void {
    const check = b.step("check-emitted", "Require embedded assets to match the authored source");
    const update = b.step("update-emitted", "Refresh app/emitted from the authored source");
    const files = b.addUpdateSourceFiles();
    const outputs = .{
        .{ source.image, "program.bpi3" },
        .{ source.application, "application.json" },
    };
    inline for (outputs) |output| {
        const compare = b.addSystemCommand(&.{"cmp"});
        compare.setName("cmp " ++ output[1] ++ " (zig build update-emitted)");
        compare.addFileArg(output[0]);
        compare.addFileArg(selected.path(b, output[1]));
        compare.expectExitCode(0);
        check.dependOn(&compare.step);
        files.addCopyFileToSource(output[0], "app/emitted/" ++ output[1]);
    }
    update.dependOn(&files.step);
}
