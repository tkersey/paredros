# Offline measurements

These measurements use synthetic provider responses and real native task storage.
They do not qualify GitHub service latency, paid inference, or deployment.
The implementation and final dependency selection remain under qualification.

## Maintained driver index, November 24

Until this change the driver rebuilt its whole index from every retained task each
time it needed one: once per daemon scheduling stage, once per gated dispatch and
once per control request. It now builds the index once when `serve` attaches,
using the same full rebuild, and afterwards maintains it in memory. Each
admission, cancellation or resume the driver performs notes its task; each later
use reads only those tasks and the tasks that are not yet terminal and disposed,
reloads a task only when its native revision moved, and recomputes the derived
obligation state in memory only when a record's input or result changes or a
progressed task is referenced by a validation. Views are snapshots: an update made
while a caller holds a view copies before it writes. Test builds, and `serve`
under `PAREDROS_VERIFY_INDEX=1`, compare every view with a fresh rebuild.

### Environment and method

Both executables used Protean `798cd57`, Zig 0.17.1, LLVM and safe optimization
on an Apple M2 Pro with 32 GiB RAM and macOS 27.3. Two other agents compiled on
the same machine throughout; each row records the one-minute load average when
its run finished. The baseline scale executable was built from `49e06e7` (the
pre-change `54ea153` plus the daemon-loop measurement), SHA-256
`d12558cd0c284bad4fa46df6763185970519412163fa650e3ce41ff2415581d2`; the
candidate from `48728a0`, SHA-256
`02d9bbf32cc6b9aaeecf23a04f898e5cf8b8b5a9fede6ae53906e982fb5e2b4c`. Later
commits change only the verification-only comparison, the measurement controller,
tests and documentation.

The daemon-loop workload seeds a history before the measured monitor: one genesis,
one cancel directive folded by one step, and pause directives on that cancelled
obligation, so every history task is terminal and never schedules work. The
monitor genesis follows. The measurement then constructs the real `Daemon` with a
control socket and drives `poll` until the check's step task is terminal, summing
the owner time spent inside `poll`. The GitHub adapter answers from memory, so no
network latency is included. One unscored check establishes the cursor; the
reported checks follow it; 24 idle polls then run with no check due. The
candidate also counts tasks probed, tasks reloaded and derivations.

```sh
zig build build-scale-tests -Dscale-tests=true -Doptimize=safe
uv run --no-project python tests/measure.py zig-out/test-tools/paredros-scale /absolute/new-directory --mode daemon --history 100
PAREDROS_SCALE_PATH=/absolute/fixture/state PAREDROS_SCALE_MODE=empty PAREDROS_EMPTY_PHASE=seed PAREDROS_EMPTY_HISTORY=10000 zig-out/test-tools/paredros-scale
uv run --no-project python tests/measure.py zig-out/test-tools/paredros-scale /absolute/new-directory --mode daemon --fixture /absolute/fixture --history 10000 --samples 6
```

A namespace is bound to its directory, so a seeded fixture cannot be copied; the
daemon mode consumes it in place. The baseline and candidate 10,000-task runs
therefore used two fixtures seeded identically by the baseline executable.

### Results

| Measurement | History | Baseline | Candidate |
|---|---:|---:|---:|
| Owner time per empty check, median | 100 | 5.036 s; 4.749 s | 1.697 s; 1.689 s |
| Owner time per empty check, sample p95 | 100 | 6.075 s; 5.982 s | 2.207 s; 1.700 s |
| Owner time per empty check, median | 10,000 | 156.075 s | 1.686 s |
| Owner time per empty check, sample p95 or maximum | 10,000 | 159.249 s (maximum) | 1.774 s |
| Idle poll owner time, median | 100 | 51.030 ms; 51.681 ms | 0.6 µs; 0.7 µs |
| Idle poll owner time, median | 10,000 | 1.791 s | 0.9 µs |
| Index build when the daemon attaches | 100 | 20.4 ms; 16.0 ms | 18.6 ms; 17.6 ms |
| Index build when the daemon attaches | 10,000 | 1.654 s | 1.837 s |
| Daemon polls per empty check, median | both | 84 | 84 |
| Database growth per empty check, median | both | 108–116 KiB | 110 KiB |
| Tasks probed, reloaded, derivations per check | both | not counted | 81, 18, 2 |
| Tasks probed or reloaded per idle poll | both | every task, every poll | 0 |

The 100-task rows are two alternating runs of each executable (baseline, candidate,
baseline, candidate) with 30 measured checks each; load averages were 10.2, 8.8,
9.0 and 8.5. The 10,000-task baseline measured five checks after its unscored
baseline, because each took about 2.6 minutes; the candidate measured 30. Their load
averages were 10.6 and 7.2. Each p95 is the nearest-rank statistic of its samples,
not a service tail estimate. Five baseline samples give no meaningful p95, so the
table reports their maximum.

Every daemon poll runs one scheduling stage; before this change each stage and
each gated dispatch rebuilt the index, so an empty check, which spans 84 polls,
paid about 84 rebuilds. With the maintained index a poll that finds nothing to do
reads no task, and a check reads only its own live step: it probes that step 81
times, reloads it 18 times as its native revision advances, and recomputes the
derived obligation state twice (when the step is admitted and when its result is
published). These counts are identical at 100 and 10,000 history tasks. The
remaining 1.7 seconds per check is the native interpreter pumping the authored
step, which the November 17 profile already identified; this change does not
reach the 250 ms target. Database growth is unchanged, as expected.

Attaching now also asks the native owner, for each terminal task, whether its
associated work is disposed, so a task that may still change stays watched. That
and the first derivation add roughly 0.2 seconds to the 10,000-task build in this
noisy sample; startup remains a full rebuild by design.

### First status after startup

Each product executable served its own offline product namespace of one genesis
and 9,999 pending pause directives, seeded by the baseline scale executable with
`PAREDROS_SCALE_CONFIG` and `PAREDROS_SCALE_RUNTIME` set to that executable's
configuration and SHA-256. The baseline product was built from `49e06e7`, SHA-256
`5e4d5dc0f974a2a1d6717e0b6385a3524cf4967807ff4c173ca379b87039a48d`; the
candidate from `8e0f04c`, SHA-256
`29569a299e25ddc6a822376e7a4836f7d602fc6e9467411b80565cd6daa0e679`. Each fixture
was served twice in alternating order; the second launch reopened the namespace
the first left behind.

```sh
uv run --no-project python tests/measure.py /absolute/paredros /absolute/new-directory --mode status --fixture /absolute/fixture
```

| Launch | Executable | Socket | First status | First status from launch | Second status |
|---|---|---:|---:|---:|---:|
| First | Baseline | 3.463 s | 1.725 s | 5.188 s | 1.726 s |
| First | Candidate | 2.949 s | 1.824 s | 4.773 s | 0.025 s |
| Second | Baseline | 2.813 s | 1.621 s | 4.434 s | 1.641 s |
| Second | Candidate | 2.791 s | 1.805 s | 4.596 s | 0.026 s |

Load averages were 11.6, 11.1, 10.9 and 10.5. The control socket exists before the
daemon attaches, so the first status waits for the startup rebuild in both
executables and is answered from the index that rebuild produced; it is not
faster. Every later status in the baseline rebuilt the index again, while the
candidate answers from the maintained index.

### Not measured

A 100,000-task history was not seeded for this comparison. Seeding takes about an
hour and a half on this machine, and one baseline empty check would take roughly
84 rebuilds of about 17 seconds each. The candidate's per-poll and per-check task
reads do not depend on the history size by construction and by the test below;
its startup at 100,000 tasks remains one full rebuild, measured above at about 17
seconds.

### Regression checks

`native daemon idle polls read a bounded number of tasks regardless of namespace
size` drives the real daemon over histories of 1 and 16 folded directives and
requires equal probe counts, no reload and no derivation across 12 idle polls.
`native driver index matches rebuild across admissions results supersession
restart` and every other test with an attached driver compare each view with a
fresh rebuild; `native driver verification rejects a namespace change that
bypasses the index` shows that comparison fails when a task is admitted behind
the driver. `native mutations of the task service flow through the driver`
rejects any native source that submits, cancels or resumes a task, or admits
through the raw service, outside the driver.

## Threaded LLVM build on Apple Silicon, November 17

PAREDROS `48a838c` used Protean `787e3ae` and Zig 0.17.1 with LLVM,
safe optimization, and multithreading on an Apple M2 Pro with 32 GiB RAM
and macOS 27.3. The scale executable had SHA-256
`59af2ddaefacf5a95e0134ba6d504f309b32c6a906283111e273ff0983e71a02`.
Other qualification work ran on the same host.

| Terminal tasks | Namespace open | Index rebuild | Namespace bytes | Pause directive median | Pause directive p95 |
|---:|---:|---:|---:|---:|---:|
| 100 | 59.53 ms | 15.32 ms | 843,920 | 59.11 ms | 59.86 ms |
| 10,000 | 1.208 s | 1.571 s | 65,073,296 | 59.08 ms | 60.84 ms |
| 100,000 | 14.243 s | 16.884 s | 650,330,256 | 59.76 ms | 63.23 ms |

Each history contains one genesis task and one pause directive for each remaining
task. The timing columns for opening and rebuilding measure those operations
individually. Across all 99,999 directives, owner time ranged from 56.63 to
256.41 ms, with a nearest-rank p99 of 67.19 ms. Each table row uses all
directives through that history size and nearest-rank p95.

The 100,000-task namespace retained 1,200,004 objects, 1,100,001 dependencies,
300,000 events, and 100,000 each of tasks, operation receipts, records and local
admissions. From 10,000 to 100,000 tasks, the namespace grew by an average of
6,503 bytes per additional directive.

A separate namespace used the product's offline launch configuration and contained
10,000 terminal tasks at launch. The shipped-form executable, SHA-256
`67ce97e291d4a3333c6019ff1ec51de41cdbfa80c0c2189caaa9ae3bf181f25c`,
created its control socket at 3.925 s and returned its first successful status at
8.651 s after launch. That response reported 9,999 pending directives, returned
the first 16 with a continuation cursor, and the daemon then shut down cleanly.
This run met the initial 10-second startup target.

The same executable also started against a separate product-configured history
of 100,000 terminal tasks. The control socket appeared at 44.862 s. An ordinary
`status` sent as soon as the socket appeared exhausted its 30-second client
deadline and exited with code 74 at 74.867 s after launch. The daemon exited
cleanly at 94.383 s following SIGTERM. Sampled daemon RSS peaked at 16.22 GiB.
This run therefore provides no successful first-status latency at 100,000 tasks.
Before launch, the measurement tool independently counted 100,000 task rows and
one obligation, and measured 13.976 s to open the namespace and 16.571 s to
rebuild the application index.

An index that reads one task at a time rebuilt the same sealed scale history in
16.462 s, compared with 17.604 s in a paired baseline run. Peak resident memory
for the measurement process fell from 8.07 GiB to 1.63 GiB. Both runs returned
one obligation. The namespace identity, seal and database hashes matched before
and after the measurement.

On the separate product-configured 100,000-task history, a candidate containing
that index and one fewer offline preflight created its socket at 27.989 s. The
first ordinary status request still timed out at 57.996 s from launch. The
daemon exited cleanly at 74.947 s, with a sampled peak of 5.97 GiB. Its
namespace identity, seal and database hashes also matched after shutdown. This
macOS ARM64 LLVM executable used the Protean candidate `3118918` and had SHA-256
`8cf1d14473085a8b774eb836715d9a7168fd35adaaa4a94db7fd2b31b2801fe0`.

A later build served the queued startup request using the index it had just
validated. The 11,881-byte response previously stalled after the first 8,192
bytes. Giving the accepted socket room for the existing per-poll write budget
allowed the whole response through. Socket creation took 29.751 s. The first
ordinary status arrived at 45.855 s after launch, 16.104 s after socket creation.
It reported 99,999 pending directives and returned 16 with continuation cursor
16. A second ordinary status timed out after 30.007 s. The daemon shut down
cleanly and the three store fingerprints matched. The executable SHA-256 was
`ed0ce49b90047b6f55cef39e651480c466cbfd046a90d5f8c4b7b38591ce2a8e`.

The next macOS ARM64 build also served a queued read when the scheduler finished
rebuilding the index. On the same 100,000-task history, the control socket appeared
30.322 s after launch. The first status took 16.762 s from socket creation
(47.084 s from launch), and the second took 17.657 s. Each returned 16 of 99,999
pending directives with continuation cursor 16. The daemon shut down cleanly
and the namespace identity, seal and database hashes matched their pre-launch
values. Sampled daemon RSS peaked at 2.94 GiB. This LLVM build used Protean
`3118918` and had SHA-256
`352691af37ba9378f6938cb9263b9e0867dddd336ec4ce900834236425b56d7a`.

The 30 empty checks after the baseline took a median 1.760 s and p95 1.828 s
of owner time. Database growth had a median of 128 KiB and p95 of 152 KiB.
Both medians exceeded the initial targets of 250 ms and 64 KiB.

## Zig C backend and GNU GCC on Apple Silicon, November 17

On an Apple M2 Pro with 32 GiB RAM and macOS 27.3, Zig 0.17.1 emitted C with
runtime safety enabled. GNU GCC 16.2 compiled it at `-O2`. The scale executable
used PAREDROS source `68684d9` and the Protean build helper at `caee1bd`.
Its SHA-256 was `fda79efd213b0b363fa85ba7ed3dff4404a389bc48e6ce9d3efaa3f28e7bb6eb`.
Other qualification work ran on the same machine.

| Workload | Samples | Median | p95 (nearest rank) |
|---|---:|---:|---:|
| Owner time per pause directive through 100 terminal tasks | 99 | 92.74 ms | 94.44 ms |
| Owner time per pause directive through 10,000 terminal tasks | 9,999 | 95.04 ms | 102.08 ms |
| Owner time per empty check after the baseline | 30 | 3.002 s | 3.234 s |
| Database growth per empty check after the baseline | 30 | 132 KiB | 148 KiB |

At 100 terminal tasks, the native namespace opened in 131.34 ms, and the
application index rebuilt in 22.13 ms. The namespace occupied 852,112 bytes.
At 10,000 terminal tasks, native opening took 1.719 s, index rebuild took
2.258 s, and the namespace occupied 65,237,136 bytes. These timings cover
namespace opening and index construction. Full daemon startup also performs
preflight checks and constructs its dispatch gate.

The 30 empty checks exceeded both initial targets of 250 ms and 64 KiB. With
genesis and the baseline check included, their namespace contained 32 tasks,
3,219 objects, 4,880 dependencies, 404 records and 493 events.

## November 15–16 environment and reproduction

The November 15–16, 2026 observations used an Apple M2 Pro, 32 GiB RAM,
macOS 27.3, Zig 0.17.1, and `-Doptimize=safe`. Scale and empty-check measurements
used Protean `9fff51546d8bf7db088db69de6e72b9807471a85` with its admitted
Horos/Kosmos dependencies. Other compilation was running during some samples;
these are development-machine measurements, not isolated hardware benchmarks.

```sh
zig build setup
zig build build-scale-tests -Dscale-tests=true -Doptimize=safe
uv run --no-project python tests/measure.py zig-out/test-tools/paredros-scale /absolute/new-scale-directory
uv run --no-project python tests/measure.py zig-out/test-tools/paredros-scale /absolute/new-empty-directory --mode empty
```

Each output directory must be new. The controller retains the binary digest,
platform, per-task samples, per-process stderr, and progressively updated report.
It seeds through public native admission and execution. SQLite is opened only
read-only after the fixture process exits to count retained rows. Each fixture
process has a 600-second limit; creating 100,000 real tasks requires multiple
batches and considerably more total time. Do not replace the binary during a run.

## Completed pause directives

The scale workload contains one genesis followed by ordered, completed pause
directive tasks. Its single obligation retains all directive predecessors. It
does not represent a mixed workload of conversations, large captures, and methods.
Startup includes native namespace opening and retained-state validation; index
rebuild is timed separately.

| Terminal tasks | Startup | Index rebuild | Namespace bytes |
|---:|---:|---:|---:|
| 100 | 59.19 ms | 15.48 ms | Not recorded in this initial sample |
| 10,000 | 1.281 s | 1.635 s | 65,110,160 |
| 100,000 | 13.614 s | 18.122 s | 650,694,800 |

The 10,000-task native-owner opening is below ten seconds. This excludes the
daemon's additional read-only preflight checks and dispatch-gate construction;
the complete daemon startup target is not established by this measurement. That namespace
contained 120,004 objects, 110,001 dependencies, 10,000 tasks, 10,000 operation
receipts, 10,000 records, 30,000 events, and 10,000 local admissions. A separate
100-task reproduction measured 99 directives at 59.16 ms median and 60.73 ms
maximum. Between 10 and 100 tasks, each directive added exactly 12 object rows,
11 dependency rows, one task, one operation receipt, one record, three events,
and one local admission. File allocation is page-granular. At 100,000 tasks the
namespace contained 1,200,004 objects, 1,100,001 dependencies, 300,000 events,
and 100,000 each of tasks, operation receipts, records, and local admissions.
The complete native measurement process, including both opening and index work,
took 45.56 seconds. These are single opening/index observations at each size.

The 99,900 directive samples for ordinals 100 through 99,999 had a 60.74 ms
median, 64.57 ms sample p95, 76.10 ms sample p99, and 423.86 ms maximum; the
minimum was 56.76 ms. The initial 99 directives are outside this distribution.
Compilation on the same machine contributes to the observed spread.

## Empty branch checks

The fixture grants only GitHub reads. It acquires typed HTTP captures through a
local adapter and uses the production request preparation, interpretation,
projection, authored check, and native session. Repository identity and branch
tip remain unchanged. One unscored baseline establishes the cursor, followed by
30 empty checks. The owner interval includes admission, processing, capture, and
terminal publication; external network latency is absent. Index verification
after completion is outside the timed interval.

| Measurement | Minimum | Median | Sample p95 | Maximum |
|---|---:|---:|---:|---:|
| Owner elapsed time | 1.660 s | 1.753 s | 1.839 s | 1.851 s |
| Database growth | 116 KiB | 128 KiB | 148 KiB | 160 KiB |

Both initial targets—250 ms and 64 KiB per empty check—are missed. The p95 is the
nearest-rank statistic of 30 samples, not a service latency guarantee. Database
growth totaled 4,005,888 bytes across the 30 measured checks. The final namespace
contained 32 tasks, 93 captures, 93 attempts, 93 occurrences, 93 execution-route
records, and 32 root-operation records. Objects occupied 2,632,318 payload bytes
across 3,219 rows, including the one retained 140,680-byte application image;
database pages, indexes, references, and events account for additional storage.

A separate one-baseline namespace establishes the row-growth denominator.
Subtracting it from the 31-check namespace gives, per measured empty check,
104 objects, 158 dependencies, 13 records, 16 events, one task, one operation
receipt, and one local admission. These are average row increments for this
fixture; sharing and page allocation can differ with other inputs.

A three-second symbolized profile attributed 1,469 of 2,187 sampled main-thread
stacks to native driver pumping inside the authored interpreter. Index rebuilding
and SQLite were not the dominant sampled costs. This identifies a different
mechanism from the competing-task restore overhead below; it does not justify an
index cache as a remedy for the isolated empty-check result.

No captures, predecessor evidence, or safety checks were removed to meet a
target. The current design retains one bounded task per check. At the default
96 checks per day, extrapolating this small fixture gives about 168 seconds of
owner elapsed time and 12.2 MiB of database growth per day. This is a planning
estimate, not a long-running workload measurement; index growth and provider
latency add costs. Rollover remains explicit. A batching or runtime optimization
would need its own preservation argument and representative measurement.

## Competing task scheduling

A separate diagnostic admits a monitor, pauses it, and asks an offline question
about that monitor. The result is the same explicit no-model response in both
executables. The baseline took 69.15 seconds. A candidate that retains the
active evaluator for at most eight physical pump calls took 11.07 and 11.10
seconds in two unprofiled runs. This is a small-sample observation, not a tail
latency estimate. Protean candidate `df3f8c9ab496cb395b03730edc17fc39b9629b19`
passed its complete local qualification and native Linux CI. PAREDROS's 284 native
checks and 12 process-death cases passed against that candidate in a separate
consumer build. Those measurements retain that historical dependency identity.
The upstream corrections have since landed through Protean PRs #74 and #75 after
qualification and serial reviews. PAREDROS now selects landed Protean `787e3ae`.
The historical measurements below retain their recorded build identities and
do not certify the new dependency.

The baseline profile attributed most sampled owner work to retiring and restoring
the active evaluator between task turns. The candidate profile shifts most of
that work to actual interpreter execution. Each public pump still yields to the
host after one bounded native quantum; the dispatch gate and worker owner remain
in place. The comparison also includes the later Protean session launch-failure
repair, whose failure branch this workload did not exercise. It is not a measured
improvement to isolated empty-check cost or retained storage.

The reproducible product smoke adds 30 status probes while the same offline
question settles. Both executables pass all five smoke assertions, including
read-only namespace audit and restart with the same admitted monitor identity.

```sh
uv run --no-project python tests/product_smoke.py /absolute/paredros --report /absolute/report.json
```

| Actual daemon measurement | Baseline | Candidate |
|---|---:|---:|
| Empty namespace, launch to socket | 177.7 ms | 178.4 ms |
| Reopened smoke namespace, launch to socket | 239.2 ms | 176.2 ms |
| Offline question with status probes | 74.70 s | 9.93 s |
| Concurrent status median, 30 samples | 207.0 ms | 25.8 ms |
| Concurrent status sample p95 | 267.0 ms | 173.6 ms |
| Concurrent status maximum | 351.0 ms | 204.9 ms |
| One active offline monitor, sampled RSS | 60.36 MiB | 52.19 MiB |
| Highest sampled RSS during question | 171.70 MiB | 164.09 MiB |

These are one matched smoke run per executable on the development machine.
Socket creation precedes the first successful query and is not by itself a full
readiness measurement. RSS is periodically sampled, not a guaranteed peak.
The baseline artifact SHA-256 is
`b842957561c3e9e4b3eb7b7239b721905546d3b7503f7d9c8320a53b1a1aeee4`;
the candidate is
`ec4f769db416267aad2cae72ad8521cd6e25bf85175041c259a29ce7a7bb1789`.
Both use the same application source and workload. The baseline uses the older
Protean pin described above. No live model or provider latency is measured.

## Retained history and daemon responsiveness

A separate offline daemon namespace was populated with one genesis and 9,999
ordered pause directives through the native owner. The original product could
open it, but status failed with `Capacity` because it attempted to include every
pending directive in one bounded response. Monitor views now expose a first page,
the total pending count, and a continuation cursor. The paginated product returned
one status response, then its next request hit the unchanged 30-second client
timeout while the owner performed several complete scheduling passes.

The daemon now performs one scheduling stage per poll, servicing control requests
between stages. Each stage uses current native-owner state; no cached index or
second journal was introduced. Reopening that same retained namespace also exposed
an incompatible parked continuation from an older executable. The application now
uses the native owner's compatibility refusal to select its existing replacement
path. It retains the original attempt and pending controls.

The corrected executable answered all 12 consecutive status requests and stopped
cleanly. Socket creation took 4.676 seconds; launch through the first successful
status took 9.661 seconds. Individual response times ranged from 4.903 to 8.288
seconds. All responses exposed the 9,999 pending directives through an initial
16-item page and its cursor. Retained task count advanced from 10,002 to 10,003
when the replacement was admitted. This is one run on the preserved failure
namespace, not a sustained-load latency guarantee or proof that the backlog had
finished folding. The executable SHA-256 was
`3b32989524b669d5f2392e3a58d240f29d8dd0e7d4e4357a582d7b4e6009c20f`.

The largest child-process peak resident memory in that run was 2.72 GiB. Samples
taken between responses were much smaller, so those samples must not be reported
as the peak. Large-history reconstruction still has substantial transient memory
cost even though requests no longer hit the observed timeout.

For a separate one-monitor idle workload with an unchanged head, ten one-second
samples after staging scheduling showed 46.8–47.3 MiB resident memory. Cumulative
CPU advanced 0.41 seconds over roughly nine seconds, compared with 1.71 seconds
before staging on the same workload. These are short development-machine samples;
they do not establish long-running idle usage or large-history memory bounds.
