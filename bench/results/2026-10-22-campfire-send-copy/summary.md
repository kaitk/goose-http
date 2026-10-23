# Emulated-ring send-copy experiment

Measured on 2026-10-22 PDT (2026-10-23 UTC), AMD Ryzen 9 9950X3D,
x86-64 Docker on WSL2 Linux 5.15.167.4, glibc 2.39. Native io_uring setup
returns EINVAL in the package counter container; the measured loop is the
readiness-based emulation. No native io_uring, macOS or Windows gain is claimed.

The proposal tries a synchronous send only for buffers of at least 16 KiB on
writable sockets without preceding queued sends. It owns any unsent tail before
returning, and reports completions in the usual `ur_wait` turn. The cutoff is a
candidate for this workload, not an established optimum.

## Plaintext cost and the size threshold

The initial all-size implementation regresses pipelined plaintext. Keeping small
sends queued brings user-mode CPU cost close to baseline, but a residual throughput
difference remains. This needs review before landing; the application gain alone
does not establish that the transport change benefits all workloads.

Builds use official Goose v2026.3, Clang 18.1.3, `LOOP=uring`, and upstream
`df12a627c9f4df51465f1ac7c324c17e86dc78b3`. The all-size candidate is `10123bb`;
the 16 KiB candidate is `a123284`. Each `bench/count.sh` sample sends ten million
`/plaintext` requests, checks all statuses as 2xx, and counts the server's
`instructions:u,cycles:u`. One worker runs on CPU 0; h2load has eight threads on
CPUs 4-15, 256 connections and 16 requests in flight per connection.

The all-size comparison uses three before/after pairs. The threshold comparison
uses three before/after pairs and three after/before pairs. Commands and exact
source revisions are in [session-steps.sh](session-steps.sh); those commands
reproduce the threshold comparison from a PR checkout using the existing harness.
The measured package binary hashes are in [binaries.txt](binaries.txt).
The harness requires perf, h2load and nc, with permission to use hardware counters.
Individual measurements, including every adverse sample, are in
[plaintext.tsv](plaintext.tsv).

| Experiment / metric | Before median (range) | Candidate median (range) |
|---|---:|---:|
| All-size instructions/request | 2,047.6 (2,047.5-2,047.6) | 2,040.1 (2,040.1-2,040.2) |
| All-size user cycles/request | 436.7 (432.3-437.7) | 560.5 (549.7-570.1) |
| All-size requests/second | 2,212,226 (2,129,599-2,515,325) | 1,649,091 (1,574,386-1,771,929) |
| 16 KiB instructions/request | 2,047.6 (2,047.5-2,047.6) | 2,048.0 (2,047.9-2,048.0) |
| 16 KiB user cycles/request | 435.25 (431.9-436.7) | 436.5 (434.0-438.9) |
| 16 KiB requests/second | 2,475,665 (2,269,966-2,523,131) | 2,265,172 (2,126,040-2,339,571) |

The threshold comparison adds about 0.02% user instructions and 0.29% user cycles,
while its throughput median falls 8.5%. Rates overlap, but that does not establish
equivalence. The counters exclude kernel execution and do not explain the whole
loopback throughput difference. The all-size throughput loss is 25.5%, with
non-overlapping ranges. Small responses must not use that all-size strategy.

All package timing runs started after three consecutive five-second quiet-host
samples. No Windows compiler jobs or processes averaging over 0.3 cores were
observed during those measurements. Builds and tests finished before timing.

## Current application evidence (16 KiB version)

The exact thresholded candidate was rechecked with the same five-pair method
described below, the same preserved baseline image, fresh fixture storage per
sample, and 30 million validated responses. Every response passed, with zero
errors. [campfire-threshold.tsv](campfire-threshold.tsv) retains all ten samples.

| Median metric | Before | 16 KiB candidate | Change |
|---|---:|---:|---:|
| User instructions/response | 7,825.7 | 7,808.5 | -0.2% |
| User cycles/response | 9,218.6 | 8,351.7 | -9.4% |
| Total server CPU microseconds/response | 8.454 | 8.115 | -4.0% |
| Valid responses/second | 213,817 | 230,004 | +7.6% |

User cycles fall in every pair: 11.2%, 5.0%, 16.5%, 14.1% and 1.4%.
Total CPU time improves in three of five pairs; throughput improves in four.
Before rates range from 205,543 to 236,734; after from 220,747 to 251,441.
The ranges overlap and one pair loses 2.8% throughput. This supports lower
user-mode cost on this workload, not a universal throughput improvement.

The measured application commit is `aea9508ac3f3eadd5925f22d64e712ff8fa3a757`,
pinning HTTP `df12a62` plus the functional patch through `a123284`. Its production
image passes the full native application tests, both HTTP backends, the unchanged
shared Chromium smoke suite, all 27 differential render cases against each current
Rust/Jai reference, and all 315 asset hash/MIME checks. Native checks include
rollback, concurrent acknowledged writes, cache invalidation/revocation, WAL restart,
200 KiB fragmented WebSocket fan-out and disconnect cleanup. No rendering or write
semantics are relaxed for timing.

The recheck runs around 23:20-23:25 PDT with no competing compiler jobs. There is
occasional desktop activity, and every sample is retained. The same generator
limits and unpublished-application reproduction limits below apply. Current
Rust/Jai throughput was not rerun for the thresholded candidate; earlier
cross-application numbers must not be attributed to this version.

```text
16-KiB application image: sha256:a1afe83bc1627fd6e218e84d8f81b023113ff601dcbb0a855415d97e7166a7d5
16-KiB application executable: 9c42349e82d4023b81345695abe62ca94b40995fd4588a4b319e9ce41ed259e7
functional patch SHA-256: 77a2998b4ade0ae9f185f0301e929ca8748121007c4bc998d7e31fa20fcc5ac5
```

## Original application evidence (all-size version)

These are supplemental measurements from an experimental Campfire application
whose source and images have not yet been published. Its build is not independently
reproducible from this HTTP PR alone. The individual numeric observations are
included in [campfire-all-size.tsv](campfire-all-size.tsv); credentials, environment
files and private local paths are omitted.

Both application images use four HTTP workers on CPUs `0,2,4,6`, a 2 GiB memory
limit, fresh native-Linux fixture storage and the unchanged shared
[Campfire verifier](https://github.com/basecamp/once-campfire-verification/tree/ec02debb3e44f40b8778a6a42db3c4515b2f9eaf).
The client uses CPUs `8,10,12,14`, 16 connections, gzip and the `room_show` contract.
The cached compressed room response is approximately 21 KiB. There are no live
WebSocket subscribers in the throughput workload. The compiler is Goose
`d9573d8139de395cd4549b876c176c25eb878fc1`, with Clang 18.1.3.

Each sample warms up for two seconds. Five pairs then alternate order, validating
exactly three million room reads per sample (30 million total). The measured batch
runs inside `perf stat -x, -e instructions:u,cycles:u,task-clock -p 1 -- sleep 25`,
with a one-second lead-in, using Linux tools 6.8.0-147. The load-generator arguments
are `http --gzip 1 --conc 16 --duration 30 --requests 3000000`, plus the disposable
server URL, cookie, room path and validator contract. Task-clock includes idle time
around the request batch. Every response passed its contract with zero errors.

| Median metric | Before | All-size candidate | Change |
|---|---:|---:|---:|
| User instructions/response | 7,826 | 7,785 | -0.5% |
| User cycles/response | 8,665 | 7,736 | -10.7% |
| Total server CPU microseconds/response | 7.95 | 7.54 | -5.2% |
| Valid responses/second | 228,703 | 250,237 | +9.4% |

User-cycle cost improves in all five pairs, by 3.4-17.2%. Throughput changes are
+10.0%, +7.0%, +3.6%, -2.6% and +17.0%. Before rates span 205,714-253,901;
after rates span 213,136-267,629. The overlapping ranges do not establish a fixed
9.4% throughput increase. A shorter three-pair probe (600,000 requests per sample,
ten-second perf window) was inconclusive: median throughput fell 2.5%, total CPU
cost rose 4.1% and user cycles fell 3.0%. Those samples are also included.

The longer application probe ran around 22:41-22:46 PDT. No compiler jobs ran;
occasional browser activity reached 0.49 cores averaged over five seconds. All
samples are retained. The comparison's generator was near its four-core limit,
so rates are not maximum server capacity. These all-size results must not be
attributed to the thresholded PR without a new measurement.

The measured application revisions were `af65824e896a496b4b685d7a692e298a7abc1106`
and `38099a82ca7b1cb138012307161ff4c2292fe6d9`. Its original HTTP patch was
`6f6e7d80e58d689b5f33a08af26c428739f96642` on `ebb4238`; rebasing that patch
onto `df12a62` leaves the send implementation unchanged. The earlier HTTP baseline
contains the merged drain changes; intervening upstream Linux runtime code is unchanged.

```text
before executable: 4272e14810ef82104b617acc90fb6e41dca9487312820c26c6dcf6d0d4b104a3
all-size executable: ab199b3ddb96c7dd0a260b9d07d50313ca7754beb5fc1680b55685c0a316d79a
load generator: f4e5801a7b5ff6ba1a1b8919a007f7d409e79c2f88433299c944c424aa24aecb
fixture database: 378b2275a197092b31aec7295b0a5c2fbfc24af94d3001ddd095c3b08832c251
```

## Correctness validation

The thresholded branch passes the deterministic C test under GCC address and
undefined-behavior sanitizers, all 60 package tests at `-O0` and `-O2` with official
Goose v2026.3, and the Unix drain tests on Linux with Clang 18.1.3. Both the emulated
ring and direct epoll deliver all 4,096 8 KiB frames (32 MiB) in order after a stalled
reader resumes, with no measured RSS growth during the stall and reusable slots
after disconnect. Direct publishers yield to health requests and stay active past
their idle deadline. These tests run through `scripts/test-drain.sh`, which the
Unix `scripts/test.sh` runner invokes.

The C fixture covers zero/below/at-threshold sends, full and partial acceptance,
owned tails after caller-buffer reuse, EAGAIN rearming, EINTR/error completion,
completion overflow, close, pre-send allocation failure and ordering behind files.
Native io_uring, macOS and Windows integration remain unmeasured for this proposal.
