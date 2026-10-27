# Agent rules

This file holds what every session needs. `agents/` holds the rules for particular work:
read the file a task touches before starting it.

## Project context

- What this is: `README.md`; what each tag adds: `CHANGELOG.md`; the API by topic:
  `docs/api.md`; which approach fits bodies, responses, and slow work:
  `docs/patterns.md`; and the examples: `examples/README.md`
- Architecture decisions, dated, with their reasons: `docs/decisions.md`; how the
  package works, and what isn't Goose: `docs/architecture.md`
- Layout, the Goose release, toolchain, and local setup: `docs/development.md`
- Environment traps and incidents, by platform: `docs/known-issues.md`
- What `extern fn` looks like from C, for the shim: `docs/c-interop.md`
- Goose compiler and stdlib gaps found here: `docs/goose-findings.md`
- Task tracking: `tasks/` (see `tasks/README.md`)
- The language: the pinned Goose release's `docs/tutorial.md`, `docs/goose_spec.md`,
  and `docs/stdlib.md`. Read the tutorial before writing Goose; check the spec before
  assuming a feature exists.
- Rules for particular work: `agents/goose.md` (writing Goose, and recording what it
  lacks), `agents/writing.md` (docs, tasks, and prose reviews), `agents/pins.md`
  (moving the Goose pin), and `agents/benchmarks.md` (measuring, and reporting a number)

Follow the recorded decisions; if a change contradicts one, update the doc in the same
change or ask first. Record setup facts you find (paths, versions, install steps) in
`docs/development.md`, and environment traps (shell quirks, ports, encodings, dated
incidents) in `docs/known-issues.md`, not in agent memory, so the next agent finds
them. Docs and commits don't credit a decision or a request to a person, as in
"Kait asked": date it (`(2026-10-11)`). A name goes only where one belongs, such as
a copyright line or another project's author. Describe the setup without anyone's machine, checkouts, or home
directory. What only one machine needs, such as where its Goose checkout is, goes in
`CLAUDE.local.md`, which git ignores. Benchmark results still name their machine. The
docs and scripts must work for a developer on a clean machine without LLM tools:
`CLAUDE.local.md` holds conveniences, never a step the setup needs, and a script fetches
what it needs or says how to get it, rather than assume a sibling checkout (2026-10-15).

## Keep changes small

Agreed 2026-10-20, after several fixes solved problems that a second look showed
weren't there.

- Meet the requirement's intent with the least machinery. Before building around an
  obstacle, ask whether the requirement needs it at all.
- When a fix starts to need a new public API, a change in another repository, or a
  workaround, stop. Say so in a sentence or two, and propose the simpler reading of the
  requirement.
- A feature's cost falls on the programs that use it: no fields in shared structs such
  as `Reply`, `Config`, or a loop's connection, and no code on the request path, for
  one feature.
- When a design makes other code compensate (a fallback, a rescan, a special case
  elsewhere), change the design rather than add the compensation.
- Add a setting, a check, or a script option only for a failure that isn't visible
  already. The server's startup line names an emulated ring, so the benchmark scripts
  need no setting that enforces io_uring.

## Working beside other agents

Several agents work in these repositories at once (2026-10-20).

- Work in a worktree of your own, on a branch from `origin/main`:
  `git worktree add ../goose-http-<topic> -b <topic> origin/main`. Remove it once the
  branch is merged.
- Leave alone a branch, a commit, or an uncommitted change that isn't yours, in any
  checkout. Ask if it's in your way.
- `restart-workers` is an experiment not pursued now: don't update, rebase, or merge
  it, and don't treat its commits as pending work (2026-10-21,
  [decision](docs/decisions.md#a-crash-ends-the-process-and-a-service-manager-restarts-it)).
- Keep logs, exports, and scratch files in a directory of your own: a session's
  scratchpad may be shared by several agents.
- Problems with your own sandbox, such as no network or no SSH, go in your report,
  not in the docs.

## Goose

- Build with the official Goose release that `scripts/goose.sh` pins. Check for a newer
  one at the start of a session (`agents/pins.md`).
- Don't edit a Goose checkout. Work around a compiler or stdlib gap here, record it in
  `docs/goose-findings.md` as `agents/goose.md` says, and report blockers to the
  maintainer.
- C is for what Goose can't reach: syscalls and kernel structures, behind thin functions
  in `shim/`. HTTP parsing, routing, response building, and JSON are Goose, since
  measuring Goose is the point. Where a profile shows Goose blocking a cost with no clear
  Goose workaround, a thin C function may do that one thing until Goose can, with the gap
  in `docs/goose-findings.md` ([decision](docs/decisions.md#c-where-goose-blocks-a-measured-cost-until-goose-has-a-way),
  2026-10-24).

## Code conventions

- Comment only where the code is hard to follow without it, and say only what a reader
  of that code needs: why, a constraint, or a contract the code can't show. Don't restate
  the next line, and don't describe earlier versions or the task that added the code;
  history belongs in git.
- Edit files with the Edit tool, not with `sed` or a Python or PowerShell script. On
  Windows, line endings differ by file type, Python defaults can write cp1252 and CRLF,
  and a shell adds a layer of escaping, and scripted edits break on all three. The Edit
  tool keeps each file's endings and needs no escaping (`docs/known-issues.md`, "Line
  endings on Windows").
- An `extern fn` whose C side keeps or writes more than the spec's default (§7.10) says
  so in a comment.
- Tests follow Goose's own convention: a top-level `test/` by area, each test a small
  program whose printed output a golden file in `test/expected/` checks, `// error:`
  fixtures for code that must not compile, and a runner that batches them with
  `goose --multi-test` ([decisions](docs/decisions.md#tests-follow-gooses-convention),
  2026-10-15).

## Running commands

- Never edit a script while it runs: Bash reads later commands from the file as it
  executes, and an edit to a benchmark script during its builds ended the run with an
  unexpected EOF before measurement began (2026-10-14). Write a separate script for an
  extension.
- Kill a process by its PID, never by pattern: `pkill -f` inside `bash -c` can match
  and kill that shell, and killing strace doesn't kill the server it started
  (`docs/known-issues.md`, "WSL from a Windows shell").

## Commits

- Push finished work to `main` once its tests pass, even when its benchmarks are still
  to run: record the pending check in its task, and add the results when they come. A
  change whose benchmarks then show a cost is reverted on `main` with an inverse commit
  (2026-10-14). Work branches are for work that isn't finished.
- One lean sentence in imperative mood, at most 72 characters.
- No body, no `Co-Authored-By` or any other trailers.
