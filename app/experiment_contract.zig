const c = @import("protean_contracts");
const t = @import("application_types");
const step = @import("step.zig");
const method = @import("method_contract.zig");
const model = @import("model_contract.zig");
const frame = @import("render_frame.zig");

pub const codec_identity = "paredros.experiment.codec.v1";
pub const clock_identity = "paredros.experiment.clock.v1";
pub const advances_per_render: u32 = 128;
pub const Condition = enum { recurrence, changed, oversized, interruption, withheld };
pub const Mode = enum { source_registration, scripted_v1, live };
pub const Rule = enum { reject_mechanical_failures_else_inconclusive };
pub const Rubric = struct {
    required: c.Vector(c.Text(128), 8),
    forbidden: c.Vector(c.Text(128), 8),
    maximum_output_bytes: u32 = 4000,
};
pub const Case = struct {
    name: t.Name,
    condition: Condition,
    trial: u32,
    input: step.RenderInput,
    rubric: Rubric,
};
pub const Candidate = struct {
    name: t.Name,
    source: t.RetainedMethodSource,
    construction_evidence: c.Vector(t.Reference, 16),
};
pub const Budget = struct {
    render_runs: u32,
    child_advances: u64,
    live_calls: u32,
    report_bytes: u32 = 1024 * 1024,
};
pub const ComparisonPlan = struct {
    version: u32 = 1,
    candidates: c.Vector(Candidate, 4),
    cases: c.Vector(Case, 32),
    rule: Rule,
    budget: Budget,
    model: ?t.ModelBinding = null,
    expected_recurrences: ?u64 = null,
};
pub const SourceDraft = struct {
    name: t.Name,
    bytes: c.Bytes(960 * 1024),
    contract_digest: t.Digest,
    provenance: c.Vector(t.Reference, 16),
    origin: enum { operator_supplied, model_proposed },
};
pub const ConstructionPlan = struct {
    version: u32 = 1,
    sources: c.Vector(SourceDraft, 4),
    maximum_source_bytes: u32 = 960 * 1024,
};
pub const Plan = union(enum) { construct: ConstructionPlan, compare: ComparisonPlan };
pub const RegisteredSource = struct {
    draft: SourceDraft,
    source_digest: t.Digest,
    qualification: enum { unqualified },
};
pub const Identity = struct {
    campaign: t.Digest,
    attempt: u32,
    plan_digest: t.Digest,
    mode: Mode,
};
pub const Measurements = struct {
    model_calls: ?u64 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    possible_charged_calls: ?u64 = null,
    retained_bytes: ?u64 = null,
    recovery_work: ?u64 = null,
    money_micros: ?u64 = null,
};
pub const Quality = struct {
    required_present: bool,
    forbidden_absent: bool,
    within_output_bound: bool,
    responsibility_preserved: bool,
    semantic_assessment: ?bool = null,
};
pub const Run = struct {
    case_index: u32,
    arm: u32,
    trial: u32,
    condition: Condition,
    output: frame.Text,
    output_digest: t.Digest,
    method_fault: ?t.Name,
    quality: Quality,
    state_bytes: u32,
    wall_elapsed_including_recovery_ms: ?u64,
    interruption_checkpoint: bool,
    actual_process_recovery: ?bool = null,
    measurements: Measurements = .{},
};
pub const Runs = c.Vector(Run, 160);
pub const CaseEvidence = struct {
    name: t.Name,
    condition: Condition,
    trial: u32,
    input_digest: t.Digest,
    rubric: Rubric,
};
pub const Spread = struct { samples: u32 = 0, minimum_ms: ?u64 = null, maximum_ms: ?u64 = null };
pub const CandidateEvidence = struct {
    name: t.Name,
    source: t.Reference,
    source_digest: t.Digest,
    contract_digest: t.Digest,
    construction_evidence: c.Vector(t.Reference, 16),
    source_bytes: u64,
    disposition: enum { rejected, evidence_inconclusive },
    completed_runs: u32,
    passed_mechanical_rubric: u32,
    cold_wall_ms: ?u64,
    recurring_wall: Spread,
    construction: Measurements = .{},
    qualification: Measurements = .{},
    recurring: Measurements = .{},
    amortization_recurrences: ?u64 = null,
};
pub const Trials = struct {
    condition: Condition,
    count: u32,
    anecdote: bool,
    includes_cold_start: bool,
    ordinary_wall: Spread,
    candidate_wall: c.Vector(Spread, 4),
};
pub const Report = struct {
    version: u32 = 1,
    kind: enum { source_registration, comparison, rejected_plan },
    identity: Identity,
    rejection: ?t.Name,
    rule: Rule,
    budget: ?Budget,
    expected_recurrences: ?u64,
    cases: c.Vector(CaseEvidence, 32),
    candidates: c.Vector(CandidateEvidence, 4),
    registered_sources: c.Vector(RegisteredSource, 4),
    trials: c.Vector(Trials, 5),
    runs: Runs,
    ordinary_cold_wall_ms: ?u64,
    ordinary_recurring_wall: Spread,
    writes: enum { simulated },
    decision: enum { ordinary_retained },
    efficacy: enum { not_established },
    owner_join: enum { required },
    campaign_totals: Measurements = .{},
};
pub const States = c.Vector(method.State, 4);
pub const Prepared = struct {
    identity: Identity,
    plan: ComparisonPlan,
    states: States,
    model: t.ModelBinding,
};
pub const RunInput = struct {
    envelope: t.Envelope,
    selected: Case,
    candidate: ?Candidate,
    state: method.State,
    model: t.ModelBinding,
};
pub const Observation = struct {
    case_index: u32,
    arm: u32,
    selected: Case,
    input: step.RenderInput,
    output: t.Head,
    started_ms: i64,
    ended_ms: i64,
};
pub const Observed = struct { run: Run, state: method.State };
pub const Checkpoint = struct { case_index: u32, arm: u32 };
pub const Stamp = struct {
    case_index: u32,
    arm: u32,
    edge: enum { begin, end },
};
pub const CodecRequest = union(enum) {
    prepare: t.Experiment,
    run_input: RunInput,
    observe: Observation,
    finish: struct { identity: Identity, plan: ComparisonPlan, runs: Runs },
    scripted_completion: model.Input,
    checkpoint: Checkpoint,
};
pub const CodecReply = union(enum) {
    prepared: Prepared,
    terminal: t.ExperimentResult,
    run_input: step.RenderInput,
    observed: Observed,
    finished: t.ExperimentResult,
    scripted_completion: model.Result,
    checkpoint: void,
};
