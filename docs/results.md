# Measurement records

Provenance and limitations for the [current benchmarks](benchmarks.md), plus selected
earlier measurements that still explain a decision or an open issue. Raw run
directories remain in `bench/results/`; superseded tables and session narratives are
recoverable from git. [bench/README.md](../bench/README.md) owns the harness and method.

## Machine

Desktop comparisons use an AMD Ryzen 7 5800X3D, 8 cores and 16 logical CPUs, Windows 11,
and WSL2 Ubuntu 26.04.1 with 15 GB assigned to WSL. Servers use CPUs 0-3, load generators
4-15; one-worker cells use CPU 0. Goose is built with gcc 15.2.0 at `-O2`, competitors
in release mode with the configurations in
[the server table](../bench/README.md#servers).

WSL2 loopback runs through a VM; its kernel cost differs from bare metal. Runs through
2026-10-12 use kernel 6.18.40.1-microsoft-standard-WSL2. The 2026-10-14 runs use
6.18.54.1-microsoft-standard-WSL2. Each run's `env.txt` records the environment.

## 2026-10-22: the emulated ring sends large writes without a copy

Task 065, measured on an AMD Ryzen 9 9950X3D: x86-64 Docker on WSL2, kernel
5.15.167.4, glibc 2.39, where io_uring setup returns `EINVAL`, so `LOOP=uring` runs the
emulated ring over epoll. Goose `v2026.3` and Clang 18.1.3 built the baseline `df12a627`
and the PR's commits `10123bb` (every size skips the copy) and `a123284` (16 KB and
up). Timing began after three quiet five-second host samples. Neither native io_uring,
macOS, nor Windows was measured.

**Plaintext.** Each sample is `bench/count.sh` with 10 M `/plaintext` requests, all
2xx: one worker on CPU 0, h2load with 8 threads on CPUs 4-15, 256 connections, 16 in
flight each. Every size ran three pairs; 16 KB ran three in each order
(`LOOP=uring RUNS=3 N=10000000 sh bench/count.sh goose-send-before goose-send-after`,
then the reverse with `PORT=29291`). Medians (ranges), per request:

| Build | User instructions | User cycles | req/s |
|---|---:|---:|---:|
| Before | 2,047.6 (2,047.5-2,047.6) | 436.7 (432.3-437.7) | 2,212,226 (2,129,599-2,515,325) |
| Every size | 2,040.1 (2,040.1-2,040.2) | 560.5 (549.7-570.1) | 1,649,091 (1,574,386-1,771,929) |
| Before | 2,047.6 (2,047.5-2,047.6) | 435.25 (431.9-436.7) | 2,475,665 (2,269,966-2,523,131) |
| 16 KB | 2,048.0 (2,047.9-2,048.0) | 436.5 (434.0-438.9) | 2,265,172 (2,126,040-2,339,571) |

Every size loses 25.5% with ranges apart, so small sends stay queued. 16 KB adds 0.02%
instructions and 0.29% cycles, yet its median falls 8.5%; the ranges overlap, and user
counters, which exclude the kernel, don't explain the gap.

**Application.** An unpublished Campfire application, which this repository can't
rebuild: four workers on CPUs 0,2,4,6 with 2 GiB, fresh fixture storage, and the shared
[Campfire verifier](https://github.com/basecamp/once-campfire-verification/tree/ec02debb3e44f40b8778a6a42db3c4515b2f9eaf);
the client on CPUs 8,10,12,14 runs `http --gzip 1 --conc 16 --duration 30 --requests
3000000` against `room_show`, a cached gzip response of about 21 KB, with no WebSocket
subscribers. After a 2 s warm-up, five pairs alternate order, 3 M validated reads per
sample under `perf stat -x, -e instructions:u,cycles:u,task-clock -p 1 -- sleep 25`;
every response passed. The every-size pairs ran earlier, on Goose `d9573d8`. Medians:

| Per response | Before | 16 KB | Change | Before | Every size | Change |
|---|---:|---:|---:|---:|---:|---:|
| User instructions | 7,825.7 | 7,808.5 | -0.2% | 7,826 | 7,785 | -0.5% |
| User cycles | 9,218.6 | 8,351.7 | -9.4% | 8,665 | 7,736 | -10.7% |
| Server CPU µs | 8.454 | 8.115 | -4.0% | 7.95 | 7.54 | -5.2% |
| Responses/s | 213,817 | 230,004 | +7.6% | 228,703 | 250,237 | +9.4% |

At 16 KB, cycles fall in every pair (11.2%, 5.0%, 16.5%, 14.1%, 1.4%), CPU time in
three of five, and throughput in four; one pair loses 2.8%. Rates span 205,543-236,734
before and 220,747-251,441 after. Every size's pairs change throughput by +10.0%, +7.0%,
+3.6%, -2.6%, and +17.0% (205,714-253,901 before, 213,136-267,629 after), and cycles by
-3.4% to -17.2%. A shorter three-pair probe (600 K reads, a 10 s perf window) lost 2.5%
throughput and spent 4.1% more CPU time while cycles fell 3.0%. Task-clock includes
idle time around the batch, and the client ran near its four-core limit, so the rates
aren't capacity. The Rust and Jai Campfire servers weren't rerun beside the 16 KB build.

**Large responses on the desktop lose (2026-10-23).** On the [desktop](#machine), four
workers and 256 connections fetching a 21 KB body, natively with `LOOP=uring-epoll` and
Clang: the base `df12a62` serves 195.0 K and 193.8 K req/s in two runs, at 20.5-20.7 µs
per request, and the PR 140.3 K and 138.0 K at 28.5-29.0 µs, 28% fewer. In Docker
under its default seccomp profile, with gcc, against `main`, the PR loses 27% at 21 KB
and 15% at 64 KB. Pipelined plaintext shows no difference beyond an A/A control of the
base against itself, which differs by 2.5%.

## 2026-10-22: v0.5.4, Goose builds only

Plod's (then goose-rest's) `bench/all.sh` measured this repository in session
`2026-10-22T2042-Tiamat`: `e4564432` (`v0.5.4`), Goose `v2026.3`, gcc 15.2.0, kernel
6.18.54.1-microsoft-standard-WSL2, on the desktop described above. The machine passed
the idle check, and this repository's tests passed in the session. The tiny-response
`key.txt` matches 2026-10-20's. The session was stopped at its REST step, which would
have measured goose-rest `v0.3.3`, a tag behind Plod's `v0.4.0`;
`bench/instructions.sh` then ran by hand, and Plod's steps ran in a session of their
own, `2026-10-22T2146-Tiamat`, with Plod at `556445e` (`v0.4.0` with docs and
comments only) and this repository at `a7ce7d12` (`v0.5.4` with comments only). The
[steps](../bench/results/2026-10-22T2042-Tiamat/session-steps.txt) and
[environment](../bench/results/2026-10-22T2042-Tiamat/session-env.txt) are kept. No
competitors were rerun.

Every rate below but three is lower than 2026-10-20's, by up to 8.1%, and the
session's drift accounts for it: `v0.4.3`, rebuilt after the REST run with its own
Goose `f114b5a` and with `v2026.3`, counted 1,583-1,621 user instructions and
2,143-2,219 cycles per request on epoll, and 1,631-1,660 and 1,880-1,926 on io_uring
([counts](../bench/results/2026-10-22T2042-Tiamat/instructions-v0.4.3.txt)), where
2026-10-20 counted 2,104-2,150 and 1,813-1,826 cycles. `v0.5.4`'s cycles in this
session fall inside those ranges, and its user instructions within 0.5% of them, and the two compilers' builds of `v0.4.3` don't differ beyond the
runs' spread. The [current benchmarks](benchmarks.md) keep 2026-10-20's numbers.

### Tiny responses

The method of 2026-10-20. Four-worker medians and ranges from the
[summary](../bench/results/2026-10-22T2042-Tiamat/summary.md), against 2026-10-20:

| Loop | Test | Connections | req/s, median (range) | Change |
|---|---|---:|---:|---:|
| io_uring | plaintext | 256 | 6.105 M (6.083-6.130 M) | -7.3% |
| io_uring | plaintext | 1,024 | 5.961 M (5.821-6.004 M) | -8.1% |
| io_uring | plaintext | 4,096 | 5.700 M (5.653-5.700 M) | +2.4% |
| io_uring | JSON | 256 | 478 K (474-479 K) | -4.4% |
| io_uring | JSON | 1,024 | 470 K (469-475 K) | -4.1% |
| epoll | plaintext | 256 | 4.853 M (4.841-4.886 M) | -7.6% |
| epoll | plaintext | 1,024 | 4.826 M (4.780-4.840 M) | -6.5% |
| epoll | plaintext | 4,096 | 4.675 M (4.549-4.741 M) | -6.5% |
| epoll | JSON | 256 | 379 K (379-381 K) | -5.7% |
| epoll | JSON | 1,024 | 378 K (377-382 K) | -4.8% |

Every cell has zero errors. Peak RSS across the tiny-response cells is 3.6-5.2 MB on
epoll and 5.2-13.2 MB on io_uring. Most cells record one to three clock steps, which
`wrk-monotonic.so` keeps from turning into timeouts.

[Counts](../bench/results/2026-10-22T2042-Tiamat/instructions.txt), by
`bench/instructions.sh` as on 2026-10-20:

| Loop | Instructions/req | User instructions/req | Cycles/req | Peak RSS |
|---|---:|---:|---:|---:|
| epoll | 2,548-2,585 | 1,605-1,629 | 2,162-2,198 | 3.5-3.6 MB |
| io_uring | 2,619-2,647 | 1,640-1,656 | 1,894-1,926 | 5.9-6.1 MB |

### REST and static files

REST by the method of 2026-10-20, on this repository alone and on Plod.
The [REST summary](https://github.com/kaitk/plod/blob/main/bench/results/2026-10-22T2146-rest-Tiamat/summary.md)
and [notes](https://github.com/kaitk/plod/blob/main/bench/results/2026-10-22T2146-rest-Tiamat/notes.md)
keep both repositories' results. This repository alone:

| Loop | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring | 568.6 K/s | 303.0 K/s | 62.0 K/s | 147.2 K/s | 1,114/s |
| epoll | 407.8 K/s | 231.7 K/s | 60.2 K/s | 137.2 K/s | 1,119/s |

Against 2026-10-20 that is 2.1-5.8% lower on io_uring and 2.4-7.4% on epoll. Every
cell has zero errors.

Static files by the method of 2026-10-20
([summary](../bench/results/2026-10-22T2042-Tiamat-files/summary.md)):

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| epoll | 54.0 K/s | 185 K/s | 2.06 GB/s | 7.64 GB/s | 10.53 GB/s | 21.41 GB/s |
| io_uring | 79.8 K/s | 225 K/s | 1.94 GB/s | 6.69 GB/s | 10.56 GB/s | 21.03 GB/s |
| emulated ring | 71.5 K/s | 208 K/s | 2.68 GB/s | 8.10 GB/s | 12.18 GB/s | 21.41 GB/s |

Every cell has zero errors. Epoll's 4 KB with one worker and io_uring's 1 MB with one
worker are 1.3% and 1.5% above 2026-10-20's, and the others 0.9-5.3% below. At 1 MB
with four workers, wrk again consumes its limit, 80.2 s of CPU in each 10 s run.

## 2026-10-20: v0.4.3, Goose builds only

goose-rest's `bench/all.sh` measured both repositories in session
`2026-10-20T0854-Tiamat`: this repository at `0a016bb0` (`v0.4.3`), goose-rest at
`62c340d` (`v0.2.1`), Goose master `f114b5a`, gcc 15.2.0, kernel
6.18.54.1-microsoft-standard-WSL2, on the desktop described above. The machine passed
the idle check, both repositories' tests had passed on WSL before the session, and
all benchmark servers passed the workload checks. No competitors were rerun.
The [environment](../bench/results/2026-10-20T0854-Tiamat/session-env.txt) records
the compiler binary's hash and the fixed rates. The tiny-response `key.txt` matches
the 2026-10-18 and 2026-10-19 sessions.

The commands, run by `bench/all.sh` from goose-rest:

```sh
SERVERS="goose goose-uring" bench/run.sh
SERVERS="goose goose-uring goose-uring-epoll" bench/files.sh
bench/instructions.sh goose goose-uring
# In goose-rest:
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest" \
    EXTRA="goose-uring-rest goose-epoll-rest" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run
bench/rest.sh count
```

### Tiny responses

wrk 4.1.0, 8 threads on CPUs 4-15, servers on CPUs 0-3 (CPU 0 with one worker),
three interleaved runs of 15 s after 5 s warm-up. Plaintext is pipelined 16 deep;
JSON isn't pipelined. Four-worker medians and ranges from the
[summary](../bench/results/2026-10-20T0854-Tiamat/summary.md):

| Loop | Test | Connections | req/s, median (range) |
|---|---|---:|---:|
| io_uring | plaintext | 256 | 6.589 M (6.449-6.632 M) |
| io_uring | plaintext | 1,024 | 6.485 M (6.461-6.512 M) |
| io_uring | plaintext | 4,096 | 5.568 M (5.334-5.917 M) |
| io_uring | JSON | 256 | 500 K (499-503 K) |
| io_uring | JSON | 1,024 | 490 K (485-492 K) |
| epoll | plaintext | 256 | 5.250 M (5.231-5.266 M) |
| epoll | plaintext | 1,024 | 5.161 M (5.157-5.208 M) |
| epoll | plaintext | 4,096 | 4.999 M (4.766-5.020 M) |
| epoll | JSON | 256 | 402 K (402-403 K) |
| epoll | JSON | 1,024 | 397 K (393-400 K) |

Against `v0.4.0`, epoll plaintext gains 5.8-6.5%; io_uring moves +1.3%, +0.2%,
and -9.0%. Against `v0.3.7`, epoll remains 3.5-4.8% slower and io_uring 7.2-13.3%.
JSON moves by -2.9% to +0.8% against `v0.4.0`. Peak RSS across all tiny-response
cells is 3.5-5.1 MB on epoll and 5.2-13.4 MB on io_uring.
Every cell has zero errors. The first one-worker epoll plaintext run at 1,024
connections records two clock steps; the four-worker cells have none.

`bench/instructions.sh`: one worker on CPU 0, wrk on CPUs 4-15 with 8 threads,
256 connections and plaintext pipelined 16 deep, three runs of 20 s; perf counts
on CPU 0 for 10 s after 5 s. Requests are wrk's rate times those 10 s.
[Counts](../bench/results/2026-10-20T0854-Tiamat/instructions.txt):

| Loop | Instructions/req | User instructions/req | Cycles/req | Peak RSS |
|---|---:|---:|---:|---:|
| epoll | 2,536-2,564 | 1,599-1,616 | 2,104-2,150 | 3.5-3.6 MB |
| io_uring | 2,604-2,625 | 1,637-1,651 | 1,813-1,826 | 5.9-6.1 MB |

User instructions are back near `v0.3.7`'s 1,598-1,604 and 1,634-1,653; the
epoll memory increase is gone. Total cycles remain above that session's
2,040-2,047 and 1,757-1,769, despite the restored user instruction counts.

### REST and static files

REST uses four workers, wrk with 8 threads and 256 connections, three interleaved
15 s runs after 5 s warm-up. Uploads alone use 1 thread and 32 connections.
The [REST summary](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-20T0854-rest-Tiamat/summary.md)
and [notes](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-20T0854-rest-Tiamat/notes.md)
retain both repositories' results and the uploads-alone medians at full precision.

| Loop | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring | 587.9 K/s | 315.4 K/s | 63.3 K/s | 156.3 K/s | 1,146/s |
| epoll | 437.9 K/s | 244.6 K/s | 61.7 K/s | 148.1 K/s | 1,162/s |

Against `v0.4.0`, C templated gains 2.1% and 2.6%, while serialized A to C move
by -3.3% to -0.3%. Uploads alone fall 1.4% and 2.0%. Beside forms, io_uring serves
170-175 uploads/s and 7.7-7.8 K forms/s; epoll serves 123-125 and 7.7-8.0 K/s.
Reads offered at 1,700/s beside uploads have p99 4.66-8.20 ms on io_uring and
0.34-1.34 ms on epoll. They are a separate workload from the earlier 16,000/s table.

Static files use 8 wrk threads, 64 connections, three 10 s runs after 3 s warm-up,
one or four workers, the same CPU placement, and files on tmpfs.
[Summary](../bench/results/2026-10-20T0854-Tiamat-files/summary.md):

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| epoll | 53.3 K/s | 187 K/s | 2.10 GB/s | 7.90 GB/s | 10.62 GB/s | 22.04 GB/s |
| io_uring | 81.7 K/s | 232 K/s | 2.00 GB/s | 6.88 GB/s | 10.40 GB/s | 21.62 GB/s |
| emulated ring | 74.0 K/s | 213 K/s | 2.83 GB/s | 8.29 GB/s | 12.47 GB/s | 21.88 GB/s |

Every cell has zero errors. At 1 MB with four workers, wrk consumes 80.2 s CPU
in each 10 s run, its limit. This comparison retains the earlier full-field table,
whose client used 12 threads and 96 connections.

## 2026-10-19: v0.4.0, Goose builds only

A session script that runs goose-rest's `bench/all.sh` steps after its tests measured
both repositories' Goose servers on the desktop, machine name Tiamat, in session
`2026-10-19T2043`: the Goose builds, goose-rest's `bench/rest.sh check`,
`bench/run.sh`, `bench/files.sh`, goose-rest's `bench/rest.sh run`,
`bench/instructions.sh`, and goose-rest's `bench/rest.sh count`. The tests ran apart:
this repository's suite passed at `4eeb467c` from a clone on WSL's own filesystem,
since `outbound_loop` listens on Unix sockets, which `/mnt/c` can't hold
([known issues](known-issues.md#kernel-and-toolchain)). The server is `6512e790`,
`v0.4.0` with changes to `bench/*.sh` and the docs only. The compiler is Goose master
`f114b5a`, which `scripts/goose.sh` pins. Kernel 6.18.54.1-microsoft-standard-WSL2,
gcc 15.2.0 at `-O2`. The `key.txt` is the
[2026-10-18 session](#2026-10-18-v037-goose-builds-only)'s, and the machine passed the
idle check before the session began. No competitor of this repository's ran. The
session's [steps](../bench/results/2026-10-19T2043-Tiamat/session-steps.txt) and
[environment](../bench/results/2026-10-19T2043-Tiamat/session-env.txt) are kept.

Plaintext lost up to 11% on epoll and up to 8.5% on io_uring, with about 10% more user
instructions per request on both loops, and the epoll server's peak RSS grew by 2.4 MB.
[Task 055](../tasks/000-archive/055-v0.4.0-plaintext-cost.md) traces both to two commits:
WebSocket's `1bc944a3`, whose `ws_read` branch, inlined into the benchmark server's
handler in `server/routes.goose`, costs about 117 user instructions per request on a
path that never takes it, and its `Transfer` field about 22; and TLS's `1012e705`, which
links OpenSSL into the epoll server. `v0.3.7` built with `f114b5a` counts what it
counted at `v2026.2`, so the compiler isn't the cause.

### Plaintext and JSON at v0.4.0

```sh
SERVERS="goose goose-uring" bench/run.sh
```

The settings of the [earlier run](#plaintext-and-json-at-v037). 4 workers, from the
[summary](../bench/results/2026-10-19T2043-Tiamat/summary.md), against `edd83c4b`'s
cells:

| Loop | Test | Conns | `v0.3.7` | `v0.4.0` | Change |
|---|---|---:|---:|---:|---:|
| io_uring | plaintext | 256 | 7.10 M (6.91-7.17) | 6.50 M (6.37-6.51) | -8.5% |
| io_uring | plaintext | 1,024 | 7.04 M (6.84-7.04) | 6.47 M (6.23-6.52) | -8.1% |
| io_uring | plaintext | 4,096 | 6.42 M (6.34-6.52) | 6.12 M (6.08-6.14) | -4.6% |
| io_uring | JSON | 256 | 517 K (509-519) | 515 K (514-516) | -0.4% |
| io_uring | JSON | 1,024 | 510 K (500-511) | 498 K (496-503) | -2.4% |
| epoll | plaintext | 256 | 5.44 M (5.39-5.54) | 4.94 M (4.85-5.03) | -9.2% |
| epoll | plaintext | 1,024 | 5.38 M (5.31-5.48) | 4.88 M (4.83-4.92) | -9.3% |
| epoll | plaintext | 4,096 | 5.25 M (5.24-5.29) | 4.69 M (4.60-4.78) | -10.5% |
| epoll | JSON | 256 | 411 K (411-411) | 399 K (395-404) | -2.9% |
| epoll | JSON | 1,024 | 408 K (402-409) | 395 K (394-397) | -3.2% |

With 1 worker, plaintext fell 2.5-10.7% on epoll and 3.5-6.6% on io_uring, and JSON
3.1-7.4% and 1.4-4.2%. Every plaintext cell is below the earlier range, and most fell
further than the 2.2-6.4% the cells moved between the two previous sessions. Peak RSS
is 5.8-7.8 MB on epoll and 5.2-16.7 MB on io_uring, against 3.4-4.9 MB and 5.0-16.3 MB.
Every cell had zero errors and no clock steps.

### Instruction counts at v0.4.0

```sh
bench/instructions.sh goose goose-uring
```

The settings of the [earlier counts](#instruction-counts-at-v037)
([counts](../bench/results/2026-10-19T2043-Tiamat/instructions.txt)):

| Loop | Instructions/req | User instructions/req | Cycles/req | Peak RSS |
|---|---:|---:|---:|---:|
| epoll, `v0.3.7` | 2,540-2,551 | 1,598-1,604 | 2,040-2,047 | 3.4-3.5 MB |
| epoll, `v0.4.0` | 2,697-2,724 | 1,760-1,778 | 2,207-2,223 | 5.8-5.9 MB |
| io_uring, `v0.3.7` | 2,601-2,632 | 1,634-1,653 | 1,757-1,769 | 5.9 MB |
| io_uring, `v0.4.0` | 2,760-2,791 | 1,792-1,812 | 1,856-1,867 | 5.9-6.0 MB |

At the medians, user instructions per request rise 11.1% on epoll, from 1,599 to 1,776,
and 9.5% on io_uring, from 1,646 to 1,802; cycles rise 8.5% and 5.4%. `v0.3.7` rebuilt
with `f114b5a` counts 1,596-1,609 and 1,644-1,663. A bisect of `main`'s first parents,
one run per step, and builds of `1bc944a3` without its changes to the server give the
split in task 055. goose-rest's `bench/rest.sh count` doesn't show the cost, since this
repository's REST server has no WebSocket route: tier A's item counts 4,159 user
instructions on it, against 4,107 on 2026-10-18.

### Static files at v0.4.0

```sh
SERVERS="goose goose-uring goose-uring-epoll" bench/files.sh
```

The settings of the [earlier run](#static-files-at-v037)
([summary](../bench/results/2026-10-19T2043-Tiamat-files/summary.md)):

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| Goose epoll | 55.5 K/s | 190 K/s | 2.12 GB/s | 7.89 GB/s | 10.7 GB/s | 22.3 GB/s |
| Goose io_uring | 83.4 K/s | 237 K/s | 1.99 GB/s | 6.92 GB/s | 10.6 GB/s | 21.8 GB/s |
| Goose, emulated ring | 75.4 K/s | 218 K/s | 2.77 GB/s | 8.32 GB/s | 12.6 GB/s | 22.2 GB/s |

Against `edd83c4b`'s medians, the 4 KB cells moved by -3.0% to -0.6%, the 64 KB cells by
-2.6% to -0.7%, and the 1 MB cells by -1.4% to +1.0%. At 1 MB with 4 workers wrk used
80.1-80.2 s of CPU in each 10 s run, the client's limit. Every cell had zero errors.

### REST tiers A to D at v0.4.0

```sh
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest aegon aegon-small" \
    EXTRA="goose-uring-rest goose-epoll-rest aegon aegon-small" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
```

The session's own step, at goose-rest `85f5542`, `v0.2.0`, which imports this
repository at `v0.4.0`
([summary](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-19T2043-rest-Tiamat/summary.md)).
The settings of the [earlier run](#rest-tiers-a-to-d-at-v037). Every server passed its
checks and reached every fixed rate with zero errors. Aegon, goose-rest's newest
competitor, ran in the same step on tiers A to C
([goose-rest's benchmarks](https://github.com/kaitk/goose-rest/blob/main/docs/benchmarks.md)).
Medians and ranges, serialized, against `edd83c4b`'s:

| Server | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring, `edd83c4b` | 608 K/s (605-608) | 316 K/s (312-317) | 64.0 K/s (63.8-64.2) | 153 K/s (151-155) | 1,182/s |
| io_uring, `6512e790` | 601 K/s (598-602) | 319 K/s (318-319) | 64.1 K/s (63.9-64.1) | 153 K/s (152-153) | 1,162/s |
| epoll, `edd83c4b` | 469 K/s (463-471) | 247 K/s (245-248) | 62.9 K/s (62.1-62.9) | 145 K/s (145-146) | 1,192/s |
| epoll, `6512e790` | 453 K/s (442-453) | 247 K/s (242-250) | 61.9 K/s (61.4-62.5) | 144 K/s (143-144) | 1,187/s |

The cells moved by -3.5% to +0.9%, the most on epoll's tier A: -3.5% serialized, and
-5.3% templated, 456 K against 482 K. Tiers B and C stayed within 1.6%. Uploads alone
fell 1.7% on io_uring and 0.4% on epoll.

Peak RSS over the three runs, in MB, A, B, C, C templated, and uploads alone: io_uring
12.7, 30.5, 70.7, 57.7, and 70.8; epoll 7.6, 28.9, 69.2, 57.6, and 69.2, each within
0.2 MB of `edd83c4b`'s, as the REST server imports no TLS. Tier D beside forms: io_uring
164-173 uploads a second with forms at 7.5-7.6 K/s, against 168-169 and 7.5-7.6 K/s;
epoll 120-122 uploads a second with forms at 7.7-7.8 K/s, against 123-124 and
7.8-7.9 K/s.

Tier C's reads at 1,700 a second: beside uploads, the io_uring loop's p99 is
4.58-7.43 ms against epoll's 0.49-1.51 ms, and 0.15-0.89 ms on both loops alone.

## 2026-10-18: v0.3.7, Goose builds only

goose-rest's `bench/all.sh` measured both repositories' Goose servers on the desktop,
machine name Tiamat, in session `2026-10-18T2118`: both test suites, the Goose builds,
goose-rest's `bench/rest.sh check`, `bench/run.sh`, `bench/files.sh`, goose-rest's
`bench/rest.sh run`, `bench/instructions.sh`, and goose-rest's `bench/rest.sh count`.
The server is `edd83c4b`, `v0.3.7`. The compiler is the Goose release `v2026.2`
(`3ee3871`), Linux archive SHA-256
`8f6d3e883f9d6ea655263b445da02bd4f6c85b4a7bbd3ca5c268bcabd7aff296`. Kernel
6.18.54.1-microsoft-standard-WSL2, gcc 15.2.0 at `-O2`. Against the
[2026-10-16 session](#2026-10-16-v036-at-goose-v20262-goose-builds-only), the compiler
is the same, and so is the request path: `v0.3.7` adds placement, which does nothing
without a placement file, and a stop for mail boxes. The cells below moved by up to
+6.4% all the same, so they measure the session as much as the code. No competitor of
this repository's ran; their comparisons use the
[2026-10-14 field run](#2026-10-14-main-after-tasks-02203-025-and-027) on the same
machine and kernel. Before it began, the 1-minute load average settled at 0.26 and
Windows CPU at 9%. The session's
[steps](../bench/results/2026-10-18T2118-Tiamat/session-steps.txt) and
[environment](../bench/results/2026-10-18T2118-Tiamat/session-env.txt) are kept.

### Plaintext and JSON at v0.3.7

```sh
SERVERS="goose goose-uring" bench/run.sh
```

The settings of the [earlier run](#plaintext-and-json-at-v20262). 4 workers, from the
[summary](../bench/results/2026-10-18T2118-Tiamat/summary.md), against `3785950e`'s
cells:

| Loop | Test | Conns | `v0.3.6` | `v0.3.7` | Change |
|---|---|---:|---:|---:|---:|
| io_uring | plaintext | 256 | 6.73 M (6.63-6.81) | 7.10 M (6.91-7.17) | +5.5% |
| io_uring | plaintext | 1,024 | 6.62 M (6.62-6.74) | 7.04 M (6.84-7.04) | +6.4% |
| io_uring | plaintext | 4,096 | 6.20 M (6.14-6.21) | 6.42 M (6.34-6.52) | +3.5% |
| io_uring | JSON | 256 | 495 K (456-498) | 517 K (509-519) | +4.4% |
| io_uring | JSON | 1,024 | 491 K (487-500) | 510 K (500-511) | +3.9% |
| epoll | plaintext | 256 | 5.22 M (5.21-5.27) | 5.44 M (5.39-5.54) | +4.2% |
| epoll | plaintext | 1,024 | 5.18 M (5.16-5.19) | 5.38 M (5.31-5.48) | +3.9% |
| epoll | plaintext | 4,096 | 5.06 M (4.97-5.08) | 5.25 M (5.24-5.29) | +3.7% |
| epoll | JSON | 256 | 402 K (394-403) | 411 K (411-411) | +2.2% |
| epoll | JSON | 1,024 | 397 K (394-401) | 408 K (402-409) | +2.8% |

Every cell rose 2.2-6.4%, each above or at the top of the earlier range. Peak RSS is
4.0-4.9 MB on epoll and 10.2-16.3 MB on io_uring with 4 workers, against 4.0-4.9 MB and
10.1-13.0 MB; the 16.3 MB is plaintext at 4,096 connections, 12.8 MB before. Every cell
had zero errors and no clock steps.

### Instruction counts at v0.3.7

```sh
bench/instructions.sh goose goose-uring
```

The settings of the [earlier counts](#instruction-counts-at-v20262)
([counts](../bench/results/2026-10-18T2118-Tiamat/instructions.txt)):

| Loop | Instructions/req | User instructions/req | Cycles/req | Peak RSS |
|---|---:|---:|---:|---:|
| epoll, `v0.3.6` | 2,475-2,517 | 1,553-1,580 | 2,067-2,085 | 3.5 MB |
| epoll, `v0.3.7` | 2,540-2,551 | 1,598-1,604 | 2,040-2,047 | 3.4-3.5 MB |
| io_uring, `v0.3.6` | 2,600-2,628 | 1,633-1,650 | 1,784-1,816 | 5.6-5.8 MB |
| io_uring, `v0.3.7` | 2,601-2,632 | 1,634-1,653 | 1,757-1,769 | 5.9 MB |

At the medians, user instructions per request rise 2.8% on epoll, from 1,556 to 1,599,
beyond the earlier range and beyond the 1,538-1,586 the same epoll code has counted
across runs, and fall 0.2% on io_uring, from 1,650 to 1,646. Which change moved
epoll's count isn't measured. Cycles per request fall 1.6% on epoll and 2.5% on
io_uring, both beyond the earlier ranges. The runs served 1.75-1.81 M and 2.06-2.08 M
requests a second, against 1.57-1.60 M and 1.87-1.90 M on 2026-10-16.

### Static files at v0.3.7

```sh
SERVERS="goose goose-uring goose-uring-epoll" bench/files.sh
```

The settings of the [earlier run](#static-files-at-v20262)
([summary](../bench/results/2026-10-18T2118-Tiamat-files/summary.md)):

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| Goose epoll | 55.9 K/s | 195 K/s | 2.15 GB/s | 8.10 GB/s | 10.8 GB/s | 22.3 GB/s |
| Goose io_uring | 86.0 K/s | 238 K/s | 2.04 GB/s | 6.97 GB/s | 10.7 GB/s | 21.9 GB/s |
| Goose, emulated ring | 77.8 K/s | 221 K/s | 2.82 GB/s | 8.45 GB/s | 12.4 GB/s | 22.3 GB/s |

Against `3785950e`'s medians, the 4 KB cells rose 2.3-5.9%, the 64 KB cells 0.6-2.1%,
and the 1 MB cells moved by -1.5% to +0.3%. At 1 MB with 4 workers wrk again used
80.2 s of CPU in each 10 s run, the client's limit. Every cell had zero errors.

### REST tiers A to D at v0.3.7

```sh
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest" \
    EXTRA="goose-uring-rest goose-epoll-rest" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
SERVERS="axum actix-web ntex dusty-routes dusty hyper" \
    EXTRA="axum actix-web ntex dusty-routes" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
```

The first command is the session's own step, at goose-rest `e478ca2`, which imports
this repository at `v0.3.7`
([summary](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-18T2118-rest-Tiamat/summary.md)).
The second ran right after the session, from 23:55Z, once the machine was idle again,
with dusty and hyper among goose-rest's frameworks
([summary](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-18T2118-rest-Tiamat-frameworks/summary.md)).
The settings of the [earlier run](#rest-tiers-a-to-d-at-v20262). Every server passed its
checks and reached every fixed rate with zero errors, but for 2 upload errors on dusty
beside forms. Medians, serialized, against `3785950e`'s and the 2026-10-16 morning's
dusty and hyper:

| Server | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring, `3785950e` | 588 K/s | 311 K/s | 62.1 K/s | 147 K/s | 1,152/s |
| io_uring, `edd83c4b` | 608 K/s | 316 K/s | 64.0 K/s | 153 K/s | 1,182/s |
| epoll, `3785950e` | 429 K/s | 240 K/s | 61.4 K/s | 136 K/s | 1,180/s |
| epoll, `edd83c4b` | 469 K/s | 247 K/s | 62.9 K/s | 145 K/s | 1,192/s |
| dusty, 2026-10-16 | 353 K/s | 164 K/s | 25.4 K/s | 130 K/s | 1,131/s |
| dusty, 2026-10-18 | 359 K/s | 177 K/s | 25.7 K/s | 136 K/s | 1,151/s |
| hyper, 2026-10-16 | 278 K/s | 154 K/s | 33.2 K/s | 124 K/s | 1,128/s |
| hyper, 2026-10-18 | 285 K/s | 157 K/s | 33.7 K/s | 125 K/s | 1,159/s |

The Goose cells rose 1.6-9.4% with the request path unchanged, the most on epoll's
tier A, 9.4%, and each serialized cell above the earlier range. hyper's rose 0.8-2.5%, and dusty's
1.2-7.9%, so the session explains some of the rise but not all of epoll's; which part
isn't measured. Uploads alone rose 2.6% on io_uring and 1.0% on epoll.

Peak RSS over the three runs, in MB, A, B, C, C templated, and uploads alone: io_uring
12.6, 30.3, 70.6, 57.6, and 70.6; epoll 7.6, 28.9, 69.3, 57.7, and 69.1, each within
0.3 MB of `3785950e`'s. Tier D beside forms: io_uring 168-169 uploads a second with
forms at 7.5-7.6 K/s, against 175-178 and 7.7-7.8 K/s; epoll 123-124 uploads a second
with forms at 7.8-7.9 K/s, against 124-126 and 8.1-8.3 K/s.

Tier C's reads at 1,700 a second: beside uploads, the io_uring loop's p99 is
5.18-8.36 ms against epoll's 0.38-1.29 ms, and 0.14-0.94 ms on both loops alone.

## 2026-10-16: v0.3.6 at Goose v2026.2, Goose builds only

goose-http's steps of goose-rest's `bench/all.sh`, run alone in the same order, measured
the Goose servers on the desktop, machine name Tiamat, in session `2026-10-16T1422`:
the tests, the Goose builds, `bench/run.sh`, `bench/files.sh`, and
`bench/instructions.sh`. goose-rest's steps followed ([below](#rest-tiers-a-to-d-at-v20262)). The server is `3785950e`, `v0.3.6`. The compiler is the Goose
release `v2026.2` (`3ee3871`), Linux archive SHA-256
`8f6d3e883f9d6ea655263b445da02bd4f6c85b4a7bbd3ca5c268bcabd7aff296`. Kernel
6.18.54.1-microsoft-standard-WSL2, gcc 15.2.0 at `-O2`. Against the
[morning's session](#2026-10-16-v034-goose-builds-only), the compiler moved from
`v2026.1` and the servers' only change is goose-compress's import pin, so the
plaintext, JSON, and static file cells measure the same loop code at a new compiler. No
competitor ran; their comparisons use the
[2026-10-14 field run](#2026-10-14-main-after-tasks-02203-025-and-027) on the same
machine and kernel, and sessions have drifted by up to 5%. Before it began, the
1-minute load average settled at 0.21 and Windows CPU at 5%. The session's
[steps](../bench/results/2026-10-16T1422-Tiamat/session-steps.txt) and
[environment](../bench/results/2026-10-16T1422-Tiamat/session-env.txt) are kept. Its
runs are superseded by the [2026-10-18 session](#2026-10-18-v037-goose-builds-only),
which compares against them.

### Plaintext and JSON at v2026.2

```sh
SERVERS="goose goose-uring" bench/run.sh
```

The settings of the [morning's run](#plaintext-and-json-at-every-connection-count). 4
workers, from the [summary](../bench/results/2026-10-16T1422-Tiamat/summary.md),
against `f875101a`'s cells at `v2026.1`:

| Loop | Test | Conns | `v2026.1` | `v2026.2` | Change |
|---|---|---:|---:|---:|---:|
| io_uring | plaintext | 256 | 6.91 M (6.73-6.94) | 6.73 M (6.63-6.81) | -2.6% |
| io_uring | plaintext | 1,024 | 6.76 M (6.62-6.91) | 6.62 M (6.62-6.74) | -2.1% |
| io_uring | plaintext | 4,096 | 6.36 M (6.23-6.38) | 6.20 M (6.14-6.21) | -2.4% |
| io_uring | JSON | 256 | 498 K (493-500) | 495 K (456-498) | -0.6% |
| io_uring | JSON | 1,024 | 488 K (479-489) | 491 K (487-500) | +0.6% |
| epoll | plaintext | 256 | 5.21 M (5.19-5.30) | 5.22 M (5.21-5.27) | +0.2% |
| epoll | plaintext | 1,024 | 5.19 M (5.05-5.32) | 5.18 M (5.16-5.19) | -0.2% |
| epoll | plaintext | 4,096 | 5.17 M (4.95-5.20) | 5.06 M (4.97-5.08) | -2.1% |
| epoll | JSON | 256 | 404 K (400-404) | 402 K (394-403) | -0.5% |
| epoll | JSON | 1,024 | 397 K (396-398) | 397 K (394-401) | 0.0% |

io_uring's plaintext fell 2.1-2.6% at every connection count, below or at the bottom
of the earlier ranges, in line with its instruction count below. Every other cell moved
by -2.1% to +0.6%, within the earlier ranges except io_uring's JSON at 1,024
connections, whose 491 K is 0.6% above them. Peak RSS is 4.0-4.9 MB on epoll and
10.1-13.0 MB on io_uring with 4 workers, against 3.9-4.8 MB and 10.1-12.7 MB. Every
cell had zero errors and no clock steps.

### Instruction counts at v2026.2

```sh
bench/instructions.sh goose goose-uring
```

The settings of the [morning's counts](#instruction-counts)
([counts](../bench/results/2026-10-16T1422-Tiamat/instructions.txt)):

| Loop | Instructions/req | User instructions/req | Cycles/req | Peak RSS |
|---|---:|---:|---:|---:|
| epoll, `v2026.1` | 2,519-2,533 | 1,577-1,586 | 2,025-2,048 | 3.3-3.4 MB |
| epoll, `v2026.2` | 2,475-2,517 | 1,553-1,580 | 2,067-2,085 | 3.5 MB |
| io_uring, `v2026.1` | 2,593-2,601 | 1,620-1,626 | 1,750-1,775 | 5.5-5.8 MB |
| io_uring, `v2026.2` | 2,600-2,628 | 1,633-1,650 | 1,784-1,816 | 5.6-5.8 MB |

At the medians, user instructions per request fall 1.5% on epoll, from 1,579 to 1,556,
with overlapping ranges, and rise 1.5% on io_uring, from 1,625 to 1,650, beyond the
earlier range. Cycles per request rise 1.8% on epoll and 3.1% on io_uring, both beyond
the earlier ranges. The runs served 1.57-1.60 M and 1.87-1.90 M requests a second,
against 1.77-1.80 M and 2.05-2.08 M in the morning and 1.48-1.60 M and 1.81-1.88 M on
2026-10-15, so this count's rate varies between sessions more than its cycles do.

### Static files at v2026.2

```sh
SERVERS="goose goose-uring goose-uring-epoll" bench/files.sh
```

The settings of the [morning's run](#static-files-without-nginx-and-caddy)
([summary](../bench/results/2026-10-16T1422-Tiamat-files/summary.md)):

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| Goose epoll | 53.4 K/s | 186 K/s | 2.12 GB/s | 7.98 GB/s | 10.7 GB/s | 22.3 GB/s |
| Goose io_uring | 82.5 K/s | 233 K/s | 2.03 GB/s | 6.89 GB/s | 10.7 GB/s | 21.9 GB/s |
| Goose, emulated ring | 73.4 K/s | 215 K/s | 2.76 GB/s | 8.32 GB/s | 12.6 GB/s | 22.2 GB/s |

Against the morning's medians, the cells moved by -5.6% to +1.0%. The 4 KB cells fell
the most: with 1 worker, 5.6% on epoll, 3.4% on io_uring, and 3.6% on the emulated ring,
each below the earlier range. At 1 MB with 4 workers wrk again used 80.1-80.2 s of CPU
in each 10 s run, the client's limit. Every cell had zero errors.

### REST tiers A to D at v2026.2

```sh
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest" \
    EXTRA="goose-uring-rest goose-epoll-rest" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
```

Right after the steps above, goose-rest's steps of its `bench/all.sh` ran at goose-rest
`0080549`, `v0.1.2`, which imports this repository at `v0.3.6`: its tests, the Goose
builds, `bench/rest.sh check`, `bench/rest.sh run`, and `bench/rest.sh count`, in
session `2026-10-16T1525`. Before it began, the 1-minute load average settled at 0.26
and Windows CPU at 7%. The settings of the
[morning's run](#rest-tiers-a-to-d); no framework ran
([summary](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-16T1525-rest-Tiamat/summary.md)).
Every server passed its checks and reached every fixed rate with zero errors. Since the
morning, this server's application moved into `bench/rest/goose/app.goose`, the store
reads scalars and fixed-size records by value, and the compiler moved to `v2026.2`.
This server's medians, serialized, against the morning's at `f875101a`:

| Loop | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring, `f875101a` | 602 K/s | 311 K/s | 62.4 K/s | 148 K/s | 1,135/s |
| io_uring, `3785950e` | 588 K/s | 311 K/s | 62.1 K/s | 147 K/s | 1,152/s |
| epoll, `f875101a` | 450 K/s | 243 K/s | 61.2 K/s | 138 K/s | 1,134/s |
| epoll, `3785950e` | 429 K/s | 240 K/s | 61.4 K/s | 136 K/s | 1,180/s |

Tier A fell 2.5% on io_uring and 4.7% on epoll, each below the morning's range, and
tier B's templated cells, not in this table, fell 4.4% on io_uring, from 398 K to
380 K, and 3.5% on epoll, from 299 K to 289 K, also below. The other cells moved by
-1.3% to +0.3%, within the morning's ranges or near them. Uploads alone rose 1.5% on
io_uring and 4.1% on epoll, from 1,131-1,153 to 1,174-1,189 a second. Which of the
three changes moved which cell isn't measured.

Peak RSS over the three runs, in MB, A, B, C, C templated, and uploads alone: io_uring
12.5, 30.2, 70.5, 57.6, and 70.7; epoll 7.5, 28.8, 69.0, 57.7, and 69.1, each within
0.4 MB of the morning's. Tier D beside forms: io_uring 175-178 uploads a second with
forms at 7.7-7.8 K/s; epoll 124-126 uploads a second with forms at 8.1-8.3 K/s.

Tier C's reads at 1,700 a second: beside uploads, the io_uring loop's p99 is
4.95-7.92 ms against epoll's 0.39-1.34 ms, and 0.14-0.86 ms on both loops alone.

## 2026-10-16: v0.3.4, Goose builds only

goose-rest's `bench/all.sh` measured the Goose servers on the desktop, machine name
Tiamat, in session `2026-10-16T0547`. The server is `f875101a`, whose code is that of
`v0.3.4`. The compiler is the Goose release `v2026.1` (`ac759c3`), Linux archive
SHA-256 `1eab29a8fba03e036425b70a59e80c1d06b7dc0067d113975a89fdb4d3f734ec`. Kernel
6.18.54.1-microsoft-standard-WSL2, gcc 15.2.0 at `-O2`. Against the
[session before](#2026-10-15-v033-goose-builds-only), the compiler is the same and
only `shim/ring_epoll.c`, the emulated ring, changed. Every Linux build links it, but
the epoll and io_uring loops don't call it, so their cells measure the same code twice.
No competitor ran in this repository's runs, so their comparisons use the
[2026-10-14 field run](#2026-10-14-main-after-tasks-02203-025-and-027) on the same
machine and kernel, and sessions have drifted by up to 5%. The REST tiers ran hyper
and dusty in the same session. Before it began, the 1-minute load average settled at
0.23 and Windows CPU at 8%. The session's
[steps](../bench/results/2026-10-16T0547-Tiamat/session-steps.txt) and
[environment](../bench/results/2026-10-16T0547-Tiamat/session-env.txt) are kept;
goose-rest's own results are in its
[benchmarks](https://github.com/kaitk/goose-rest/blob/main/docs/benchmarks.md). Its
plaintext, JSON, instruction, static file, and Goose REST runs are superseded by the
[afternoon's session](#2026-10-16-v036-at-goose-v20262-goose-builds-only), which
compares against them.

### Plaintext and JSON at every connection count

```sh
SERVERS="goose goose-uring" bench/run.sh
```

1 worker on CPU 0 or 4 on CPUs 0-3; wrk 4.1.0 with 8 threads on CPUs 4-15; plaintext
pipelined 16 deep at 256, 1,024, and 4,096 connections, JSON at 256 and 1,024; 3
interleaved runs of 15 s after 5 s of warm-up, medians. 4 workers, from the
[summary](../bench/results/2026-10-16T0547-Tiamat/summary.md), against `95f4f2f1`'s
cells of 2026-10-15:

| Loop | Test | Conns | `95f4f2f1` | `f875101a` | Change |
|---|---|---:|---:|---:|---:|
| io_uring | plaintext | 256 | 6.95 M (6.92-7.00) | 6.91 M (6.73-6.94) | -0.6% |
| io_uring | plaintext | 1,024 | 6.84 M (6.82-6.90) | 6.76 M (6.62-6.91) | -1.1% |
| io_uring | plaintext | 4,096 | 6.35 M (6.34-6.43) | 6.36 M (6.23-6.38) | +0.1% |
| io_uring | JSON | 256 | 517 K (502-518) | 498 K (493-500) | -3.7% |
| io_uring | JSON | 1,024 | 504 K (492-507) | 488 K (479-489) | -3.2% |
| epoll | plaintext | 256 | 5.46 M (5.39-5.50) | 5.21 M (5.19-5.30) | -4.5% |
| epoll | plaintext | 1,024 | 5.31 M (5.19-5.33) | 5.19 M (5.05-5.32) | -2.2% |
| epoll | plaintext | 4,096 | 5.20 M (5.17-5.28) | 5.17 M (4.95-5.20) | -0.6% |
| epoll | JSON | 256 | 403 K (401-408) | 404 K (400-404) | +0.2% |
| epoll | JSON | 1,024 | 400 K (397-404) | 397 K (396-398) | -0.8% |

The same code lost up to 4.5%, within the 5% drift between sessions but below the
earlier ranges in three cells: io_uring's JSON at both connection counts, 3.2-3.7%, and
epoll's plaintext at 256 connections, 4.5%. Peak RSS is 3.9-4.8 MB on epoll and
10.1-12.7 MB on io_uring with 4 workers, against 3.9-4.8 MB and 10.1-16.3 MB before.
Every cell had zero errors and no clock steps.

### Instruction counts

```sh
bench/instructions.sh goose goose-uring
```

As in [Instructions per request](#instructions-per-request): one worker on CPU 0,
plaintext pipelined 16 deep at 256 connections, wrk with 8 threads on CPUs 4-15 for
20 s, perf on CPU 0 for 10 s from 5 s in, 3 runs, kernel work included
([counts](../bench/results/2026-10-16T0547-Tiamat/instructions.txt)). Against
`95f4f2f1`'s of 2026-10-15
([counts](../bench/results/2026-10-15T2102-Tiamat/instructions.txt)):

| Loop | Instructions/req | User instructions/req | Cycles/req | Peak RSS |
|---|---:|---:|---:|---:|
| epoll, `95f4f2f1` | 2,477-2,508 | 1,548-1,566 | 2,137-2,246 | 3.3-3.4 MB |
| epoll, `f875101a` | 2,519-2,533 | 1,577-1,586 | 2,025-2,048 | 3.3-3.4 MB |
| io_uring, `95f4f2f1` | 2,496-2,588 | 1,557-1,616 | 1,848-1,871 | 5.7-5.8 MB |
| io_uring, `f875101a` | 2,593-2,601 | 1,620-1,626 | 1,750-1,775 | 5.5-5.8 MB |

User instructions per request rise 1.5% on epoll, from a median of 1,555 to 1,579, and
1.4% on io_uring, from 1,602 to 1,625, both beyond the earlier ranges. Cycles per
request fall 5.3% and 5.5%, and the runs served 1.77-1.80 M and 2.05-2.08 M requests a
second, against 1.48-1.60 M and 1.81-1.88 M. The loops' code is the same in both
sessions. Counted on 2026-10-16 with `v2026.1`, 3 interleaved runs each, outside a
session, `v0.3.1` took 1,532-1,539 user instructions per request on epoll and
`1c53fda1`, whose code this session ran, 1,538-1,550, with cycles of 2,068-2,084 and
2,051-2,080. The same epoll code has counted 1,538-1,586 user instructions per request
across these runs; the cause of that spread isn't measured.

### Static files without nginx and Caddy

```sh
SERVERS="goose goose-uring goose-uring-epoll" bench/files.sh
```

`bench/files.sh`'s defaults differ from the 2026-10-12 run in
[benchmarks.md](benchmarks.md#static-files): wrk ran with 8 threads and 64
connections, not 12 and 96, on CPUs 4-15; 3 runs of 10 s after 3 s of warm-up,
medians; nginx and Caddy didn't run
([summary](../bench/results/2026-10-16T0547-Tiamat-files/summary.md)).

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| Goose epoll | 56.6 K/s | 192 K/s | 2.17 GB/s | 7.95 GB/s | 10.9 GB/s | 22.2 GB/s |
| Goose io_uring | 85.3 K/s | 236 K/s | 2.01 GB/s | 6.95 GB/s | 10.8 GB/s | 21.9 GB/s |
| Goose, emulated ring | 76.2 K/s | 216 K/s | 2.81 GB/s | 8.38 GB/s | 13.0 GB/s | 22.2 GB/s |

On the epoll and io_uring loops every cell's median request rate is 0.3-6.5% above
`95f4f2f1`'s, the most at 4 KB with 1 worker, 6.5% on epoll and 3.4% on io_uring. At
1 MB with 4 workers wrk again used 80.2 s of CPU in each 10 s run, all of its 8
threads, so 21.9-22.2 GB/s is the client's limit. These cells don't replace the table
in benchmarks.md, whose run had nginx and Caddy beside Goose under the same load.

The emulated ring's fix holds under the full run. Its 64 KB cell with 1 worker peaked
at 2.4, 2.9, and 2.7 ms in its three runs, against 3.8-5.5 s before, with no timeouts
and zero errors. Its highest peak in any cell is 9.3 ms, at 1 MB with 1 worker, and the
highest of all 54 runs is 34.8 ms, on epoll. With 1 worker the emulated ring's rates
rose 7.1% at 4 KB, 4.8% at 64 KB, and 17.4% at 1 MB, from 11.1 to 13.0 GB/s (ranges
11.06-11.11 and 12.83-13.03); with 4 workers they moved by 0.1-1.1% below the client's
limit. With 1 worker it now leads epoll by 29% at 64 KB and by 20% at 1 MB.

### REST tiers A to D

```sh
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest" \
    EXTRA="goose-uring-rest goose-epoll-rest" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
SERVERS="axum actix-web dusty-routes dusty hyper" \
    EXTRA="axum actix-web dusty-routes" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
```

goose-rest's `bench/rest.sh run` measured this repository's REST server beside
goose-rest's, then hyper, dusty, and goose-rest's peers in a second run of the same
session: 4 workers on CPUs 0-3; wrk 4.1.0 with 8 threads and 256 connections on CPUs
4-15; uploads alone with 1 thread and 32 connections; 3 interleaved runs of 15 s after
5 s of warm-up, a fresh server per cell, each server checked first
([summary](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-16T0547-rest-Tiamat/summary.md),
[competitors](https://github.com/kaitk/goose-rest/blob/main/bench/results/2026-10-16T0547-rest-Tiamat-frameworks/summary.md)).
Every server passed its checks and reached every fixed rate with zero errors. This
server's medians, serialized, against the
[run of 2026-10-15](#2026-10-15-rest-frameworks-beside-v031), whose binaries were
`de19e3b` at compiler `46356c2`:

| Loop | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring, 2026-10-15 | 586 K/s | 313 K/s | 61.8 K/s | 144 K/s | 1,125/s |
| io_uring, 2026-10-16 | 602 K/s | 311 K/s | 62.4 K/s | 148 K/s | 1,135/s |
| epoll, 2026-10-15 | 432 K/s | 243 K/s | 60.3 K/s | 136 K/s | 1,154/s |
| epoll, 2026-10-16 | 450 K/s | 243 K/s | 61.2 K/s | 138 K/s | 1,134/s |

The cells moved by -1.7% to +4.1%. io_uring's A and templated C rose 2.7%, and epoll's
A 4.1% and C 1.5%, each beyond the earlier range; io_uring's B fell 0.4% and epoll's
uploads 1.7%, both within the earlier ranges. hyper and dusty, in the same session: A
278 K and 353 K, B 154 K and 164 K, C 33.2 K and 25.4 K, C templated 124 K and 130 K,
uploads 1,128/s and 1,131/s, -0.5% to +5.0% from 2026-10-15.

Peak RSS over the three runs, in MB, A, B, C, C templated, and uploads alone: io_uring
12.4, 30.1, 70.5, 57.6, and 70.3; epoll 7.6, 28.6, 68.9, 57.5, and 68.9, each within
0.2 MB of `bc75f2a`'s on 2026-10-14. Tier D beside forms: io_uring 164-165 uploads a
second with forms at 7.4-7.5 K/s; epoll 119-121 uploads a second with forms at 7.5 K/s.

Step 4 offered tier C's reads at 1,700 a second, not the 16,000 of the "Reads p99"
column in benchmarks.md. Beside uploads the io_uring loop's reads have a p99 of
6.03-10.6 ms against epoll's 0.47-1.29 ms, and 0.15-0.84 ms on both loops alone.

dusty's log shows `error.IncompleteBody` 19 times, uploads that wrk cut off as a cell
ended, as on 2026-10-15. No upload cell counted an error.

## 2026-10-15: v0.3.3, Goose builds only

goose-rest's `bench/all.sh` measured the Goose servers alone on the desktop, machine
name Tiamat, in session `2026-10-15T2102`. The server is `95f4f2f1`, whose code is
that of `v0.3.3`. The compiler is the Goose release `v2026.1` (`ac759c3`), Linux
archive SHA-256 `1eab29a8fba03e036425b70a59e80c1d06b7dc0067d113975a89fdb4d3f734ec`.
Kernel 6.18.54.1-microsoft-standard-WSL2, gcc 15.2.0 at `-O2`. No competitor ran, so
every comparison with one uses the
[2026-10-14 field run](#2026-10-14-main-after-tasks-02203-025-and-027) on the same
machine and kernel, and sessions have drifted by up to 5%. Against the
[session before](#2026-10-14-v031-goose-builds-only), both the code and the compiler
changed. The session's [steps](../bench/results/2026-10-15T2102-Tiamat/session-steps.txt)
and [environment](../bench/results/2026-10-15T2102-Tiamat/session-env.txt) are kept;
its REST tiers are in goose-rest's
[benchmarks](https://github.com/kaitk/goose-rest/blob/main/docs/benchmarks.md).

Its plaintext, JSON, instruction, and static file runs are superseded by the
[session of 2026-10-16](#2026-10-16-v034-goose-builds-only), which compares against
them; its [summary](../bench/results/2026-10-15T2102-Tiamat/summary.md),
[instruction counts](../bench/results/2026-10-15T2102-Tiamat/instructions.txt), and
[static files](../bench/results/2026-10-15T2102-Tiamat-files/summary.md) remain.
Against `de19e3b` on 2026-10-14, its plaintext and JSON cells moved by -1.4% to +3.0%,
and its static file cells by -2.1% to +2.7%. The emulated ring's 64 KB cell with 1
worker starved connections: latency peaked at 3.8-5.5 s in every run, and the second
counted 22 timeouts past wrk's `--timeout 8`. The ring's wait returned the completions
of its queued sockets without collecting epoll's events, so while a few busy
connections kept making completions, the others never saw their edge. `v0.3.4`
collects the events on every wait (task 042, archived).

## 2026-10-15: REST frameworks beside v0.3.1

goose-rest's `bench/rest.sh run` measured its frameworks beside this repository's REST
server, hyper, and the catch-all dusty in one session, machine name Tiamat
([summary](../bench/results/2026-10-15T1539-rest-Tiamat/summary.md),
[tiers F, R, and M](../bench/results/2026-10-15T1539-rest-Tiamat/summary-extra.md)).
The Goose binaries are the ones of [the session before](#2026-10-14-v031-goose-builds-only),
code as `v0.3.1`, compiler `46356c2`; goose-rest's results and the comparison of
frameworks are in its
[benchmarks](https://github.com/kaitk/goose-rest/blob/main/docs/benchmarks.md). The
[session of 2026-10-16](#rest-tiers-a-to-d) supersedes its rates and compares
against them.

```sh
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest axum actix-web dusty-routes dusty hyper" \
    EXTRA="goose-uring-rest goose-epoll-rest axum actix-web dusty-routes" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
```

Kernel 6.18.54.1-microsoft-standard-WSL2; 4 workers on CPUs 0-3; wrk 4.1.0 with 8
threads and 256 connections on CPUs 4-15; uploads alone with 1 thread and 32
connections; 3 interleaved runs of 15 s after 5 s of warm-up, a fresh server per cell,
each server checked first. Before the run, the 1-minute load average was 0.74 and then
0.50, and Windows CPU 8% and then 6%
([idle.txt](../bench/results/2026-10-15T1539-rest-Tiamat/idle.txt)).
Every server reached every fixed rate with zero errors.

This server's medians, serialized, against the Goose-only session the day before:

| Loop | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring, 2026-10-14 | 598 K/s | 315 K/s | 62.4 K/s | 147 K/s | 1,120/s |
| io_uring, 2026-10-15 | 586 K/s | 313 K/s | 61.8 K/s | 144 K/s | 1,125/s |
| epoll, 2026-10-14 | 444 K/s | 244 K/s | 60.9 K/s | 137 K/s | 1,128/s |
| epoll, 2026-10-15 | 432 K/s | 243 K/s | 60.3 K/s | 136 K/s | 1,154/s |

The same binaries moved by -2.7% to +2.3% between the two sessions. hyper and dusty, in
the same session: A 269 K and 341 K, B 149 K and 161 K, C 32.4 K and 25.2 K, C templated
118 K and 130 K, uploads 1,104/s and 1,137/s. Their 2026-10-14 field-run medians in
[benchmarks.md](benchmarks.md#rest-apis) are within 2.5% of these on every column but
dusty's C templated, 125 K there, 4.1% lower.

dusty's log shows `error.IncompleteBody` on `POST /api/v3/imports` 13 times, and
dusty-routes's 3 times: uploads that wrk cut off as a cell ended. No upload cell counted
an error.

## 2026-10-14: v0.3.1, Goose builds only

goose-rest's `bench/all.sh` measured the Goose servers alone on the desktop, machine
name Tiamat, in session `2026-10-14T2039`. The server is `de19e3b`, whose code is
that of `v0.3.1` (`faead67`). The compiler is built from Goose `bc3c1f1`, which
`env.txt` records as `46356c2`: the two commits differ only by a logo image. Kernel
6.18.54.1-microsoft-standard-WSL2, gcc 15.2.0 at `-O2`. No competitor ran, so every
comparison with one below uses the
[2026-10-14 field run](#2026-10-14-main-after-tasks-02203-025-and-027) on the same
machine and kernel, and sessions have drifted by up to 5%. The session failed before
goose-rest's tiers F, R, and M on a checker bug; those ran on 2026-10-15 from the
same binaries. The session's [steps](../bench/results/2026-10-14T2039-Tiamat/session-steps.txt),
[environment](../bench/results/2026-10-14T2039-Tiamat/session-env.txt), and
[last log lines](../bench/results/2026-10-14T2039-Tiamat/session-tail.txt) are kept.

Its plaintext, JSON, instruction, and static file runs are superseded by the
[session of 2026-10-15](#2026-10-15-v033-goose-builds-only), which compares
against them; its [summary](../bench/results/2026-10-14T2039-Tiamat/summary.md) and
[static files](../bench/results/2026-10-14T2039-Tiamat-files/summary.md) remain.

### REST tiers A to D

```sh
SERVERS="goose-uring goose-epoll goose-uring-rest goose-epoll-rest" \
    RATE_A=100000 RATE_B=24000 RATE_C=1700 bench/rest.sh run   # from goose-rest
```

goose-rest's `bench/rest.sh run` wraps this repository's: 4 workers on CPUs 0-3,
saturation with wrk 4.1.0, 8 threads and 256 connections on CPUs 4-15, uploads
alone with 1 thread and 32 connections, 3 interleaved runs of 15 s after 5 s of
warm-up with a fresh server per cell, each server checked first
([summary](../bench/results/2026-10-14T2039-rest-Tiamat/summary.md)). Goose's medians,
serialized, against `b03a446`'s in [benchmarks.md](benchmarks.md#rest-apis):

| Loop | A | B | C | C, templates | Uploads alone |
|---|---:|---:|---:|---:|---:|
| io_uring, `b03a446` / `bc75f2a` | 577 K/s | 308 K/s | 60.3 K/s | 144 K/s | 1,080/s |
| io_uring, `de19e3b` | 598 K/s | 315 K/s | 62.4 K/s | 147 K/s | 1,120/s |
| epoll, `b03a446` / `bc75f2a` | 427 K/s | 238 K/s | 58.9 K/s | 135 K/s | 1,076/s |
| epoll, `de19e3b` | 444 K/s | 244 K/s | 60.9 K/s | 137 K/s | 1,128/s |

Every rate is 1.4-4.8% higher, within session drift. Peak RSS matches the earlier
run's to within 1 MB in every saturation cell. Tier D beside forms: io_uring 153-182
uploads a second against 149-159 before, with forms at 7.1-7.2 K/s; epoll 117-120
uploads a second.

Step 4 offered tier C's reads at 1,700 a second, not at the 16,000 of the "Reads p99"
column in benchmarks.md, so its p99 doesn't replace that column. At 1,700 a second
the io_uring loop's reads still suffer beside uploads: p99 4.8-7.5 ms against epoll's
0.40-1.35 ms, and 0.14-0.96 ms on both loops alone. Every fixed-rate cell reached its
rate with zero errors.

goose-rest's results from the same sessions are in its task 010.

## 2026-10-14: REST strings scanned 16 bytes at a time

`b03a446` has the REST server look for a string's JSON escapes with std's `find_any`,
which the runtime runs over 16 bytes at a time, and call `json::format_string` only
for a string that has one. Serialized B and C gain 11-23%, beyond the ranges, on both
loops; A, the templated tiers, and peak RSS don't change. It replaces the byte loop
whose placement cost `bc75f2a` its serialized rates
([below](#2026-10-14-the-serialized-rest-loss-is-a-loops-placement)).

Same machine and kernel as below; both builds `goose build --cc gcc --standalone` at
Goose `46356c2`, `cm` from `git archive bc75f2a` and `cs` from the working tree that
became `b03a446` (env.txt's "8f0308e (modified)"); the checker passed on every tier,
both JSON modes, and both loops.

```sh
OUT=... SERVERS="goose-uring-cm goose-uring-cs" STEPS=1 bench/rest.sh run
OUT=... SERVERS="goose-epoll-cm goose-epoll-cs" STEPS=1 bench/rest.sh run
```

4 workers on CPUs 0-3, wrk 4.1.0 with 8 threads and 256 connections on CPUs 4-15,
three interleaved runs of 15 s after 5 s of warm-up, medians and ranges, req/s, from
the [io_uring](../bench/results/2026-10-14-rest-scan/uring/summary.md) and
[epoll](../bench/results/2026-10-14-rest-scan/epoll/summary.md) summaries:

| Loop | Tier | `bc75f2a` | `b03a446` | Change | CPU µs/req |
|---|---|---:|---:|---:|---:|
| io_uring | B serialize | 268.9 K (258.8-271.3) | 308.3 K (306.2-310.2) | +14.7% | 14.9 → 13.0 |
| io_uring | C serialize | 48.9 K (45.7-49.2) | 60.3 K (60.1-60.5) | +23.3% | 81.7 → 66.3 |
| epoll | B serialize | 214.1 K (199.3-215.0) | 237.8 K (231.8-237.9) | +11.1% | 18.7 → 16.9 |
| epoll | C serialize | 48.3 K (44.6-48.6) | 58.9 K (58.7-59.3) | +21.9% | 83.0 → 68.1 |

p99 at saturation falls from 1.47 to 1.22 ms on io_uring B, 11.7 to 9.03 ms on C,
1.80 to 1.52 ms on epoll B, and 10.5 to 8.57 ms on C. Every other cell's range
overlaps. Counted as in the section below, user instructions per request fall from
57.1-57.2 K to 40.2-40.8 K on B and from 751-763 K to 522-525 K on C, against
`e4f7b55`'s 56.8-57.0 K and 752-754 K
([counts](../bench/results/2026-10-14-rest-033/counts.tsv), build `cs`). Uploads and
reads beside them were not rerun; they keep `bc75f2a`'s numbers.

## 2026-10-14: the serialized REST loss is a loop's placement

The serialized B/C loss of `bc75f2a` against `e4f7b55`
([below](#2026-10-14-main-against-the-readme-benchmark-build)) is the placement of
std's `json_format_string` byte scan, about a third of tier C's user cycles. In
`e4f7b55` the loop's 36 bytes lie within one 64-byte line; the package's later code
moves it 32 bytes, across a line, in every later build measured. The same
instructions then take 4-7% more cycles. No API change, data-loading change, or
`mallopt` setting costs a measurable rate. [Task 033](../tasks/000-archive/033-rest-regressions.md)
records the decision; scripts and raw output are in
[2026-10-14-rest-033](../bench/results/2026-10-14-rest-033/).

Same machine and kernel as below; every REST build is `goose build --cc gcc
--standalone` at Goose `46356c2` from `git archive` of its revision, 4 workers on
CPUs 0-3, io_uring, wrk 4.1.0 with 8 threads and 256 connections on CPUs 4-15.
The REST binary is the same on both loops, so epoll was not rerun.

**Bisect.** `STEPS=1 bench/rest.sh run`, three interleaved runs of 15 s after 5 s of
warm-up, along main's first parents ([summary](../bench/results/2026-10-14-rest-033/bisect-summary.md)).
Medians and ranges, req/s, and peak RSS:

| Build | B serialize | C serialize | Peak RSS B / C, MB |
|---|---:|---:|---:|
| `e4f7b55` | 275.6 K (275.4-275.9) | 51.1 K (50.7-51.4) | 47 / 105 |
| `a1c6e8d`, API work merged | 271.9 K (270.7-276.6) | 49.7 K (48.9-49.8) | 50 / 104 |
| `afb4a40`, workarounds dropped | 270.7 K (268.6-271.0) | 49.6 K (49.5-49.8) | 51 / 104 |
| `71ef2c0`, queue hand-off | 270.4 K (270.0-272.1) | 49.7 K (48.7-49.8) | 30 / 70 |
| `bc75f2a`, shared store | 271.3 K (268.7-272.7) | 49.2 K (48.9-49.5) | 30 / 70 |

The whole loss falls on the first step, and the memory reductions on the later ones.
Templated cells and tier A overlap across all five builds. A separate run of
`bc75f2a` without its `mallopt(M_MMAP_THRESHOLD, 131072)`, or with the threshold
raised to 32 MB after loading, served B at 265.9 K and 265.7 K against 265.9 K and C
at 48.0 K and 48.4 K against 48.5 K ([summary](../bench/results/2026-10-14-rest-033/mallopt-summary.md)).

**Counts.** `count.sh` runs each server, warms it for 5 s, and counts its user
instructions and cycles with `perf stat` over 10 s of a 14 s wrk run, three
interleaved runs ([counts](../bench/results/2026-10-14-rest-033/counts.tsv)).
Against `e4f7b55`, `a1c6e8d` runs 56.7-56.9 K against 56.7-56.9 K instructions per
B request and 749-754 K against 749-753 K per C request, but 25.2-25.4 K against
24.3-24.5 K cycles on B and 259-266 K against 248-249 K on C. Branch, L1, and TLB
misses per request match ([events](../bench/results/2026-10-14-rest-033/events.txt)).
`perf record` puts about 32% of tier C's user cycles in the scan loop; the
[disassembly](../bench/results/2026-10-14-rest-033/loops.txt) shows it at offset 0 of
a 64-byte line in `e4f7b55` and offset 32 in `a1c6e8d`, `71ef2c0`, and `bc75f2a`.

**Check.** `bc75f2a` built through a `gcc` wrapper that adds `-falign-loops=64`
places the loop at offset 16, within one line. Counted as above, later in the
session, when every rate ran lower: B 264.8-268.8 K req/s against `e4f7b55`'s
261.6-273.0 K and `bc75f2a`'s 254.5-264.4 K; C 48.0-48.5 K against 48.0-48.5 K and
46.2-46.6 K, at 257-259 K cycles against 258-260 K and 273-276 K. It is not adopted:
task 033 says why.

## 2026-10-14: main against the README benchmark build

Main at `bc75f2a` has overlapping plaintext and JSON throughput ranges with the
baseline, but costs more user cycles on epoll and loses serialized REST throughput.
REST memory is substantially lower. Both `bc75f2a` (`m`) and the README's previous
benchmark build, `e4f7b55` (`x`), were rebuilt with Goose `46356c2`; this compares the
server revisions at one compiler pin, rather than comparing two compiler versions.
The later documentation commit `02f28c9` changes no measured code.

AMD Ryzen 7 5800X3D, Windows 11, WSL2 Ubuntu 26.04.1, kernel
6.18.54.1-microsoft-standard-WSL2, gcc 15.2.0 at `-O2`. The machine was kept quiet:
only README/documentation editing continued, with no other benchmarks or taxing
work. The initial process check found no `wrk`, `zrk`, `h2load`, or `rest-goose`.

Each build came from `git archive <rev> | tar -x -C /root/bconf/<tag>`, not the
working tree. `LOOP=epoll scripts/build.sh` and `LOOP=uring scripts/build.sh` built
the small-response servers; `$GOOSE build --cc gcc --standalone -o
build/rest/rest-goose-c<tag> <dir>/bench/rest/goose/rest.goose` built REST. The
existing REST datasets and competitors were retained; `bench/rest.sh build` was
not rerun. The batch removed `/root/bconf` when it ended. Commands and full revision
IDs are in the [batch](../bench/results/2026-10-14-rest-main/batch.sh) and
[revision record](../bench/results/2026-10-14-rest-main/revs.txt).

### Instructions and cycles

```sh
RUNS=3 bench/count.sh goose-c{x,m} goose-c{x,m}-uring
```

One worker on CPU 0; h2load 1.68.0 on CPUs 4-15, 8 threads, 256 connections,
16 requests in flight per connection, exactly 10 million plaintext requests per
sample. `perf stat` counts the server process's user instructions and user cycles.
Medians of three runs, with minimum and maximum in parentheses, from
[counts](../bench/results/2026-10-14-desktop-main-count/runs.tsv) and
[environment](../bench/results/2026-10-14-desktop-main-count/env.txt):

| Loop | x instructions/req | m instructions/req | x cycles/req | m cycles/req |
|---|---:|---:|---:|---:|
| epoll | 1,833.1 (1,833.1-1,833.1) | 1,836.0 (1,836.0-1,836.0) | 492.6 (489.4-498.1) | 510.1 (503.3-515.7) |
| io_uring | 1,888.6 (1,888.5-1,888.6) | 1,885.4 (1,885.4-1,885.4) | 454.8 (434.8-461.8) | 445.0 (436.5-453.0) |

Epoll loses 2.9 instructions per request and 3.55% median user cycles, beyond
both ranges. io_uring saves 3.2 instructions; its cycle ranges overlap.

### Plaintext and JSON

```sh
OUT=bench/results/2026-10-14-desktop-main-run \
    SERVERS="goose-cx goose-cm goose-cx-uring goose-cm-uring" \
    TESTS="plaintext:256 json:256" LATENCY=0 bench/run.sh
```

One worker on CPU 0 or four on CPUs 0-3; wrk 4.1.0 with 8 threads on CPUs 4-15,
256 connections, TechEmpower headers, plaintext pipelined 16 deep and JSON without
pipelining. Three interleaved runs of 15 s per cell after 5 s of warm-up; a fresh
server per cell. Latency was not measured. Medians and ranges, requests per second,
from the [summary](../bench/results/2026-10-14-desktop-main-run/summary.md):

| Loop | Workers | Test | x req/s | m req/s | Median change |
|---|---:|---|---:|---:|---:|
| epoll | 1 | plaintext | 1.521 M (1.513-1.527 M) | 1.500 M (1.489-1.550 M) | -1.37% |
| epoll | 1 | JSON | 120.9 K (119.5-123.9 K) | 118.8 K (116.6-121.2 K) | -1.74% |
| io_uring | 1 | plaintext | 1.803 M (1.800-1.809 M) | 1.821 M (1.761-1.841 M) | +1.04% |
| io_uring | 1 | JSON | 145.2 K (144.1-145.9 K) | 144.2 K (143.0-149.3 K) | -0.64% |
| epoll | 4 | plaintext | 4.862 M (4.343-4.992 M) | 4.873 M (4.788-4.894 M) | +0.21% |
| epoll | 4 | JSON | 383.0 K (382.1-387.6 K) | 374.8 K (368.1-385.4 K) | -2.14% |
| io_uring | 4 | plaintext | 6.427 M (6.346-6.451 M) | 6.370 M (6.327-6.402 M) | -0.89% |
| io_uring | 4 | JSON | 472.2 K (471.2-476.5 K) | 481.0 K (480.8-481.6 K) | +1.87% |

Every throughput loss has overlapping ranges. Four-worker io_uring JSON improves
beyond the ranges. All 48 samples have zero socket errors and non-2xx responses.
The harness logged wall-clock steps in 25 samples; wrk uses the monotonic-clock
preload, and [clock logs](../bench/results/2026-10-14-desktop-main-run/) are retained.
One-worker io_uring plaintext peak RSS rises from 5.74 MB (5.66-5.75) to 5.84 MB
(5.77-5.85), a 1.77% median increase with separate ranges. Other small-response RSS
ranges overlap. MB follows the harness's convention, KiB divided by 1,024.

### REST APIs

```sh
OUT=bench/results/2026-10-14-rest-main \
    SERVERS="goose-uring-cx goose-uring-cm" \
    STEPS="1 2 4" RATE_C=16000 bench/rest.sh run
OUT=bench/results/2026-10-14-rest-main-epoll \
    SERVERS="goose-epoll-cx goose-epoll-cm" \
    STEPS="1 2 4" RATE_C=16000 bench/rest.sh run
```

Four workers on CPUs 0-3; the load on CPUs 4-15. Saturation uses wrk 4.1.0,
8 threads and 256 connections. Uploads alone use 1 thread and 32 connections;
beside forms, forms use 7 threads and 224 connections. Three interleaved runs of
15 s after 5 s of warm-up, with a fresh server per cell. Both revisions passed
the checker on A to D and both JSON modes, on both loops. The io_uring batch ran
first, then the [epoll extension](../bench/results/2026-10-14-rest-main-epoll/batch.sh)
used the same archived REST binaries. Each directory's `revs.txt` names the builds;
the working tree's concurrent documentation edits do not enter those binaries.

Requests per second at saturation, medians with run ranges in parentheses, from
the [io_uring summary](../bench/results/2026-10-14-rest-main/summary.md) and
[epoll summary](../bench/results/2026-10-14-rest-main-epoll/summary.md). Serialized
responses are built per request; templates prebuild each record's JSON at startup
and splice in request-specific values.

| Loop | Tier | JSON | x req/s | m req/s | Median change |
|---|---|---|---:|---:|---:|
| io_uring | A | serialize | 564.0 K (556.2-568.8 K) | 562.4 K (556.6-562.4 K) | -0.30% |
| io_uring | A | template | 576.8 K (561.9-579.9 K) | 577.6 K (573.3-579.7 K) | +0.13% |
| io_uring | B | serialize | 271.2 K (271.1-273.1 K) | 264.0 K (262.9-264.5 K) | -2.68% |
| io_uring | B | template | 356.4 K (355.1-357.5 K) | 365.6 K (359.7-366.4 K) | +2.58% |
| io_uring | C | serialize | 49.8 K (49.2-49.9 K) | 48.1 K (47.5-48.3 K) | -3.29% |
| io_uring | C | template | 140.3 K (139.9-140.4 K) | 140.1 K (138.9-140.6 K) | -0.13% |
| epoll | A | serialize | 412.1 K (407.0-421.0 K) | 415.9 K (413.8-416.5 K) | +0.91% |
| epoll | A | template | 430.5 K (425.0-436.5 K) | 432.8 K (428.0-432.9 K) | +0.53% |
| epoll | B | serialize | 212.5 K (212.1-214.3 K) | 200.1 K (196.5-208.8 K) | -5.84% |
| epoll | B | template | 270.8 K (268.9-275.5 K) | 274.6 K (273.1-277.0 K) | +1.42% |
| epoll | C | serialize | 47.7 K (47.3-49.1 K) | 45.6 K (44.7-47.1 K) | -4.40% |
| epoll | C | template | 128.2 K (128.0-131.4 K) | 129.0 K (124.5-131.2 K) | +0.66% |

Serialized B and C lose beyond the run ranges on both loops. B templated gains
beyond the ranges on io_uring; every other saturation rate has overlapping ranges.
There are no saturation errors. These are server-revision comparisons: the
earlier competitor measurements are retained, not rerun. Even the baseline runs
slower than its earlier field-run medians, so gaps to those competitors include
session drift.

Peak RSS per run at saturation, MB, medians with ranges. The current benchmark
table uses each cell's highest peak instead of its median.

| Loop | Tier | JSON | x peak RSS MB | m peak RSS MB |
|---|---|---|---:|---:|
| io_uring | A | serialize | 14.99 (14.98-15.04) | 12.38 (12.37-12.39) |
| io_uring | A | template | 22.57 (22.57-22.66) | 11.50 (11.45-11.52) |
| io_uring | B | serialize | 46.74 (46.63-51.90) | 30.12 (30.04-30.18) |
| io_uring | B | template | 152.76 (152.61-153.53) | 50.05 (50.03-50.21) |
| io_uring | C | serialize | 103.53 (102.40-104.79) | 70.41 (70.31-70.50) |
| io_uring | C | template | 175.95 (175.18-176.12) | 57.59 (57.53-57.62) |
| epoll | A | serialize | 9.25 (8.90-9.88) | 7.41 (7.29-7.46) |
| epoll | A | template | 18.15 (16.38-18.28) | 8.29 (8.11-8.29) |
| epoll | B | serialize | 45.93 (45.42-46.34) | 28.55 (28.53-28.57) |
| epoll | B | template | 151.75 (151.68-151.91) | 50.02 (50.02-50.11) |
| epoll | C | serialize | 102.53 (101.29-102.90) | 68.97 (68.67-68.98) |
| epoll | C | template | 175.80 (174.70-175.93) | 57.69 (57.53-57.73) |

Every REST saturation cell has lower peak RSS beyond the ranges. Workers receive
their loaded records over queues, and prebuilt JSON is held once per process in
the shared store. The rate losses come from neither: the
[follow-up](#2026-10-14-the-serialized-rest-loss-is-a-loops-placement) traces them to
the placement of one hot loop.

The serialized B/C losses also appear in CPU time and latency at saturation.
CPU is the server's total user and kernel time per request; latency is wrk's,
measured at saturation, not the fixed-rate read test. Medians and run ranges:

| Loop | Tier | x CPU us/req | m CPU us/req | x p50 ms | m p50 ms | x p99 ms | m p99 ms |
|---|---|---:|---:|---:|---:|---:|---:|
| io_uring | B | 14.74 (14.64-14.75) | 15.15 (15.12-15.21) | 0.92 (0.91-0.92) | 0.94 (0.94-0.94) | 1.43 (1.43-1.44) | 1.52 (1.48-1.56) |
| io_uring | C | 80.39 (80.09-81.27) | 83.11 (82.83-84.15) | 4.99 (4.97-5.03) | 5.18 (5.16-5.21) | 10.89 (10.85-11.19) | 11.42 (11.33-11.44) |
| epoll | B | 18.86 (18.70-18.90) | 20.04 (19.21-20.41) | 1.21 (1.20-1.21) | 1.26 (1.21-1.27) | 1.71 (1.69-1.73) | 1.96 (1.79-2.16) |
| epoll | C | 84.17 (81.67-84.72) | 88.07 (85.11-89.80) | 5.18 (4.97-5.22) | 5.32 (5.23-5.51) | 10.29 (10.06-10.64) | 11.25 (10.65-11.85) |

CPU per request rises beyond the ranges by 2.82%/3.38% on io_uring B/C and
6.24%/4.63% on epoll B/C. Their p99 rises beyond the ranges by 6.29%/4.87% and
14.62%/9.33%, respectively. p50 also rises beyond the ranges except on epoll B.
No other saturation CPU or latency metric loses beyond the ranges.

### Uploads and reads beside uploads

The REST commands above include step 2's uploads alone and beside forms. Medians
with ranges; RSS is the peak per run, in MB:

| Loop | Load | x uploads/s | m uploads/s | x forms req/s | m forms req/s | x peak RSS MB | m peak RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|
| io_uring | uploads alone | 1,095 (1,086-1,114) | 1,080 (1,065-1,089) | | | 103.77 (103.59-103.94) | 70.34 (70.24-70.46) |
| io_uring | beside forms | 154 (150-157) | 154 (149-159) | 6,851 (6,808-6,903) | 6,957 (6,808-7,008) | 162.93 (162.31-163.56) | 124.52 (124.44-125.84) |
| epoll | uploads alone | 1,088 (1,064-1,089) | 1,076 (1,059-1,085) | | | 102.18 (102.01-102.71) | 68.92 (68.80-68.99) |
| epoll | beside forms | 111 (109-114) | 112 (110-114) | 6,987 (6,912-7,124) | 7,147 (7,035-7,166) | 172.14 (171.08-173.09) | 131.73 (130.69-132.44) |

Uploads alone lose 1.40% on io_uring and 1.06% on epoll, within overlapping
ranges. Upload and forms rates beside each other overlap, as do their latency
ranges except epoll forms p99, which improves. Peak RSS is lower beyond the ranges
for both upload roles on both loops.

Step 4 offers tier C's reads at 16,000/s through zrk 2.3.0, split over six routes,
alone and beside uploads. Each route has one zrk process, pinned to CPUs 4-15;
the tier-C allocation uses 254 connections and 11 threads across those processes
(integer shares of the harness's 256-connection and 12-thread budgets, with a
minimum of 8 connections and 1 thread per route). Beside reads, wrk uses 1 thread
and 32 upload connections. Both builds reach the offered rate with zero errors.
Medians with ranges, from three 15 s runs after 5 s of warm-up:

| Loop | Reads | x CPU us/req | m CPU us/req | x uploads/s | m uploads/s | x peak RSS MB | m peak RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|
| io_uring | alone | 93.47 (92.78-94.40) | 95.94 (95.50-96.19) | | | 103.95 (103.73-103.98) | 70.26 (70.10-70.51) |
| io_uring | beside uploads | 250.39 (250.31-251.07) | 251.13 (251.12-251.52) | 681 (670-704) | 642 (625-663) | 103.89 (103.32-104.12) | 70.42 (70.38-70.53) |
| epoll | alone | 92.15 (91.94-92.84) | 95.09 (94.88-95.29) | | | 102.55 (101.94-102.61) | 68.80 (68.79-69.09) |
| epoll | beside uploads | 252.47 (251.39-252.82) | 252.85 (252.62-253.24) | 668 (626-676) | 654 (649-680) | 102.63 (102.41-102.72) | 68.80 (68.66-68.88) |

Read-only CPU cost rises beyond the ranges by 2.65% on io_uring and 3.19% on
epoll. io_uring uploads beside reads lose 5.80% beyond the ranges; epoll loses
2.02%, within overlapping ranges. Mixed CPU cost includes both reads and uploads,
divided by read requests, so it is not the CPU cost of a read alone. Its increase
is 0.30% on io_uring, beyond narrowly separate ranges, and 0.15% on epoll, within
the ranges.

Read p99 beside uploads ranges over all routes and runs from 9.22-16.44 ms at x
to 8.47-17.96 ms at m on io_uring, and from 1.60-4.11 ms to 1.80-2.62 ms on
epoll. Every route's individual ranges overlap. Reads alone also overlap except
epoll's history route: median p99 rises from 0.790 ms (0.786-0.811) to 0.816 ms
(0.815-0.914), 3.29%, with narrowly separate ranges. Its 0.026 ms median loss is
recorded rather than treated as a broad latency regression. Epoll's shifts route
improves beyond the ranges. All route-level results remain in the two summaries.

The results do not meet the original expectation that every REST rate remain
within run spread. The measured losses are accepted for the current summary
(2026-10-14); no code was fixed or reverted. Task 033 attributed them to a hot
loop's placement, not to an API change.

Release validation after measurement (2026-10-14): `GOOSE=<Linux compiler>
scripts/test.sh` passes in WSL Ubuntu, including io_uring, its epoll fallback,
epoll, echo, and the examples. `GOOSE=<Windows compiler> nice -n 19
scripts/test.sh` passes in Git Bash, including IOCP, echo, and the examples.
Both compilers are built from Goose `46356c2`; no measured code changed between
the archived main build and validation. The full logs are retained as
[Linux validation](../bench/results/2026-10-14-rest-main/validation-linux.log) and
[Windows validation](../bench/results/2026-10-14-rest-main/validation-windows.log).

## 2026-10-14: main after tasks 022.03, 025, and 027

The field run uses server `e4f7b55` and Goose `0bdbd18`, before the final worker-load
and shared-store merges. Its raw throughput tables remain in the linked summaries;
the current [benchmarks](benchmarks.md) name the later Goose builds separately.

### Plaintext and JSON

`bench/run.sh` with `SERVERS="goose goose-uring libreactorng vanilla-io_uring zix
xitca-web tokio hyper" WORKER_COUNTS=4 LATENCY=0`: 4 workers, wrk 4.1.0 with 8 threads,
3 runs of 15 s after 5 s of warm-up. Plaintext uses 16-deep pipelines at 256, 1,024,
and 4,096 connections; JSON uses 256 and 1,024 without pipelining.
[Summary](../bench/results/2026-10-14-field/summary.md).

`RUNS=3 bench/count.sh` uses one worker and 10 million requests to compare executed
user instructions with `2afc12f`, rebuilt at the same Goose pin. Task 027 records
the comparisons and unresolved benchmark checks.

### REST APIs

`bench/rest.sh build`, then `bench/rest.sh run` with
`SERVERS="goose-uring goose-epoll xitca-web hyper tokio dusty"`: 4 workers, 3 rounds of
15 s after 5 s of warm-up, with each server checked first. Saturation uses wrk with
8 threads and 256 connections. Uploads alone use 1 thread and 32 connections;
the mixed run offers tier C reads at 16,000 requests per second beside uploads.
[Field summary](../bench/results/2026-10-14-rest-field/summary.md).

The later task 025 comparison uses Goose `46356c2` and variant
`goose-uring-27s` at `effcd47`, on the same machine and kernel with the same load
settings. It records the final store and worker-load memory reduction:
[variant summary](../bench/results/2026-10-14-rest-027-025/summary.md).
Its `env.txt` names the orchestration checkout as modified; task 025 identifies
each variant's source commit. The final epoll peak memory has not been remeasured.

Idle memory at `1818526`, Goose `46356c2`, uses the epoll loop, 1, 2, and 4 workers,
one sample of VmRSS 3 s after listening, with no requests:
[idle.tsv](../bench/results/2026-10-14-rest-idle-main/idle.tsv).
Task 025 records the measurement and its remaining accounting work.

## The full field

The earlier desktop matrix at `73dd28c`, Goose `6448f3f`, kernel 6.18.40.1, includes
servers absent from the later field: zeemo, vanilla-epoll, may-minihttp, and Tina.
`bench/run.sh` used 1 and 4 workers, wrk with 8 threads, the same plaintext and JSON
connection counts as above, 3 runs of 15 s, and h2load latency measurements.
[2026-10-12 matrix](../bench/results/2026-10-12-matrix/summary.md).

Some competitor cells were copied with `REUSE` from compatible earlier runs. Their
source appears in the summaries. Session drift reached 5%, so small cross-session
differences do not establish a server improvement. vanilla-epoll's JSON cells were
not rerun because they leaked enough memory to exhaust the VM; those entries are
older measurements.

## Static files

`bench/files.sh` on 2026-10-12, server `fcfd80d`, Goose `5c83a5a`, desktop kernel
6.18.40.1: files on tmpfs, wrk 4.1.0 with 12 threads on CPUs 4-15 and 96 connections;
1 worker on CPU 0 or 4 on CPUs 0-3; 3 runs of 10 s after 3 s of warm-up, medians.
[Summary](../bench/results/2026-10-12-files/summary.md) includes rates, spread, and CPU.

nginx 1.28.3 uses `sendfile`, `tcp_nopush`, `open_file_cache`, and no access log.
Caddy 2.10.2 uses `file_server` and `GOMAXPROCS` equal to the worker count.
At 1 MB with 4 workers, wrk uses all its assigned CPU time: rate measures the client
limit, while server CPU per request still distinguishes the implementations.

Server CPU per request, in µs:

| Server | 4 KB, 1 worker | 4 KB, 4 | 64 KB, 1 | 64 KB, 4 | 1 MB, 1 | 1 MB, 4 |
|---|---:|---:|---:|---:|---:|---:|
| Goose io_uring | 12.3 | 18.5 | 31.6 | 41.1 | 96.3 | 122 |
| Goose epoll | 18.1 | 22.7 | 29.7 | 35.8 | 91.5 | 106 |
| Goose, emulated ring | 13.2 | 19.7 | 22.8 | 33.8 | 85.7 | 107 |
| nginx | 20.2 | 23.4 | 28.6 | 32.5 | 106.8 | 148 |
| Caddy | 77.7 | 81.0 | 79.9 | 84.1 | 155.9 | 197 |

The direct-file threshold and Windows `TransmitFile` comparison are recorded in
task 020. The unexplained 64 KB gap to nginx remains task 024. The same summary
records Goose's in-memory `/bytes` comparison, which separates file handling from
response transmission.

<a id="rest-apis"></a>
<a id="rest-apis-1"></a>
## Earlier REST comparisons

The 2026-10-13 desktop field at `23aa531`, Goose `6448f3f`, kernel 6.18.40.1,
used `bench/rest.sh run`: 4 workers, 8 client threads and 256 connections for
saturation, 3 rounds of 15 s after 5 s of warm-up.
[Summary](../bench/results/2026-10-13-rest/summary.md).
[Fixed-rate rerun](../bench/results/2026-10-13-rest-rates/summary.md).

dusty joined in a separate comparison with hyper and task 027's Goose variants:
[2026-10-13 REST variants](../bench/results/2026-10-13-rest-027/summary.md).
Session drift means its results should first be compared with hyper from that run.
Task 021 records the workloads, competitor exclusions, and the epoll fairness
decision. Tasks 025 and 027 retain the before/after evidence for their changes.

## Instructions per request

The earlier cross-server instruction comparison uses `bench/instructions.sh` on
2026-10-12, server `47876ad`, desktop kernel 6.18.40.1: one worker on CPU 0,
plaintext pipelined 16 deep at 256 connections, wrk with 8 threads on CPUs 4-15 for
20 s, and perf on CPU 0 for 10 s from 5 s into the run; 3 runs. Counts include
kernel network work on that CPU.
[Raw counts](../bench/results/2026-10-12-desktop-instructions/runs.tsv).

Tina's comparison and interpretation are retained in task 019. Fixed-count user
instruction comparisons for current API changes belong to task 027; their totals
are not interchangeable with these CPU-wide counts.

## HttpArena's profiles

[HttpArena](https://www.http-arena.com/)'s own harness at `0720ee5`, run by
`bench/httparena.sh run` under Docker Desktop 29.8.2 on 2026-10-12: each server's
container on CPUs 0-3, gcannon `11c802b` on CPUs 4-15 with 4 threads, the best of 3 runs
of 5 s per profile, and latency-1m at 200,000 requests per second instead of 1,000,000.
The script's header lists what else it changes in the checkout. The Goose entry is the
epoll loop, since Docker's default seccomp profile blocks io_uring, at `1a1f368` with
Goose `5c83a5a`; `env.txt` says "(modified)" for an edit to this file. Results in
[bench/results/httparena-2026-10-12-full](../bench/results/httparena-2026-10-12-full).

| Profile | Goose | tokio | vanilla-epoll | dusty |
|---|---:|---:|---:|---:|
| baseline (mixed GET and POST), req/s | 524K | 508K | 478K | 423K |
| limited-conn (10 requests per connection), req/s | 311K | 316K | 308K | 352K |
| pipelined, req/s | 7.39M | 6.72M | 7.18M | 0.59M |
| latency-1m, CPU per request | 10.58 µs | 10.71 µs | 11.00 µs | 14.64 µs |
| latency-1m, p99 | 230 µs | 159 µs | 176 µs | 181 µs |
| baseline, container memory | 34 MiB | 175 MiB | 76 MiB | 161 MiB |

Memory and CPU here are the container's, socket buffers included, so they compare
containers, not processes. The servers used 232-362% of their 400% CPU in baseline,
limited-conn, and pipelined, so those profiles measure gcannon as much as the servers.
latency-1m's p99 moved by up to 15 times between runs on 2026-10-11, so it ranks the
servers only roughly.

Task 018's two profiles, run the same way on 2026-10-12 with the Goose entry at
`4752493` and Goose `6448f3f`, after `bench/httparena.sh validate` passed all 32 of its
checks: async, `GET /delay/10` on 32,000 connections, and latency-10k, latency-1m's
endpoint offered at 10,000 requests per second by zrk 2.3.0 for 20 s. Results in
[bench/results/httparena-2026-10-12-async](../bench/results/httparena-2026-10-12-async).
Latency is the best run's.

| Profile | Goose | tokio | vanilla-epoll | dusty |
|---|---:|---:|---:|---:|
| async, req/s | **241K** | 228K | 196K | 226K |
| async, p50 / p99 | 56 / 99 ms | 61 / 87 ms | 90 / 116 ms | 13 / 216 ms |
| async, container memory | **159 MiB** | 1.1 GiB | 401 MiB | 662 MiB |
| latency-10k, CPU per request | 30.4 µs | 30.6 µs | **30.0 µs** | 42.8 µs |
| latency-10k, p99 / p99.9 | 172 µs / 8.3 ms | 158 µs / 10.8 ms | 166 µs / 16.4 ms | 158 µs / 1.2 ms |
| latency-10k, container memory | **15 MiB** | 42 MiB | 26 MiB | 46 MiB |

- async's 3 runs per server spread by 7-16%: Goose 221-241K, tokio 212-228K,
  vanilla-epoll 180-196K, dusty 193-226K. Each server used 320-343% of its 400% CPU.
- gcannon ran 64 threads in async, not `THREADS`, and counted 38,000-48,000 connect
  errors per run for every server, likely because `SKIP_TUNE` leaves out the
  harness's `system_tune`, which widens the ephemeral port range; not measured.
- dusty answers half its delays at 13 ms and the slowest at 216 ms; the others keep
  p50 and p99 within 2 times of each other.
- At 10,000 requests per second, the four spend 3 times latency-1m's CPU per request:
  each request wakes an idle loop. Goose, tokio, and vanilla-epoll are within 2%.


## M1 Pro, Linux in Docker

The host is a MacBook Pro `MacBookPro18,3`, Apple M1 Pro with 8 performance and
2 efficiency cores, macOS 26.3.1. Docker Desktop 29.8.2 supplies a 10-CPU, 8 GB VM,
kernel 7.0.14-linuxkit, running Ubuntu 26.04 with gcc 15.2.0, rustc 1.99.0,
wrk 4.1.0, and h2load 1.68.0.

The partial field at server `9623c6a`, Goose `efe3155`, used:

```sh
MACHINE=m1pro-docker SERVERS="goose goose-uring may-minihttp hyper tokio xitca-web" \
    WORKER_COUNTS=4 SERVER_CPUS=0-3 CLIENT_CPUS=4-9 CLIENT_THREADS=8 \
    RUNS=3 DURATION=10 WARMUP=3 TESTS="plaintext:256 plaintext:1024 json:256" bench/run.sh
```

[2026-10-11 summary](../bench/results/2026-10-11-m1pro-docker/summary.md).
wrk was near its CPU limit in the fastest cells. Transparent huge pages dominated
Goose's RSS, so it cannot be compared directly with desktop RSS.

The fuller arm64 field at `b2e0337`, Goose `efe3155`, used 3 workers on CPUs 0-2
and 8 client threads on CPUs 3-9, 3 runs of 10 s after 3 s of warm-up:
[plaintext](../bench/results/2026-10-11-m1pro-docker-3w-plaintext/summary.md) and
[JSON](../bench/results/2026-10-11-m1pro-docker-3w-json/summary.md).
JSON omitted vanilla-epoll because its memory growth exceeded the VM's capacity.
Copied competitor rows carry session drift; task 012 retains the open full-matrix
validation. These results are historical platform checks, not current-build rankings.

HttpArena `0720ee5` on the same VM used server `16528ea`, Goose `efe3155`, and the
epoll entry: `bench/httparena.sh run`, 3 workers on CPUs 0-2, gcannon `11c802b` with
4 threads on CPUs 3-9, best of 3 runs of 5 s; latency-1m offered 200,000 requests per
second. Every entry passed validation.
[Profile records](../bench/results/httparena-2026-10-11-m1pro-docker).
The clients also constrained these profiles. Memory includes socket buffers and
transparent huge pages, so it compares containers on this VM only.

## M1 Pro, macOS native

`bench/run-macos.sh` on 2026-10-11 used server `9623c6a` on the same M1 Pro host,
macOS 26.3.1, Darwin 25.3.0: 4 workers per server,
wrk 4.2.0 with 4 threads, 256 and 1,024 plaintext connections pipelined 16 deep,
256 JSON connections, 3 runs of 10 s after 3 s of warm-up. Nothing was pinned;
the machine was on AC power under `caffeinate -i`, with listen backlog cap 128.
[Raw runs](../bench/results/2026-10-11-m1pro-native/runs.tsv).

All servers were near the same loopback round-trip limit. Adding workers did not
raise JSON throughput; two independent server/client pairs shared the same total
capacity. These runs show native operation and memory use, not a reliable ranking
of server implementations. Task 012 records the profile and shared-listener work.

## Windows, IOCP

Task 017's baseline records `bench/oha.sh` on both Windows and WSL2 at `fcfd80d`,
Goose `5c83a5a`, desktop kernel 6.18.40.1: oha 1.16.0, 2 million plaintext requests,
256 connections, 1 and 4 workers, 3 runs, with no CPU pinning. The client shares CPUs
with the server, so the comparison does not isolate server capacity.
[IOCP runs](../bench/results/2026-10-12-iocp-plaintext) and
[io_uring runs](../bench/results/2026-10-12-uring-plaintext-oha).
The kernel trace analysis and candidate evaluation remain open in task 017.
