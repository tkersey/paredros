const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");
const bytes = @import("bytes.zig");

const Purpose = @FieldType(t.Notification, "purpose");

pub fn prompt(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    question: a.Value(t.Question),
) !a.Value(t.Notification) {
    const condition = try b.field(question, "source_condition");
    const none = try b.caseOf(condition, "none");
    const some = try b.caseOf(condition, "some");
    const sb = some.body();
    const compared = try sb.product(try c.schema(t.Comparison), .{
        .repository = try sb.field(try sb.field(head, "specification"), "repository"),
        .base = try sb.field(some.payload(), "base"),
        .tip = try sb.field(some.payload(), "tip"),
    });
    const comparison = try b.match(condition, .{
        .none = try none.ret(try c.literal(?t.Comparison, null)),
        .some = try some.ret(try sb.variant(try c.schema(?t.Comparison), "some", compared)),
    });
    const asked = try b.product(try c.schema(@FieldType(Purpose, "question")), .{
        .identity = try b.field(question, "identity"),
        .choices = try b.field(question, "choices"),
    });
    return b.product(try c.schema(t.Notification), .{
        .specification_revision = try b.field(question, "specification_revision"),
        .text = try b.field(question, "prompt"),
        .comparison = comparison,
        .purpose = try b.variant(try c.schema(Purpose), "question", asked),
    });
}

pub fn pending(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
) !a.Value(?t.Notification) {
    const question = try b.field(head, "question");
    const none = try b.caseOf(question, "none");
    const some = try b.caseOf(question, "some");
    const sb = some.body();
    const message = try prompt(c, sb, head, some.payload());
    return b.match(question, .{
        .none = try none.ret(try c.literal(?t.Notification, null)),
        .some = try some.ret(try sb.variant(try c.schema(?t.Notification), "some", message)),
    });
}

pub fn raised(
    c: protean.Context,
    b: anytype,
    previous: a.Value(?t.Question),
    head: a.Value(t.Head),
) !a.Value(t.Head) {
    const current = try b.field(head, "question");
    const absent = try b.caseOf(current, "none");
    const present = try b.caseOf(current, "some");
    const pb = present.body();
    const unasked = try pb.caseOf(previous, "none");
    const asked = try pb.caseOf(previous, "some");
    const ab = asked.body();
    const same = try ab.call(try bytes.emit(c, 32), .{
        .left = try ab.field(asked.payload(), "identity"),
        .right = try ab.field(present.payload(), "identity"),
        .index = try ab.constant(u64, 0),
    });
    const fresh = try pb.match(previous, .{
        .none = try unasked.ret(try unasked.body().constant(bool, true)),
        .some = try asked.ret(try ab.booleanNot(same)),
    });
    const message = try pb.variant(
        try c.schema(?t.Notification),
        "some",
        try prompt(c, pb, head, present.payload()),
    );
    const selected = try b.match(current, .{
        .none = try absent.ret(try c.literal(?t.Notification, null)),
        .some = try present.ret(try pb.select(
            fresh,
            message,
            try c.literal(?t.Notification, null),
        )),
    });
    return b.update(head, .{ .message = selected });
}
