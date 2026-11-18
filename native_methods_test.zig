test {
    _ = @import("tests/native_experiment.zig");
    _ = @import("tests/native_method.zig");
    _ = @import("tests/method_catalog.zig");
}

comptime {
    if (@import("builtin").zig_backend != .stage2_x86_64)
        @compileError("Linux campaign qualification requires direct Zig x86-64 code generation");
}
