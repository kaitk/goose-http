#!/bin/sh
# Runs the REST benchmark of task 021 on this machine, and writes the raw
# results to bench/results/<date>-rest-<machine>/.
#
#   bench/rest.sh build    the datasets (bench/rest/gen.goose) into DATA, the
#                          Goose server (bench/rest/goose) into build/rest/rest,
#                          the competitors (bench/rest/NAME) into
#                          build/rest/rest-NAME, and zrk into CACHE; with
#                          ONLY=goose, all but the competitors
#   bench/rest.sh run      checks each server with bench/rest/check.py, then
#                          measures, round by round
#
# The competitors are hyper, tokio, may-minihttp, xitca-web, odin-http, tina,
# and dusty. The Odin ones build with the odin-http and Tina checkouts that
# bench/build.sh fetches into CACHE, so it runs first. dusty is a framework,
# not an HTTP layer as the others are (task 021).
#
# What a run measures, each server with WORKERS workers on SERVER_CPUS and the
# load on CLIENT_CPUS, a fresh server per cell:
#
#   1. Tiers A to C at saturation, both JSON ways: wrk with the tier's script,
#      CLIENT_THREADS threads and 256 connections, WARMUP s discarded and then
#      DURATION s, with the server's CPU time and peak RSS (VmHWM).
#   2. Tier D: tier-d.lua's uploads role alone (1 thread, 32 connections), and
#      beside the forms role (CLIENT_THREADS - 1 threads, 224 connections).
#   3. Tiers A to C at a fixed rate, both JSON ways: bench/rest/rate.py, a zrk
#      per route, at RATE_A, RATE_B, and RATE_C requests per second, which
#      default to half the lowest median rate a server reached in step 1, to
#      two significant figures. zrk corrects for coordinated omission.
#   4. The mixed run: a TIER=d server, warmed up with tier C at saturation,
#      then tier C's reads at RATE_C, alone and beside the uploads role.
#
# may-minihttp, Tina, and Plod's Aegon and viltrum servers have no tier D (task
# 021, and no_d below), so they
# skip its checker and steps 2 and 4, and env.txt says why.
#
# Each step warms each server up first: cold, Goose's first seconds
# put tier C's p99 at 20-70 ms in a 3 s run, where warm it stays under 2 ms.
#
# Settings, from the environment:
#   SERVERS        goose-uring goose-epoll hyper, or any of the competitors.
#                  goose-uring-TAG and goose-epoll-TAG run another Goose
#                  build, build/rest/rest-goose-TAG, to compare builds.
#   SERVER_CPUS    0-3, WORKERS the number of them
#   CLIENT_CPUS    4-15, CLIENT_THREADS 8
#   RUNS 3, DURATION 15, WARMUP 5, PORT 29380
#   STEPS          1 2 3 4. Without step 1, step 3 needs RATE_A, RATE_B, and
#                  RATE_C, and step 4 RATE_C.
#   MACHINE        a short name for the machine (the host name), for OUT
#   DATA           build/rest; OUT bench/results/<date>-rest-<machine>
#   ZRK            zrk 2.3.0's x86-64 release, as HttpArena pins it
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cache=${CACHE:-$HOME/.cache/goose-http-bench}
. "$root/scripts/goose.sh"
bin=$root/build/rest
data=${DATA:-$root/build/rest}
PATH=$HOME/.cargo/bin:$PATH

ZRK_VERSION=2.3.0
ZRK_SHA256=ab6f1c1ce34ce73f52afd106419d15e5c494bd1cedd475afa56babb85b09a816
zrk=${ZRK:-$cache/zrk-$ZRK_VERSION/zrk}

case ${1:-} in
build)
    mkdir -p "$bin" "$data" "$cache"
    goose=$GOOSE
    "$goose" build --cc gcc --standalone -o "$bin/gen" "$root/bench/rest/gen.goose"
    "$bin/gen" "$data"
    "$goose" build --cc gcc --standalone -o "$bin/rest" "$root/bench/rest/goose/rest.goose"
    if [ ! -x "$zrk" ]; then
        curl -sSLf -o "$cache/zrk.tar.gz" \
            "https://github.com/zoxy-io/zrk/releases/download/v$ZRK_VERSION/zrk-$ZRK_VERSION-x86_64-linux.tar.gz"
        [ "$(sha256sum <"$cache/zrk.tar.gz" | cut -d' ' -f1)" = "$ZRK_SHA256" ] ||
            { echo "bench/rest.sh: zrk.tar.gz doesn't match ZRK_SHA256"; exit 1; }
        mkdir -p "$(dirname "$zrk")"
        tar -xzf "$cache/zrk.tar.gz" -C "$(dirname "$zrk")" zrk
    fi
    if [ "${ONLY:-}" = goose ]; then
        ls -l "$bin"
        exit 0
    fi
    # As bench/build.sh builds bench/NAME: for this machine, from CACHE, and
    # xitca-web with its TechEmpower entry's flags.
    for name in hyper tokio may-minihttp xitca-web; do
        flags="-C target-cpu=native"
        [ "$name" != xitca-web ] || flags="$flags --cfg tokio_unstable"
        (cd "$cache" && RUSTFLAGS="$flags" cargo build --release --locked \
            --manifest-path "$root/bench/rest/$name/Cargo.toml" --target-dir "$cache/target-rest-$name")
        cp "$cache/target-rest-$name/release/rest-$name" "$bin/rest-$name"
    done
    odin=${ODIN:-odin}
    pin() { sed -n "s/^$1=//p" "$root/bench/build.sh"; }
    "$odin" version | grep -q "$(pin ODIN_VERSION)" ||
        { echo "bench/rest.sh: odin-http and Tina need Odin $(pin ODIN_VERSION)"; exit 1; }
    for dep in odin-http:ODIN_HTTP_COMMIT tina:TINA_COMMIT; do
        [ "$(git -C "$cache/deps/${dep%%:*}" rev-parse HEAD 2>/dev/null)" = "$(pin "${dep#*:}")" ] ||
            { echo "bench/rest.sh: $cache/deps/${dep%%:*} isn't at its pin; run bench/build.sh"; exit 1; }
    done
    # bench/build.sh's flags for each. Tina's egress buffer is the largest that
    # compiles (bench/rest/tina/main.odin).
    "$odin" build "$root/bench/rest/odin-http" -collection:deps="$cache/deps" \
        -o:speed -disable-assert -no-bounds-check -out:"$bin/rest-odin-http"
    "$odin" build "$root/bench/rest/tina" -collection:deps="$cache/deps" \
        -o:speed -define:TINA_ASSERTS=false -define:HTTP_EGRESS_BUFFER_SIZE=63488 \
        -out:"$bin/rest-tina"
    # As bench/build.sh builds bench/dusty: from a copy in CACHE, since zig
    # fetches packages beside build.zig.zon, for HttpArena's target and CPU.
    zig=${ZIG:-zig}
    "$zig" version | grep -qx "$(pin ZIG_VERSION)" ||
        { echo "bench/rest.sh: dusty needs Zig $(pin ZIG_VERSION)"; exit 1; }
    case $(uname -m) in
    aarch64)
        target=aarch64-linux-musl cpu=native
        grep -q '^CPU implementer.*0x61' /proc/cpuinfo && cpu=apple_m1
        ;;
    *) target=x86_64-linux-musl cpu=x86_64_v3+aes+pclmul+adx ;;
    esac
    rm -rf "$cache/app-rest-dusty"
    mkdir -p "$cache/app-rest-dusty"
    cp -r "$root/bench/rest/dusty/." "$cache/app-rest-dusty/"
    (cd "$cache/app-rest-dusty" && "$zig" build --cache-dir "$cache/zig-cache" \
        --global-cache-dir "$cache/zig-global" --prefix "$cache/rest-dusty-out" \
        -Dtarget=$target -Dcpu=$cpu --release=fast)
    cp "$cache/rest-dusty-out/bin/rest-dusty" "$bin/rest-dusty"
    ls -l "$bin"
    exit 0
    ;;
run) ;;
*)
    echo "usage: bench/rest.sh build | run"
    exit 2
    ;;
esac

servers=${SERVERS:-goose-uring goose-epoll hyper}
server_cpus=${SERVER_CPUS:-0-3}
client_cpus=${CLIENT_CPUS:-4-15}
threads=${CLIENT_THREADS:-8}
workers=${WORKERS:-$(taskset -c "$server_cpus" nproc)}
runs=${RUNS:-3}
duration=${DURATION:-15}
warmup=${WARMUP:-5}
port=${PORT:-29380}
steps=${STEPS:-1 2 3 4}
machine=${MACHINE:-$(hostname -s)}
out=${OUT:-$root/bench/results/$(date -u +%Y-%m-%dT%H%M)-rest-$machine}
url=http://127.0.0.1:$port
hz=$(getconf CLK_TCK)

# The binary in build/rest that serves server $1.
binary() {
    case $1 in
    goose-uring | goose-epoll) echo rest ;;
    goose-uring-* | goose-epoll-*) echo "rest-goose-${1#goose-*-}" ;;
    *) echo "rest-$1" ;;
    esac
}

# Why server $1 has no tier D (task 021), or nothing if it has one.
no_d() {
    case $1 in
    may-minihttp) echo "it frames a request body by Content-Length alone, so can't read a chunked one" ;;
    tina) echo "reading a streamed body's pieces faults (SIGSEGV) after a few bodies in small chunks" ;;
    aegon | aegon-small | viltrum) echo "it reads a body whole before a route runs, so can't refuse one declared over the route's limit until it arrives" ;;
    esac
}

for s in $servers; do
    [ -x "$bin/$(binary "$s")" ] || { echo "bench/rest.sh: no server $s; run bench/rest.sh build"; exit 1; }
done
[ -x "$zrk" ] || { echo "bench/rest.sh: no $zrk; run bench/rest.sh build"; exit 1; }
[ -e "$root/build/bench/wrk-monotonic.so" ] || { echo "bench/rest.sh: run bench/build.sh"; exit 1; }
ulimit -n 65536
mkdir -p "$out"
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null' EXIT

{
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "machine: $machine"
    echo "kernel: $(uname -r)"
    echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) logical CPUs"
    echo "server cpus: $server_cpus, workers: $workers, client cpus: $client_cpus, client threads: $threads"
    echo "duration: $duration s, warm-up: $warmup s, runs: $runs"
    echo "goose-http: $(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet || echo ' (modified)')"
    echo "goose: $(goose_version)"
    echo "cc: $(${CC:-cc} --version | head -1)"
    echo "rustc: $(rustc --version)"
    case " $servers " in *" odin-http "* | *" tina "*)
        echo "odin: $(${ODIN:-odin} version), odin-http $(git -C "$cache/deps/odin-http" rev-parse --short HEAD)," \
            "tina $(git -C "$cache/deps/tina" rev-parse --short HEAD)"
    ;; esac
    case " $servers " in *" dusty "*)
        echo "zig: $(${ZIG:-zig} version), dusty" \
            "$(sed -n 's/.*dusty#\([0-9a-f]\{7\}\).*/\1/p' "$root/bench/rest/dusty/build.zig.zon")," \
            "zio $(sed -n 's/.*zio?ref=v\([0-9.]*\)#.*/\1/p' "$root/bench/rest/dusty/build.zig.zon")"
    ;; esac
    echo "wrk: $(wrk -v 2>&1 | head -1)"
    echo "zrk: $ZRK_VERSION"
    echo "servers: $servers"
    for s in $servers; do
        [ -z "$(no_d "$s")" ] || echo "tier d skipped for $s: $(no_d "$s")"
    done
} >"$out/env.txt"
(cd "$bin" && sha256sum $(for s in $servers; do binary "$s"; done | sort -u)) >"$out/binaries.txt"

# Starts server $1 on tier $2 with JSON way $3, and waits until it listens.
start() {
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo "bench/rest.sh: port $port is taken; set PORT"
        exit 1
    fi
    case $1 in
    goose-uring | goose-uring-*) loop=uring ;;
    goose-epoll | goose-epoll-*) loop=epoll ;;
    *) loop= ;;
    esac
    # A server that exits or doesn't listen gets one more try, in case its
    # port is still held all the same.
    for attempt in 1 2; do
        # Tina logs its crashes as lines like "[FATAL] Shard 0 caught sig=11",
        # so nothing is filtered out of the log.
        REST_DATA=$data TIER=$2 JSON=$3 WORKERS=$workers LOOP=$loop \
            taskset -c "$server_cpus" "$bin/$(binary "$1")" "$port" >>"$out/$1.log" 2>&1 &
        pid=$!
        tries=0
        # Loading tier C's records takes a few seconds.
        until nc -z 127.0.0.1 "$port" 2>/dev/null; do
            tries=$((tries + 1))
            kill -0 "$pid" 2>/dev/null && [ $tries -lt 600 ] || break
            sleep 0.1
        done
        ! nc -z 127.0.0.1 "$port" 2>/dev/null || return 0
        echo "bench/rest.sh: $1 isn't listening, try $attempt of 2" | tee -a "$out/$1.log"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
        sleep 1
    done
    tail -3 "$out/$1.log"
    exit 1
}

ticks() { awk '{print $14 + $15}' "/proc/$pid/stat"; }

# Stops the server, after writing its CPU ticks since mark, the clock's ticks
# per second, and its peak RSS in KB into $1.stat.
stop() {
    echo "$c0 $(ticks) $hz $(awk '/^VmHWM/ {print $2}' "/proc/$pid/status")" >"$1.stat"
    halt
}

# Stops the server and waits until its port can be bound again. odin-http's
# and Tina's listeners outlive their process by up to 50 ms, while the kernel
# releases their io_uring rings' files, and hold the port a while after they
# stop accepting.
halt() {
    kill $pid
    wait $pid 2>/dev/null || true
    pid=
    tries=0
    until python3 -c 'import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))' "$port" 2>/dev/null; do
        tries=$((tries + 1))
        [ $tries -lt 100 ] || { echo "bench/rest.sh: port $port stays taken"; exit 1; }
        sleep 0.1
    done
}

wrk_() {
    taskset -c "$client_cpus" env LD_PRELOAD="$root/build/bench/wrk-monotonic.so" \
        wrk --timeout 10s --latency "$@"
}

# Notes the start of cell $1 in times.txt, which times each step.
cell() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" | tee -a "$out/times.txt"
}

# Each server answers the checker before its runs, on each tier it serves.
for s in $servers; do
    for t in a b c d; do
        for j in serialize template; do
            [ "$t" = d ] && { [ "$j" = template ] || [ -n "$(no_d "$s")" ]; } && continue
            cell "check-$s-$t-$j"
            start "$s" "$t" "$j"
            f=$out/check-$s-$t-$j.txt
            python3 "$root/bench/rest/check.py" "$port" "$data" "$t" >"$f" 2>&1 &&
                { [ "$t" != d ] || python3 "$root/bench/rest/check.py" "$port" "$data" c >>"$f" 2>&1; } ||
                { echo "bench/rest.sh: $s fails tier $t ($j):"; tail -3 "$f"; exit 1; }
            halt
        done
    done
done

for run in $(seq "$runs"); do
    case " $steps " in *" 1 "*)
    for s in $servers; do
    for t in a b c; do
    for j in serialize template; do
        name=$out/sat-$s-$t-$j-r$run
        cell "${name##*/}"
        start "$s" "$t" "$j"
        set -- -t "$threads" -c 256 -s "$root/bench/rest/tier-$t.lua" "$url" -- "$data"
        wrk_ -d "$warmup" "$@" >/dev/null
        c0=$(ticks)
        wrk_ -d "$duration" "$@" >"$name.wrk"
        stop "$name"
    done
    done
    done
    ;; esac

    case " $steps " in *" 2 "*)
    for s in $servers; do
    [ -z "$(no_d "$s")" ] || continue
    for role in alone both; do
        name=$out/d-$s-$role-r$run
        cell "${name##*/}"
        start "$s" d serialize
        set -- -s "$root/bench/rest/tier-d.lua" "$url" -- "$data"
        wrk_ -t 1 -c 32 -d "$warmup" "$@" uploads >/dev/null
        set -- -d "$duration" "$@"
        c0=$(ticks)
        if [ "$role" = both ]; then
            wrk_ -t $((threads - 1)) -c 224 "$@" forms >"$name.forms.wrk" &
            forms=$!
        fi
        wrk_ -t 1 -c 32 "$@" uploads >"$name.uploads.wrk"
        [ "$role" = alone ] || wait $forms
        stop "$name"
    done
    done
    ;; esac
done

# The fixed rates, from step 1's results unless given.
rate_a=${RATE_A:-} rate_b=${RATE_B:-} rate_c=${RATE_C:-}
case " $steps " in *" 3 "*) need="a b c" ;; *" 4 "*) need=c ;; *) need= ;; esac
for t in $need; do
    eval "r=\$rate_$t"
    [ -n "$r" ] || r=$(python3 "$root/bench/rest/summary.py" --half "$out" "$t")
    eval "rate_$t=$r"
    echo "rate $t: $r" | tee -a "$out/env.txt"
done

for run in $(seq "$runs"); do
    case " $steps " in *" 3 "*)
    for s in $servers; do
    for t in a b c; do
    for j in serialize template; do
        name=$out/rate-$s-$t-$j-r$run
        cell "${name##*/}"
        start "$s" "$t" "$j"
        wrk_ -t "$threads" -c 256 -d "$warmup" -s "$root/bench/rest/tier-$t.lua" "$url" -- "$data" >/dev/null
        eval "r=\$rate_$t"
        c0=$(ticks)
        python3 "$root/bench/rest/rate.py" "$zrk" "$url" "$data" "$t" "$r" "$duration" "$client_cpus" "$name" ||
            echo "$name: zrk exited with an error"
        stop "$name"
    done
    done
    done
    ;; esac

    case " $steps " in *" 4 "*)
    for s in $servers; do
    [ -z "$(no_d "$s")" ] || continue
    for role in alone uploads; do
        name=$out/mixed-$s-$role-r$run
        cell "${name##*/}"
        start "$s" d serialize
        wrk_ -t "$threads" -c 256 -d "$warmup" -s "$root/bench/rest/tier-c.lua" "$url" -- "$data" >/dev/null
        c0=$(ticks)
        if [ "$role" = uploads ]; then
            wrk_ -t 1 -c 32 -d "$duration" -s "$root/bench/rest/tier-d.lua" "$url" -- "$data" uploads \
                >"$name.uploads.wrk" &
            up=$!
        fi
        python3 "$root/bench/rest/rate.py" "$zrk" "$url" "$data" c "$rate_c" "$duration" "$client_cpus" "$name" ||
            echo "$name: zrk exited with an error"
        [ "$role" = alone ] || wait $up
        stop "$name"
    done
    done
    ;; esac
done

cell end
echo "results: $out"
python3 "$root/bench/rest/summary.py" "$out" | tee "$out/summary.md"
