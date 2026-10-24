#!/bin/sh
# Checks HTTP/3 (http.h3) with an HTTP/3 client of its own QUIC and TLS:
# builds examples/h3, runs it with LOOP (epoll by default; uring for
# http::serve, on Linux with io_uring) and a self-signed certificate, serving
# test/fixtures/static/, and runs scripts/h3_client.py against it in a
# container with aioquic: every route, and each file as identity, br, and
# gzip, compared byte for byte. Needs Docker, which fetches python:3.12-slim
# and aioquic on its first run. PORT and TLS_PORT move the server's ports
# from 29080 and 29443. Fails if any check fails.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
port=${PORT:-29080}
tls_port=${TLS_PORT:-29443}
aioquic=1.7.0
static=$root/test/fixtures/static

command -v docker >/dev/null || { echo "test-h3.sh: needs Docker" >&2; exit 2; }
mkdir -p "$root/build/examples"
"$GOOSE" build -o "$root/build/examples/h3" "$root/examples/h3/h3.goose"

log=$(mktemp)
certs=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$log" "$certs"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$certs/server.key" \
    -out "$certs/server.crt" -days 2 -subj /CN=localhost 2>/dev/null
LOOP=${LOOP:-epoll} PORT=$port TLS_PORT=$tls_port \
    "$root/build/examples/h3" "$certs/server.crt" "$certs/server.key" "$static" >"$log" 2>&1 &
pid=$!
tries=0
until grep -q "h3 on port $tls_port" "$log"; do
    tries=$((tries + 1))
    if [ $tries -ge 50 ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "the server didn't start:" >&2
        cat "$log" >&2
        exit 1
    fi
    sleep 0.1
done
sleep 0.2

# Docker Desktop reaches the host by name; Linux's containers share its
# network. Under Docker Desktop on WSL, the host network is the Docker VM's,
# not WSL's, so its containers reach WSL at WSL's own address.
case $(uname -s) in
Linux)
    net=--network=host host=127.0.0.1
    if docker info --format '{{.OperatingSystem}}' | grep -q 'Docker Desktop'; then
        host=$(hostname -I | cut -d' ' -f1)
    fi
    ;;
*) net= host=host.docker.internal ;;
esac
# shellcheck disable=SC2086 # net is one argument or none
docker run --rm $net -v "$root/scripts:/scripts:ro" -v "$static:/static:ro" python:3.12-slim \
    sh -c "pip install -q --root-user-action=ignore --disable-pip-version-check aioquic==$aioquic &&
           python /scripts/h3_client.py $host $tls_port /static"
