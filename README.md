# PAREDROS

PAREDROS is a personal assistant built as a Zig application on Protean. It watches
a configured GitHub branch, retains acquired evidence, prepares commit digests,
and delivers them to one configured owner's Slack DM. Conversation, local control,
recovery, and retained method experiments use the same durable task history.

The application is under qualification. Live Slack installation and paid model
qualification have not been performed.

## Build

Use exact Zig 0.17.1. The native product targets `aarch64-macos` and
`x86_64-linux-musl`.

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

`describe-build` reports the embedded application/runtime/dependency identities
and the hash of the executable actually running. Keep that executable with its
namespace when retaining the original execution history.

## Offline checks

```sh
zig build test -Dnative=false -Doptimize=safe
zig build build-native-tests build-crash-tests -Dnative-tests=true -Dcrash-tests=true -Doptimize=safe
zig build test-native -Dnative-tests=true -Doptimize=safe
uv run --no-project python tests/process_crash.py zig-out/test-tools/paredros-crash-tests
uv run --no-project python tests/product_smoke.py zig-out/bin/paredros
```

Native tests compile into six groups and all groups run by default. The separate
build step permits reuse of completed compilation; it does not count as test
execution. `-Dnative-group=NAME` and `-Dtest-filter=TEXT` select diagnostics only.
The process-death controller uses local provider fixtures, kills the process at
named admission, dispatch, or capture boundaries, and checks retained state and
acquisition counts in a fresh process. It does not contact live providers.

The Linux workflow splits continuity and transitions with
`-Dnative-partition=first|second`; each named test runs in exactly one partition.
The unchanged import-only root runs in both partitions, giving 290 checks in CI
and 288 in the six unfiltered local groups. The product and crash fixture compile
separately, and every artifact executes in a fresh job. Each job retains its
ten-minute limit. Prepared compiler work is reused through the authenticated
current-run archive; build jobs do not save a redundant cache after uploading
their completed artifact. Source checks, five product smoke assertions, and twelve
process-death cases are additional. GitHub Actions qualification remains pending
for this draft.

This draft pins the Protean candidate `df3f8c9` used by the offline consumer
checks. The release dependency still awaits corrections, required serial reviews,
and landing of [Protean PR #74](https://github.com/tkersey/protean/pull/74).
Upstream corrections cover recovery dispatch metadata, task/attempt pagination,
and placement dispatch/recovery gating. Final dependency selection, packaged-pin qualification, Linux CI,
and application review remain pending. This draft is not a qualified release.

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

Monitor views include a bounded first page of pending directives, their total,
and `pending_directives_next`. Use `monitor directives ID --after ORDINAL
--limit N` to continue from that ordinal until the next cursor is null. Each page
describes the current retained state; controls may be folded between requests.
Individual admitted tasks remain available through `task show ID`.

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
disposition, and keeps source output disabled. Repeating the same transfer command
uses the same default operation identity, including after a client restart.
Responses also expose that identity. An explicit `--operation` overrides it.
Use a new snapshot filename for a new cut; existing files are never overwritten
with different content.

Import requires a fresh target namespace and matching configured resource
bindings. It preserves portable observations, pending controls, method source,
and unresolved delivery evidence. Imported output remains held. Establish that
the original source cannot run again before declaring exclusive ownership.

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
