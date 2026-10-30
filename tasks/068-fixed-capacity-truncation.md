# 068: Fixed-capacity buffers that drop input

Status: todo

A limited array (`T[..N]`) aborts when pushed past its capacity, so input is lost
silently only where code checks `len < cap` and skips the rest. A decoder that does
that with peer input can disagree with the peer or another server about what was
sent, or can accept what it should refuse. Examples from other servers: a 65th path
segment dropped before `/..` removes the wrong one, a 17th `Connection` token that a
proxy forwards, and a parameter padded past a frontend's limit. Overflow on peer input
should be a protocol error, such as 400, a stream error, or a duplicate, never a
quiet drop (2026-10-27).

A first pass found one case and fixed it: `quic_ranges_add` dropped its oldest range
when full, then accepted packets in or below it again, against RFC 9000 §13.2.3. A
`floor` now rejects them (`bb1b46be`, after `v0.5.13`). The same pass judged these to
be harmless:

- `router.goose`: `Allow` leaves out methods past 96 bytes, and a route with more than
  `MAX_PARAMS` parameters doesn't match (404).
- `h2.goose`: the first `H2_HEAD_LINES` line ends are a cache, and later lines are
  found by scanning.
- `h3.goose`: ACK ranges past 64 are ignored, which only resends acknowledged packets.

The 2026-10-24 security review's fixes settled two more (2026-10-30). `H3Spans` merged
its two closest ranges when full, which for the bytes a stream received delivered a
gap's zeros, and for those acknowledged skipped bytes that weren't. A range received
apart from 8 others now closes the connection, and one acknowledged apart from 8
others is sent again; only lost ranges still merge, which only resends bytes
(`test/h3/spans.goose`). `ready` kept a closed stream beside its slot's next stream
until it overflowed and aborted; it now holds each open stream once
(`test/h3/ready_list.goose`).

The other buffers that hold peer input still need a check: the connection IDs and
`streams` and `sending` in `h3.goose`, `held` in `hpack.goose`, `params` in
`h2frame.goose`, `streams` in `h2.goose`, `digits` in `qpack.goose` and `h2.goose`,
`version` in `http.goose`, and `via`, `peer`, and `fields` in `client.goose`.

## Acceptance criteria

- [ ] Each limited array that peer input fills either refuses overflow as a protocol
      error or has a comment saying why dropping is safe.
- [ ] Each refusal has a test in `test/` that overfills it.
- [ ] The fixed `quic_ranges_add` is in a release, with a `CHANGELOG.md` entry.
