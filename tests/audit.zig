const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const audit = @import("../app/audit.zig");
const contract = @import("../app/audit_contract.zig");
const t = @import("application_types");

pub const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        return c.author.module(try audit.emit(c), try c.schema(t.Failure));
    }
};

test "Slack audit authored loop admits only capture-backed history read" {
    var compiled = try protean.compile(std.testing.allocator, protean.system(.{
        .InitialArgs = t.Audit,
        .Result = t.AuditResult,
        .Failure = t.Failure,
        .application = Application,
    }));
    defer compiled.deinit();
    try std.testing.expectEqual(1, compiled.program.effects.len);
    try std.testing.expectEqualStrings(contract.identity, compiled.program.effects[0].identity);
}
