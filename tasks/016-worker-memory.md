# 016: What each worker commits

Status: in-progress (asked for 2026-10-12)

The Goose maintainer, shown the server's peak RSS, remarked that its workers commit some
memory, though not much (2026-10-12). Nothing here says where a worker's memory goes.
The numbers so far are totals: in `bench/instructions.sh`'s runs with one worker, the
epoll build peaks at 2.2-2.4 MB and the io_uring build at 5.0-5.4 MB (task 013, at
`28c478c`), and in the 4-worker matrix the io_uring build reached 12.4 MB with JSON at
1,024 connections (task 013, `bench/results/2026-10-12-night/`). After task 013's
100 MB streaming tests, peak RSS was 2.7 MB for epoll and 8.5 MB for io_uring.

Account for a worker's committed memory by source, then shrink what can be shrunk
without costing requests per second. Sources to measure, per worker:

- The thread itself: the stack `thread_spawn` gives it, and what the Goose runtime
  allocates per thread.
- glibc's malloc arena for the thread, and what stays committed in it after a burst
  (the spill pool, a grown `wbuf`, the connection slots).
- The read buffer (`Config.max_head`), the write buffer, the spill pool, and the
  connection slots, which grow with the connections a worker holds and never shrink.
- io_uring: the submission and completion rings (`Config.ring_entries`), the provided
  buffers (`ring_buffers` × `ring_buffer_size`, 1 MB by default), and `shim/uring.c`'s
  cache of freed send records, up to 4 MB a ring.
- The emulated ring (`shim/ring_epoll.c`) and IOCP (`shim/iocp.c`), which keep their
  own records.

Ask the maintainer which of the runtime's per-thread commits the remark meant, before
changing anything on the Goose side: that would be a finding for `docs/goose-findings.md`,
not a change here.

## Acceptance criteria

- [ ] A table of each worker's committed memory by source, for both loops on Linux,
      idle, after `bench/run.sh`'s largest plaintext cell, and after the streaming
      tests, with how each number was measured (`/proc/PID/smaps`, or allocator
      statistics)
- [ ] Each source that can shrink without costing requests per second does, measured
      with `bench/run.sh`'s cells or `bench/count.sh`, or is recorded as kept, with
      the reason
- [ ] What the maintainer's remark referred to, and whether anything on the Goose side
      is worth a finding

## Where a worker's memory goes (2026-10-12)

Measured at `ef09c0f` with Goose `5c83a5a`, one worker (`WORKERS=1`), each cell 8 s of
wrk 4.1.0 with 4 threads, plaintext pipelined 16 deep, one run. Linux numbers are
`Rss` from `/proc/PID/smaps`, sorted by mapping, in Docker Desktop's Linux VM on an
M1 Pro (Ubuntu 26.04 image, kernel 7.0.14-linuxkit, 10 CPUs, gcc 15, run with
`--security-opt seccomp=unconfined` so io_uring works). That VM runs transparent huge
pages set to `always`; "THP off" runs the server under `PR_SET_THP_DISABLE`. The
streaming tests aren't measured yet.

| Linux, KB | epoll, THP | epoll, THP off | io_uring, THP | io_uring, THP off |
|---|---|---|---|---|
| Idle, total RSS | 7,904 | 1,800 | 6,380 | 2,308 |
| Data stacks, idle | 4,172 | 76 | 2,124 | 84 |
| Data stacks, after 4,096 connections | 4,716 | 660 | 6,808 | 684 |
| malloc thread arena, after load | 2,048 | 28 | 4,096 | 2,940 |
| io_uring rings | | | 516 | 516 |
| After plaintext at 4,096, total RSS | 8,456 | 2,388 | 13,112 | 5,816 |

The rest of each total is the binary and libraries' pages (about 1.6 MB) and the thread
stack (12 KB of its 8 MB).

- **Data stacks.** A worker holds 12 (epoll) or 13 (io_uring) of the runtime's 2 GB
  reservations, committed on first touch and never given back (`goose --stacks`). With
  4 KB pages they hold 76-84 KB idle. One stack, the connection slots, grows by about
  130 bytes a connection, to 544-584 KB at 4,096 connections. With huge pages, any
  stack could take 2 MB for its first byte, until Goose `0bdbd18` kept huge pages off
  each stack's first 2 MB.
- **Thread arena.** glibc's arena for the worker. On io_uring it holds the 1 MB of
  provided buffers (`ring_buffers` × `ring_buffer_size`), which the kernel writes in
  full, and the send records: one for each send in flight, kept on free lists.
- **io_uring rings.** 4,096 submission entries and 16,384 completions, 516 KB.
- **Runtime per thread.** A 64 KB signal stack (malloc) and a copy of the arguments and
  globals. Both are small next to the above.

On macOS (kqueue, `vmmap` dirty pages, 16 KB pages), the epoll loop's worker holds
192 KB of data stacks idle and 512 KB after 4,096 connections. The emulated ring's
malloc grows to 2.1 MB, its provided buffers and send records.

### Send records in size classes

The ring shims gave every send of up to 8 KB an 8 KB record, so each send in flight kept
a page or two committed for a 150-byte JSON response. `shim/uring.c` and
`shim/ring_epoll.c` now keep records in six power-of-two classes from 256 bytes to
8 KB, each with its own free list. Same Docker VM, io_uring, one worker, THP off,
3 alternating runs of 6 s (after 2 s of warmup):

| Cell | Thread arena, before | after | Peak RSS, before | after |
|---|---|---|---|---|
| json, 1,024 connections | 2,144-2,640 KB | 1,140-1,160 KB | 4,604-5,096 KB | 3,600-3,612 KB |
| json, 256 | 1,588-2,048 KB | 1,088-1,128 KB | 3,916-4,392 KB | 3,440-3,476 KB |
| plaintext, 1,024 | 2,624-2,972 KB | 2,104-2,592 KB | 5,084-5,428 KB | 4,564-5,052 KB |
| plaintext, 256 | 2,116-2,480 KB | 1,768-2,024 KB | 4,460-4,824 KB | 4,108-4,372 KB |

Requests per second stayed within the runs' spread (plaintext 2.90-3.20 M against
2.93-3.19 M, JSON 271-303 K against 270-306 K). That VM shares its CPUs with macOS, so
the rate still needs `bench/count.sh` or `bench/run.sh` on the WSL2 machine.
`scripts/test.sh` passes on macOS and in the Docker VM, all three Linux loops.

`shim/iocp.c` has the same classes, and keeps big records up to 4 MB as the other shims
do (2026-10-12). `scripts/test.sh` passes in Git Bash, where the stream run's peak
working set was 8,468 KB; its rate isn't measured yet.

### Still to do

- Confirm on WSL2 that the size classes cost no instructions (`bench/count.sh`), and
  record which THP mode the WSL2 kernel uses.
- Measure a worker again where transparent huge pages are `always`, now that Goose
  `0bdbd18` keeps them off each data stack's first 2 MB. The package doesn't set
  `PR_SET_THP_DISABLE` (decided 2026-10-12): it would apply to the whole program, the
  program's own memory included.
- Done in task 065 (2026-10-24): 64 provided buffers, 256 KiB a worker, measured at
  the same rate on Linux.
- The table after the streaming tests.

### The maintainer's remark

The remark ("workers do some memory committing but not that bad apparently") isn't in
the Goose repository's issues or pull requests. Read against the runtime, "committing"
fits the data stacks: each worker reserves 12-13 of them, and each keeps every page it
has touched. With 4 KB pages that costs well under 1 MB a worker, which fits "not that
bad". With huge pages it doesn't: up to 2 MB a stack. Still to ask the maintainer
whether that is what they meant.
