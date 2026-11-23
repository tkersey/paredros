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
product's smoke checks, ten process-death cases, and historical namespace
reopen and archive import. On macOS one build compiles every essential artifact
concurrently. The product and native tests embed the committed emitted application in
`app/emitted/`, so they compile alongside Protean's emitter instead of after it.
Qualification runs `check-emitted`, which requires those bytes to equal a fresh
emission from `app/`. After editing `app/`, run
`zig build update-emitted -Dnative=true -Doptimize=safe` and commit the result. On
x86-64 Linux under Rosetta, export `ZIG_DEBUG_CMD=1` before invoking Zig. Use
`zig build qualify -- --list` to inspect the groups. Each invocation executes the
tests and writes fresh timings, outcomes, and logs under `zig-out/qualification/`.
For groups and their prerequisites use `zig build qualify -- --group NAME[,NAME...]`.
This requires only the fixtures used by the selected groups.

The authority, transitions, rendering, continuity and methods owner groups, the
24-arm comparison and the 100,000-task daemon are diagnostics. They do not gate a
candidate, and their absence from a result is not a pass. Run them with
`--group`, for example `zig build qualify -- --group methods-campaign`.

Historical reopen and import use fixtures produced by the older application.
The scale check opens a product-configured namespace containing 100,000 real
tasks. Keep dedicated offline fixtures under
`.zig-cache/qualification-fixtures/{reopen,archive,100k}`, or set
`PAREDROS_HISTORY_REOPEN`, `PAREDROS_HISTORY_ARCHIVE`, and
`PAREDROS_HISTORY_100K` to their respective directories. If a selected check's
fixture is missing, qualification stops before running anything and reports
every check incomplete. To provision another machine, build
the legacy application at commit `77866577394711e6152a1e97fdecfeb0cfcd2f2c`
in a separate checkout. The following commands create a dedicated historical
namespace and snapshot with that binary and seed a separate scale namespace with
the installed product. Run these once per fixture, outside the timed checks.

```sh
uv run --no-project python tests/seed_history.py /path/to/legacy-checkout .zig-cache/qualification-fixtures/reopen
ln -s reopen .zig-cache/qualification-fixtures/archive
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
so they run in local and fallback qualification with historical reopen and
import, which need local fixtures. When none of a hosted run's jobs start, the
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

By owner decision this release ships without the specified Slack integration.
Outputs the specification sends to the owner's Slack DM are recorded as local
messages and read with `messages`; owner input arrives only through the local CLI
and control socket. There is no Slack ingress, button, history or lineage audit,
marker reconciliation, or recovery-candidate scan.
[The implementation specification](docs/implementation-spec.md) is left as
originally written. The release also omits three other specified behaviors:
GitHub transport health in `status`; the single announcement for a reference that
returns `404` on consecutive checks (A65), whose head field would make existing
namespaces unreadable; and the visible storage hold for exhausted storage. When SQLite reports
a full database, Protean fences the store (`StorageUnavailable`); the `storage`
delivery-hold variant stays reserved in the schema but is never produced.

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
the same authenticated local socket. Mutations accept `--operation ID`; reuse an
ID only for the same request. An admission response means the operation is
durable. It does not mean the resulting message has been recorded yet.

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
`proposal show` returns the complete retained proposal.

For provider access, explicitly select `mode: "live"`, grant the required
capabilities, and supply protected credential-file references. Configure the exact
GitHub repository and ref. Model access additionally requires the selected model
account, slug, effort, and absolute SIWC executable and authentication-directory
paths. Credentials stay in the launch environment; they are excluded from
application inputs and snapshots.

[Installation and service configuration](docs/setup.md) includes the live
configuration template, credential-file rules, and pending live qualification
scenario.

## Reading updates

Every output for the owner is a local message: the activation notice, commit
digests, questions, failure notices, and control notices. A message is recorded
when its `delivery` task completes. That task performs no external write; the next
step folds its confirmation once and advances the told frontier.

```sh
paredros --config /absolute/config.json messages OBLIGATION_ID
paredros --config /absolute/config.json messages OBLIGATION_ID --after ORDINAL --limit N
```

`messages` is read-only and returns a bounded page. It orders one obligation's
messages by producer head sequence, then purpose, then key, so an ordinal cursor
stays valid as messages are added; continue from the last ordinal until the next
cursor is null. Each item carries its task, purpose, key, issue, superseded key,
covered sequence range, text, links, and choices, with a state of `delivered`,
`pending`, `legacy_delivered`, `legacy_unsent`, or `legacy_possibly_sent`.

A question's choices include the command that answers it, `question answer ID
QUESTION_DIGEST CHOICE`; `monitor show` also reports the open question. `proposal
show` and `proposal confirm` handle proposals, and `ask` waits for and prints the
conversation reply. A held digest is inspected with `delivery show KEY_JSON` and
released with `delivery release ID KEY_JSON`.

## Upgrading a Slack-era namespace

A namespace created by an earlier build keeps its Slack identity. Keep its
configuration's `slack` section (`account`, `app`, `workspace`, `operator`,
`channel`, `bot_id`) unchanged: it is read only as the namespace's owner binding,
which fixes the tenant and the destination that retained tasks, imports, and
recovery release are checked against. Without it, or with any value changed,
existing tasks belong to a different owner and are refused. Remove
`grants.slack_history`, `grants.slack_write`, `slack_bot_credential_file`, and
`slack_app_credential_file`; a configuration that still sets them is refused with
`SlackRemoved`. A configuration without `slack` binds a new namespace to the local
owner.

Reopening an old namespace writes nothing by itself. Retained Slack deliveries,
button interactions, and audit records keep validating against their stored
digests and stay readable; audit and lineage-audit tasks are never dispatched
again. A commit digest that was never sent is reissued as a local message with the
next generation. A digest whose Slack write may have been sent is held as an
uncertain transmission; `delivery release` issues a local replacement that warns
the earlier copy may also have arrived. Activation notices, questions, control
notices, and conversation replies addressed to Slack stay as history, listed by
`messages` with a legacy state, and are not reissued. A Slack-origin conversation
turn whose reply was never delivered gets a local message. Importing a Slack-era
bundle requires the same `slack` section in the importing configuration; its
unresolved deliveries arrive held and are reissued locally after release.

## Recovery and handoff

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
Transfer export durably fences the source namespace, folds the transferred
disposition, and keeps source output disabled. A bundle carries the live
application closure and the imported members it still depends on, once; it never
contains an earlier bundle, so repeated snapshots and transfer chains do not grow
with prior cuts. Export refuses a namespace whose own import is incomplete, and
refuses a filename that already exists before it takes a cut or fences the source;
existing files are never overwritten.

Each snapshot export run takes a new cut, except that a run for a NAME whose cut
is still pending resumes that cut. A namespace has one transfer: after the first
transfer export fences it, any later transfer export resumes that transfer and
writes its committed cut under the requested NAME. Every export response reports
`data.operation`, the operation that owns the cut. When a command exits 75 before
the file is written, it prints that operation; rerun the same export command with
`--operation OPERATION` to finish writing exactly that cut.

Import requires a fresh target namespace and matching configured resource
bindings, checked on every import command. The first command admits the bundle's
manifest; the daemon then materializes its members and lineages in bounded steps,
including across a restart, while other control ingress waits. Repeat
`transfer import PATH` to observe progress; exit 75 means the daemon is still
materializing. Reusing an import operation for a different file is refused as an
operation conflict. Import preserves portable observations, pending controls,
method source, and unresolved delivery evidence. Imported output, including
imported conversation turns, remains held; `recovery status` reports `import_hold`.
While it is held, `ask`, `monitor add`, and monitor proposals are refused with
`ContinuityImportHeld`, and live-model experiments wait. Neither
`recovery begin` nor `serve --recover` opens a boundary before the import is
materialized (`ContinuityImportPending`); run `serve` to finish it. Establish
that the original source cannot run again, then declare exclusive ownership when
releasing: run `recovery begin`, take TASK and DIGEST from `recovery status`, and
run `recovery release TASK DIGEST --exclusive-owner`.

After a known filesystem rollback, start with `serve --recover`. Inspect
`recovery status` and `delivery show KEY_JSON`, and make explicit dispositions for
uncertain outputs with `delivery release`. `recovery status` prints the
current boundary as hex `data.recovery.task` and `data.recovery.digest`, which
`recovery release` accepts unchanged, with the size and SHA-256 of the
cumulative recovery cut rather than its entries. To release a recovery boundary:

```sh
paredros --config /absolute/config.json recovery release TASK DIGEST --exclusive-owner
```

The task and digest come from `recovery status`. Release checks current resource
bindings and preserves individual uncertainty holds. It cannot reopen a namespace
fenced for transfer. Local messages leave no external evidence, so an output held
after a rollback is resolved only by an explicit `delivery release`. A rollback that the operator does not identify cannot be detected
reliably from stale local state; there is no exactly-once promise across rollback.

## Service operation

[The systemd example](packaging/systemd/paredros.service) runs one daemon with a
45-second graceful worker drain and a 60-second service stop deadline. Adapt the
account, executable, and configuration paths. SIGTERM stops admission, joins or
terminates the current worker under the native owner, and leaves uncertain work
visible for recovery. Namespace locking permits one local owner; it cannot fence
a copied namespace on another machine.

Snapshots contain source and conversation data. Keep the original namespace as
the historical archive; continuity files preserve the live application closure,
not an unlimited native execution archive.
