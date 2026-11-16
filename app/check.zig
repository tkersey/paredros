const protean = @import("protean");
const cts = @import("protean_contracts");
const t = @import("application_types");
const g = @import("github_contract.zig");
const a = @import("author.zig");
const bytes = @import("bytes.zig");

pub const Input = struct { repository: t.Repository, previous: ?t.Oid };
pub const Evidence = cts.Vector(t.ReadEvidence, null);
pub const Commits = cts.Vector(t.Commit, null);
pub const Oids = cts.Vector(t.Oid, null);
pub const Result = struct {
    kind: enum { baseline, unchanged, complete, rejected },
    base: ?t.Oid,
    tip: ?t.Oid,
    reason: ?g.Failure,
    commits: Commits,
    evidence: Evidence,
};
pub const Function = a.Function(struct { input: Input }, Result);
const Read = a.Operation(g.Request, g.Reply);
const FinishInput = struct { repository: t.Repository, result: Result };
const Finish = a.Function(struct { input: FinishInput }, Result);
const State = struct {
    repository: t.Repository,
    page: g.Page,
    commits: Commits,
    evidence: Evidence,
};
const Pages = a.Function(struct { state: State }, Result);
const ReferenceInput = struct { input: Input, evidence: Evidence };
const Reference = a.Function(struct { input: ReferenceInput }, Result);
const ProjectInput = struct { commits: Commits, seen: Oids, index: u64 };
const Project = a.Function(ProjectInput, Oids);

pub fn emit(c: protean.Context) !Function {
    const reader = try c.external(g.identity, try c.schema(g.Request), try c.schema(g.Reply), .read);
    const project = try projectOids(c);
    const finish = try finishFunction(c, reader);
    const pages = try pagesFunction(c, reader, project, finish);
    const reference = try referenceFunction(c, reader, pages, finish);
    const function = try c.author.function("acquire GitHub observation", .{
        .input = try c.schema(Input),
    }, try c.schema(Result), .{reader});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const reply = try b.perform(reader, try request(c, b, try b.field(input, "repository"), "repository_before", try b.constant(void, {})));
    const success = try b.caseOf(reply, "repository");
    const rejected = try b.caseOf(reply, "rejected");
    const ref = try b.caseOf(reply, "reference");
    const page = try b.caseOf(reply, "page");
    const next = try success.body().call(reference, .{ .input = try success.body().product(
        try c.schema(ReferenceInput),
        .{
            .input = input,
            .evidence = try success.body().sequenceValue(try c.schema(Evidence), .{success.payload()}),
        },
    ) });
    const result = try b.match(reply, .{
        .repository = try success.ret(next),
        .rejected = try rejected.ret(try rejection(c, rejected.body(), rejected.payload(), try b.field(input, "previous"), try c.literal(?t.Oid, null), try c.literal(Evidence, .{ .items = &.{} }))),
        .reference = try ref.fail(try c.schema(Result), try invalid(c)),
        .page = try page.fail(try c.schema(Result), try invalid(c)),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn request(c: protean.Context, b: anytype, repository: a.Value(t.Repository), comptime phase: []const u8, payload: anytype) !a.Value(g.Request) {
    return b.product(try c.schema(g.Request), .{
        .repository = repository,
        .phase = try b.variant(try c.schema(@FieldType(g.Request, "phase")), phase, payload),
    });
}

fn invalid(c: protean.Context) !a.Value(t.Failure) {
    return c.literal(t.Failure, .{ .code = .{ .bytes = "github_reply_shape" } });
}

fn rejection(c: protean.Context, b: anytype, rejected: anytype, base: a.Value(?t.Oid), tip: a.Value(?t.Oid), evidence: a.Value(Evidence)) !a.Value(Result) {
    const optional = try b.field(rejected, "evidence");
    const none = try b.caseOf(optional, "none");
    const some = try b.caseOf(optional, "some");
    const retained = try b.match(optional, .{
        .none = try none.ret(evidence),
        .some = try some.ret(try some.body().append(evidence, some.payload(), .{})),
    });
    return b.product(try c.schema(Result), .{
        .kind = try c.literal(@FieldType(Result, "kind"), .rejected),
        .base = base,
        .tip = tip,
        .reason = try b.variant(try c.schema(?g.Failure), "some", try b.field(rejected, "reason")),
        .commits = try c.literal(Commits, .{ .items = &.{} }),
        .evidence = retained,
    });
}

fn finishFunction(c: protean.Context, reader: Read) !Finish {
    const function = try c.author.function("recheck repository identity", .{
        .input = try c.schema(FinishInput),
    }, try c.schema(Result), .{reader});
    const b = try c.author.body(function);
    const input = try b.parameter("input");
    const previous = try b.field(input, "result");
    const evidence = try b.field(previous, "evidence");
    const reply = try b.perform(reader, try request(c, b, try b.field(input, "repository"), "repository_after", try b.constant(void, {})));
    const success = try b.caseOf(reply, "repository");
    const rejected = try b.caseOf(reply, "rejected");
    const reference = try b.caseOf(reply, "reference");
    const page = try b.caseOf(reply, "page");
    const result = try b.match(reply, .{
        .repository = try success.ret(try success.body().update(previous, .{
            .evidence = try success.body().append(evidence, success.payload(), .{}),
        })),
        .rejected = try rejected.ret(try rejection(c, rejected.body(), rejected.payload(), try b.field(previous, "base"), try b.field(previous, "tip"), evidence)),
        .reference = try reference.fail(try c.schema(Result), try invalid(c)),
        .page = try page.fail(try c.schema(Result), try invalid(c)),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn referenceFunction(c: protean.Context, reader: Read, pages: Pages, finish: Finish) !Reference {
    const equal = try bytes.emit(c, 40);
    const function = try c.author.function("freeze exact Git reference", .{
        .input = try c.schema(ReferenceInput),
    }, try c.schema(Result), .{reader});
    const b = try c.author.body(function);
    const input = try b.field(try b.parameter("input"), "input");
    const evidence = try b.field(try b.parameter("input"), "evidence");
    const repository = try b.field(input, "repository");
    const previous = try b.field(input, "previous");
    const reply = try b.perform(reader, try request(c, b, repository, "reference", try b.constant(void, {})));
    const success = try b.caseOf(reply, "reference");
    const rejected = try b.caseOf(reply, "rejected");
    const repo = try b.caseOf(reply, "repository");
    const page = try b.caseOf(reply, "page");
    const sb = success.body();
    const tip = try sb.field(success.payload(), "tip");
    const retained = try sb.append(evidence, try sb.field(success.payload(), "evidence"), .{});
    const none = try sb.caseOf(previous, "none");
    const some = try sb.caseOf(previous, "some");
    const compared = try compareTip(c, some.body(), repository, some.payload(), tip, retained, equal, pages, finish);
    const selected = try sb.match(previous, .{
        .none = try none.ret(try emptyResult(c, none.body(), finish, repository, previous, tip, retained, .baseline)),
        .some = try some.ret(compared),
    });
    const result = try b.match(reply, .{
        .reference = try success.ret(selected),
        .rejected = try rejected.ret(try rejection(c, rejected.body(), rejected.payload(), previous, try c.literal(?t.Oid, null), evidence)),
        .repository = try repo.fail(try c.schema(Result), try invalid(c)),
        .page = try page.fail(try c.schema(Result), try invalid(c)),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn emptyResult(c: protean.Context, b: anytype, finish: Finish, repository: a.Value(t.Repository), base: a.Value(?t.Oid), tip: a.Value(t.Oid), evidence: a.Value(Evidence), comptime kind: @FieldType(Result, "kind")) !a.Value(Result) {
    return b.call(finish, .{ .input = try b.product(try c.schema(FinishInput), .{
        .repository = repository,
        .result = try b.product(try c.schema(Result), .{
            .kind = try c.literal(@FieldType(Result, "kind"), kind),
            .base = base,
            .tip = try b.variant(try c.schema(?t.Oid), "some", tip),
            .reason = try c.literal(?g.Failure, null),
            .commits = try c.literal(Commits, .{ .items = &.{} }),
            .evidence = evidence,
        }),
    }) });
}

fn compareTip(c: protean.Context, b: anytype, repository: a.Value(t.Repository), base: a.Value(t.Oid), tip: a.Value(t.Oid), evidence: a.Value(Evidence), equal: a.Function(bytes.Parameters(40), bool), pages: Pages, finish: Finish) !a.Value(Result) {
    const unchanged = try b.branch();
    const changed = try b.branch();
    const baseline = try unchanged.variant(try c.schema(?t.Oid), "some", base);
    const first = try changed.product(try c.schema(State), .{
        .repository = repository,
        .page = try changed.product(try c.schema(g.Page), .{
            .base = base,
            .tip = tip,
            .ordinal = try changed.constant(u64, 1),
            .url = try c.literal(?cts.Utf8, null),
            .metadata = try c.literal(?g.Metadata, null),
            .seen = try c.literal(Oids, .{ .items = &.{} }),
        }),
        .commits = try c.literal(Commits, .{ .items = &.{} }),
        .evidence = evidence,
    });
    return b.conditional(try b.call(equal, .{
        .left = base,
        .right = tip,
        .index = try b.constant(u64, 0),
    }), try unchanged.ret(try emptyResult(c, unchanged, finish, repository, baseline, tip, evidence, .unchanged)), try changed.ret(try changed.call(pages, .{ .state = first })));
}

fn projectOids(c: protean.Context) !Project {
    const function = try c.author.function("retain acquired commit identities", .{
        .commits = try c.schema(Commits),
        .seen = try c.schema(Oids),
        .index = try c.schema(u64),
    }, try c.schema(Oids), &.{});
    const b = try c.author.body(function);
    const commits = try b.parameter("commits");
    const seen = try b.parameter("seen");
    const index = try b.parameter("index");
    const active = try b.branch();
    const ended = try b.branch();
    const failure = try a.failure(c, "github_commit_bounds");
    const commit = try active.variantPayload(try active.sequenceGet(commits, index), "some", failure);
    const next = try active.call(function, .{
        .commits = commits,
        .seen = try active.append(seen, try active.field(commit, "oid"), .{}),
        .index = try active.checked(.add, index, try active.constant(u64, 1), .{ .overflow = failure }),
    });
    try c.author.define(function, try b.ret(try b.conditional(
        try b.less(index, try b.sequenceLength(commits)),
        try active.ret(next),
        try ended.ret(seen),
    )));
    return function;
}

fn pagesFunction(c: protean.Context, reader: Read, project: Project, finish: Finish) !Pages {
    const function = try c.author.function("acquire frozen comparison pages", .{
        .state = try c.schema(State),
    }, try c.schema(Result), .{reader});
    const b = try c.author.body(function);
    const state = try b.parameter("state");
    const page = try b.field(state, "page");
    const reply = try b.perform(reader, try request(c, b, try b.field(state, "repository"), "page", page));
    const success = try b.caseOf(reply, "page");
    const rejected = try b.caseOf(reply, "rejected");
    const repository = try b.caseOf(reply, "repository");
    const reference = try b.caseOf(reply, "reference");
    const result = try b.match(reply, .{
        .page = try success.ret(try acceptPage(c, success.body(), function, project, finish, state, success.payload())),
        .rejected = try rejected.ret(try rejection(c, rejected.body(), rejected.payload(), try b.variant(try c.schema(?t.Oid), "some", try b.field(page, "base")), try b.variant(try c.schema(?t.Oid), "some", try b.field(page, "tip")), try b.field(state, "evidence"))),
        .repository = try repository.fail(try c.schema(Result), try invalid(c)),
        .reference = try reference.fail(try c.schema(Result), try invalid(c)),
    });
    try c.author.define(function, try b.ret(result));
    return function;
}

fn acceptPage(c: protean.Context, b: anytype, pages: Pages, project: Project, finish: Finish, state: a.Value(State), reply: a.Value(@FieldType(g.Reply, "page"))) !a.Value(Result) {
    const page = try b.field(state, "page");
    const commits = try b.field(reply, "commits");
    try a.require(c, b, try b.less(try b.constant(u64, 0), try b.sequenceLength(commits)), "github_empty_page");
    const evidence = try b.append(try b.field(state, "evidence"), try b.field(reply, "evidence"), .{});
    const all = try b.concat(try b.field(state, "commits"), commits, .{});
    const next = try b.field(reply, "next");
    const none = try b.caseOf(next, "none");
    const some = try b.caseOf(next, "some");
    const next_page = try some.body().update(page, .{
        .ordinal = try some.body().checked(.add, try b.field(page, "ordinal"), try b.constant(u64, 1), .{ .overflow = try a.failure(c, "github_page_overflow") }),
        .url = next,
        .metadata = try some.body().variant(try c.schema(?g.Metadata), "some", try b.field(reply, "metadata")),
        .seen = try some.body().call(project, .{
            .commits = commits,
            .seen = try b.field(page, "seen"),
            .index = try b.constant(u64, 0),
        }),
    });
    const successor = try some.body().update(state, .{ .page = next_page, .commits = all, .evidence = evidence });
    const completed = try none.body().product(try c.schema(Result), .{
        .kind = try c.literal(@FieldType(Result, "kind"), .complete),
        .base = try b.variant(try c.schema(?t.Oid), "some", try b.field(page, "base")),
        .tip = try b.variant(try c.schema(?t.Oid), "some", try b.field(page, "tip")),
        .reason = try c.literal(?g.Failure, null),
        .commits = all,
        .evidence = evidence,
    });
    return b.match(next, .{
        .some = try some.ret(try some.body().call(pages, .{ .state = successor })),
        .none = try none.ret(try none.body().call(finish, .{ .input = try none.body().product(
            try c.schema(FinishInput),
            .{ .repository = try b.field(state, "repository"), .result = completed },
        ) })),
    });
}
