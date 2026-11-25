const c = @import("protean_contracts");
const t = @import("application_types");
const model = @import("model_contract.zig");
const w = c.workspace;

pub const workspace_identity = "paredros.method.workspace.v1";
pub const codec_identity = "paredros.method.codec.v1";
pub const completion_identity = "paredros.method.completion.v1";
pub const State = c.Bytes(16 * 1024);
pub const GuestInput = struct {
    batches: c.Vector(
        struct { reference: t.Reference, value: t.Batch },
        null,
    ),
    state: State,
};
pub const GuestOutput = struct { body: model.Summary, state: State };
pub const CompletionRequest = struct { context: c.Text(256 * 1024) };
pub const CompletionReply = union(enum) { summary: model.Summary, rejected: void };
pub const MethodInput = struct {
    retained: t.RetainedMethodSource,
    guest: GuestInput,
    input_bytes_max: u64,
    model: ?t.ModelBinding,
    initiating_input: t.Digest,
};
pub const Result = struct {
    outcome: union(enum) { success: GuestOutput, fault: t.Name },
    model_consumed: bool,
};
pub const WorkspaceRequest = struct {
    source_digest: t.Digest,
    contract_digest: t.Digest,
    command: w.Command,
};
pub const Prepared = struct {
    build: w.Command,
    input_json: c.Utf8,
    port_identity: ?c.Text(128),
};
pub const Built = struct { program: w.Ref, input: w.ValueInput };
pub const Port = struct {
    reference: w.Ref,
    generation: u64,
    argument_schema: w.Ref,
};
pub const Observation = struct {
    expected: w.Expected,
    state: union(enum) { running: void, waiting: void, port: Port, done: w.Ref, fault: t.Name },
};
pub const JsonText = c.Text(2 * 1024 * 1024);
pub const Page = struct {
    text: JsonText,
    next: u64,
    total: u64,
    eof: bool,
};
pub const CodecRequest = union(enum) {
    prepare: MethodInput,
    built: struct { reply: w.Reply, prepared: Prepared },
    observe: struct { reply: w.Reply, port_identity: ?c.Text(128) },
    page: struct { reply: w.Reply, offset: u64 },
    payload: JsonText,
    output: JsonText,
    encode_reply: CompletionReply,
};
pub const CodecReply = union(enum) {
    prepared: Prepared,
    built: Built,
    observed: Observation,
    page: Page,
    payload: CompletionRequest,
    output: GuestOutput,
    encoded: c.Utf8,
    fault: t.Name,
};
