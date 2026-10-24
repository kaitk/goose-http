#!/bin/sh
# Builds each program in examples/ and requests each of its routes once, so
# that a change to the package can't leave an example broken. Each example
# listens on port 8080, which must be free. Needs curl.
#
# GOOSE names the compiler (default: the pinned release, scripts/goose.sh), and CC the C compiler,
# as scripts/build.sh takes them. BIN is where the examples are built, and
# PREBUILT=1 runs the ones already there, as scripts/test-aarch64.sh does on a
# machine without the compiler. RSS=1 prints each example's peak RSS on Linux.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${PREBUILT:-}" ] || . "$root/scripts/goose.sh"
goose=${GOOSE:-}
url=http://127.0.0.1:8080
case $(uname -s) in
MINGW* | MSYS*) windows=1 cc=${CC:-msvc} ;;
*) windows= cc=${CC:-gcc} ;;
esac
bin=${BIN:-$root/build/examples}
mkdir -p "$bin"
tmp=$(mktemp -d)
pid=

# Ends the running example. Git Bash's kill doesn't always end a native
# program, so on Windows it goes by the Windows process id.
end_example() {
    if [ -n "${RSS:-}" ] && [ -r "/proc/$pid/status" ]; then
        echo "$name${LOOP:+ ($LOOP)}: peak RSS $(sed -n 's/^VmHWM:[[:space:]]*//p' "/proc/$pid/status")"
    fi
    if [ -n "$windows" ]; then
        taskkill //F //PID "$(cat "/proc/$pid/winpid")" >/dev/null
    else
        kill "$pid"
    fi
    wait "$pid" 2>/dev/null || true
    pid=
}

trap 'status=$?
if [ -n "$pid" ]; then
    [ $status -eq 0 ] || { echo "example output:"; cat "$tmp/log"; }
    end_example 2>/dev/null || true
fi
rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

# Builds example $1 and starts it with the arguments after it, then waits
# until it listens.
start() {
    name=$1
    shift
    src=$root/examples/$name/$name.goose
    [ -f "$src" ] || src=$root/examples/$name/app.goose
    if [ -z "${PREBUILT:-}" ]; then
        "$goose" build --cc "$cc" --standalone -o "$bin/$name" "$src" >"$tmp/log" 2>&1 ||
            { cat "$tmp/log"; fail "$name doesn't build"; }
    fi
    tries=0
    while curl -s -o /dev/null "$url/" 2>/dev/null; do
        tries=$((tries + 1))
        [ $tries -lt 50 ] || fail "port 8080 is taken"
        sleep 0.1
    done
    "$bin/$name${windows:+.exe}" "$@" >"$tmp/log" 2>&1 &
    pid=$!
    tries=0
    until curl -s -o /dev/null "$url/" 2>/dev/null; do
        kill -0 "$pid" 2>/dev/null || fail "$name exited at start"
        tries=$((tries + 1))
        [ $tries -lt 100 ] || fail "$name isn't listening after 10 s"
        sleep 0.1
    done
}

# Requests with curl's arguments after $1, which is the status it must
# answer; the body lands in $tmp/body.
expect() {
    want=$1
    shift
    code=$(curl -sS -o "$tmp/body" -w '%{http_code}' "$@")
    [ "$code" = "$want" ] || fail "$name: curl $*: $code, want $want: $(head -c 200 "$tmp/body")"
}

# Fails unless $tmp/body holds $1.
holds() {
    grep -qF -- "$1" "$tmp/body" || fail "$name: body $(head -c 200 "$tmp/body"), want $1"
}

start hello
expect 200 "$url/"
holds "Hello, World!"
expect 404 "$url/nope"
end_example

start routes
expect 200 "$url/"
expect 200 "$url/users/42"
holds '{"id":"42"}'
expect 200 -d hi "$url/echo"
holds hi
expect 405 -X DELETE "$url/users/42"
expect 404 "$url/nope"
end_example

start api
json='Content-Type: application/json'
expect 401 -H "$json" -d '{"text":"buy milk"}' "$url/notes"
# A worker's notes are its own, so the read goes on the same connection.
code=$(curl -sS -o /dev/null -w '%{http_code} ' -H 'Authorization: Bearer let-me-in' -H "$json" \
    -d '{"text":"buy milk"}' "$url/notes" --next -sS -o "$tmp/body" -w '%{http_code} ' "$url/notes/1")
[ "$code" = "201 200 " ] || fail "api: POST then GET: $code"
holds "buy milk"
expect 422 -H 'Authorization: Bearer let-me-in' -H "$json" -d '{"note":1}' "$url/notes"
expect 200 "$url/visits"
holds 1
expect 200 -H 'Cookie: visits=4' "$url/visits"
holds 5
# Written as a form, then listed as CSV, read with its entity tag, and
# deleted, each on the same connection.
bearer='Authorization: Bearer let-me-in'
code=$(curl -sS -o /dev/null -w '%{http_code} ' -H "$bearer" -d 'text=call+mum' "$url/notes" \
    --next -sS -o "$tmp/body" -w '%{http_code} ' -H 'Accept: text/csv' "$url/notes")
[ "$code" = "201 200 " ] || fail "api: POST form then GET CSV: $code"
holds ',"call mum"'
code=$(curl -sS -o /dev/null -w '%{http_code} ' -H "$bearer" -d 'text=x' "$url/notes" \
    --next -sS -o /dev/null -w '%{http_code} ' -H 'If-None-Match: "1"' "$url/notes/1" \
    --next -sS -o /dev/null -w '%{http_code} ' -X DELETE "$url/notes/1" \
    --next -sS -o /dev/null -w '%{http_code} ' -u admin:secret -X DELETE "$url/notes/1" \
    --next -sS -o /dev/null -w '%{http_code} ' "$url/notes/1")
[ "$code" = "201 304 401 204 404 " ] || fail "api: ETag and DELETE: $code"
expect 406 -H 'Accept: image/png' "$url/notes"
expect 415 -H "$bearer" -H 'Content-Type: text/plain' -d hi "$url/notes"
expect 200 -H 'X-Forwarded-For: 203.0.113.7' "$url/whoami"
holds 203.0.113.7
end_example

start upload
head -c 300000 /dev/zero >"$tmp/zeros"
expect 200 --data-binary "@$tmp/zeros" "$url/upload"
holds "300000 bytes"
printf 'hello' >"$tmp/part.txt"
expect 200 -F note=hi -F "file=@$tmp/part.txt" "$url/form"
holds "note: 2 bytes"
holds "file (part.txt): 5 bytes"
expect 415 -d plain "$url/form"
# Larger than the read buffer, so gathered: 17,786 bytes, sized and chunked,
# and then a megabyte and a byte, past /words's limit.
{ seq 1 3000; seq 1 1000; } >"$tmp/words"
expect 200 --data-binary "@$tmp/words" "$url/words"
holds "4000 words, 3000 different"
expect 200 -H 'Transfer-Encoding: chunked' --data-binary "@$tmp/words" "$url/words"
holds "4000 words, 3000 different"
head -c 1048577 /dev/zero >"$tmp/big"
expect 413 -H 'Expect: 100-continue' --data-binary "@$tmp/big" "$url/words"
end_example

start later
expect 200 "$url/primes/100"
holds 25
expect 404 "$url/primes/x"
end_example

mkdir "$tmp/site"
printf 'Hello, files!\n' >"$tmp/site/a.txt"
site=$tmp/site
[ -z "$windows" ] || site=$(cygpath -m "$site")
start files "$site"
expect 200 "$url/files/a.txt"
holds "Hello, files!"
expect 206 -r 0-4 "$url/files/a.txt"
[ "$(cat "$tmp/body")" = Hello ] || fail "files: a range came as $(cat "$tmp/body")"
etag=$(curl -sS -D - -o /dev/null "$url/files/a.txt" | tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: //p')
expect 304 -H "If-None-Match: $etag" "$url/files/a.txt"
expect 404 "$url/files/missing.txt"
end_example

start compress
expect 200 --compressed -H 'Accept-Encoding: gzip' "$url/report"
holds '"id":200'
coding=$(curl -sS -D - -o /dev/null -H 'Accept-Encoding: gzip' "$url/report" | tr -d '\r' |
    sed -n 's/^[Cc]ontent-[Ee]ncoding: //p')
[ "$coding" = gzip ] || fail "compress: /report came with Content-Encoding '$coding', want gzip"
expect 200 --compressed -H 'Accept-Encoding: gzip' "$url/count/1000"
holds 1000
expect 200 "$url/report"
holds '"id":1,'
end_example

start c
expect 200 "$url/"
holds "Hello from C!"
expect 200 "$url/count"
holds '{"requests":'
expect 200 -A me "$url/agent"
holds me
expect 200 -d hi "$url/echo"
holds hi
expect 404 "$url/nope"
end_example

# HTTPS beside HTTP, with a certificate of its own. goose-tls isn't set up on
# Windows yet, nor for scripts/test-aarch64.sh's cross builds, which leave it out.
if [ -z "$windows" ] && command -v openssl >/dev/null && { [ -z "${PREBUILT:-}" ] || [ -x "$bin/tls" ]; }; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
        -days 2 -subj /CN=localhost 2>/dev/null
    start tls "$tmp/tls.crt" "$tmp/tls.key"
    expect 200 "$url/"
    holds "Hello, World!"
    expect 200 -k https://127.0.0.1:8443/
    holds "Hello, World!"
    expect 200 -k -d hi https://127.0.0.1:8443/echo
    holds hi
    expect 404 -k https://127.0.0.1:8443/nope
    end_example
    # HTTP/3's example, over its TCP listeners: scripts/test-h3.sh speaks
    # HTTP/3 to it.
    if [ -z "${PREBUILT:-}" ] || [ -x "$bin/h3" ]; then
        start h3 "$tmp/tls.crt" "$tmp/tls.key" "$root/test/fixtures/static"
        expect 200 "$url/baseline2?a=1&b=2"
        holds 3
        expect 200 -k https://127.0.0.1:8443/static/small.txt
        holds small
        end_example
    fi
fi

# The device's sysfs, faked: a thermal zone and an LED of its own. Windows has
# no epoll loop.
mkdir "$tmp/zone" "$tmp/led"
printf '47250\n' >"$tmp/zone/temp"
printf '0\n' >"$tmp/led/brightness"
printf '255\n' >"$tmp/led/max_brightness"
THERMAL=$tmp/zone LED=$tmp/led
[ -z "$windows" ] || { THERMAL=$(cygpath -m "$THERMAL"); LED=$(cygpath -m "$LED"); }
export THERMAL LED
loops="uring epoll"
[ -z "$windows" ] || loops=uring
for LOOP in $loops; do
    export LOOP
    start device
    expect 200 "$url/"
    holds "EventSource"
    expect 200 "$url/api/status"
    holds '"temp_mc":47250,"led":false,"gpio":false,"gpio_simulated":true'
    expect 204 -X PUT "$url/api/led/on"
    [ "$(cat "$tmp/led/brightness")" = 255 ] || fail "device: LED brightness $(cat "$tmp/led/brightness")"
    expect 204 -X PUT "$url/api/gpio/on"
    expect 200 "$url/api/status"
    holds '"led":true,"gpio":true'
    expect 204 -X PUT "$url/api/led/off"
    expect 400 -X PUT "$url/api/gpio/maybe"
    expect 200 -N "$url/api/events?n=2&ms=100"
    [ "$(grep -c '^data: {"temp_mc":47250}' "$tmp/body")" = 2 ] || fail "device: events $(cat "$tmp/body")"
    end_example
done
unset THERMAL LED LOOP

echo "test-examples.sh: all passed"
