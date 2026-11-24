const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");

pub const Control = enum { pause, @"resume", cancel, transfer };
pub const Input = struct { head: t.Head, control: Control };
pub const Function = a.Function(struct { input: Input }, t.Head);

pub fn emit(c: protean.Context) !Function {
    const function = try c.author.function("fold responsibility mode", .{
        .input = try c.schema(Input),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const head = try b.field(input, "head");
    const control = try b.field(input, "control");
    const old_mode = try b.field(head, "mode");
    const final = try b.select(
        try enumIs(c, b, t.Mode, old_mode, .cancelled),
        try b.constant(bool, true),
        try enumIs(c, b, t.Mode, old_mode, .transferred),
    );
    const desired = try b.select(
        try enumIs(c, b, Control, control, .cancel),
        try c.literal(@FieldType(t.Head, "desired_mode"), .cancelled),
        try b.select(
            try enumIs(c, b, Control, control, .@"resume"),
            try c.literal(@FieldType(t.Head, "desired_mode"), .active),
            try b.select(
                try enumIs(c, b, Control, control, .pause),
                try c.literal(@FieldType(t.Head, "desired_mode"), .paused),
                try b.field(head, "desired_mode"),
            ),
        ),
    );
    const next = try b.update(head, .{
        .mode = try nextMode(c, b, head, control),
        .desired_mode = desired,
    });
    try c.author.define(function, try b.ret(try b.select(final, head, next)));
    return function;
}

fn nextMode(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    control: a.Value(Control),
) !a.Value(t.Mode) {
    const paused = try c.literal(t.Mode, .paused);
    const resumed = try b.select(
        try b.field(head, "recovery_hold"),
        paused,
        try c.literal(t.Mode, .active),
    );
    const continued = try b.select(try enumIs(c, b, Control, control, .pause), paused, resumed);
    const transferred = try b.select(
        try enumIs(c, b, Control, control, .transfer),
        try c.literal(t.Mode, .transferred),
        continued,
    );
    return b.select(
        try enumIs(c, b, Control, control, .cancel),
        try c.literal(t.Mode, .cancelled),
        transferred,
    );
}

pub fn enumIs(
    c: protean.Context,
    b: anytype,
    comptime T: type,
    value: a.Value(T),
    expected: T,
) !a.Value(bool) {
    return b.equal(try b.enumTag(value), try b.enumTag(try c.literal(T, expected)));
}

pub fn recoveryHold(
    c: protean.Context,
    b: anytype,
    head: a.Value(t.Head),
    reference: a.Value(t.InputReference),
) !a.Value(t.Head) {
    const digest = try b.field(head, "digest");
    const none = try b.caseOf(digest, "none");
    const some = try b.caseOf(digest, "some");
    const held = try some.body().update(some.payload(), .{
        .hold = try c.literal(t.DeliveryHold, .uncertain_transmission),
    });
    const next_digest = try b.match(digest, .{
        .none = try none.ret(try c.literal(?t.DigestIntent, null)),
        .some = try some.ret(try some.body().variant(
            try c.schema(?t.DigestIntent),
            "some",
            held,
        )),
    });
    return b.update(head, .{
        .mode = try c.literal(t.Mode, .paused),
        .recovery_hold = try b.constant(bool, true),
        .recovery_boundary = try b.variant(try c.schema(?t.InputReference), "some", reference),
        .digest = next_digest,
        .question = try holdQuestion(c, b, try b.field(head, "question")),
    });
}

fn holdQuestion(
    c: protean.Context,
    b: anytype,
    question: a.Value(?t.Question),
) !a.Value(?t.Question) {
    const none = try b.caseOf(question, "none");
    const some = try b.caseOf(question, "some");
    const held = try some.body().update(some.payload(), .{
        .held = try some.body().constant(bool, true),
    });
    return b.match(question, .{
        .none = try none.ret(try c.literal(?t.Question, null)),
        .some = try some.ret(try some.body().variant(try c.schema(?t.Question), "some", held)),
    });
}

pub fn recoveryRelease(c: protean.Context, b: anytype, head: a.Value(t.Head)) !a.Value(t.Head) {
    const desired = try b.field(head, "desired_mode");
    const Desired = @FieldType(t.Head, "desired_mode");
    const selected = try b.select(
        try enumIs(c, b, Desired, desired, .cancelled),
        try c.literal(t.Mode, .cancelled),
        try b.select(
            try enumIs(c, b, Desired, desired, .active),
            try c.literal(t.Mode, .active),
            try c.literal(t.Mode, .paused),
        ),
    );
    return b.update(head, .{
        .mode = selected,
        .recovery_hold = try b.constant(bool, false),
        .recovery_boundary = try c.literal(?t.InputReference, null),
    });
}
