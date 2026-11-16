const std = @import("std");
const native = @import("protean_native");
const environment = @import("environment");

pub fn main(init: std.process.Init) void {
    const code = environment.run(init, .{
        .image = @embedFile("native_image"),
        .application = @embedFile("native_application"),
        .manifest = @embedFile("native_manifest"),
    }) catch |err| native.reportFailure(err);
    if (code != 0) std.process.exit(code);
}
