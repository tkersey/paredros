test {
    _ = @import("tests/native_render_frame.zig");
    _ = @import("tests/native_check_publish.zig");
    _ = @import("tests/native_audit.zig");
    _ = @import("tests/native_step.zig");
    _ = @import("tests/native_turn.zig");
    _ = @import("tests/native_render.zig");
    _ = @import("tests/native_authoring.zig");
}

comptime {
    if (@import("builtin").zig_backend != .stage2_x86_64)
        @compileError("Linux rendering qualification requires direct Zig x86-64 code generation");
}
