const app = @import("../native/application.zig");
const Application = struct {
    pub const use_product_assets = true;
    pub const declarations = app.Application.declarations;
};

pub const Fixture = @import("native_fixture.zig").Fixture(@import("application_types"), Application);
