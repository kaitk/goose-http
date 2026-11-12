#!/bin/sh
# Starts the HTTP server of build/server and tests it: the endpoints with
# curl, TechEmpower's checks, pipelining, keep-alive, hostile and slow
# clients, and many connections at once with scripts/http_client.py, then
# short wrk and h2load runs that must see only 200s and no errors. The
# epoll build also serves h2c on the port + 2 and, where openssl makes it a
# certificate, h2 or HTTP/1.1 over TLS, as ALPN chooses, on the port + 1 and
# the port + 363, which it tests the same way.
# Fails on the first error, or if the server died along the way.
#
# PORT picks the port (29080): keep it below the kernel's ephemeral range
# (32768 and up), as for test-echo.sh. WORKERS sets the server's worker
# count (4). LOAD=short makes the load runs a tenth as long, for a run after a
# full one.
#
# On Windows, in Git Bash, it tests the IOCP build and leaves out the load
# runs and the fd limit run (docs/development.md, "Windows").
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-29080}
export WORKERS="${WORKERS:-4}"
url=http://127.0.0.1:$port
client="python3 $root/scripts/http_client.py $port"
log=$(mktemp)
out=$(mktemp)
# The directory the server's /files/ serves, which the client fills.
files=$(mktemp -d)
pid=
case $(uname -s) in
MINGW* | MSYS*) windows=1 ;;
*) windows= ;;
esac
# Named in full on Windows: Git Bash runs build/server before build/server.exe,
# and a Linux build in the same tree leaves one.
server=$root/build/server${windows:+.exe}
# A native program on Windows takes a Windows path.
if [ -n "$windows" ]; then files_path=$(cygpath -m "$files"); else files_path=$files; fi
# The dataset /json/{count} answers from, which the client writes.
dataset=$(mktemp)
$client dataset "$dataset"
if [ -n "$windows" ]; then export DATASET=$(cygpath -m "$dataset"); else export DATASET=$dataset; fi
if [ -n "$windows" ]; then log_path=$(cygpath -m "$log"); else log_path=$log; fi
export FILES="$files_path"
# A self-signed RSA-2048 pair, as HttpArena mounts one, for the TLS build's
# listener on the port + 1 (server/server_tls.goose, https.goose). The other
# builds ignore it.
certs=$(mktemp -d)
if [ -z "$windows" ] && command -v openssl >/dev/null; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$certs/server.key" -out "$certs/server.crt" \
        -days 2 -subj /CN=localhost 2>/dev/null
    export TLS_CERT="$certs/server.crt" TLS_KEY="$certs/server.key"
fi

# Ends the server. Git Bash's kill doesn't always end a native program, so
# on Windows it goes by the Windows process id.
end_server() {
    if [ -n "$windows" ]; then
        taskkill //F //PID "$(cat "/proc/$pid/winpid")" >/dev/null
    else
        kill "$pid"
    fi
}

# On any failure, show what the server said and don't leave it running.
trap 'status=$?
if [ -n "$pid" ]; then
    [ $status -eq 0 ] || { echo "server output:"; cat "$log"; }
    end_server 2>/dev/null || true
fi
rm -f "$log" "$out" "$dataset"
rm -rf "$files" "$certs"' EXIT

# Sets the fd limit, which Windows has none of for native programs.
limit_fds() {
    [ -n "$windows" ] || ulimit -n "$1"
}

# Whether the server listens, on ::1 for one that takes IPv6 only. Windows has
# no nc.
probe='import socket, sys; socket.create_connection((sys.argv[2], int(sys.argv[1])), 1)'
listening() {
    host=127.0.0.1
    [ -z "${IPV6_ONLY:-}" ] || host=::1
    if [ -n "$windows" ]; then
        python3 -c "$probe" "$port" "$host" 2>/dev/null
    else
        nc -z "$host" "$port" 2>/dev/null
    fi
}

# The many-client run holds 10000 connections open on each side.
limit_fds 65536

fail() {
    echo "FAIL: $*"
    exit 1
}

# Starts the server, with an fd limit of $1 if given.
start() {
    # The io_uring loop's listener outlives the process by a moment: the
    # kernel tears a ring down after its process exits.
    tries=0
    while listening; do
        tries=$((tries + 1))
        [ $tries -lt 50 ] || fail "port $port is taken; set PORT"
        sleep 0.1
    done
    (limit_fds "${1:-65536}" && exec "$server" http "$port") >"$log" 2>&1 &
    pid=$!
    tries=0
    # A server on a Unix socket listens once its file is there.
    case ${ADDRESS:-} in
    unix:*) until [ -S "${ADDRESS#unix:}" ]; do
            kill -0 "$pid" 2>/dev/null || fail "the server exited at start"
            tries=$((tries + 1))
            [ $tries -lt 100 ] || fail "the server isn't listening after 10 s"
            sleep 0.1
        done
        return ;;
    esac
    until listening; do
        kill -0 "$pid" 2>/dev/null || fail "the server exited at start"
        tries=$((tries + 1))
        [ $tries -lt 100 ] || fail "the server isn't listening after 10 s"
        sleep 0.1
    done
}

stop() {
    end_server
    wait "$pid" 2>/dev/null || true
    pid=
}

start
# The TLS build's two TLS ports, TLS_PORT's and H2_PORT's, from its first
# line; empty for none.
tls=$(grep -o ', TLS on port [0-9]*' "$log" | sed -n '1s/.* //p')
h2tls=$(grep -o ', TLS on port [0-9]*' "$log" | sed -n '2s/.* //p')

body=$(curl -sS "$url/plaintext")
[ "$body" = "Hello, World!" ] || fail "curl /plaintext: $body"
body=$(curl -sS "$url/json")
[ "$body" = '{"message":"Hello, World!"}' ] || fail "curl /json: $body"
ctype=$(curl -sS -o /dev/null -w '%{content_type}' "$url/json")
[ "$ctype" = application/json ] || fail "curl /json: Content-Type $ctype"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$url/nope")
[ "$code" = 404 ] || fail "curl /nope: $code"
# Two requests on one connection.
connects=$(curl -sS -o /dev/null -o /dev/null -w '%{num_connects} ' "$url/plaintext" "$url/json")
[ "$connects" = "1 0 " ] || fail "curl didn't reuse the connection: $connects"
echo "curl: ok"

$client tfb
$client forms
$client pipeline
$client large
$client websocket
$client stream
# The stream run sends and takes hundreds of MB; a server that held them whole
# would grow by as much. Linux reads it from /proc and Windows from the peak
# working set; macOS has neither.
peak=
if [ -n "$windows" ]; then
    peak=$(powershell.exe -NoProfile -Command \
        "[int]((Get-Process -Id $(cat "/proc/$pid/winpid")).PeakWorkingSet64 / 1024)" | tr -d '\r')
elif [ -r "/proc/$pid/status" ]; then
    peak=$(awk '/^VmHWM/ {print $2}' "/proc/$pid/status")
fi
if [ -n "$peak" ]; then
    [ "$peak" -lt 65536 ] || fail "the server's peak RSS reached $peak kB"
    echo "stream: peak RSS $peak kB"
fi
$client files "$files_path"
# Every file a response opened is closed, with its client gone or not. macOS
# has no /proc, so there it asks lsof. On Windows an open that shares nothing
# fails while any handle to the file is open.
if [ -n "$windows" ]; then
    sleep 1
    held=$(powershell.exe -NoProfile -Command \
        "@(Get-ChildItem -LiteralPath '$files_path' -File -Recurse | Where-Object {
            try { [IO.File]::Open(\$_.FullName, 'Open', 'Read', 'None').Close(); \$false } catch { \$true }
        }).Count" | tr -d '\r')
    [ "$held" = 0 ] || fail "the server holds $held files open"
    echo "files: none left open"
elif [ -d "/proc/$pid/fd" ]; then
    sleep 1
    held=$(ls -l "/proc/$pid/fd" | grep -c "$files" || true)
    [ "$held" = 0 ] || fail "the server holds $held files open"
    echo "files: none left open"
elif [ "$(uname -s)" = Darwin ]; then
    sleep 1
    held=$(lsof -p "$pid" 2>/dev/null | grep -c "$files" || true)
    [ "$held" = 0 ] || fail "the server holds $held files open"
    echo "files: none left open"
fi
$client chunked
$client compress "$dataset"
$client keepalive
$client client
$client later-off
$client hostile
$client many 10000

# The slow clients, against a server with timeouts other than the defaults,
# which the client reads too: the head's, the body's, and the write's apart.
kill -0 "$pid" || fail "the server died"
stop
export REQUEST_MS=4000 BODY_MS=3000 WRITE_MS=5000
start
$client slow
[ -z "$tls" ] || python3 "$root/scripts/http_client.py" "$tls" tls-slow
kill -0 "$pid" || fail "the server died"
stop
unset REQUEST_MS BODY_MS WRITE_MS
# A cap of 3 requests a connection, which the client expects.
export MAX_REQUESTS=3
start
$client requests
kill -0 "$pid" || fail "the server died"
stop
unset MAX_REQUESTS
# One worker with room for 8 connections: the ninth waits for one to close.
export MAX_CONNS=8
saved_workers=$WORKERS
WORKERS=1
start
$client max-conns 8
kill -0 "$pid" || fail "the server died"
stop
WORKERS=$saved_workers
unset MAX_CONNS
# The access log, on the server's output.
export ACCESS_LOG=1
start
$client log "$log_path"
kill -0 "$pid" || fail "the server died"
stop
unset ACCESS_LOG
# Answers that wait, with a box and a timer table in each worker.
export MAIL_SLOTS=64
export MAIL_CHECK_STALE=1
start
$client later
grep -q '^mail stale: gone' "$log_path" || fail "a reply after disconnect wasn't STALE"
grep -q '^mail stale: expired' "$log_path" || fail "a reply after timeout wasn't STALE"
kill -0 "$pid" || fail "the server died"
stop
unset MAIL_SLOTS
unset MAIL_CHECK_STALE
# Where it listens: "::", dual-stack, then IPv6 only, and on Linux and macOS a
# Unix socket, whose file the server removes when it stops. The socket's path
# must fit sun_path, 104 bytes on macOS, which mktemp's directory does.
export ADDRESS=::
start
$client listen "$ADDRESS"
stop
export IPV6_ONLY=1
start
$client listen "$ADDRESS" v6only
stop
unset IPV6_ONLY
if [ -z "$windows" ]; then
    export ADDRESS="unix:$files/http.sock"
    start
    $client listen "$ADDRESS"
    kill -TERM "$pid"
    wait "$pid" || fail "the server exited with status $? after a stop on a Unix socket"
    pid=
    [ ! -e "$files/http.sock" ] || fail "the server left its Unix socket's file"
fi
unset ADDRESS
start

if [ -n "$windows" ]; then
    kill -0 "$pid" || fail "the server died"
    stop
    # The client starts this server itself, in a process group of its own,
    # which Ctrl+Break needs.
    $client stop-break "$(cygpath -m "$server")"
    echo "test-http passed, without the load runs and the fd limit run on Windows. The server's output:"
    sed 's/^/    /' "$log"
    exit 0
fi

# Load generators, briefly: every response a 200, and no errors. wrk times
# requests with the wall clock, which WSL2 steps back now and then, and
# counts each request in flight across a step as a timeout; its timeouts are
# left to h2load, which uses a monotonic clock.
wrk_ok() {
    ! grep -E 'Non-2xx' "$out" || fail "wrk $1"
    ! grep -E 'Socket errors' "$out" | grep -v 'connect 0, read 0, write 0,' || fail "wrk $1"
    grep -E 'requests in' "$out"
}
if [ "${LOAD:-full}" = short ]; then secs=1 n1=20000 n2=50000; else secs=3 n1=200000 n2=500000; fi
wrk -t 2 -c 64 -d "$secs" -s "$root/scripts/pipeline.lua" "$url/plaintext" -- 16 >"$out"
wrk_ok plaintext
wrk -t 2 -c 64 -d "$secs" "$url/json" >"$out"
wrk_ok json
h2load --h1 -c 64 -m 16 -n "$n1" "$url/plaintext" >"$out"
grep -q 'succeeded, 0 failed, 0 errored, 0 timeout' "$out" || { cat "$out"; fail "h2load"; }
grep -q "status codes: $n1 2xx, 0 3xx, 0 4xx, 0 5xx" "$out" || { cat "$out"; fail "h2load"; }
grep -E '^requests:' "$out"
h2load --h1 -c 64 -n "$n2" "$url/json" >"$out"
grep -q 'succeeded, 0 failed, 0 errored, 0 timeout' "$out" || { cat "$out"; fail "h2load json"; }
grep -q "status codes: $n2 2xx, 0 3xx, 0 4xx, 0 5xx" "$out" || { cat "$out"; fail "h2load json"; }
grep -E '^requests:' "$out"
echo "load: ok"

# h2c, on the port the server says it serves it on (H2C_PORT, the port + 2):
# responses through curl with prior knowledge, /delay's TIMEOUT at once
# without waiting configured, a body larger than a stream's window both ways,
# a file, and a short h2load run. h2spec is scripts/test-h2spec.sh's.
h2c=$(sed -n 's/.*, h2c on port \([0-9]*\),.*/\1/p' "$log" | head -n 1)
if [ -z "$h2c" ]; then
    echo "h2c: not served by this loop"
elif ! curl -V | grep -q HTTP2; then
    echo "h2c: skipped, this curl has no HTTP/2"
else
    h2url=http://127.0.0.1:$h2c
    h2get() { curl -sS --http2-prior-knowledge "$@"; }
    body=$(h2get "$h2url/plaintext")
    [ "$body" = "Hello, World!" ] || fail "h2c /plaintext: $body"
    body=$(h2get "$h2url/json")
    [ "$body" = '{"message":"Hello, World!"}' ] || fail "h2c /json: $body"
    version=$(h2get -o /dev/null -w '%{http_version}' "$h2url/plaintext")
    [ "$version" = 2 ] || fail "h2c answered in HTTP/$version"
    status=$(h2get -o /dev/null -w '%{http_code}' "$h2url/missing")
    [ "$status" = 404 ] || fail "h2c /missing: $status"
    for q in "" "?open=1"; do
        body=$(h2get --max-time 3 "$h2url/delay/10000$q") || fail "h2c /delay/10000$q: no TIMEOUT at once"
        [ "$body" = 10000 ] || fail "h2c /delay/10000$q: $body"
    done
    head -c 300000 /dev/urandom >"$files/h2c.bin"
    h2get --data-binary "@$files/h2c.bin" -H 'Content-Type: application/octet-stream' \
        -o "$files/h2c.echo" "$h2url/echo"
    cmp -s "$files/h2c.bin" "$files/h2c.echo" || fail "h2c /echo didn't return the body"
    h2get -o "$files/h2c.file" "$h2url/files/h2c.bin"
    cmp -s "$files/h2c.bin" "$files/h2c.file" || fail "h2c /files/ didn't send the file"
    size=$(h2get "$h2url/bytes?n=1000000" | wc -c | tr -d ' ')
    [ "$size" = 1000000 ] || fail "h2c /bytes sent $size bytes"
    rm -f "$files/h2c.bin" "$files/h2c.echo" "$files/h2c.file"
    h2load -c 64 -m 100 -n 200000 "$h2url/plaintext" >"$out"
    grep -q 'succeeded, 0 failed, 0 errored, 0 timeout' "$out" || { cat "$out"; fail "h2load h2c"; }
    grep -q 'status codes: 200000 2xx, 0 3xx, 0 4xx, 0 5xx' "$out" || { cat "$out"; fail "h2load h2c"; }
    grep -q 'Application protocol: h2c' "$out" || { cat "$out"; fail "h2load didn't speak h2c"; }
    grep -E '^requests:' "$out"
    echo "h2c: ok"
fi

# HTTP/1.1 over TLS, on the port the epoll loop serves it on (TLS_PORT, the
# port + 1): TLS 1.3 and ALPN http/1.1 through openssl s_client, responses and
# a reused connection through curl, a body echoed and a file and /bytes sent
# larger than the write buffer, the client's checks over TLS and its bad
# handshakes, a short h2load run, and requests after two KeyUpdates from
# s_client.
if [ -z "$tls" ]; then
    echo "tls: not served by this loop"
else
    tlsurl=https://127.0.0.1:$tls
    tlsget() { curl -sSk --http1.1 "$@"; }
    openssl s_client -connect "127.0.0.1:$tls" -alpn http/1.1 </dev/null >"$out" 2>&1 || true
    grep -q '^New, TLSv1.3' "$out" || { cat "$out"; fail "s_client: not TLS 1.3"; }
    grep -q 'ALPN protocol: http/1.1' "$out" || { cat "$out"; fail "s_client: ALPN wasn't http/1.1"; }
    body=$(tlsget "$tlsurl/plaintext")
    [ "$body" = "Hello, World!" ] || fail "tls /plaintext: $body"
    body=$(tlsget "$tlsurl/json")
    [ "$body" = '{"message":"Hello, World!"}' ] || fail "tls /json: $body"
    connects=$(tlsget -o /dev/null -o /dev/null -w '%{num_connects} ' "$tlsurl/plaintext" "$tlsurl/json")
    [ "$connects" = "1 0 " ] || fail "tls: curl didn't reuse the connection: $connects"
    head -c 3000000 /dev/urandom >"$files/tls.bin"
    tlsget --data-binary "@$files/tls.bin" -H 'Content-Type: application/octet-stream' \
        -o "$files/tls.echo" "$tlsurl/echo"
    cmp -s "$files/tls.bin" "$files/tls.echo" || fail "tls /echo didn't return the body"
    tlsget -o "$files/tls.file" "$tlsurl/files/tls.bin"
    cmp -s "$files/tls.bin" "$files/tls.file" || fail "tls /files/ didn't send the file"
    size=$(tlsget "$tlsurl/bytes?n=1000000" | wc -c | tr -d ' ')
    [ "$size" = 1000000 ] || fail "tls /bytes sent $size bytes"
    rm -f "$files/tls.bin" "$files/tls.echo" "$files/tls.file"
    python3 "$root/scripts/http_client.py" "$tls" tls
    h2load --h1 -c 64 -n 50000 "$tlsurl/json" >"$out"
    grep -q 'succeeded, 0 failed, 0 errored, 0 timeout' "$out" || { cat "$out"; fail "h2load tls"; }
    grep -q 'status codes: 50000 2xx, 0 3xx, 0 4xx, 0 5xx' "$out" || { cat "$out"; fail "h2load tls"; }
    grep -q 'Application protocol: http/1.1' "$out" || { cat "$out"; fail "h2load tls: ALPN wasn't http/1.1"; }
    grep -E '^requests:' "$out"
    { printf 'GET /json HTTP/1.1\r\nHost: x\r\n\r\n'; sleep 0.3; echo k; sleep 0.3; echo K; sleep 0.3
      printf 'GET /json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'; sleep 0.5; } |
        openssl s_client -connect "127.0.0.1:$tls" -alpn http/1.1 >"$out" 2>&1 || true
    # The first KEYUPDATE follows the first body on its line.
    [ "$(grep -o 'KEYUPDATE' "$out" | wc -l | tr -d ' ')" = 2 ] && [ "$(grep -c '^HTTP/1.1 200' "$out")" = 2 ] ||
        { cat "$out"; fail "tls: a request after s_client's two KeyUpdates"; }
    echo "tls: ok"
fi

# h2 or HTTP/1.1 over TLS, as ALPN chooses, on the port the server serves it
# on (H2_PORT, the port + 363): curl with --http2 and --http1.1 on that one
# port, openssl s_client's ALPN, a body larger than a stream's window both
# ways and a file, through the record layer, and a short h2load run over h2;
# and the TLS port above, which shares its context, answering --http2 in
# HTTP/2. The client's ALPN checks, and an idle connection's GOAWAY, run below
# with IDLE_MS.
if [ -z "$h2tls" ]; then
    echo "h2 over TLS: not served"
elif ! curl -V | grep -q HTTP2; then
    echo "h2 over TLS: skipped, this curl has no HTTP/2"
else
    h2tlsurl=https://127.0.0.1:$h2tls
    version=$(curl -sSk --http2 -o /dev/null -w '%{http_version}' "$h2tlsurl/plaintext")
    [ "$version" = 2 ] || fail "h2 over TLS: curl --http2 got HTTP/$version"
    version=$(curl -sSk --http1.1 -o /dev/null -w '%{http_version}' "$h2tlsurl/plaintext")
    [ "$version" = 1.1 ] || fail "h2 over TLS: curl --http1.1 got HTTP/$version"
    if [ -n "$tls" ]; then
        version=$(curl -sSk --http2 -o /dev/null -w '%{http_version}' "https://127.0.0.1:$tls/plaintext")
        [ "$version" = 2 ] || fail "tls: curl --http2 got HTTP/$version"
    fi
    for p in h2 http/1.1; do
        openssl s_client -connect "127.0.0.1:$h2tls" -alpn "$p" </dev/null >"$out" 2>&1 || true
        grep -q "^ALPN protocol: $p\$" "$out" || { cat "$out"; fail "s_client -alpn $p: not chosen"; }
    done
    head -c 3000000 /dev/urandom >"$files/h2tls.bin"
    curl -sSk --http2 --data-binary "@$files/h2tls.bin" -H 'Content-Type: application/octet-stream' \
        -o "$files/h2tls.echo" "$h2tlsurl/echo"
    cmp -s "$files/h2tls.bin" "$files/h2tls.echo" || fail "h2 over TLS /echo didn't return the body"
    curl -sSk --http2 -o "$files/h2tls.file" "$h2tlsurl/files/h2tls.bin"
    cmp -s "$files/h2tls.bin" "$files/h2tls.file" || fail "h2 over TLS /files/ didn't send the file"
    rm -f "$files/h2tls.bin" "$files/h2tls.echo" "$files/h2tls.file"
    h2load -c 64 -m 100 -n 100000 "$h2tlsurl/plaintext" >"$out"
    grep -q 'succeeded, 0 failed, 0 errored, 0 timeout' "$out" || { cat "$out"; fail "h2load h2 over TLS"; }
    grep -q 'status codes: 100000 2xx, 0 3xx, 0 4xx, 0 5xx' "$out" || { cat "$out"; fail "h2load h2 over TLS"; }
    grep -q 'Application protocol: h2$' "$out" || { cat "$out"; fail "h2load: ALPN wasn't h2"; }
    echo "h2 over TLS: ok"
fi

kill -0 "$pid" || fail "the server died"
stop
echo "The server's output:"
sed 's/^/    /' "$log"

# The client's ALPN offers on the h2 port, and an idle h2 connection's
# GOAWAY and close_notify after IDLE_MS.
if [ -n "$h2tls" ]; then
    export IDLE_MS=2000
    start
    python3 "$root/scripts/http_client.py" "$h2tls" tls-h2
    kill -0 "$pid" || fail "the server died"
    stop
    unset IDLE_MS
fi

# A graceful stop by SIGTERM: the server exits by itself, with status 0, once
# its connections have closed.
start
$client stop "$pid"
tries=0
while kill -0 "$pid" 2>/dev/null; do
    tries=$((tries + 1))
    [ $tries -lt 50 ] || fail "the server was still running 5 s after its connections closed"
    sleep 0.1
done
wait "$pid" || fail "the server exited with status $? after the stop"
pid=

# Loops called again after a stop serve as the first ones did.
export SERVER_RUNS=2
start
unset SERVER_RUNS
kill -TERM "$pid"
# The server says so as its workers start again, once every one has returned.
tries=0
until [ "$(grep -c '^http: ' "$log")" = 2 ] && listening; do
    tries=$((tries + 1))
    [ $tries -lt 100 ] || fail "the server didn't serve again 10 s after a stop"
    sleep 0.1
done
$client keepalive
kill -TERM "$pid"
wait "$pid" || fail "the server exited with status $? after its second stop"
pid=
echo "restart: ok"

# One worker with 40 fds: accepting pauses at the limit, and resumes as
# connections close. Direct descriptors aren't held to the fd limit, which is
# their point, so uring-direct has no such limit to reach.
if [ "${LOOP:-}" = uring-direct ]; then
    echo "test-http passed. The fd limit's test skipped: direct descriptors pass it"
    exit 0
fi
WORKERS=1
start 40
$client emfile 60
kill -0 "$pid" || fail "the server died"
grep -q 'accept: Too many open files' "$log" || fail "the server never reached EMFILE"
stop
echo "test-http passed. The server's output at the fd limit:"
sed 's/^/    /' "$log"
