# 065: A worker's floor, and timers on time

Status: in-progress (asked for 2026-10-24, from Plod's task 061)

Plod's first HttpArena run (2026-10-23, 64 threads) matched viltrum's rate on every
profile but async, and held 240 to 300 MiB at 1,024 connections or fewer, against
viltrum's 56 to 80. Plod's task 061 has the run and the comparison. Two causes are
goose-http's:

- **A worker's floor.** About 3.7 MiB a worker whatever the connections: tables sized
  for the most a worker could hold, touched at startup, and the provided buffers,
  which the kernel cycles through in full.
- **Late timers.** The loops' clock was the coarse one, up to a scheduler tick old, so
  `/delay/10` answered 2 ms late with the CPUs idle. async is closed-loop on
  `/delay/10` at 32,000 connections, so lateness alone sets its rate.

HttpArena's standard mode holds an entry to its framework's defaults, so these are
fixed in the defaults and the design, not in the entry's `Config`.

## Measured (2026-10-24)

Ryzen 7 5800X3D, 16 threads, Ubuntu in WSL2 (kernel 6.18.54.1, `HZ=250`), Goose
`v2026.3`. Workers pinned with `taskset` to CPUs 0-7, wrk 4.1.0 on 8-15. `VmRSS` and
`smaps` from `/proc`. One run per cell unless the table says otherwise.

Plod's entry at `v0.5.4` (goose-http `v0.5.8`), per worker:

| Source | Idle | Under load |
|---|---:|---:|
| Timer table, `max_waiting` 16,384, every cell written at open | ~640 KiB | |
| The box's live keys, 16,384, each stored 0 after `calloc` | ~120 KiB | |
| io_uring rings, 4,096 entries | 260 KiB | |
| Provided buffers, 256 of 4 KiB | | 1 MiB |
| glibc's thread arena | | 170-220 KiB |

goose-http's server (`server/server.goose`, `http`, 8 workers, `MAIL_SLOTS=256`,
`MAX_WAITING=16384`), `origin/main` at `c09ab76b` against this branch, two
alternating rounds of 5 s per cell, wrk on `/delay/10`:

| Loop | Build | Idle RSS | 64 connections, p50 / p99 | 4,000 connections, average |
|---|---|---:|---|---|
| io_uring | main | 16.5 MiB | 12.17 / 16.31 ms, 12.19 / 12.35 ms | 14.17, 12.03 ms |
| io_uring | branch | 9.7 MiB | 10.24 / 10.49 ms, 10.20 / 10.46 ms | 13.47, 13.33 ms |
| epoll | main | 12.3 MiB | 12.29 / 12.48 ms, 12.29 / 14.54 ms | 15.53, 15.68 ms |
| epoll | branch | 5.5 MiB | 10.27 / 10.59 ms, 10.27 / 10.61 ms | 12.46, 12.36 ms |

At 4,000 connections, lateness grows with connections (io_uring, branch: 0.6 ms at
500, 0.9 at 1,000, 1.6 at 2,000, 3.4 at 4,000) while the server uses 2.3 of its 8
CPUs and wrk 3.8 of its 8. The closed loop puts the connections in step, so each
worker answers its due exchanges in one pass, and the last waits for the pass. In
HttpArena both servers served about 56K async requests a second per CPU used, so
there Plod's gap was waiting, not work.

## Done on the branch `timers`

- `timer_table` adds cells as `arm` needs them, up to the capacity, reusing freed
  cells first; `mail_open` no longer stores 0 into each live key `calloc` zeroed.
- `net_clock_ms` reads `CLOCK_MONOTONIC` on Linux and `CLOCK_MONOTONIC_RAW` on macOS
  ([decision](../docs/decisions.md#timers-fall-due-by-the-precise-monotonic-clock)).

## Still to do

- The provided buffers: 64 and 128 against 256, with `bench/count.sh` and
  `bench/run.sh`'s pipelined cells, as task 016 asks before the default changes. A
  first check, in Plod's entry with 64 buffers and the smaller tables, served
  `/pipeline` 16 deep at 8.05-8.10M req/s against 8.07-8.10M, three alternating
  rounds, at 13.1 MiB against 28.4 MiB.
- The ring's 4,096 submission entries, measured the same way.
- HttpArena's async and a low-connection profile, before and after, with viltrum,
  through Plod's `bench/httparena.sh`.

## Acceptance criteria

- [ ] The branch's tests pass on Linux (`scripts/test.sh`), and it is on `main`
- [ ] `bench/count.sh` shows no instruction cost per request from the precise clock
- [ ] The provided buffers' and ring entries' defaults changed or kept, with the
      measurements
- [ ] Plod's task 061 has the before-and-after HttpArena numbers
