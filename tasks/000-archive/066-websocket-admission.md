# 066: WebSockets a worker admits

Status: done (found and finished 2026-10-24, from Plod's task 061). Built as proposed,
with `ws_admit` removed ([decision](../../docs/decisions.md#a-websocket-is-promised-its-bytes-while-it-holds-a-message)).

A WebSocket is promised its whole message limit and 131 bytes when it upgrades
(`ws_admit`, `websocket.goose`), and keeps the promise for its life
([decision](../../docs/decisions.md#the-gather-budget-counts-bytes-promised-and-refuses-at-admission)).
At the default limit, 64 KiB, and the default budget, 64 MiB, a worker admits about
1,021, and each one past that gets 503 at its upgrade.

The promise is rarely used. A frame that arrives whole is read from the read buffer,
and `ws.held` takes bytes only for a message in fragments or a frame split across
reads. So a worker's WebSockets are bounded by a worst case that nearly never happens
at once, not by its memory.

HttpArena's echo-ws at 16,384 connections shows it. On 4 workers (Plod's task 061,
2026-10-24) Plod served 1,824 messages a second, the rest of the connections refused
and reconnecting, where viltrum served 342,019. HttpArena's 64 workers admit 65,000,
so its leaderboard doesn't show the limit, but the connections a server holds at the
defaults depend on its worker count. A chat server, such as the Campfire workload on
goose-http, holds many idle WebSockets each.

## Proposal

Promise a WebSocket's bytes when `ws.held` first needs them, and give the promise back
when `ws.held` empties: at a message's first fragment, or at a frame that a read
leaves unfinished. A message the budget can't hold then closes the connection with
1013 (Try Again Later), the code RFC 6455's registry gives a server that is
overloaded, since after the upgrade there is no status to answer with.

What it changes from the decision:

- A refusal comes at a message, not at the upgrade. A client that sends one large
  message after hours of small ones could be closed then, where today it would have
  been refused at the start. That is the trade the decision rejected for bodies ("a
  count of the bytes in use, which grants a growth when it comes and so refuses it
  then"); for a WebSocket the refusal has a standard answer, which a body partway
  sent doesn't.
- Nothing admitted fails partway through a message: the promise is still the whole
  limit, taken before the message's first byte is held.

## Measured (2026-10-24)

Plod's HttpArena entry, its root files declaring goose-http at `99975706` and Plod at
`eb3e439`, on `bench/httparena.sh run` with `RUNS=1` (one 5 s run per cell) at
HttpArena's `d9438f6`: 4 workers on CPUs 0-3, gcannon on 4-15. Ryzen 7 5800X3D, Ubuntu
in WSL2 (kernel 6.18.54.1), Docker Desktop 29.8.2. Messages a second, and the
container's peak memory; "before" is goose-http `v0.5.8`, from Plod's task 061.

| Profile, connections | This change | Before | viltrum `v1.3.2` |
|---|---|---|---|
| echo-ws, 4,096 | 591,443, 44 MiB | 581,178, 52 MiB | 498,056, 165 MiB |
| echo-ws, 16,384 | 439,682, 145 MiB | 1,824, 132 MiB | 342,019, 652 MiB |
| echo-ws-pipeline, 16,384 | 6,320,813, 145 MiB | 26,085, 131 MiB | 5,185,142, 652 MiB |

All 16,384 connections were held, with no reconnects or errors. Plod's task 061 has
every cell of the run.

## Acceptance criteria

- [x] The proposal accepted or rejected, and the decision recorded either way
      (accepted 2026-10-24, `ws_admit` removed since no program needs it)
- [x] Whole frames hold no budget, and a message the budget can't hold gets 1013
      (`test/websocket/ws_parts.goose`)
- [x] echo-ws at 16,384 connections on 4 workers measured, through Plod's entry
      (2026-10-24, above)
