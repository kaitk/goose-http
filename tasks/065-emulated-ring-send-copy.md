# 065: Avoid copying immediately accepted large sends

Status: in-progress

The readiness-based ring can submit a large buffer during the extern call and own
only its unsent tail. Small sends remain queued, and all completions remain deferred.

## Acceptance criteria

- [x] No Goose argument survives the extern call; queued sends and files retain order.
- [x] Full/partial sends, EAGAIN, EINTR/errors, allocation failure, close and completion
  overflow pass deterministic tests, including the 16 KB boundary and empty sends.
- [x] Sanitizers, the 60 package tests at both optimization levels, and both Linux
  loops' stalled-reader, disconnect-reuse and publisher-fairness tests pass.
- [x] Record individual application and plaintext samples, including adverse results.
- [ ] Resolve or characterize the remaining plaintext throughput difference before landing.
- [x] Validate the shared emulation on macOS; native io_uring and Windows are unchanged.
  On macOS 26.3.1 with Apple clang 21 (2026-10-23), `scripts/test.sh` passed, including
  `test-http.sh`'s large and stream runs on the ring emulated over kqueue, and
  `ring_send.c` passed under `-fsanitize=address,undefined`.
- [ ] Explain why 21 and 64 KiB responses lose 27% and 15% on the emulated ring (Ryzen
  5800X3D, WSL2, 2026-10-23), against the +7.6% on Campfire's pages.

The all-size attempt reduces application CPU cost but loses 25.5% median throughput
in pipelined plaintext. A 16 KB floor restores user-cycle cost close to baseline,
but its six-sample plaintext median remains 8.5% lower. This is a review candidate,
not a demonstrated win across workloads: on the desktop, the emulated ring loses 27-29% at
21 KiB and 15% at 64 KiB, while it reads pipelined plaintext's difference as noise
(an A/A control of the base differs by 2.5%). The
[measurement record](../docs/results.md#2026-10-22-the-emulated-ring-sends-large-writes-without-a-copy)
has the machine, commands, compiler pins, medians and ranges, and limitations.
