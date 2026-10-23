# Tasks

Markdown-based task tracking. One file per task, or one folder for a task with
several subtasks or its own supporting files.

## Naming

`NNN-short-slug.md` — zero-padded, sequential number plus a kebab-case slug,
e.g. `003-epoll-server.md`.

A task with subtasks or supporting files is a folder with the same name,
`NNN-short-slug/`, holding the task itself as `README.md` and one file per
subtask as `NN-short-slug.md`, numbered within the folder. Subtasks use the same format
as tasks.

## Format

```markdown
# NNN: Title

Status: todo | in-progress | done | cancelled

Short description of what and why.

## Acceptance criteria

- [ ] Concrete, verifiable outcome
- [ ] ...
```

Update the status line as work progresses; tick criteria as they are met. A cancelled task
says who cancelled it, when, and why. A task that measures something records the numbers
in its own file, with how they were measured.

## Archive

When a task is done and nothing still builds on its file, move it to `000-archive/` with
`git mv`, keeping its name. The main folder then lists only open work. Numbers stay
unique across both folders: pick the next number after the highest in either. Refer to
tasks by number ("task 008"), not by path, so a move breaks no reference.

Archived tasks describe the implementation and validation at completion. Use the
README, API reference, and architecture for current behavior, and the benchmark summary
for the latest accepted measurements. A pending measurement remains explicit even when
its implementation is already on `main`.

## Order

Next, in the order requested on 2026-10-14: task 032's shared benchmark harness, then
goose-rest's first benchmark run on the desktop. The HTTP changes it needs are on
`main`.

| Open work | Remaining outcome or dependency |
|---|---|
| 006: platform ports | Platform subtasks are done; the optional conditional-compilation goal remains unresolved. |
| 012: macOS benchmarks | Complete the Docker matrix; retain the platform and client limits. |
| 014: HTTP/2 and TLS | h2c serves from the epoll and io_uring loops (014.01), with a question open; HTTP/1.1 over TLS serves from the epoll and io_uring loops, passes HttpArena's validation, and is measured on json-tls and 8gbit (014.02, 2026-10-20). kTLS was retired (2026-10-22, goose-tls's task 007); h2 over TLS serves from both loops (task 061, 2026-10-22), and HttpArena's h2 profiles remain. |
| 016: worker memory | Finish source accounting, reductions, and the Goose-side question. |
| 017: IOCP speed | Read the kernel trace and evaluate candidates against the recorded baseline. |
| 022: compression | Record approval of the implemented boundary and finish outstanding platform validation. |
| 024: 64 KB files | Explain and measure the gap to nginx; recheck the threshold if paths change. |
| 025: REST memory | Finish source accounting and the sharing question; reporting awaits authorization. Reductions are on `main`. |
| 026: reads beside uploads | Measure and reduce completion-loop read latency without losing upload throughput. |
| 027: idiomatic API | Record the pending tier C templated benchmark recheck; API and examples are on `main`. |
| 029: embedded aarch64 | Validate on a board; emulated tests do not settle it. |
| 032: shared benchmark harness | Reuse one harness across scripts and document external server integration. |
| 034: Goose releases | goose-http and goose-rest build and pass from the release on every platform; goose-compress and our own packages remain. |
| 045: pinning | Done (2026-10-21): no layout beat floating on bare-metal Linux, so placement stays on the branch `placement`. |
| 046: placement and lanes | Placement stays off `main` (task 045); lanes are `http::Lane`. Group commit remains. |
| 048: packages spawn threads | On `main` on a pinned Goose commit; the README's quick start waits for a release. |
| 053: outbound connections | goose-postgres and the ACME package's HTTPS requests wait on it (goose-rest's task 047). |
| 054: WebSocket | Built and tested, Autobahn included; HttpArena's echo-ws benchmark runs remain. |
| 061: h2 over TLS | Serves from both loops, chosen by ALPN; HttpArena's baseline-h2 waits for goose-tls's own server, and static-h2 is deferred. |
| 062: io_uring's request cost | Since TLS on io_uring, plaintext `/api/me` costs +22 instructions there; explain it and remove it, or record why it stays. |
| 063: upgraded drain credits | Unix integration and request-cost checks; native io_uring, macOS, and Windows validation remain before release. |
| 065: emulated ring send copy | On the branch `send-copy`; an A/A control decides whether plaintext's 8.5% median loss is noise before it merges. |

Tasks 013 and 018 have completed acceptance criteria and are archived with the other
completed work. Compression subtasks stay with their open parent. Completed platform
subtasks stay with task 006 until its remaining goal is resolved.
