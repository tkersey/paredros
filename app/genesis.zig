const protean = @import("protean");
const t = @import("application_types");
const a = @import("author.zig");

pub const Function = a.Function(struct { input: t.Genesis }, t.Head);

pub fn emit(c: protean.Context) !Function {
    const function = try c.author.function("paredros genesis", .{
        .input = try c.schema(t.Genesis),
    }, try c.schema(t.Head), &.{});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const specification = try b.field(input, "specification");
    try a.require(c, b, try b.equal(
        try b.field(try b.field(input, "envelope"), "version"),
        try b.constant(u32, 1),
    ), "unsupported_input_version");
    try a.require(c, b, try b.less(
        try b.constant(u64, 0),
        try b.field(specification, "interval_ms"),
    ), "invalid_interval");
    const imported = try b.field(input, "imported");
    const fresh = try b.caseOf(imported, "none");
    const restored = try b.caseOf(imported, "some");
    const result = try b.match(imported, .{
        .none = try fresh.ret(try freshHead(c, fresh.body(), input)),
        .some = try restored.ret(try importedHead(c, restored.body(), input, restored.payload())),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn freshHead(c: protean.Context, b: anytype, input: a.Value(t.Genesis)) !a.Value(t.Head) {
    const specification = try b.field(input, "specification");
    try a.require(c, b, try b.equal(
        try b.field(specification, "revision"),
        try b.constant(u64, 0),
    ), "invalid_initial_revision");
    return b.product(try c.schema(t.Head), .{
        .version = try b.constant(u32, 1),
        .obligation = try c.literal(t.GenesisIdentity, .{ .self = {} }),
        .lineage = try b.field(input, "lineage"),
        .sequence = try b.constant(u64, 0),
        .predecessor = try c.literal(?t.Reference, null),
        .attempt = try b.constant(u32, 0),
        .superseded = try c.literal(?t.InputReference, null),
        .folded_directive_ordinal = try b.constant(u64, 0),
        .last_directive = try c.literal(?t.InputReference, null),
        .consumed = try c.literal(@FieldType(t.Head, "consumed"), .{ .items = &.{} }),
        .specification = specification,
        .mode = try c.literal(t.Mode, .active),
        .desired_mode = try c.literal(@FieldType(t.Head, "desired_mode"), .active),
        .recovery_hold = try b.constant(bool, false),
        .recovery_boundary = try c.literal(?t.InputReference, null),
        .observed = try c.literal(t.Frontier, .{ .sequence = 0, .epoch = 0, .tip = null }),
        .told = try c.literal(t.Frontier, .{ .sequence = 0, .epoch = 0, .tip = null }),
        .told_receipt = try c.literal(?t.Receipt, null),
        .last_observation = try c.literal(?t.Observation, null),
        .digest = try c.literal(?t.DigestIntent, null),
        .activation = try b.variant(
            try c.schema(?t.DeliveryIntent),
            "some",
            try activation(c, b, input),
        ),
        .question = try c.literal(?t.Question, null),
        .method = try c.literal(t.Method, .{ .ordinary = {} }),
        .method_disposition = try c.literal(?t.MethodDisposition, null),
        .next_due_ms = try b.field(input, "clock_ms"),
        .clock_ms = try b.field(input, "clock_ms"),
        .skipped_slots = try b.constant(u64, 0),
        .phase = try c.literal(t.Phase, .fold),
        .previous_check_overran = try b.constant(bool, false),
        .check_failure_streak = try b.constant(u32, 0),
        .render_failure_streak = try b.constant(u32, 0),
        .source_not_before_ms = try b.field(input, "clock_ms"),
        .render_not_before_ms = try b.field(input, "clock_ms"),
        .accounting = try c.literal(t.Accounting, .{}),
    });
}

fn importedHead(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Genesis),
    imported: a.Value(@typeInfo(@FieldType(t.Genesis, "imported")).optional.child),
) !a.Value(t.Head) {
    const previous = try b.field(imported, "head");
    const desired = try b.field(previous, "desired_mode");
    const cancelled = try b.equal(
        try b.enumTag(desired),
        try b.enumTag(try c.literal(@FieldType(t.Head, "desired_mode"), .cancelled)),
    );
    return a.replace(c, b, t.Head, previous, .{
        .obligation = try c.literal(t.GenesisIdentity, .{ .self = {} }),
        .sequence = try b.constant(u64, 0),
        .predecessor = try b.variant(
            try c.schema(?t.Reference),
            "some",
            try b.field(imported, "source"),
        ),
        .attempt = try b.constant(u32, 0),
        .superseded = try c.literal(?t.InputReference, null),
        .consumed = try c.literal(@FieldType(t.Head, "consumed"), .{ .items = &.{} }),
        .folded_directive_ordinal = try b.constant(u64, 0),
        .last_directive = try c.literal(?t.InputReference, null),
        .mode = try b.select(
            cancelled,
            try c.literal(t.Mode, .cancelled),
            try c.literal(t.Mode, .paused),
        ),
        .recovery_hold = try b.constant(bool, true),
        .recovery_boundary = try c.literal(?t.InputReference, null),
        .clock_ms = try b.field(input, "clock_ms"),
        .next_due_ms = try b.field(input, "clock_ms"),
    });
}

fn activation(
    c: protean.Context,
    b: anytype,
    input: a.Value(t.Genesis),
) !a.Value(t.DeliveryIntent) {
    const specification = try b.field(input, "specification");
    return b.product(try c.schema(t.DeliveryIntent), .{
        .destination = try b.field(specification, "destination"),
        .key = try b.product(try c.schema(t.DeliveryKey), .{
            .lineage = try b.field(input, "lineage"),
            .purpose = try c.literal(@FieldType(t.DeliveryKey, "purpose"), .activation),
            .identity = try b.field(try b.field(input, "envelope"), "stable_request"),
            .generation = try b.constant(u32, 0),
        }),
        .payload = try c.literal(t.LogicalPayload, .{
            .obligation = null,
            .specification_revision = 0,
            .prior_sequence = 0,
            .through_sequence = 0,
            .frozen_text = .{ .bytes = "PAREDROS is active. " ++
                "First source observation is pending. " ++
                "Marker retrieval has not yet been qualified." },
            .prompt = null,
            .supersedes = null,
        }),
    });
}
