# PAREDROS

PAREDROS is a personal assistant built as a Zig application on Protean. It watches
a configured GitHub branch, retains acquired evidence, prepares commit digests,
and delivers them to one configured owner's Slack DM. Conversation, local control,
recovery, and retained method experiments use the same durable task history.

The application is under qualification. Live Slack installation and paid model
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

Run `zig build check` after editing GitHub or Slack protocol handling. It exercises
normalization, evidence digests, pagination, Slack delivery classification, and
other provider assertions. The check compiles a small host test executable and
executes it on each invocation. For a change to native GitHub capture or
recovery, add the real parked-page, reopen, and resume check.

```sh
zig build check
zig build check -Dcheck-recovery=true
```

Run `zig build qualify` with Zig 0.17.1, Node, and uv installed. It runs the
essential set within one 600-second budget measured from the `zig build`
invocation: TigerStyle over every tracked Zig file, the 108 source contracts, the
emitted-application check, the native `providers` owner group, the installed
product's smoke checks, twelve process-death cases, and historical namespace
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
controller uses local fixtures, kills the process at named admission, dispatch, or
capture boundaries, and checks retained state and acquisition counts in a fresh
process.

CI runs TigerStyle and three lanes on GitHub-hosted Ubuntu x86-64: source with the
emitted-application check, providers, and product. Each lane runs
`zig build qualify -- --group` and the complete workflow must finish within 600
seconds. Its product smoke passes `--essential`, omitting the licenses, version
and offline ask probes, which cost about 75 seconds on the direct backend; the
macOS smoke keeps them. The process-death cases need about nine minutes there,
so they run in local and fallback qualification with historical reopen and
import, which need local fixtures. When none of a hosted run's jobs start, the
fallback workflow dispatches full macOS qualification on the Mac's self-hosted runner as a
separate `macOS fallback` check; it never replaces the hosted result.

PAREDROS pins Protean by commit and package hash in `build.zig.zon`. It uses
[the native embedding and recovery changes](https://github.com/tkersey/protean/pull/74),
[the authenticated Kosmos borrowing update](https://github.com/tkersey/protean/pull/75)
and [direct Linux x86-64 builds with bundled Clang](https://github.com/tkersey/protean/pull/76).
All three upstream changes completed their required qualification, serial reviews,
and landing. Application qualification and reviews must cover this selected pin;
upstream verification alone does not qualify PAREDROS. Live-provider qualification
remains deferred.

By owner decision this release omits three specified behaviors: Slack and GitHub
transport health in `status`; the single announcement for a reference that returns
`404` on consecutive checks (A65), whose head field would make existing namespaces
unreadable; and the visible storage hold for exhausted storage. When SQLite reports
a full database, Protean fences the store (`StorageUnavailable`); the `storage`
delivery-hold variant stays reserved in the schema but is never produced.

[Offline measurements](docs/measurements.md) document task storage, startup,
empty-check costs, reproduction commands, and the current performance limits.

## Run and control

Start with [the offline configuration example](docs/config.example.json), changing
the UID and absolute paths to match the account running the daemon. Create the
namespace parent, control-socket parent, and backup directory with owner-only
permissions. Offline mode reads no credentials and grants no provider access.

```sh
paredros --config /absolute/config.json serve
paredros --config /absolute/config.json status
paredros --config /absolute/config.json monitor add --wording 'Report new commits.'
paredros --config /absolute/config.json ask 'What are you watching?'
paredros --config /absolute/config.json monitor pause OBLIGATION_ID
```

`--help` lists the typed commands. `stdio` accepts one JSON request per line over
the same authenticated local socket. Mutations accept `--operation ID`; reuse an
ID only for the same request. An admission response means the operation is
durable. It does not mean a remote message was delivered.

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

Monitor views report reconciliation as `pending`, `qualified`, or `degraded`,
with retained readback references in `reconciliation_evidence`. A successful
readback does not hide a failed audit whose order cannot be established. These
observations never clear a digest or recovery hold.

`recovery candidates [AFTER LIMIT]` pages authenticated same-lineage Slack markers
from retained history captures, including markers whose delivery intent is absent
from the restored state. Results retain their source namespace, task, and capture
references and identify incomplete scans. New scans use a moving window without
a local-clock upper bound and remain inconclusive when traversal ends. Candidates
require owner disposition; they do not advance observed or told progress.

Proposal confirmations use the exact `REQUEST_DIGEST:ATTEMPT:ORDINAL` identity.
`proposal show` returns the complete retained proposal. Slack offers a button only
when the complete description fits its bounded presentation.

For provider access, explicitly select `mode: "live"`, grant the required
capabilities, and supply protected credential-file references. Configure exact
GitHub repository/ref and Slack account/app/workspace/operator/DM bindings. Model
access additionally requires the selected model account, slug, effort, and
absolute SIWC executable and authentication-directory paths. Credentials stay in
the launch environment; they are excluded from application inputs and snapshots.

[Installation and service configuration](docs/setup.md) includes the Slack app
manifest, live configuration template, credential-file rules, and pending live
qualification scenario.

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
disposition, and keeps source output disabled. Repeating the same transfer export
or import command uses the same default operation identity, including after a
client restart. Each snapshot export run takes a new cut. Responses also expose
the operation identity, and an explicit `--operation` overrides it. Export refuses
a filename that already exists before it takes a cut or fences the source; existing
files are never overwritten.

Import requires a fresh target namespace and matching configured resource
bindings. It preserves portable observations, pending controls, method source,
and unresolved delivery evidence. Imported output remains held. Establish that
the original source cannot run again, then declare exclusive ownership when
releasing: run `recovery begin`, take TASK and DIGEST from `recovery status`, and
run `recovery release TASK DIGEST --exclusive-owner`.

After a known filesystem rollback, start with `serve --recover`. Inspect
`recovery status`, perform read-only `delivery audit KEY_JSON` operations, and
make explicit dispositions for uncertain outputs. To release a recovery boundary:

```sh
paredros --config /absolute/config.json recovery release TASK DIGEST --exclusive-owner
```

The task and digest come from `recovery status`. Release checks current resource
bindings and preserves individual uncertainty holds. It cannot reopen a namespace
fenced for transfer. A negative Slack history scan never proves that a prior write
was not sent. A rollback that the operator does not identify cannot be detected
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
