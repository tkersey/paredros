# Offline measurements

These measurements use synthetic provider responses and real native task storage.
They do not qualify Slack, GitHub service latency, paid inference, or deployment.
The implementation and final dependency selection remain under qualification.

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
