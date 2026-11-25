# PAREDROS

PAREDROS is a personal assistant built as a Zig application on Protean. It watches
a configured GitHub branch, retains acquired evidence, prepares commit digests,
and records them as local messages that its one owner reads through the local
CLI. Conversation, local control, recovery, and retained method experiments use
the same durable task history.

The application is under qualification. Live provider and paid model
qualification have not been performed.

## Build

Use Zig 0.17.1. For `x86_64-linux-musl`, Zig emits x86-64 machine code directly
for Zig sources. Its bundled Clang compiles the two C sources, SQLite and the
POSIX shim. On Apple Silicon, Zig uses LLVM for `aarch64-macos` because its
direct ARM64 backend in 0.17.1 does not support the daemon's concurrent workers.

```sh
zig build setup
zig build -Dnative=true -Doptimize=safe
zig-out/bin/paredros describe-build
zig-out/bin/paredros licenses
```

`setup` uses the pinned Protean package's dependency admission tool and lockfiles.
It acquires and authenticates Horos, Kosmos, and SQLite under
`.protean-native/inputs`. `zig build setup -Dsetup-offline=true` verifies existing
inputs without acquisition. The native build independently checks those inputs.
Explicit `-Dkosmos-source=PATH` and `-Dsqlite-source=PATH` select other copies of
the same authenticated inputs.

`describe-build` reports the embedded application/runtime/dependency identities,
the Zig backend and the hash of the running executable. Keep that executable
with its namespace when retaining the original execution history.

## Offline checks

Run `zig build check` after editing GitHub protocol handling. It exercises
normalization, evidence digests, pagination, and other provider assertions. The check compiles a small host test executable and
executes it on each invocation. For a change to native GitHub capture or
recovery, add the real parked-page, reopen, and resume check.

```sh
zig build check
zig build check -Dcheck-recovery=true
```

Run `zig build qualify` with Zig 0.17.1, Node, and uv installed. It runs the
essential set within one 600-second budget measured from the `zig build`
invocation: TigerStyle over every tracked Zig file, the source contracts, the
emitted-application check, the native `providers` owner group, the installed
product's smoke checks, and eight process-death cases. On macOS one build compiles
every essential artifact concurrently. The product and native tests embed the committed emitted application in
`app/emitted/`, so they compile alongside Protean's emitter instead of after it.
Qualification runs `check-emitted`, which requires those bytes to equal a fresh
emission from `app/`. After editing `app/`, run
`zig build update-emitted -Dnative=true -Doptimize=safe` and commit the result. On
x86-64 Linux under Rosetta, export `ZIG_DEBUG_CMD=1` before invoking Zig. Use
`zig build qualify -- --list` to inspect the groups. Each invocation executes the
tests and writes fresh timings, outcomes, and logs under `zig-out/qualification/`.
For groups and their prerequisites use `zig build qualify -- --group NAME[,NAME...]`.

The authority, transitions, rendering, continuity and methods owner groups, the
24-arm comparison and the 100,000-task daemon are diagnostics. They do not gate a
candidate, and their absence from a result is not a pass. Run them with
`--group`, for example `zig build qualify -- --group methods-campaign`.

The 100,000-task daemon diagnostic opens a product-configured namespace
containing 100,000 real tasks. Keep it under
`.zig-cache/qualification-fixtures/100k`, or set `PAREDROS_HISTORY_100K` to its
directory. If its fixture is missing, `--group daemon-100k` stops before running
anything. Generate it once with the installed product, outside the timed checks:

```sh
zig build setup
zig build install build-scale-tests -Dnative=true -Dscale-tests=true -Doptimize=safe
uv run --no-project python tests/seed_scale_fixture.py
```

The scale fixture takes roughly 100 minutes to generate on the measured Mac.
Keep the generated namespace at its original location between candidates.
Ctrl-C lets the current batch close. Running the same generation command
again with the same producer resumes at the saved batch.

For individual diagnostics, `zig build test` runs the source contracts.
`zig build test-native -Dnative-tests=true -Dnative-group=NAME -Doptimize=safe`
runs native suites; repeat `-Dnative-group` to select several. The process-death
controller uses local fixtures, kills the process at named admission, dispatch,
capture, completion, or consumption boundaries, and checks retained state and
acquisition counts in a fresh process.

CI runs on GitHub-hosted Ubuntu x86-64. The `native` gate requires TigerStyle and
two lanes, source with the emitted-application check and providers, and must pass
within 600 seconds of the trigger. Each lane runs `zig build qualify -- --group`.
The Linux product smoke runs on every pull request as its own
`Qualification / product` check but is outside the gate: compiling the product
takes six to eight minutes on a hosted runner, which leaves the lane at nine to
ten minutes, so it runs with `--budget-seconds 840`. It passes `--essential`, omitting the licenses, version and offline
ask probes, which cost about 75 seconds on the direct backend; the macOS smoke
keeps them. The process-death cases need about nine minutes on a hosted runner,
so they run in local and fallback qualification. When none of a hosted run's jobs start, the
fallback workflow dispatches full macOS qualification on the Mac's self-hosted
runner as a separate `macOS fallback` check; it never replaces the hosted result.

PAREDROS pins Protean by commit and package hash in `build.zig.zon`. It uses
[the native embedding and recovery changes](https://github.com/tkersey/protean/pull/74),
[the authenticated Kosmos borrowing update](https://github.com/tkersey/protean/pull/75)
and [direct Linux x86-64 builds with bundled Clang](https://github.com/tkersey/protean/pull/76).
All three upstream changes completed their required qualification, serial reviews,
and landing. Application qualification and reviews must cover this selected pin;
upstream verification alone does not qualify PAREDROS. Live-provider qualification
remains deferred.

By owner decision this release ships without the specified Slack integration
and performs no external write. Every output for the owner is a local message
published with the head that decides it and read with `messages`; owner input
arrives only through the local CLI and control socket. There are no delivery
tasks, delivery holds or releases, audits, or rollback boundaries.
[Amendment 2.2 of the implementation specification](docs/implementation-spec.md)
states these laws. The release also omits three other specified behaviors:
GitHub transport health in `status`; the single announcement for a reference that
returns `404` on consecutive checks (A65); and a visible storage hold for exhausted
storage. When SQLite reports a full database, Protean fences the store
(`StorageUnavailable`).

[Offline measurements](docs/measurements.md) document task storage, startup,
empty-check costs, reproduction commands, and the current performance limits.

## Run and control

Start with [the offline configuration example](docs/config.example.json), changing
the UID and absolute paths to match the account running the daemon. Create the
namespace parent, control-socket parent, and backup directory with owner-only
permissions. Offline mode reads no credentials and grants no provider access.
`serve` holds an exclusive lock on the control socket path plus `.lock` while it
runs, and reclaims a socket left by a killed daemon only while holding that lock.

```sh
paredros --config /absolute/config.json serve
paredros --config /absolute/config.json status
paredros --config /absolute/config.json monitor add --wording 'Report new commits.'
paredros --config /absolute/config.json messages OBLIGATION_ID
paredros --config /absolute/config.json ask 'What are you watching?'
paredros --config /absolute/config.json monitor pause OBLIGATION_ID
```

`--help` lists the typed commands. `stdio` accepts one JSON request per line over
the same authenticated local socket. Mutations accept `--operation ID` anywhere
on the command line; reuse an ID only for the same request. The daemon first
looks the ID up: a recorded operation returns its original disposition (or
`OperationConflict` for different bytes), and only an unrecorded one is validated
and admitted. A new ID is printable ASCII without `:`, which is reserved for
operations the daemon derives itself; a new ID containing it is refused with
`ReservedOperationId`. The directive the daemon derives itself (`transfer`) is
refused from callers with `SystemDirective`. An admission response means the
operation is durable. It does not mean that a step has folded it or published a
resulting message yet.

Every specification a head can hold passes one bound check, so the schedule,
backoff, pacing and byte arithmetic of every step is total. A monitor interval
(`--interval-ms`, an amendment, or a confirmed proposal) must be between 1 ms and
366 days (31622400000 ms); a longer one is refused with `IntervalTooLong`. The
policies are bounded as follows, and a value outside them is refused with
`PolicyOutOfBounds`:

| Policy | Bound |
|---|---|
| `notification_interval_ms`, `clock_regression_tolerance_ms` | 0 to 31622400000 |
| `phase_attempts` | 1 to 20 |
| `method_faults` | 1 to 1000 |
| `render_input_bytes` | 1024 to 1048576 |
| `context_bytes` | 1024 to 253952 |

The same table bounds the operator wording: 256 bytes of fixed render prelude plus
the wording and the repository ref must fit in half of the render limit (the
smaller of `render_input_bytes` and `context_bytes`), so every render has room
for commit records. A longer wording is refused with `WordingTooLong`.

The check runs when a monitor is added, when an amendment folds (an out-of-bound
amendment is rejected with the reason `invalid_interval`, `invalid_wording` or
`invalid_policy_NAME` and the head keeps its specification), when a bundle is
imported, and when the configuration loads. A configuration whose `interval_ms`
exceeds the bound fails to load with `IntervalMsExceedsMaximum`; one with an
out-of-bound policy fails with `PolicyOutOfBounds`. An amendment that changes the
interval moves a check that is not yet due to the first slot after the step's
clock observation on the original anchor; a check that is already due stays due,
and the slots it already missed are counted on the old interval.

`monitor amend ID REVISION` changes the interval (`--interval-ms N`), the wording
(`--wording TEXT`) or the policies (`--policies-json JSON`). The policies object
replaces the whole `Policies` value, so it names every policy. An amendment that
moves the monitored repository closes a pending source question, because its
condition no longer applies; any other amendment leaves the question open and
answerable.

Every identifier, digest and cursor in a reply uses the form its command accepts,
and that is the only spelling accepted: task IDs and digests are lowercase hex,
proposal identities are `REQUEST_DIGEST:ATTEMPT:ORDINAL`, and numbers are decimal
digits without a sign, separators or leading zeros. Copy `data.next` from
`status` into `status --after` until it is null; it is null as soon as no later
obligation exists.

`monitor check ID` records a requested check; its disposition is `requested`, not
`applied`, and `head.check_requested` stays true until a step performs the check.
That step is the first one whose provider deadline has passed: the request does
not wait for the monitor's own retry pacing or the next slot, but it does wait
for a `Retry-After` or rate-limit reset. A replaced check or an unattributed
failure ends the request. Once a `cancel` (or the system's `transfer`) is
admitted, every later directive for that obligation is refused with
`FinalObligation`, and the step that folds the final directive rejects any
directive after it with `obligation_final`, so every admitted directive has
exactly one disposition. A proposal confirmed again under a new operation ID
records that operation, so its repeat returns the same task and the ID cannot be
reused for another request.

Every per-item task of the daemon (an obligation's controls or step, a turn
recovery, a retained resume, the import of transferred turns) runs through one
boundary. A failure there is an observation, not a fence: the item's `fault`
(reason, time, consecutive failures, next retry), shown by `status` and `monitor
show`, records the latest failure; the item is retried with a backoff from one
second to one minute; the next success clears it. A fault never stops admitted
directives from being folded. A fold-only step that failed is replaced by another
fold-only step after a backoff derived from its attempt number (one minute,
doubling, at most an hour), or at once when a directive it did not fold has been
admitted since; a cancelled fold-only step is replaced at once. Only
namespace-wide failures (storage unavailable, a corrupt store, including any
record the index cannot rebuild, exhausted memory, or a wall clock outside years
1970 to 9999) stop `serve`. Faults are held by the running daemon.

A head records `clock_regressions` and the last regression it observed
(`last_clock_regression`). When a step observes the wall clock more than
`clock_regression_tolerance_ms` behind the previous head, every schedule instant
(`schedule.next_due_ms`, `schedule.source_not_before_ms`,
`schedule.render_not_before_ms`, and the provider deadline from `Retry-After` or a
rate-limit reset, `schedule.provider_not_before_ms`) keeps its remaining duration
from the corrected clock: the regression neither shortens nor extends it.
`skipped_slots` counts the anchored slots that passed without a check of their
own. The due slot moves only when a check completes, when a check is rejected for a
reason that waits for the next slot or exhausts its retries, or when an amendment
changes the interval, and each of those moves counts the anchored slots strictly
between the owed slot and the step's clock. A failed or replaced check, including
a replaced step that never reached the provider, keeps the owed slot and retries
with the phase backoff.

Under a pause, a step that already captured its provider response finishes from
that capture instead of being cancelled and repeated after resume; any step that
would need new provider I/O is replaced by a fold-only step.

`status` reports the running daemon's application version and executable SHA-256
under `data.daemon`. `data.namespace_bytes` sums the logical lengths of the live
namespace's database, identity, seal, and lock files, including the SQLite
journal and pending seal when present. It excludes backups and filesystem block
overhead. An active commit can change the file sizes between observations.

Monitor views include a bounded first page of pending directives, their total,
and `pending_directives_next`. Use `monitor directives ID --after ORDINAL
--limit N` to continue from that ordinal until the next cursor is null. Each page
describes the current retained state; controls may be folded between requests.
Individual admitted tasks remain available through `task show ID`.

The monitor's `backlog.untold_batches` counts observed batch sequences still owed
to the owner. `backlog.oldest` identifies the first outstanding sequence, its
retained task/result reference, acquisition time, and coverage. A positive count
with a null oldest record exposes missing evidence at that sequence.

Proposal confirmations use the exact `REQUEST_DIGEST:ATTEMPT:ORDINAL` identity.
The reply that `ask` prints, like `task show` of a turn, lists each of its
proposals under `data.confirmations` with that `identity` and the `command` that
confirms it:

```sh
paredros --config /absolute/config.json ask 'Pause the monitor.' --target OBLIGATION_ID
paredros --config /absolute/config.json proposal show REQUEST_DIGEST:ATTEMPT:ORDINAL
paredros --config /absolute/config.json proposal confirm REQUEST_DIGEST:ATTEMPT:ORDINAL
```

`proposal show` returns the complete retained proposal.

For provider access, explicitly select `mode: "live"`, grant the required
capabilities, and supply protected credential-file references. Configure the exact
GitHub repository and ref. Model access additionally requires the selected model
account, slug, effort, and absolute SIWC executable and authentication-directory
paths. Credentials stay in the launch environment; they are excluded from
application inputs and snapshots.

Once GitHub answers a read, the answer is a typed check result, never an unknown
attempt. A body over 2 MiB, a malformed, truncated, or interrupted response, an
echoed credential, or a `304` with no retained response is an incomplete check
with its reason. An oversized comparison page raises the gap question, because the
comparison cannot be acquired completely within that bound. A `Retry-After` or
rate-limit reset that is not a decimal count of seconds, such as an HTTP-date,
defers the next check by one hour from capture.

[Installation and service configuration](docs/setup.md) includes the live
configuration template, credential-file rules, and pending live qualification
scenario.

## Reading updates

Every output for the owner is a local message: the activation notice, commit
digests, and question prompts. A message is part of the head that decides it and
is published atomically with that head. The genesis head carries the activation
notice. The step that renders a digest carries it and advances the told frontier
to the digest's coverage in the same head, so the told frontier and the retained
digests that cover it are one fact. The step that raises a question carries its
prompt; an import carries the prompt of a question that is still pending.
Directive dispositions are reported by the CLI and in status, not as messages. A
paused, cancelled, or transferred obligation renders nothing more.

```sh
paredros --config /absolute/config.json messages OBLIGATION_ID
paredros --config /absolute/config.json messages OBLIGATION_ID --after ORDINAL --limit N
```

`messages` is read-only and returns a bounded page projected from the
obligation's selected head chain: one item per head that carries a message, in
head-sequence order. Heads are only ever appended to the chain, so an ordinal
cursor stays valid as messages are added; continue from the last ordinal until
the next cursor is null. Each item carries the head task and sequence, its
purpose, specification revision, covered frontiers for a digest, question
identity for a prompt, text, links, and choices. Every listed message is retained.

A pending question's choices include the command that answers it, `paredros
--config PATH question answer ID QUESTION_DIGEST CHOICE`. PATH is the absolute
path of the configuration the daemon was started with, so the command works from
any directory; `monitor show` also reports the open question. Once the question
closes, its prompt stays in the history without a command. `proposal show` and
`proposal confirm` handle proposals.

`ask` waits for and prints the conversation reply. A model reply is untrusted
text: like commit messages in a digest, every control, bidirectional-override
or other non-printable scalar in it, including line breaks, is replaced with a
space before the reply is recorded. Every turn ends with a reply:
the daemon resumes or replaces an unfinished attempt, retries a failed model call
once with the frozen context, and then completes a final authored failure reply.
`task show` of a turn follows its replacements and reports the recorded result
and task status; it does not predict later daemon decisions. A proposal that can
no longer be confirmed is listed with `confirmable` false and no command. When the
reply is not recorded within the wait, `ask` prints the latest task view, says the
reply is still pending, and exits 75; read it later with `task show`.

## Upgrading a namespace

`namespace check` reads a namespace created by an earlier build without writing
to it. `serve` continues it and writes: steps and conversation turns pinned to an
earlier program, profile, or runtime are superseded by replacements under this
build (the old step or turn is cancelled and a new one runs). To keep the earlier
state as an archive, take a snapshot export with the earlier build before serving
the namespace with this one.

## Backup and handoff

`namespace check` audits compatibility without opening the namespace for normal
execution. An incompatible build must use a supported continuity bundle exported
by the original build.

```sh
paredros --config /absolute/config.json transfer export backup.paredros --snapshot
paredros --config /absolute/config.json transfer export handoff.paredros
paredros --config /new/config.json transfer import /backup/handoff.paredros
```

Exports write only into the configured protected `backup_directory`. Snapshot
export captures an immutable cut while the original responsibility continues.
Transfer export durably marks the source namespace as transferred, folds a
`transfer` directive into a final `transferred` head for every obligation, and
dispatches no further work there. A bundle carries the live
application closure and the imported members it still depends on, once; it never
contains an earlier bundle, so repeated snapshots and transfer chains do not grow
with prior cuts. Export refuses a namespace whose own import is incomplete, and
refuses a filename that already exists before it takes a cut or fences the source;
existing files are never overwritten. While an admitted `monitor add` has not run,
snapshot export refuses with `ContinuityGenesisPending` and transfer export keeps
finalizing. A `monitor add` this build can never run (its task is blocked, or
pinned to another program, profile, or runtime) is carried by both snapshot and
transfer bundles as a pending monitor: its admitted request travels as a member,
and import admits it as a fresh monitor in the destination with the same lineage
and a head at the import clock. Transfer finalization waits for an admitted
`cancel` to fold rather than adding a `transfer` behind it. Every reference a
carried record holds is recorded against the bundle member it names, so a bundle
re-exported through any number of namespaces still resolves its methods,
reports and batches.

Each snapshot export run takes a new cut, except that a run for a NAME whose cut
is still pending resumes that cut. A namespace has one transfer: after the first
transfer export fences it, any later transfer export resumes that transfer and
writes its committed cut under the requested NAME. Every export response reports
`data.operation`, the operation that owns the cut. When a command exits 75 before
the file is written, it prints that operation; rerun the same export command with
`--operation OPERATION` to finish writing exactly that cut.

Export and import check that the bundle is closed before reporting success or
admitting anything: every head, control and turn reference to a batch or method
report must name exactly one member of that kind listed in its dependencies.
Otherwise the bundle is refused (`MissingContinuityReference`,
`AmbiguousContinuityReference` or `UnlistedContinuityReference`). Validation
indexes members by digest and runs in time linear in the bundle size. An
exported method report carries the known and possible charges recorded for its
experiment.

Import requires a fresh target namespace and matching configured resource
bindings, checked on every import command. The first command admits the bundle's
manifest; the daemon then materializes its members and lineages in bounded steps,
including across a restart, while other control ingress waits. The client sends
an absolute PATH byte for byte and joins a relative PATH onto its own working
directory with one separator, without collapsing `.` or `..`, so the daemon opens
the file the caller named. The daemon refuses a relative path (`RelativeTransferPath`). Repeat `transfer
import PATH` to observe progress; exit 75 means the daemon is still materializing.
The client hashes the file once per command and sends its SHA-256 with the path
(`--sha256 DIGEST` supplies it explicitly). The import operation is bound to its
path, size limit and that digest. The daemon looks the operation up first and
reports progress from stored state without reading the file; only a new import
reads it, and a file whose bytes no longer match the digest is refused with
`BundleDigestMismatch`. Resource bindings are checked against the stored manifest
on every import command, so a configured owner/name rename does not change the
operation. Reusing an import operation for a different file is refused as an
operation conflict.
Import preserves portable observations, pending controls, method source, and
known and unknown costs. Each imported obligation starts in its prior mode with no
hold: an active one resumes checks and renders once its imported pending controls
are admitted, and a pending question's prompt is published again by the import
genesis. Messages published before the cut stay in the source namespace, which
remains their archive. Imported conversation turns that never replied run as
soon as the import is materialized. While the import is still materializing,
`ask`, `monitor add`, directives, and exports are refused with
`ContinuityImportPending`; run `serve` to finish it. A `monitor add` repeated with
an operation that created an imported obligation returns that obligation, and the
same operation with a different request is refused as an operation conflict.

A filesystem rollback or snapshot restore needs no output hold: every message is
a local record that rolls back with its namespace. Running one lineage in only one
place remains the operator's responsibility.

## Service operation

[The systemd example](packaging/systemd/paredros.service) runs one daemon with a
45-second graceful worker drain and a 60-second service stop deadline. Adapt the
account, executable, and configuration paths. SIGTERM stops admission, joins or
terminates the current worker under the native owner, and leaves unfinished work
for the next `serve` to resume or replace. Namespace locking permits one local owner; it cannot fence
a copied namespace on another machine.

Snapshots contain source and conversation data. Keep the original namespace as
the historical archive; continuity files preserve the live application closure,
not an unlimited native execution archive.
