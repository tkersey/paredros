const c = @import("protean_contracts");
const invocation = @import("protean").model_invocation;

pub const application_id = "paredros";
pub const application_version = "0.0.1";
pub const Answer = void;
pub const answer_schema_id = "paredros.answer.v1";
pub const input_schema_id = "paredros.input.v1";
pub const output_schema_id = "paredros.output.v1";
pub const failure_schema_id = "paredros.failure.v1";
pub const message_schema_id = "paredros.message.v1";

pub const Id = [16]u8;
pub const Digest = [32]u8;
pub const Oid = [40]u8;
pub const Name = c.Text(128);
pub const Text = c.Text(16 * 1024);
pub const Timestamp = c.Text(64);
pub const OperationId = c.Text(128);
pub const ModelBinding = struct {
    policy: Digest,
    selection: invocation.AdaptiveSelection,
    profile: invocation.AdaptiveInferenceProfile,
    catalog: invocation.ArtifactReference,
    responses: c.ResponsesContract,
};
pub const Reference = struct { task: Id, digest: Digest };
pub const InputReference = struct { task: Id, digest: Digest };
pub const PublicationReference = union(enum) { current: void, retained: Reference };
pub const ControlReceipt = struct { operation: OperationId, task: Id, bytes: c.Bytes(64 * 1024) };
pub const RevisionReference = struct { task: Id, revision: u64, digest: Digest };
pub const GenesisIdentity = union(enum) { self: void, task: Id };
pub const Origin = union(enum) {
    local: struct { uid: u32 },
    derived: struct { predecessor: Reference },
};
pub const Envelope = struct {
    version: u32 = 1,
    operation: OperationId,
    stable_request: Digest,
    origin: Origin,
};
pub const Repository = struct {
    account: Name,
    id: u64,
    owner: Name,
    name: Name,
    ref: c.Text(1024),
};
pub const Policies = struct {
    notification_interval_ms: u64 = 60_000,
    clock_regression_tolerance_ms: u64 = 300_000,
    phase_attempts: u32 = 3,
    method_faults: u32 = 3,
    render_input_bytes: u64 = 64 * 1024,
    context_bytes: u64 = 64 * 1024,
};
pub const Specification = struct {
    revision: u64,
    repository: Repository,
    interval_ms: u64,
    anchor_ms: i64,
    wording: Text,
    policies: Policies,
};
pub const Mode = enum { active, paused, cancelled, transferred };
pub const Phase = enum { fold, check, render };
pub const Coverage = enum { baseline, complete, incomplete, behind, diverged, accepted_gap };
pub const Observation = struct {
    sequence: u64,
    epoch: u64,
    tip: Oid,
    batch: ?PublicationReference,
    coverage: Coverage,
    acquired_ms: i64,
    provider_date: ?Timestamp,
    commit_count: u64,
};
pub const Frontier = struct {
    sequence: u64,
    epoch: u64,
    tip: ?Oid,
};
pub const Accounting = struct {
    known_calls: u64 = 0,
    known_input_tokens: u64 = 0,
    known_output_tokens: u64 = 0,
    retained_bytes: u64 = 0,
    failed_attempts: u64 = 0,
    possible_charged_calls: u64 = 0,
};
pub const Question = struct {
    identity: Digest,
    condition: Digest,
    specification_revision: u64,
    source_condition: ?struct {
        epoch: u64,
        base: Oid,
        tip: Oid,
        coverage: enum { behind, diverged, incomplete },
    } = null,
    choices: c.Vector(Choice, 8),
    prompt: Text,
};
pub const Comparison = struct { repository: Repository, base: Oid, tip: Oid };
pub const Choice = struct { value: Name, label: Name };
pub const Notification = struct {
    specification_revision: u64,
    text: Text,
    comparison: ?Comparison = null,
    purpose: union(enum) {
        activation: void,
        digest: struct { prior: Frontier, through: Frontier },
        question: struct { identity: Digest, choices: c.Vector(Choice, 8) },
    },
};
pub const Method = union(enum) {
    ordinary: void,
    retained: struct {
        source: Reference,
        source_digest: Digest,
        contract_digest: Digest,
        report: Reference,
        applicability: Digest,
        state: c.Bytes(16 * 1024),
        consecutive_faults: u32,
    },
};
pub const RetainedMethodSource = struct {
    source: Reference,
    source_digest: Digest,
    contract_digest: Digest,
    bytes: c.Bytes(null),
};
pub const MethodDisposition = struct {
    source: Reference,
    source_digest: Digest,
    reason: Name,
    consecutive_faults: u32,
    model_consumed: bool,
    reverted: bool,
};
pub const Schedule = struct {
    next_due_ms: i64,
    source_not_before_ms: i64,
    render_not_before_ms: i64,
    provider_not_before_ms: i64,
};
pub const ClockRegression = struct { previous_clock_ms: i64, clock_ms: i64 };
pub const Head = struct {
    version: u32 = 1,
    obligation: GenesisIdentity,
    lineage: Digest,
    sequence: u64,
    predecessor: ?Reference,
    attempt: u32,
    superseded: ?InputReference,
    folded_directive_ordinal: u64,
    last_directive: ?InputReference,
    consumed: c.Vector(RevisionReference, 128),
    specification: Specification,
    mode: Mode,
    desired_mode: enum { active, paused, cancelled },
    observed: Frontier,
    told: Frontier,
    last_observation: ?Observation,
    message: ?Notification,
    question: ?Question,
    method: Method,
    method_disposition: ?MethodDisposition = null,
    schedule: Schedule,
    check_requested: bool,
    clock_ms: i64,
    skipped_slots: u64,
    clock_regressions: u64,
    last_clock_regression: ?ClockRegression,
    phase: Phase,
    previous_check_overran: bool,
    check_failure_streak: u32,
    render_failure_streak: u32,
    accounting: Accounting,
};
pub const Amendment = struct {
    expected_revision: u64,
    interval_ms: ?u64,
    wording: ?Text,
    policies: ?Policies,
    repository_route: ?struct { owner: Name, name: Name },
};
pub const DirectiveBody = union(enum) {
    pause: void,
    @"resume": void,
    cancel: void,
    check: void,
    amend: Amendment,
    answer: struct { question: Digest, choice: Name },
    adopt: struct { expected_revision: u64, method: Method },
    revert: struct { expected_revision: u64 },
    transfer: void,
};
pub const Directive = struct {
    envelope: Envelope,
    obligation: Id,
    ordinal: u64,
    predecessor: ?InputReference,
    body: DirectiveBody,
};
pub const DirectiveFact = struct { reference: InputReference, value: Directive };
pub const DirectiveDisposition = struct {
    directive: InputReference,
    ordinal: u64,
    outcome: union(enum) { applied: void, requested: void, rejected: Name },
};
pub const Commit = struct { oid: Oid, message: c.Utf8 };
pub const ReadEvidence = struct {
    request_digest: Digest,
    target: c.Utf8,
    status: u16,
    headers: c.Vector(struct { name: c.Utf8, value: c.Bytes(null) }, null) = .{ .items = &.{} },
    identity_encoding: bool = true,
    media_type: ?Name = null,
    content_encoding: ?Name = null,
    body: c.Bytes(null),
    body_digest: Digest,
    captured_ms: i64,
    provider_date: ?Timestamp,
    request_id: ?Name,
    link: ?c.Utf8,
    etag: ?c.Utf8,
    retry_after: ?Name,
    rate_remaining: ?Name,
    rate_reset: ?Name,
};
pub const Batch = struct {
    repository: Repository,
    sequence: u64,
    epoch: u64,
    base: Oid,
    tip: Oid,
    coverage: Coverage,
    commits: c.Vector(Commit, null),
    raw_evidence: c.Vector(ReadEvidence, null),
    acquired_ms: i64,
    provider_date: ?Timestamp,
};
pub const Settlement = struct {
    reference: RevisionReference,
    owner_snapshot: c.Bytes(null) = .{ .bytes = "" },
    kind: enum { phase, turn, experiment, superseded },
    accounting: Accounting,
    previous_accounting: Accounting = .{},
    previous_reference: ?RevisionReference = null,
};
pub const Supersession = struct {
    input: InputReference,
    phase: Phase = .fold,
    attempt: u32,
    cancellation: ControlReceipt,
    cause: enum { incompatible, unknown, rejected, failed, control },
};
pub const ReportValue = struct { plan: c.Bytes(1024 * 1024), result: ExperimentResult };
pub const ContinuityMember = struct {
    envelope: Envelope,
    bundle: Digest,
    report: ReportValue,
};
pub const ContinuityCut = struct {
    envelope: Envelope,
    bundle_digest: Digest,
    bytes: c.Bytes(null),
};
pub const ContinuityImport = struct { bundle: Digest, manifest: Reference, member: u32 };
pub const CarriedHead = struct { head: Head, batches: c.Vector(Batch, null) };
pub const TransferMarker = struct { envelope: Envelope };
pub const ConfirmationReceipt = struct { envelope: Envelope, task: Id };
pub const Genesis = struct {
    envelope: Envelope,
    lineage: Digest,
    specification: Specification,
    clock_ms: i64,
    imported: ?struct {
        carried: ?CarriedHead,
        continuity: ContinuityImport,
    },
};
pub const Step = struct {
    envelope: Envelope,
    obligation: Id,
    predecessor: Reference,
    previous: Head,
    sequence: u64,
    attempt: u32,
    supersession: ?Supersession,
    directives: c.Vector(DirectiveFact, 128),
    facts: c.Vector(Settlement, 128),
    batches: c.Vector(struct { reference: Reference, value: Batch }, null),
    clock_ms: i64,
    fold_only: bool,
    model: ?ModelBinding = null,
    method_source: ?RetainedMethodSource = null,
};
pub const StepResult = struct {
    head: Head,
    batch: ?Batch,
    dispositions: c.Vector(DirectiveDisposition, 128),
};
pub const Proposal = struct {
    identity: struct { operation: OperationId, ordinal: u32, attempt: u32 = 0 },
    target: ?Id,
    body: union(enum) { genesis: Specification, directive: DirectiveBody },
    description: ?Text = null,
};
pub const TurnReplacement = struct {
    input: InputReference,
    attempt: u32,
    cancellation: ControlReceipt,
    reference: RevisionReference,
    owner_snapshot: c.Bytes(null),
};
pub const TurnContinuity = struct {
    manifest: Reference,
    member: u32,
    turn: u32,
    continuation: enum { portable_import },
};
pub const Turn = struct {
    envelope: Envelope,
    continuity: ?TurnContinuity = null,
    replacement: ?TurnReplacement = null,
    refusal: ?Name = null,
    ordinal: u64 = 0,
    text: Text,
    context: c.Text(256 * 1024),
    context_references: c.Vector(RevisionReference, 128),
    attempt: u32,
    model: ?ModelBinding = null,
    target: ?Id = null,
    expected_revision: ?u64 = null,
    proposal_offers: c.Vector(@FieldType(Proposal, "body"), 32) = .{ .items = &.{} },
    genesis_template: ?Specification = null,
};
pub const TurnResult = struct {
    reply: Text,
    proposals: c.Vector(Proposal, 3),
};
pub const Experiment = struct {
    envelope: Envelope,
    campaign: Digest,
    attempt: u32,
    plan: c.Bytes(1024 * 1024),
    evidence: c.Vector(Reference, null),
    live_model: bool,
};
pub const ExperimentResult = struct {
    campaign: Digest,
    attempt: u32,
    report: c.Bytes(1024 * 1024),
    accounting: Accounting,
};
pub const Input = union(enum) {
    genesis: Genesis,
    step: Step,
    directive: Directive,
    turn: Turn,
    experiment: Experiment,
    continuity_member: ContinuityMember,
    continuity_cut: ContinuityCut,
    transfer: TransferMarker,
    confirmation: ConfirmationReceipt,
};
pub const Output = union(enum) {
    genesis: Head,
    step: StepResult,
    directive: Directive,
    turn: TurnResult,
    experiment: ExperimentResult,
    continuity_member: ContinuityMember,
    continuity_cut: ContinuityCut,
    transfer: TransferMarker,
    confirmation: ConfirmationReceipt,
};
pub const Failure = struct { code: Name };
pub const Message = union(enum) { pause: struct { directive: InputReference } };
