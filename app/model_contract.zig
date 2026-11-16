const protean = @import("protean");
const c = @import("protean_contracts");
const t = @import("application_types");
const frame = @import("render_frame.zig");

pub const Binding = t.ModelBinding;
pub const Effort = @FieldType(protean.model_invocation.AdaptiveSelection, "effective_effort");
pub const Summary = struct { summary: c.Text(1024), highlights: frame.Highlights };
pub const ProposalBody = @FieldType(t.Proposal, "body");
pub const RawSummary = struct {
    summary: c.Text(1024),
    highlights: c.Vector(struct { oid: c.Text(40), text: c.Text(256) }, 8),
};
pub const Amendment = struct {
    interval_ms: ?u64,
    wording: ?t.Text,
    policies: ?t.Policies,
    repository_route: @FieldType(t.Amendment, "repository_route"),
};
pub const Suggestion = union(enum) {
    propose_amend: Amendment,
    select_proposal: struct { index: u32 },
    propose_genesis: struct { interval_ms: u64, wording: t.Text, policies: t.Policies },
};
pub const Conversation = struct { reply: t.Text, proposals: c.Vector(Suggestion, 3) };
pub const Action = union(enum) { summarize: RawSummary, converse: Conversation };
pub const P = protean.model_invocation.Profile(Action, .{
    .{ .name = "summarize", .description = "Suggest an inert summary and at most eight " ++
        "highlights naming exact commit OIDs in the supplied evidence. Do not invent links " ++
        "or claim file-level analysis. This candidate grants no operation authority." },
    .{ .name = "converse", .description = "Suggest a reply and at most three proposed " ++
        "operations for separate owner confirmation. Proposals execute nothing. " ++
        "Use only the caller-selected target and revision." },
}, .{
    .model_id_bytes = 128,
    .temperature_bytes = 32,
    .maximum_messages = 2,
    .message_bytes = 256 * 1024,
    .maximum_output_items = 8,
    .call_id_bytes = 128,
    .arguments_json_bytes = 512 * 1024,
    .result_text_bytes = 128 * 1024,
    .provider_response_bytes = 2 * 1024 * 1024,
});
pub const Input = struct {
    binding: Binding,
    phase: enum { summary, conversation },
    context: c.Text(256 * 1024),
    initiating_input: t.Digest,
    target: ?t.Id,
    expected_revision: ?u64,
    proposal_offers: c.Vector(ProposalBody, 32),
    genesis_template: ?t.Specification,
};
pub const BoundProposal = struct {
    initiating_input: t.Digest,
    target: ?t.Id,
    expected_revision: ?u64,
    body: ProposalBody,
};
pub const Proposals = c.Vector(BoundProposal, 3);
pub const Candidate = union(enum) {
    summary: Summary,
    conversation: struct { reply: t.Text, proposals: Proposals },
    rejected: P.InterpretationFailure,
};
pub const Result = struct { candidate: Candidate, usage: ?protean.model_invocation.AdaptiveUsage };
