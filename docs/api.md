# API

The package's API by topic, each with the example that shows it. The concepts come first
in the [README](../README.md#concepts), which pattern fits large bodies, long responses,
and slow work is in [patterns](patterns.md), and the examples are listed in
[examples/](../examples/README.md).

## Requests and responses

### Handler

Shown in `hello/` and `routes/`.

- **`req`**: the parsed head, `http::Request`. Slices into the read buffer, valid until
  the handler returns.
  - `http::field_of(req, name)`: a field's value, and whether it's there. Name is
    case-insensitive.
  - `http::each_field(req) { name, value => }`: all fields, repeats included.
  - `http::authority(req)`: the host and port, from an absolute-form target before
    `Host` (RFC 9112 §3.2.2).
  - `http::path_of(req.target)`, `http::query_of(req.target, key)`,
    `http::each_query(req.target) { key, value => }`: still percent-encoded.
  - `http::query_int(req.target, key)`: a query value as an integer, and whether it's
    there as one.
  - `http::decode(s, out)`: decodes one. With `plus` set, `+` is a space.
  - A target with a bad `%` escape gets 400.
- **`body`**: the whole body, if it fits in the read buffer with the head. Chunked is
  decoded. A longer body is dropped and `body` is empty, and a longer chunked body gets
  413, since the handler couldn't tell it from an empty one. To read one, gather it whole
  with `http::gather` ([Helpers for APIs](#helpers-for-apis)) or take it in pieces
  ([Streaming](#streaming)).
- **`out`**: an `http::Reply`. One whole response, any size.
  - `http::respond(out, status, content_type, body)`, with no `Content-Type` for an
    empty `content_type`, as for a 204, or
  - `http::start(out, status)`, `http::field(out, name, value)`,
    `http::finish(out, fields, body)`. `fields` ends in `"Content-Length: "`, which
    `finish` follows with the body's length: `http::TEXT` and `http::JSON` add their
    `Content-Type`, `http::NO_TYPE` none, and a response with fields of its own writes
    them in one string, as `"Allow: GET\r\nContent-Length: "`.
  - `http::field` drops a field with CR, LF, or an invalid name, so request data can't
    split the response, and returns false; `http::is_field(name, value)` checks one
    before the response starts. `finish`'s `fields` are written as they are, for
    constant text.
  - Clear `out.keep_alive` before `start` to close after the response.
  - `out.common` is the fields `start` writes after each status line: `Server` and
    `Date`, which the loop renders once a second. To add fields to every response, as
    for CORS, set it to the loop's fields followed by yours, whole lines each ending
    in `\r\n`:

    ```rust
    var common: u8[>..] = [];
    common.append(out.common);
    common.append("X-Frame-Options: DENY\r\n");
    out.common = common;
    ```

    `out` is the handler's copy, so the change holds for each `start` after it, in the
    functions given `out` included, until the handler returns. The next call starts
    from the loop's fields again, and the responses the loop writes itself, such as a
    400 for a request it couldn't parse, don't get yours. `start` copies the bytes, so
    they need last only until then. Check a value from the request with
    `http::is_field` first.
  - `http::insert_field(out, mark, name, value)` adds a field to a response already
    written, for a value known only then, such as `Server-Timing`'s: `mark` is
    `out.buf.len` from before the response began. The field goes at the end of the
    head, and the body moves up. It's dropped as `http::field` drops one, and returns
    whether it was added.

A handler passed by name, `http::serve(cfg, route)`, should be an `inline fn`, as in
`server/routes.goose`. As a call, it keeps `http::start` from folding a constant status:
about 190 instructions per request in the benchmark server.

Don't `return` from a handler written as a block. A block's `return` returns from the
function the block is written in, the worker's `thread_fn`, which ends its loop with
the request unanswered and the client waiting. Neither the loop nor the compiler can
catch it
([findings](goose-findings.md#a-function-cant-keep-its-block-from-returning-past-it)).
A handler that returns early is a function: passed by name, as `upload/` does, or
called from the block, as `api/` and `later/` do.

### Routes

Shown in `routes/`.

```rust
var r = http::router(req);
if http::on(r, "GET", "/users/:id") { show(http::param(r, "id"), out); }
else if http::on(r, "PUT", "/users/:id") { update(http::param(r, "id"), body, out); }
else if http::on(r, "GET", "/files/*path") { file(http::param(r, "path"), out); }
else { http::otherwise(r, out); }
```

- `:name` matches one segment, `*name` the rest of the path, last only.
- A `GET` route takes `HEAD` too.
- A literal segment matches an escape of an unreserved character (`/%75sers` is
  `/users`); an escaped `/` doesn't split a segment.
- A path with a `.` or `..` segment, escaped or not, or an escaped control byte, matches
  no route: a handler that checks access by a path's prefix can't be walked around.
- `http::otherwise`: 501 for a method the server doesn't know, 400 for a path the
  router refused, 204 for `OPTIONS *`, 405 with `Allow` from the routes whose path
  matched, 204 with it for `OPTIONS`, else 404.
- Parameters are slices of the target, still encoded, valid until the handler returns.
  Nothing allocates.

### Helpers for APIs

`respond_json` is shown in `routes/` and `api/`; media types, cookies, Bearer and Basic
credentials, forms, and the client's address in `api/`; multipart, `body_within`, and
`gather` in `upload/`.

The helpers that read a request take it as `const http::Request&`, so a call doesn't
copy it. Pass them a variable, such as the handler's `req`: Goose doesn't yet bind a
call's result to a reference parameter.

- Media types: `http::require_type(req, out, "application/json")` answers 415 for
  another `Content-Type`; `http::accept_or_406(req, out, ["application/json",
  "text/csv"])` picks an offer by `Accept`, or answers 406. `http::media_type` and
  `http::param_of` parse a type and its parameters.
- Cookies: `http::cookie_of(req, name)`, `http::each_cookie(req) { name, value => }`,
  and `http::set_cookie(out, http::Cookie { name: "sid", value: id, max_age: 3600,
  http_only: true, same_site: "Lax", .. })`, which returns false and writes nothing
  for a cookie `http::is_cookie` refuses.
- `http::authorization(req)`: the scheme and credentials. `http::basic_auth(req,
  decoded)`: the user and password. `http::bearer(req)`: a Bearer token.
  `http::challenge(out, "Basic realm=\"api\"")`: 401.
- Forms: `http::form_value(body, key, out)` and `http::each_form(body) { key, value =>
  }`. Multipart: `http::start_multipart(req, st.parts)` at `REQUEST`, then
  `http::each_part(st.parts, ev.data) { part => }` for each piece of the body, where
  `part` is an `http::Part`: `Head { fields }`, `Data { bytes }`, or `End`. Use
  `http::disposition(fields)` for a part's name and filename. A check of your own,
  such as of a part's head, fails the body with `http::fail_multipart(st.parts)`.
  At `END`, the body is whole if `http::multipart_done(st.parts)`. An
  `http::Multipart` holds up to 2 KB of a part's head between pieces, and fails the
  body on a longer one. It's in the request's state, so every connection's slot holds
  those 2 KB, whichever route the connection is on. For a body already
  whole, `http::find_part(req, body, name)` returns the first part with that
  Content-Disposition name as slices of `body`: its content, its head fields (for
  `disposition` and `field_in`), and a status, `http::PART_FOUND`, `PART_ABSENT`,
  `PART_TYPE` (not `multipart/form-data`, or no usable boundary), or `PART_BAD` (a body
  `each_part` fails, a part without a form-data Content-Disposition, or one never
  closed). It stops at the part it finds.
- `http::respond_json(out, status) { b => json::format_key(b, "id"); ... }`.
  `http::json_string(b, s)` writes `s` as a JSON string, quotes included, into any
  builder with `push` and `append`. Its output is `json::format_string`'s: `\n`, `\t`,
  `\r`, `\b`, and `\f` in their short forms, and other control bytes as `\u00XX`. It
  looks for a byte to escape 16 bytes at a time, where `json::format_string` tests each
  byte.
- `Config.max_requests` caps a connection's requests. `http::body_within(st.taken, ev,
  out, limit)` at `REQUEST` and each `BODY` answers 413 past a route's own limit.
- `http::gather(ev, st.body, out, limit) { req, body, o => }`, called with every event
  of a handler with state, calls its block once with the whole body, however large, up
  to `limit` bytes. `st.body` is an `http::Gather` in the request's state. A body that
  came with its head goes to the block at `REQUEST`. A longer one is copied, with the
  head, into a run of the worker's gather pool as it arrives, and goes to the block at
  `END`. `CLOSED` frees what it held. Past `limit`, at most `Config.max_body`, it
  answers 413 and closes, as `body_within` does.
- The gather pool has a budget in each worker: the most bytes it promises its runs at
  once, `http::GATHER_BUDGET`, 64 MiB, unless `http::gather_budget(bytes)` sets another,
  in `main` before `http::run`, for every worker, or in a worker before its loop. A body
  is promised its bytes at its head: a Content-Length's exact size, or a chunked body's
  `limit`. One the budget can't hold gets 503 with `Retry-After: 1` there, and the
  connection closes; a body admitted is never refused later. A WebSocket is promised
  its bytes at its upgrade ([WebSocket](#websocket))
  ([decision](decisions.md#the-gather-budget-counts-bytes-promised-and-refuses-at-admission)).
- `http::peer(out)`: the connection's address and port. `http::client(req, out,
  trusted)`: the client a trusted proxy forwarded for, from `Forwarded` or
  `X-Forwarded-For`, with `trusted` from `http::network("10.0.0.0/8")`.
  `http::format_address(text, a)` writes one.

### Conditional requests and ranges

`http::serve_file` uses these ([Files](#files)), as `files/` shows. `api/` answers
`If-None-Match` for a note with `not_modified` alone.

- `http::not_modified(req, etag, modified)`: whether a `GET` gets 304. `If-None-Match`
  first, else `If-Modified-Since`.
- `http::range_of(req, size, etag)`: the one byte range asked for, with 206, 416, or
  200 for the whole (for example when `If-Range` names another entity tag).
- `http::content_range(out, start, end, size)`: writes `Content-Range`.

### Parts

The checks and writers the helpers above are made of, for a program or a framework
that answers in its own shape
([decision](decisions.md#every-convenience-is-a-composition-of-public-parts)).

- `http::has_type(req, want)`: whether `Content-Type` is `want`, the check
  `require_type` answers 415 for. `http::negotiate(req, offers)`: the index of the
  offer `Accept` prefers, or -1, the choice `accept_or_406` answers 406 for.
- `http::known_method(method)`: whether RFC 9110 defines the method, or it's PATCH;
  a server answers another with 501. `http::is_routable(path)`: whether a path has no
  dot-segment and no escaped control byte, which `router` checks.
  `http::same_segment(lit, seg)`: whether a pattern's literal segment matches a
  path's, still encoded.
- `http::field_in(fields, name)`: a field's value in field lines, as trailers or a
  head kept elsewhere; `field_of` reads the request's.
- `http::parse(buf, max_head, max_body, max_line, max_fields)`: the request head at
  the start of `buf`, and 200, `INCOMPLETE`, or the status to refuse it with, as for a
  head a program kept and reads again.
- `http::forwarded_client(req, peer, trusted)`: `client` for a peer the program
  already has.
- `out.minor == http::H2_MINOR` on an HTTP/2 stream, where `upgrade` answers 501.
  `http::switched(out)`: switches the stream to an upgraded protocol's bytes, once a
  101's head the program wrote itself is whole.
- `http::unrouted(r)`: the status `otherwise` answers a request no route took, 501,
  400, 204, 405, or 404; a 204 or 405 carries `r.allow` in `Allow` when it isn't
  empty. `http::unrouted(method, path, routable, allow)`: the same status for a
  router of the program's own, from the method, the path, whether `is_routable`
  holds for it, and the methods of the routes whose path matched.
- `http::field_at(fields, pos)`: the field line at `pos`, its name and value, and
  where the next starts, for walking fields. `http::same_name(a, b)`: whether two
  field names are the same, ignoring case.
- `http::file_tag(f)`: the `ETag` that `serve_file` sends for `f`, quoted, for a
  program that answers its 304 or 416 itself with `not_modified` and `range_of`.
- `open_precompressed`'s parts: `coding_q` weighs each coding, `open_file` opens each
  copy, the fresher by `f.modified` is kept, and `http::close_file(f)` closes a file
  passed over. A `File` the program makes this way sets `coding` to the copy's
  `Content-Encoding` and `vary` to true, which `serve_file` then sends.
- Compression's parts, which `respond_compressed` composes: `http::coding_for(req,
  c)`, the coding the response takes; `http::coding_q(req, coding)`, the weight
  `Accept-Encoding` gives a coding, in thousandths; `http::compressible(type)`,
  whether a body of that type is worth compressing; `http::coding_field(coding)`, its
  `Content-Encoding` line; and `http::compress_whole(data, out, coding, c)`, which
  appends `data` compressed. `begin_compressed`, for a response sent in pieces, adds
  `http::take_compressed(z, coding, c)`, which takes an encoder for `coding` from the
  worker's pool into a `Compressed` that holds none, and resets it, for a head the
  program writes itself; `send_compressed`, `end_compressed`, and
  `release_compressed` then work as after `begin_compressed`.
- `http::status_line(status)`: the status line with its CRLF, or "" for a status
  without a listed reason phrase. `http::write_body(out, fields, body, head_only)`:
  writes `fields`, which end in `Content-Length: `, the body's length, and the body.
  `http::refuse(out, status, common)`: the loops' refusal, with no body, after which
  the connection closes.
- `http::Stream` and `http::Framing`: a response's state in `out.stream`, which a test
  harness builds to call a handler without a loop.
- The gather pool's parts, which `gather` composes, for a framework's own runs under the
  worker's budget. An `http::Gather` is a run and its promise: its bytes are
  `http::gathered[g.at..g.at + g.len]`, in `g.cap` bytes that never pass `g.most`.
  `http::gather_promise(g, most)` promises `g` up to `most` bytes, or returns false and
  promises nothing where the budget can't hold them, the refusal a program answers.
  `http::gather_piece(g, data)` appends, in a run that starts at 16 KB and doubles, up
  to `g.most`, and returns false, appending nothing, past it. `http::gather_clear(g)`
  frees the run and keeps the promise; `http::release_gather(g)` gives back both.
  `http::gather_head(g, req, limit)` promises the head, rebuilt, and the body, as
  `gather` does at `REQUEST`, and copies the head in; `parse` reads it again.

## Bodies and responses of any size

### Streaming

A handler with state is called once for each event of an exchange, below, so it can
read a body and write a response in pieces. When a route needs one:
[request bodies](patterns.md#request-bodies) and
[long responses](patterns.md#long-responses). Shown in `upload/`, and in `server/`:
`/upload`, `/echo`, `/bytes`, `/stream`, and `/upgrade`.

`st` is state of the program's own type, reset to `fresh` per request, kept in the
connection's slot. A handler that keeps none, but needs `WAKE` or `TIMEOUT`, passes
`false`, as `later/` does.

```rust
struct Upload { bytes: i64 = 0 }

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg, Upload { .. }) { ev, st, out =>
        if ev.kind == http::REQUEST && !ev.whole {
            // The body comes in BODY pieces; answer at END.
        } else if ev.kind == http::REQUEST || ev.kind == http::END {
            st.bytes += ev.data.len;
            var text: u8[..24] = [];
            format(text, st.bytes);
            http::respond(out, 200, "text/plain", text);
        } else if ev.kind == http::BODY {
            st.bytes += ev.data.len;
        }
    };
    http::report(e);
}
```

| Event | When |
|---|---|
| `REQUEST` | Head parsed, in `ev.req`. With `ev.whole`, the body is in `ev.data`, as it always is when it fits in the read buffer with the head. |
| `BODY` | A piece of a longer body, decoded if chunked, up to `Config.max_body`. |
| `END` | The body is complete. Request trailers are in `ev.trailers`, here or at a whole body's `REQUEST`; `http::field_in` finds one. |
| `MORE` | A response is open, the body has ended, and the connection has room to send. |
| `CLOSED` | The connection closed while the handler was owed a call. Release what `st` holds. |
| `WAKE` | A message came to the address `later` returned: its bytes in `ev.data`, its tag in `ev.tag`. ([Answers that wait](#answers-that-wait)) |
| `TIMEOUT` | `later`'s time limit passed first, or there was no room to wait, which `ev.tag == http::NO_ROOM` says. |
| `DRAINED` | An upgraded connection's output that `after_drain` asked about has reached the socket. ([WebSocket](#websocket)) |
| `DONE` | With `Config.log`, the response is whole: `ev.status`, `ev.sent` bytes, and `ev.ms` from the head's first byte, for an access log. `ev.req` is the request only when it was answered at `REQUEST`. |

- `http::begin(out, status, length)` opens a response: `Content-Length`, or chunked
  for -1. HTTP/1.0 then closes at the end.
- `http::send(out, bytes)` writes a piece. `http::end(out)` ends it;
  `http::end(out, trailers)` adds trailer fields to a chunked one.
- The loop calls `MORE` only while the client takes what it's sent, so a slow client
  can't make the worker hold a whole response. A `MORE` that neither sends, ends, nor
  waits closes the connection. The client has fallen behind once the output queued for
  it passes the write buffer, on `serve_epoll`, or `Config.max_queued`, on `serve`.
- A response before the body has arrived drops the rest, up to `Config.max_drain`,
  then closes.
- `Expect: 100-continue` gets `100 Continue` unless the handler answers at `REQUEST`.
- `http::upgrade_of(req)`: the protocol asked for, such as `websocket`.
  `http::upgrade(out, protocol)` answers 101. After that, bytes come as `BODY`,
  `http::send` writes them raw, and `http::end` closes. `BODY` keeps coming while the
  exchange waits with `later` ([answers that wait](#answers-that-wait)).
  [WebSocket](#websocket) is built on this.

### WebSocket

Shown in `server/`: `/ws` echoes each message, as HttpArena's echo-ws profiles ask.

RFC 6455, in the optional module `http.websocket`. Its handshake's SHA-1 comes from
goose-hash, which a program that imports the module declares in its root file:

```rust
import http from "github.com/kaitk/goose-http@<tag>";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;

struct St { ws: http::WebSocket = http::WebSocket { limit: 1 << 16, .. } }

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg, St { .. }) { ev, st, out =>
        if ev.kind == http::REQUEST {
            http::ws_upgrade(ev.req, st.ws, out);
        } else {
            http::ws_read(ev, st.ws, out) { op, data, o => http::ws_send(o, op, data); };
        }
    };
    http::report(e);
}
```

- `http::ws_upgrade(req, st.ws, out)` at `REQUEST`: answers a `GET` that asks for
  `websocket` with 101 and `Sec-WebSocket-Accept`, computed for this request, and
  returns true; the connection then carries frames into `st.ws`. Otherwise it answers
  and returns false: 426 with `Upgrade: websocket` to a request that doesn't ask for
  it, 426 with `Sec-WebSocket-Version: 13` for another version, 400 for another method
  or a `Sec-WebSocket-Key` that isn't 16 bytes in base64, and 501 on an h2 stream.
  `http::ws_upgrade(req, st.ws, out, protocol)` names a subprotocol in
  `Sec-WebSocket-Protocol`: one of those the client offered, which
  `http::field_of(req, "sec-websocket-protocol")` gives.
- A WebSocket is promised bytes of the worker's gather budget
  ([Helpers for APIs](#helpers-for-apis)) only while it holds part of a message: the
  fragments of one, or a frame split across reads. Then it's promised `limit` and 131
  bytes, a message nearly at the limit and a control frame not yet whole after it, and
  gives them back once the message is whole. A frame that arrives whole holds nothing,
  so idle connections and small messages cost no budget, and a worker holds as many
  WebSockets as `Config.max_conns` allows. A message the budget can't hold closes its
  connection with 1013 (Try Again Later), in a Close first.
- `ws_upgrade` is two parts, for a program that answers a refusal in its own shape.
  `http::ws_check(req, out.minor)` answers nothing and returns the status, `ws_upgrade`'s
  101, 426, 400, or 501; for 101, the request's `Sec-WebSocket-Key`; and otherwise the
  fields the refusal must carry, whole lines ending in `\r\n`, which a 426 needs.
  `http::ws_switch(out, key, protocol)` then writes the 101 and switches the
  connection. It leaves out a `protocol` that isn't a valid field value, where
  `ws_upgrade` answers 400; neither checks that the client offered it, which is the
  program's choice. Here in a function the handler calls:

  ```rust
  let status, key, fields = http::ws_check(req, out.minor);
  guard status == 101 else {
      http::start(out, status);
      out.buf.append(fields);
      http::finish(out, http::JSON, "{\"error\":\"no_websocket\"}");
      return;
  }
  http::ws_switch(out, key, "");
  ```

- `http::ws_read(ev, st.ws, out) { op, data, o => }` with every later event: at `BODY`
  it reads each frame the bytes complete, all those that arrived together in one call,
  and calls the block with each whole message, `op` `http::WS_TEXT` or
  `http::WS_BINARY`. A message in fragments comes joined. `data` lasts until the block
  returns. At `CLOSED` it gives back what `st.ws` holds; other events, such as `WAKE`,
  are the handler's.
- `ws_read` is `http::ws_take(bytes, st.ws, out) { op, data, o => }` at `BODY`, which
  takes the connection's next bytes from wherever the program holds them, and
  `http::ws_release(st.ws)` at `CLOSED`.
- Without the program, a ping gets its pong, and the client's Close gets a Close with
  the same code, after which the connection closes. A frame the protocol forbids
  closes it with 1002 (unmasked, an RSV bit set, an unknown opcode, a control frame in
  fragments or longer than 125 bytes, a continuation out of place, a bad close code),
  text that isn't UTF-8 with 1007, and a message longer than `WebSocket.limit`, 64 KiB
  by default, with 1009, and one the gather budget can't hold with 1013, each with a
  Close first. A frame's length is checked from its head, before its payload arrives.
- `http::ws_send(out, op, data)` sends a message in one frame, at any event of the
  connection's, such as `WAKE` for one from another thread. Text must be UTF-8.
- `http::after_drain(out)`, after `send` or `ws_send` on an upgraded connection, asks
  for one `DRAINED` once that output has reached the socket, not the peer. A publisher
  sends its next bounded batch there, which may call `after_drain` again; a slow
  client then holds one batch, not a growing queue. It returns false with nothing
  sent since the last request, which stays pending, or without an open upgraded
  stream. A `later` wait stays armed meanwhile, and a connection that fails gets
  `CLOSED` instead. Sends that don't wait for `DRAINED` aren't limited: the program
  bounds its own batches and queues
  ([broadcasts](patterns.md#broadcasts-to-upgraded-connections)).
  `examples/drain.goose` sends one 8 KiB batch per `DRAINED`.
- `http::ws_close(out, st.ws, code, reason)` starts the close: 1000 and no reason by
  default. Messages that arrive after are dropped, and the connection closes when the
  client's Close comes, or after `Config.idle_ms`.
- On a TLS listener ([HTTPS](#https)) the same handler serves `wss://`: the frames
  travel inside TLS like any upgraded bytes.
- No extension, such as permessage-deflate, is negotiated, so a frame with an RSV bit
  set is a protocol error. Autobahn's test suite passes but for its extension
  sections, which aren't run (`scripts/test-autobahn.sh`).

### Files

Shown in `files/`, and in `server/`: `/files/NAME` serves the directory in `FILES`, and
so does `/static/NAME`, as HttpArena's static profiles ask.

- `http::open_file(path)`: opens a regular file, or 404 or 403.
- `http::open_precompressed(req, path)`: the same, or in its place `path.br`,
  `path.zst`, or `path.gz`, whichever the request's `Accept-Encoding` weighs highest,
  and not older than `path`. `serve_file` then adds `Content-Encoding`, `Vary`, and an
  `ETag` of the copy's own. Dynamic gzip, deflate, and zstd use the optional
  `http.compression` module, as [`compress/`](../examples/compress/compress.goose) shows;
  `serve_file` does not compress a file on the fly.
- `http::serve_file(req, out, f, http::content_type_of(path), st.file)`: answers `GET`
  or `HEAD` with 200, 206, 304, or 416, with `ETag`, `Last-Modified`, and
  `Accept-Ranges`.
- `http::send_file(out, st.file)` at each `MORE` until false, then `http::end(out)`.
  With a `Content-Length` of 64 KB or more, it hands the file to the loop, which sends
  it without copying it through the program: `sendfile` on the epoll loop and the
  emulated ring, splice through a pipe on io_uring, and `TransmitFile` on IOCP. Client
  editions of Windows run two `TransmitFile` calls at a time across the system, so many
  downloads at once may queue there. A smaller file, which one read and a send serve
  faster, and a chunked response read up to 64 KB with `pread` per call.
- `http::close_body(st.file)` at `CLOSED`.
- `http::file_path(dir, name, path)`: appends to `path` the file in `dir` that `name`
  names, such as a route's `*name` parameter, decoded. False for a bad escape or a
  path that would leave `dir`, which `http::is_safe_path` checks: it rejects `.` and
  `..` segments, NUL, backslashes, and colons, escaped or not.

## Answers that wait

A handler with state can hand a request to another thread, or wait for a timer, and
answer later without blocking its worker. How to shape that work, with a diagram of
`later/`: [slow work](patterns.md#slow-work). Shown in `later/`, and in `server/`:
`/later` and `/events` wait for a lane with a timer table of its own
(`server/backend.goose`), with `MAIL_SLOTS` set, as does `/upgrade?delay=D` once
upgraded, and `/delay/MS` waits for a timer.

`Config.mail_slots` and `Config.max_waiting` turn waiting on; both are 0 by default, and
then a loop opens no box and arms no timer: each `later` gets `TIMEOUT` at once, on the
loop's next pass, and its address takes no message.

```rust
// At REQUEST: the reply's address, with a time limit the handler must give.
let job = Job { reply: http::later(out, 5000), .. };
guard http::lane_send_value(lane, JOB, job) == http::SENT
else { http::respond(out, 503, "text/plain", "busy"); return; }

// At WAKE: ev.data and ev.tag are what the lane sent to reply.
// At TIMEOUT: the limit passed first; answer 504.
```

- `http::later(out, ms)` makes the exchange wait for a message to the address it
  returns, then calls the handler with `WAKE` or `TIMEOUT`. After `begin`, or at
  `MORE`, it pauses an open response, for Server-Sent Events and long polling. A call
  that writes a whole response doesn't wait. A worker holds at most
  `Config.max_waiting` exchanges waiting at once; past it, `later` gives `TIMEOUT` at
  once, with the tag `http::NO_ROOM`, so a handler can answer 503 rather than 504.
- Requests pipelined behind a waiting exchange wait in the read buffer, and reading
  stops once it's full.
- An upgraded connection is read while it waits: the client's bytes still come as
  `BODY`, and the handler can answer them with `http::send`, then `WAKE` or `TIMEOUT`
  comes when the reply or the limit does. A `later` at `BODY` starts the limit again,
  and `http::end` stops the wait and closes. A client that closes meanwhile gets the
  handler `CLOSED`, and the reply then finds the address `STALE`.
- A send to an exchange that no longer waits returns `STALE`. A message already
  queued or in flight when the wait ends can still be dropped by the loop. At stop,
  a waiting exchange gets `Config.grace_ms`, then `CLOSED`.
- `http::mail_live(address)` tells any thread whether the box accepts that key now,
  so a lane can skip work for a client that is no longer waiting. It is a snapshot:
  a later send can still return `STALE`. The key stays live through `WAKE` while the
  handler calls `later` again, so a reply can go in pieces back to back; it is
  cleared once the handler returns without waiting, and before `TIMEOUT` or
  `CLOSED`.
- A thread owns a box: `http::mail_open(slots, size)`, which returns the box
  and an `http::Error`, `http::mail_wait(box, ms)`, `http::mail_take(box) { key, tag, bytes => }`. `http::mail_send(address, tag,
  bytes)` returns `SENT`, `FULL` (no slot free), `TOO_LONG` (longer than a slot), or
  `STALE` at once, from any thread, and never blocks. `http::mail_slot_size(address)`
  gives a sender the box's slot size, or -1 for a `STALE` address, a stopped box
  included; `mail_live` is false for a stopped box too.
- `http::mail_stop(box)` stops a box, from any thread. The stop is a flag in the box,
  not a message, so a full box can't refuse it, and it wakes the owner's `mail_wait`.
  From then on, sends return `STALE`, and what the box already holds is still taken.
  Once the box is stopped, `mail_wait` returns at once on every call, `false` when
  nothing is pending, so a lane's loop ends on `http::mail_stopped(box)`. In the
  owner, `mail_stopped` is true once the box is stopped and holds nothing, or is
  closed. It first waits out a send in flight across the stop, so a job sent before
  the stop is never left behind. A second stop does nothing.
- A box's slot count is a power of two of at least 2. `mail_open` refuses any other
  count with `EINVAL`, including 1: the ring tells a full slot from a free one by its
  sequence number, which takes at least two slots.
- `http::mail_send_value(address, tag, v)` sends a flat value, such as a struct
  holding the reply's address, as its `to_bytes` image, and `http::mail_value(bytes,
  v)` reads it back into `v`, verified by `from_bytes`, or returns false. A limited
  array's image takes its whole capacity: size the box for that.
- `http::timer_table(n)`, `http::arm`, `http::cancel`, and `http::expire` are the
  loops' timers, for a worker's own.
- Generic boxes can opt into key tracking with
  `http::mail_open(slots, size, waker, live_keys, key_shift)`. Only their owner calls
  `http::mail_mark(box, key, live)`: a nonzero key selects entry `key >> key_shift`,
  and sends require the whole key to match. Clearing an old key preserves a newer
  key in the same entry. With `live_keys = 0`, the default, any key is accepted.
- A worker's own box, which replies come to, has `Config.mail_slots` slots of
  `Config.mail_size` bytes, 256 by default. A `Config.mail_slots` that `mail_open`
  refuses stops the loop with that error.

### Lanes

A lane is the threads that do one kind of slow work, each with a box of its own. `main`
opens it before `http::run`, passes it to the workers, and stops it once `run` returns,
as `later/` does:

```rust
thread_fn counter(box: http::Box) {
    http::lane(box) { tag, bytes => /* the job */ };
}

fn main() {
    let primes = http::lane_open(http::LaneConfig { threads: 2, .. }, counter);
    http::run(cfg, primes, worker);
    http::lane_stop(primes);
}
```

- `http::lane_open(cfg, thread)` spawns `cfg.threads` threads, 1 by default and 64 at
  most, each the `thread_fn` `thread(box: http::Box)` with a box of `cfg.slots` slots
  of `cfg.size` bytes, 64 of 256 by default. `http::lane_open(cfg, a, thread)` passes
  `a` too, to `thread(box: http::Box, a: A)`. A box that fails to open ends the
  program. The `http::Lane` it returns is flat, so it crosses `thread_spawn` and
  `http::run`.
- `http::lane_spawn(cfg) { b => thread_spawn(thread, b, ...) }` is `lane_open`'s
  work: it opens each box, calls the block to start that box's thread, and keeps the id
  the block returns. It is for a package whose lane threads take other parameters than
  `lane_open` passes, as Plod's typed lanes do; a program opens its lanes with
  `lane_open`.
- `http::lane(box) { tag, bytes => }` is the thread's loop: it calls the block with
  each job, in the order sent, until the lane is stopped and its box empty, then closes
  the box.
- `http::lane_send(lane, tag, bytes)` and `http::lane_send_value(lane, tag, v)` send a
  job from any thread to the least busy of the lane's threads, and to the others in turn
  while each is full. Each returns at once: `SENT`, `FULL` when every box is full,
  `TOO_LONG`, or `STALE` once the lane is stopped.
- `http::lane_stop(lane)` stops every box and waits for the threads, each of which
  first takes what its box holds. The stop is a flag in each box, not a message, so a
  full box can't refuse it.
- `http::lane_of(box)` is a lane of one box and no thread, for a test that plays the
  lane: the route sends to it, and the test takes the jobs with `mail_take`.

A lane thread that does work of its own between jobs, such as `server/backend.goose`'s
timers, writes the loop that `http::lane` is, with its own time limit on the wait:

```rust
while !http::mail_stopped(box) {
    http::mail_wait(box, ms);
    http::mail_take(box) { key, tag, bytes => /* the job */ };
    // the thread's own work
}
http::mail_close(box);
```

## Outbound connections

Connections the program opens to another server, such as a database: TCP, or a Unix
socket on Linux and macOS. Shown in `test/outbound/`:
`outbound_blocking.goose` for a lane's thread, `outbound_loop.goose` for a handler on
`serve_epoll` and on `serve`.

An `http::Socket` is the connection, `fd` -1 for none. A host is `localhost`, an IPv4
or IPv6 address, bracketed or not, or `unix:PATH`, whose port is ignored. The blocking
`http::connect` also takes a name, which it resolves with the system's resolver;
`http::connect_start` fails one with `ENOSYS` from `resolve`, since resolving blocks
the loop.

### On a thread without a loop

A lane's job blocks on the socket, each call up to a time limit in milliseconds, -1 for
none:

```rust
let s, e = http::connect("127.0.0.1", 5432, 5000);
guard e.code == 0 else { /* e.call, e.code: ECONNREFUSED, ETIMEDOUT, ... */ }
let sent = http::send_all(s, request, 5000);
let n = http::recv(s, buf, 5000);   // bytes into buf; 0: the server closed
http::hangup(s);
```

- `http::connect(host, port, ms)` returns the socket, connected, or `Socket { fd: -1 }`
  and an `http::Error`: `connect`'s `ECONNREFUSED`, `ETIMEDOUT` past `ms`, and the like,
  or `connect_start`'s. A name is resolved first, which `ms` doesn't bound: `resolve`'s
  `ENOENT` for a name with no address, or `EAGAIN` for a lookup that failed for now.
  Its addresses are tried in the resolver's order, up to 8, all within `ms`, and the
  error is the last one's.
- `http::send_all(s, data, ms)` sends all of `data` within `ms` in all, and returns an
  `http::Error` whose code is 0, `ETIMEDOUT`, or the send's, such as `EPIPE` once the
  server has closed.
- `http::recv(s, buf, ms)` waits up to `ms` for bytes and puts up to `buf.len` into
  `buf`: how many, 0 once the server has closed its side, `-ETIMEDOUT`, or `-code`.
- `http::hangup(s)` closes the socket and sets `s.fd` to -1; it does nothing for a
  socket already closed.

### On the worker's loop

A handler with state on `serve_epoll`, or on `serve` with io_uring, drives a socket
without blocking: the worker that
asked owns it, and the exchange waits for it as it waits for mail
([answers that wait](#answers-that-wait)), so `Config.mail_slots` and
`Config.max_waiting` must turn waiting on:

```rust
// At REQUEST:
let s, e = http::connect_start("127.0.0.1", 5432);
guard e.code == 0 else { /* refused at once, or a host it can't take */ }
st.s = s;
http::wait_socket(out, st.s, http::WRITABLE, 1000);

// At WAKE, with ev.tag == http::SOCKET_READY:
let c = http::connected(st.s);           // once, after the connect's WAKE
let n = http::send(st.s, query);         // what the socket took, or -EAGAIN
let n = http::recv(st.s, buf);           // what it held, 0, or -EAGAIN
http::wait_socket(out, st.s, http::READABLE, 1000);

// At TIMEOUT: the limit passed first. At CLOSED: http::hangup(st.s).
```

- `http::connect_start(host, port)` starts a connect and returns the socket without waiting.
  Its connect may still be going on; an `http::Error` for a host it can't take, or a
  connect that failed at once, which a refused one on loopback can be.
- `http::wait_socket(out, s, events, ms)` makes the exchange wait, after this call to
  the handler, until `s` is ready for `http::READABLE`, `http::WRITABLE`, or both, or
  for at most `ms`. The handler is then called with `WAKE`, whose `ev.tag` is
  `http::SOCKET_READY`, or with `TIMEOUT`. A message to the exchange's address ends the
  wait too, as after `later`. Its `http::Error` is 0, or `ENOSYS` on `serve`'s
  emulated ring and on IOCP, where the exchange doesn't wait and the handler answers.
- A wait that ends another way, by `TIMEOUT`, by mail, or at `CLOSED`, leaves the
  socket armed on epoll and kqueue: its event can still come as a `WAKE` with
  `SOCKET_READY` in the exchange's next wait, which the handler treats as "try again".
  io_uring cancels the socket's poll as the wait ends, as the handler answers in the
  call that waited, and as an h2 stream that waits is reset or refused, so no such
  `WAKE` comes there, and a socket hung up then closes at once.
- `SOCKET_READY` means the socket was ready: by the time the handler reads, it may not
  be, so `recv` and `send` can still give `-EAGAIN`, and the handler waits again. A
  socket closed or failed is readable, and its `recv` gives 0 or `-code`. Keep
  `SOCKET_READY` out of the program's own mail tags.
- `http::connected(s)`: how `connect_start`'s connect went, once the socket is writable: code
  0, `EINPROGRESS` while it goes on, or its error, such as `ECONNREFUSED`, reported
  once.
- `http::recv(s, buf)` and `http::send(s, data)` take and give what the socket has now:
  a count, `recv`'s 0 once the server has closed, `-EAGAIN` when it would wait, or
  `-code`, such as `-EPIPE`.
- The program owns the socket, and closes it with `http::hangup`: at `CLOSED`, at
  `TIMEOUT`, or when the loop returns, for one kept across requests, such as a pool's.
  A socket kept between requests is read by whichever exchange waits on it next; the
  loop reads nothing of it meanwhile.

`http::serve` watches sockets on io_uring only: on its emulation and on IOCP,
`wait_socket` fails with `ENOSYS`, and only the blocking calls work.

### An HTTP client

The module `http.client` makes HTTP/1.1 requests, plain or over TLS, on the blocking
socket, so it runs where the blocking calls do: on a lane's thread, or in a program
without a loop. A program that imports it declares goose-tls in its root file, as for
[HTTPS](#https). Shown in `test/client/`.

```rust
import http from "github.com/kaitk/goose-http@<tag>";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.client;

var session = http::session();
let response, err = http::post(session, "https://api.example.com/v1/login") { req =>
    http::bearer(req, api_key);
    http::header(req, "X-Device-Id", device_id);
    http::json(req, credentials);
};
guard err.code == 0 else { /* err.call names the step that failed */ }
let token, found = http::header(response, "X-Token");
http::free(session);
```

| Call | Does |
|---|---|
| `http::session(ms)` | A session whose TLS trusts OpenSSL's store of certificate authorities, with a limit of `ms` milliseconds on each wait, 30,000 by default (-1: none) |
| `http::session_trusting(ca, ms) -> Session, bool` | A session whose TLS trusts only the certificates in `ca`, PEM text, and whether its context was made |
| `http::free(s)` | Closes the session's connection and frees its TLS context |
| `http::get(s, url) { req => ... }`, `post`, `put`, `patch`, `delete` | Sends the request once the block has added to it, and returns the `http::ClientResponse` and an `http::Error` |
| `http::get(s, url)`, `http::delete(s, url)` | The same, with nothing to add |
| `http::request(s, method, url) { req => ... }` | Any other method |
| `http::header(req, name, value)` | Adds a header field |
| `http::bearer(req, token)` | Adds `Authorization: Bearer token` |
| `http::json(req, v)` | Makes `v` the body, as `v`'s `format` overload writes it, with `Content-Type: application/json` |
| `http::body(req, media, bytes)` | Makes `bytes` the body, with `Content-Type: media` |
| `http::header(r, name) -> const u8[:], bool` | A response field's value, as `field_of` finds a request's |

A `ClientResponse` holds `status`, `fields`, its header field lines, each ending in CRLF,
and `body`. `Session.max_body`, 16 MB by default, is the most body a response may have,
as sent. `Session.via` is an address to connect to in place of the URL's host and port,
such as `unix:/run/app.sock`; TLS still checks the URL's host.

- A session keeps its connection, and reuses it for the next request to the same scheme,
  host, and port, unless the server answered with `Connection: close` or has closed it
  since. It doesn't send a request again on a connection that fails.
- It writes `Host`, `User-Agent: goose-http`, `Accept: */*`, `Content-Type`, and
  `Content-Length` itself, and decodes a chunked body. It skips a 1xx before the final
  response. It doesn't follow redirects, keep cookies, or decode a compressed body.
- Under TLS, a connection that ends without close_notify fails with `recv`, so a body
  that ends with the connection can't be cut short unnoticed.

A request that fails returns status 0 and an `http::Error`, whose `call` names the step:

| `call` | When |
|---|---|
| `url` | The URL isn't `http://` or `https://` with a host, or has a user or a bad port |
| `header` | A field name isn't a token, a value holds a control byte such as CR or LF, or the block set `Host`, `Content-Length`, `Transfer-Encoding`, or `Connection` |
| `body` | The block set a second body |
| `resolve`, `connect`, `send`, `recv` | The socket's, with its code, as [on a thread without a loop](#on-a-thread-without-a-loop) |
| `tls` | The handshake failed, such as for a certificate the session doesn't trust, or a TLS record did; `tls::error_text()` says why |
| `response` | The response is malformed, or its body is past `max_body` |

The calls are compositions of parts a program can call on its own:
`http::parse_url(url) -> Url, bool`, `http::write_request(out, method, u, req)`, which
appends the request's bytes, `http::read_response(raw, closed, head, max_body, r)`, which
reads a response from the bytes so far (`READ_COMPLETE`, `READ_AT_CLOSE`, `INCOMPLETE`,
or `READ_MALFORMED`), and `http::exchange(s, method, url, req)`, which carries one
request on the session's connection.

## The store

Used by the benchmarks' REST server, `bench/rest/goose/rest.goose`.

`import http.store` gives byte blobs that `main` writes before it starts the workers,
and every worker then reads: one copy for the process
([architecture](architecture.md#the-store)).

- `http::store_put(bytes)` copies bytes into a new blob and returns an `http::Blob`
  and 0, or a blob with id -1 and `-EPERM` after the freeze or `-ENOMEM`.
- `http::store_freeze()` ends the puts. Call it before any other thread reads, and
  hand the blobs on through a queue, `thread_spawn`, or `thread_wait`.
- `http::store_len(b)`: the blob's length, or -1 for a blob the store doesn't have.
- `http::store_append(b, from, to, out)` appends bytes `from..to` to `out`, such as
  `out.buf` for a response, or returns false with nothing appended for a range
  outside the blob or a blob the store doesn't have.
- `http::store_i64(b, at)`, `http::store_u32(b, at)`, `http::store_u8(b, at)`, and
  `http::store_f64(b, at)` return the value at byte `at`, little-endian as
  `bytes_of` writes it, and true, from one C call with no buffer. A value that
  doesn't fit inside the blob, or a blob the store doesn't have, gives 0 and false.
  A column is one blob, read at `i * 8` for an `i64`:

  ```rust
  let prices, err = http::store_put(bytes_of(price_column));   // an i64[>..]
  let price, ok = http::store_i64(prices, i * 8);
  ```

- `http::store_record<T>(b, i, read)` returns record `i` of a blob of flat
  fixed-size `T`s end to end, such as `bytes_of` an array of them gives, by value,
  and true; or `default<T>()` and false for an `i` outside the blob or a blob the
  store doesn't have. `read` is the program's own C function for `T`, since an
  `extern fn` can't be generic (spec §7.10). It copies the record with
  `store_record_at`, which the package's C provides:

  ```rust
  struct Item { id: i64, price: i64, stock: i32 }
  extern "app_item_read" fn item_read(id: i64, i: i64, out: Item&) -> i32;
  let item, ok = http::store_record<Item>(items, i, item_read);
  ```

  ```c
  /* app.c, named by the program's sidecar: c_sources = ["app.c"]; */
  #include <stdint.h>
  #include <string.h>

  #pragma pack(push, 1)  /* Goose structs have no padding */
  typedef struct { int64_t id, price; int32_t stock; } item;
  #pragma pack(pop)
  _Static_assert(sizeof(item) == 20, "Item's size in Goose");

  const uint8_t *store_record_at(int64_t id, int64_t i, int64_t size);

  int32_t app_item_read(int64_t id, int64_t i, item *out) {
      const uint8_t *p = store_record_at(id, i, sizeof *out);
      if (!p) return -1;
      memcpy(out, p, sizeof *out);
      return 0;
  }
  ```

  The C needs only the record's size, but declaring its fields lets
  `_Static_assert` catch a struct that changed on one side. Nothing verifies the
  bytes, as `from_bytes` would, so the blob must hold `T`s as `bytes_of` wrote them,
  and `T` no references, whose links would come back unproven.

A scalar read costs half of a `store_append` of the same 8 bytes into a buffer, and a
record read half of a `store_append` of the record. Rebuilding the record in Goose
from its `store_append` image with `from_bytes` costs four times the C read
(task 040, `bench/store.sh`).

## Running a server

### Config and shutdown

The stop on Ctrl+C is shown in `routes/`.

`http::Config`: address, port, workers, limits, timeouts, buffer sizes. All have
defaults. `http::worker_count(cfg)` returns the worker count: `Config.workers`, or for
0, the default, one worker per hardware thread the process may use, which `taskset` or
a cpuset lowers. On macOS the default is one per performance core's logical CPU (8 on
an M1 Pro), and each worker takes the user-interactive QoS class. A CPU quota without a
mask, such as Docker's `--cpus` or a Kubernetes CPU limit, leaves the count at the
host's hardware threads, so set `Config.workers` to the quota.

`http::run(cfg, worker)` spawns `http::worker_count(cfg)` workers, each a `thread_fn`
that calls a loop with its own copy of `cfg`, and returns once every one has returned.
Up to two of the program's values go between `cfg` and the worker, which takes them
after its `Config`: `http::run(cfg, app, worker)` spawns
`thread_fn worker(cfg: http::Config, app: App)`. The worker comes last because Goose
passes a function value after a call's other arguments (spec §7.6). A program that picks
a loop at run time calls `run` once per choice, as `server/app.goose` does. An abort in
any thread ends the process ([crashes](patterns.md#a-crash-ends-the-process)).

`Config.address` is where to listen: empty for every IPv4 address (127.0.0.1 on
Windows), an IPv4 or IPv6 address, `"::"` for every address, IPv4 too unless
`Config.ipv6_only`, or `"unix:/run/app.sock"` for a Unix socket on Linux and macOS,
whose path fits in 104 bytes on macOS and 108 on Linux. The server removes a socket file
left at the path before it binds, and its own when it stops. Where it's empty, an h3
listener's UDP socket takes every address, IPv6 too: a QUIC client that resolves
`localhost` to `::1` first doesn't fall back to `127.0.0.1`, as a TCP client does when
refused.

A loop returns:

- when a call fails, with an `http::Error`. `http::report` prints it to stderr.
- after `http::stop()`, with error code 0. The listener and idle connections close.
  Each other connection gets `Connection: close` on its next response. The loop returns
  when they close, or after `Config.grace_ms`.

`http::stop_on_signals()` makes `SIGTERM` and `SIGINT` stop the loops, and returns an
`http::Error` whose code is 0 when it can. `http::exit_on_error(e)` prints an error to
stderr and ends the process with status 1, and does nothing for code 0:

```rust
fn main() {
    http::exit_on_error(http::stop_on_signals());
    http::run(http::Config { port: 8080, .. }, worker);
}
```

A server on io_uring that a signal kills instead leaves its listener open briefly after
it exits, and a successor on the same port can lose connections to it
([known issues](known-issues.md#a-killed-io_uring-servers-listener-outlives-it)).

### Event loops

The program calls one. Goose compiles a generic function only where it's called, so the
other isn't in the binary.

| Loop | Linux | macOS | Windows |
|---|---|---|---|
| `http::serve` | io_uring, kernel 6.1+ | ring emulated on kqueue | IOCP |
| `http::serve_epoll` | epoll | kqueue | `ENOSYS` |

- `http::serve` is the default. On Linux 12-22% faster than epoll, at 2-5 times the
  peak RSS, 10-16 MB with 4 workers. Where `io_uring_setup` fails, as under Docker's
  default seccomp profile, it emulates the ring on epoll; `http::ring_probe()` says why.
  With `Config.require_ring`, `serve` fails with call `io_uring` and that error
  instead, before it opens a listener, so that a server meant to run on io_uring
  doesn't run on epoll unnoticed. On macOS it always fails (`ENOSYS`); on Windows the
  completion port is the platform's own.
- `http::serve_epoll` is faster on macOS, and on Linux uses a quarter of the memory.

The benchmark server links both. `LOOP` picks: `uring` (`iocp` on Windows), `epoll`,
or `uring-epoll`. See
[architecture](architecture.md#completion-loop).

### Several ports, and h2c

Both loops serve h2c, HTTP/2 over TCP with prior knowledge: each connection must open
with HTTP/2's preface, as `curl --http2-prior-knowledge` and `h2load` send it. There is
no `Upgrade: h2c`, and no detection of the preface on an HTTP/1.1 port. On Windows,
`http::serve` takes one listener, since its ring keeps one accept, and fails with
`ENOSYS` on `Config.listeners`; `http::ring_listeners()` says how many a ring takes.
h2c on Windows is untested.

- `Config.h2c` makes `Config.port` serve h2c instead of HTTP/1.1.
- `Config.listeners` adds up to `http::MAX_LISTENERS` (3) more ports on the same
  address, each an `http::Listener { port, h2c, tls }`, served by the same workers. It
  can't be used with a Unix socket address. `tls` is [HTTPS](#https)'s.
- `Config.h2_max_streams` (128, up to 256) is the most streams a client may have open
  on a connection. `Config.h2_stream_window` (65,535) and `Config.h2_conn_window`
  (1 MiB) are what it may send on each stream, and on the connection, before the
  server gives the window back.

```rust
thread_fn worker(cfg: http::Config) {
    let e = http::serve_epoll(cfg) { req, body, out =>
        http::respond(out, 200, "text/plain", "Hello, World!");
    };
    http::report(e);
}

fn main() {
    var cfg = http::Config { port: 8080, .. };
    cfg.listeners.push(http::Listener { port: 8082, h2c: true });
    http::run(cfg, worker);
}
```

Handlers don't change: each stream is an exchange, called with the events an HTTP/1.1
request gets, and the response a handler writes, head and body, is sent as HEADERS and
DATA frames under HTTP/2's flow control. A body that fits in `Config.max_head` and in
half the stream window comes whole at `REQUEST`; a longer one comes in pieces. A stream
that waits (`later`) holds back no other. A handler that clears `out.keep_alive` ends
the connection with a GOAWAY once its open streams are done, and at a stop each h2c
connection gets a GOAWAY. `upgrade` answers 501 on a stream.

The benchmark server serves h2c on its port + 2, 8082 beside 8080, on every loop but
IOCP. `H2C_PORT` names another port, and `H2C_PORT=0` turns it off.

### HTTPS

Both loops serve HTTP/1.1 and h2 over TLS 1.3 on the listeners that ask for it, with
[goose-tls](https://github.com/kaitk/goose-tls)'s TLS 1.3 server, written in Goose over
OpenSSL 3's libcrypto. Only a program that imports the module `http.tls` needs
goose-tls, which its root file declares, and it builds with CMake and OpenSSL's headers
([goose-tls's setup](https://github.com/kaitk/goose-tls/blob/main/docs/development.md#openssl)):

```rust
import http from "github.com/kaitk/goose-http@<tag>";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;

thread_fn worker(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    let e = http::serve(cfg, server) { req, body, out =>
        http::respond(out, 200, "text/plain", "Hello, World!");
    };
    http::release(server);
    http::report(e);
}

fn main() {
    let ctx, ok = tls::server_files("server.crt", "server.key", ["h2", "http/1.1"]);
    guard ok else { write_stderr(str(tls::error_text(), "\n")); exit(1); }
    var cfg = http::Config { port: 8080, .. };
    cfg.listeners.push(http::Listener { port: 8443, tls: true });
    http::run(cfg, ctx, worker);
    tls::free(ctx);
}
```

- `Config.tls`, or a `Listener`'s `tls`, makes a port serve TLS; the others go on
  serving HTTP/1.1 or h2c, from the same workers.
- `http::tls_server(ctx)` gives a worker its `http::TlsServer`, with its own reference
  to the context, which `http::release(server)` frees once the loop has returned.
  The context is goose-tls's: a certificate chain and key, from PEM files or text,
  TLS 1.3 only, and the ALPN protocols to offer, in the order the server prefers them.
- ALPN chooses each connection's protocol, from the context's list. Where it lists
  `h2`, as above, a client that offers `h2` gets h2, and one that offers only
  `http/1.1`, or no ALPN, gets HTTP/1.1, on the same port. With `["http/1.1"]` every
  client that connects gets HTTP/1.1. A client that offers ALPN but none of the list,
  such as one offering only `h2` to `["http/1.1"]`, is refused with
  `no_application_protocol` (RFC 7301 §3.2). The `Config.h2_*` settings apply to h2
  over TLS as to h2c, and so does the rest of [h2c](#several-ports-and-h2c)'s
  behavior: handlers don't change, and a stop sends GOAWAY.
- A loop's TLS listeners share its one context, and so one ALPN list. A program that
  wants `h2` on one port and only `http/1.1` on another runs a second set of workers
  with a second context. A connection can move to another context at its ClientHello
  ([below](#https)).
- `http::serve(cfg, server) { req, body, out => ... }` and
  `http::serve(cfg, fresh, server) { ev, st, out => ... }` are the two `serve`s with
  the TLS of the listeners that ask for it, and `http::serve_epoll` takes the same
  arguments. Without a context, or with `tls` on an h2c listener, the loop fails with
  `EINVAL` before it listens, as either loop without a `TlsServer` does on any TLS
  listener. On Windows, `http::serve` fails with `ENOSYS` on a TLS listener.

Handlers don't change, and neither do the limits and timeouts, but for the handshake:
a client has `Config.request_ms` from its connection to finish it. A connection that
closes after its response sends close_notify, and so does an idle one that times out
or is closed by a stop; an h2 connection sends GOAWAY first. Files are read in pieces
rather than sent by `sendfile` or splice.

The benchmark server's TLS build (`scripts/build.sh` with `TLS=1`) serves h2 or
HTTP/1.1 over TLS, as ALPN chooses, with either loop, when `TLS_CERT` and `TLS_KEY`
name a PEM certificate chain and its key: on its port + 1 and its port + 363, as
HttpArena's 8081 and 8443 are beside 8080, from one context
([decisions](decisions.md#the-benchmark-server-offers-h2-on-both-tls-ports)).
`TLS_PORT` and `H2_PORT` name other ports, and 0 turns either off.

**A context per connection.** A program can move a connection to another context at its ClientHello, from the name
the client sent in SNI and the protocols it offered in ALPN: a certificate per host
name, a renewed certificate for new connections while open ones keep theirs, or
ACME's TLS-ALPN-01 challenge (RFC 8737), where a client offering `acme-tls/1` for the
challenged name gets the challenge certificate and every other client the server's,
on the same port
([decisions](decisions.md#the-program-chooses-a-connections-context-at-its-clienthello)):

```rust
struct Chooser { challenge: tls::Context }

// Called for each connection paused at its ClientHello; without use_context the
// connection keeps the context it was accepted from.
fn http::tls_hello(c: Chooser&, conn: tls::Conn) {
    if tls::server_name(conn) == "example.com" && tls::offers(conn, "acme-tls/1") {
        tls::use_context(conn, c.challenge);
    }
}

thread_fn worker(cfg: http::Config, ctx: tls::Context, c: Chooser) {
    var server = http::tls_server(ctx, c);
    let e = http::serve(cfg, false, server) { ev, st, out => ... };
    http::release(server);
    http::report(e);
}

fn main() {
    let ctx, ok = tls::server_files("server.crt", "server.key", ["h2", "http/1.1"]);
    tls::choose_context(ctx);      // once, before any worker accepts
    let challenge, cok = tls::server(cert, key, ["acme-tls/1"]);
    http::run(cfg, ctx, Chooser { challenge: challenge }, worker);
}
```

- `tls::choose_context(ctx)`, goose-tls's, makes each handshake from `ctx` pause
  after the ClientHello. Call it once, before the workers start.
- `http::tls_server(ctx, chooser)` gives a worker an `http::TlsServerOf<C>`, which
  holds the chooser, a value of the program's own type `C`; `http::TlsServer` is the
  one without a chooser. `http::release(server)` frees the server's reference to
  `ctx`; the contexts the chooser holds are the program's to free.
- At the pause the handshake calls `http::tls_hello(chooser, conn)`, which the program
  declares in the namespace `http` for its chooser's type, then goes on.
  `tls::server_name(conn)`, `tls::offers(conn, protocol)`, and `tls::use_context(conn,
  other)` are goose-tls's ([its architecture](https://github.com/kaitk/goose-tls/blob/main/docs/architecture.md#a-context-per-connection)).
  The context moved to answers with its own certificate and ALPN list, so a
  connection moved to one that lists only `acme-tls/1` is served HTTP/1.1, which an
  ACME server closes after the handshake.
- The chooser is the worker's own and changes only in `tls_hello`, so a challenge or
  a renewed certificate from another thread reaches it as the program arranges: for
  instance, mail to each worker that `tls_hello` takes at the next hello.
- With a chooser, a worker calls `serve` or `serve_epoll` with `fresh`: the forms
  without it take only an `http::TlsServer`.

### HTTP/3

HTTP/3 (RFC 9114) over QUIC version 1 is off unless a program asks for it: a listener
with `h3` serves it on a UDP socket on its own port, beside its TLS over TCP, from
the module `http.h3`. Only a program that imports that module has it. QUIC's
handshake and packet protection are goose-tls's, so h3 needs a TLS listener, and the
context's ALPN list must include `h3`:

```rust
import http from "github.com/kaitk/goose-http@<tag>";
import tls from "github.com/kaitk/goose-tls@<tag>";
import http.tls;
import http.h3;

thread_fn worker(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    var h3 = http::h3_server(ctx);
    let e = http::serve_epoll(cfg, server, h3) { req, body, out =>
        http::respond(out, 200, "text/plain", "Hello, World!");
    };
    http::release(h3);
    http::release(server);
    http::report(e);
}

fn main() {
    let ctx, ok = tls::server_files("server.crt", "server.key", ["h3", "h2", "http/1.1"]);
    guard ok else { write_stderr(str(tls::error_text(), "\n")); exit(1); }
    var cfg = http::Config { port: 8080, .. };
    cfg.listeners.push(http::Listener { port: 8443, tls: true, h3: true });
    http::run(cfg, ctx, worker);
    tls::free(ctx);
}
```

- `Config.h3`, or a `Listener`'s `h3`, serves HTTP/3 on that listener's port too. It
  needs `tls` on the same listener, and the forms of `serve` and `serve_epoll` that
  take an `http::H3Server` beside the `TlsServer`; without them the loop fails with
  `EINVAL` before it listens.
- `http::h3_server(ctx)` gives a worker its `http::H3Server`, for the forms whose
  handler takes the whole request, and `http::h3_server(ctx, fresh)` an
  `http::H3ServerOf<S>` for the forms with state, whose `fresh` it takes.
  `http::release(h3)` frees its reference to the context.
- The handler is the one HTTP/1.1 and h2 call, with the same events: each request
  stream is an exchange, its response is turned into HEADERS and DATA frames, and
  files are read in pieces at `MORE`, as over TLS. `Reply.minor` is `H2_MINOR`, and
  `Reply.fd` is -1: a request on a UDP socket has no socket of its own.
- goose-http adds no `Alt-Svc` field. A browser finds h3 where the program's
  responses over TCP name it, such as `Alt-Svc: h3=":8443"; ma=86400`.
- A client may have 128 request streams open at once, and send 1 MiB on each and 16
  MiB on the connection before more credit comes; the credit goes back as the handler
  takes the bytes. A worker holds at most `Config.max_conns` QUIC connections, and
  an idle one closes after 30 s.
- On Linux each worker has its own socket, with `SO_REUSEPORT`, and the kernel keeps
  a client's datagrams on one worker; runs of datagrams to one client go out
  together with GSO where the kernel can segment them. On macOS, `SO_REUSEPORT` gives
  every datagram to one of the workers' sockets. `http::serve` serves h3 over
  io_uring only: on the ring it emulates it fails with `ENOSYS`, and so does Windows.
- Not yet: an exchange can't wait, so `later` gets `TIMEOUT` with `NO_ROOM` at once;
  no 0-RTT, no connection migration, no Retry, and no QPACK dynamic table, which
  this side gives no capacity.

`scripts/test-h3.sh` checks `examples/h3` with aioquic, an HTTP/3 client with a QUIC
and TLS of its own, in a container.

