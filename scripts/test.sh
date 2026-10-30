#!/bin/sh
# Runs every test this repository has, and fails on the first failure: the
# typecheck of the server's and the examples' root files, the tests in test/
# (test/run_tests.py, which typechecks and runs each one and reports every
# failure among them), one of them through the JIT, then each loop's build of the server
# (scripts/build.sh) with scripts/test-http.sh against it, which tests h2c
# too where the loop serves it, and TLS on each loop but iocp from one TLS
# build (TLS=1), with full load runs on the first loop and short ones after,
# scripts/test-h2spec.sh against each loop but iocp where h2spec has a binary,
# and with AUTOBAHN=1, scripts/test-autobahn.sh against each build, which
# needs Docker, then scripts/test-echo.sh, and scripts/test-examples.sh, which builds each
# example and requests each of its routes on port 8080, and with H3=1,
# scripts/test-h3.sh, which needs Docker too, on epoll, and on Linux on
# io_uring.
#
# The loops are uring and epoll on Linux and macOS, where the uring build is
# also tested over the emulation on epoll it falls back to (LOOP=uring-epoll)
# on Linux, and iocp on Windows, in Git Bash. On Windows the typecheck is the
# Windows compiler's, which no other step runs there.
#
# GOOSE names the compiler, and CC the C compiler, as for build.sh; PORT and
# WORKERS pass through to the test scripts.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
goose=$GOOSE
os=$(uname -s)
case $os in
MINGW* | MSYS*) loops=iocp ;;
*) loops="uring epoll" ;;
esac

step() {
    echo
    echo "== $*"
}

h2spec() {
    step "test-h2spec.sh, $1 loop"
    if [ "$os" = Darwin ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        echo "skipped: h2spec's macOS build is x86-64, and Rosetta 2 isn't installed"
    elif [ "$os" = Linux ] && [ "$(uname -m)" != x86_64 ]; then
        echo "skipped: h2spec has no build for Linux on $(uname -m)"
    else
        LOOP=$1 "$root/scripts/test-h2spec.sh"
    fi
}

# macOS holds a closed client's port in TIME_WAIT for 30 s, and the next
# script's 10,000 connections fail with EADDRNOTAVAIL until most are gone
# (docs/known-issues.md, "macOS"). Waits for that, up to 60 s.
drain() {
    [ "$os" = Darwin ] || return 0
    i=0
    while [ "$(netstat -an -p tcp | grep -c TIME_WAIT)" -gt 100 ] && [ $i -lt 60 ]; do
        sleep 1
        i=$((i + 1))
    done
}

for f in "$root"/server/server.goose "$root"/server/server_epoll.goose "$root"/server/server_tls.goose \
    "$root"/examples/hello/hello.goose "$root"/examples/routes/routes.goose \
    "$root"/examples/api/api.goose "$root"/examples/upload/upload.goose \
    "$root"/examples/later/later.goose "$root"/examples/files/files.goose \
    "$root"/examples/compress/compress.goose "$root"/examples/c/app.goose \
    "$root"/examples/tls/tls.goose; do
    step "check ${f#"$root"/}"
    "$goose" --check "$f"
done

step "test/run_tests.py"
python3 "$root/test/run_tests.py"

# A program run through the JIT, as `goose file.goose` runs one, loads the package's
# library once it calls the shim, and the library needs the C of every extern the
# package's sidecar covers: a test's extern with none of its own broke every such
# program (v0.5.14).
if [ "$loops" != iocp ]; then
    step "a test through the JIT"
    "$goose" "$root/test/http/sys_errors.goose" | diff - "$root/test/expected/sys_errors.out"
fi

case $os in
Linux | Darwin)
    step "test-drain.sh"
    sh "$root/scripts/test-drain.sh"
    ;;
esac

# The first test-http.sh run has the full load runs, and the others short ones
# (LOAD=short): a loop's failure under load shows in either.
load=full
built=
for loop in $loops; do
    # The tests take the TLS listener too, from one TLS build, which serves
    # either loop as LOOP says at run time; IOCP has no TLS.
    if [ "$loop" = iocp ]; then
        step "LOOP=$loop build.sh"
        LOOP=$loop "$root/scripts/build.sh"
    elif [ -z "$built" ]; then
        step "TLS=1 build.sh, for every loop"
        TLS=1 LOOP=epoll "$root/scripts/build.sh"
        built=1
    fi
    drain
    step "test-http.sh, $loop loop"
    LOAD=$load LOOP=$loop "$root/scripts/test-http.sh"
    load=short
    [ "$loop" = iocp ] || h2spec "$loop"
    if [ "${AUTOBAHN:-}" = 1 ]; then
        drain
        step "test-autobahn.sh, $loop loop"
        LOOP=$loop "$root/scripts/test-autobahn.sh"
    fi
    if [ "$loop" = uring ] && [ "$os" = Linux ]; then
        drain
        step "test-http.sh, uring loop over epoll"
        LOAD=short LOOP=uring-epoll "$root/scripts/test-http.sh"
        h2spec uring-epoll
    fi
done

drain
step "test-echo.sh"
"$root/scripts/test-echo.sh"

step "test-examples.sh"
"$root/scripts/test-examples.sh"

if [ "${H3:-}" = 1 ]; then
    step "test-h3.sh, epoll loop"
    LOOP=epoll "$root/scripts/test-h3.sh"
    if [ "$os" = Linux ]; then
        step "test-h3.sh, uring loop"
        LOOP=uring "$root/scripts/test-h3.sh"
    fi
fi

echo
echo "test.sh: all passed"
