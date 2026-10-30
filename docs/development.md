# Development

This guide sets up a machine to build, test, and benchmark goose-http. Linux is the
main platform: the benchmarks run there, and performance comparisons use it unless a
measurement names another platform. macOS builds both loops over kqueue, and Windows
builds the io_uring loop over I/O completion ports. The tasks record which platforms
each test covers.

When a step fails in a way this guide doesn't explain, check
[known issues](known-issues.md), which lists environment traps and incidents by
platform.

## Layout

```text
http.goose     the package's entry: settings, errors, what both loops share
*.goose        other modules, all namespace http: parser and response writers
               (message.goose), loops (uring.goose, epoll.goose), router
               (router.goose), files (file.goose), shim functions (sys.goose, ring.goose),
               HTTP/2's HPACK (hpack.goose) and frames (h2frame.goose),
               and with nothing of HTTP in them, mail between threads (mail.goose), the timer table
               (timers.goose), handles (handle.goose), and the store (store.goose)
http.build     the package's sidecar: each platform's shim
shim/          C for syscalls: sockets, epoll, io_uring, kqueue, IOCP, boxes, and the store
server/        the benchmark server, importing the package from "../"
examples/      small servers (examples/README.md); the API by topic is docs/api.md
test/          the tests, a folder per area, their golden files (expected/), and the
               runner, run_tests.py (below)
fuzz/          libFuzzer targets for the parsers of what a client sends, and their seeds
bench/         competing servers, load scripts, recorded results
scripts/       build, test, and Goose setup scripts
docs/          the API, architecture, development setup, known issues, results, Goose findings
tasks/         task tracking (tasks/README.md)
CHANGELOG.md   what each tag adds
```

What isn't Goose, and why, is in
[architecture](architecture.md#what-isnt-goose).

## Get Goose

The scripts use the official Goose release that `scripts/goose.sh` pins: `v2026.3`
(`8511ae3`), since 2026-10-21. It has every fix the commit pinned before it was built for:
[aardappel/goose#37](https://github.com/aardappel/goose/pull/37), which `http::run` and
`http::lane_open` need, [#41](https://github.com/aardappel/goose/pull/41), gcc's
`ByteSet` miscompile, and [#42](https://github.com/aardappel/goose/pull/42), TinyCC on
lib64 systems. The first script that needs the compiler downloads the release's
archive for the platform from
[the releases page](https://github.com/aardappel/goose/releases), checks its SHA-256,
and unpacks it into `build/goose-v2026.3-<platform>/`; later runs reuse it. To fetch the
compiler and print its path:

```sh
scripts/goose.sh
```

The release needs the C library's headers on Linux and the Xcode command line tools on
macOS ([Goose's README](https://github.com/aardappel/goose#install-a-release)). Linux on
arm64 has no release archive, so there the script builds the release's tag from source,
as `GOOSE_COMMIT` does ([use another compiler](#use-another-compiler)). `http.build`
excludes `build/` from the package, because the unpacked compiler's `stdlib/` declares
`extern fn`s that the package's JIT library would otherwise try to link (2026-10-15).

## Build and test

Set up the platform first: [Linux](#linux), [macOS](#macos), or [Windows](#windows),
or [Linux in a VM or container](#linux-in-a-vm-or-container). The scripts then work from
any directory:

| Command | What it does |
|---|---|
| `scripts/build.sh` | Builds the benchmark server into `build/server` with `goose build`, at `-O2` for Goose and gcc: on Linux `server/server.goose`, which serves with the io_uring loop, or with `LOOP=epoll` `server/server_epoll.goose`, which serves with the epoll loop, and with `LOOP=epoll TLS=1` `server/server_tls.goose`, which adds the TLS listener, links OpenSSL, and serves either loop as `LOOP` says at run time. |
| `scripts/test.sh` | Runs every test, and stops at the first failure ([below](#run-every-test)). |
| `test/run_tests.py` | Runs the tests in `test/` and compares their output with `test/expected/` ([below](#run-the-tests-in-test)). |
| `scripts/test-http.sh` | Tests the HTTP server of `build/server` ([below](#test-the-http-server)). |
| `scripts/test-echo.sh [server]` | Tests the echo servers of `build/server`, or of another command ([below](#test-the-echo-servers)). |
| `bench/build.sh` | Builds the Goose server and the competing servers into `build/bench/` ([below](#benchmarks)). |
| `bench/run.sh` | Runs the benchmark matrix against `build/bench/` and writes `bench/results/<date>/` ([below](#benchmarks)). |

`build.sh` runs `goose build --cc gcc --standalone`. gcc builds a faster server than
clang; `CC` picks another. `--standalone` puts the runtime in the program's C file, so
gcc can inline the runtime's functions into the server. The server imports the package
from `../`, whose sidecar, `http.build`, names the C in `shim/` to compile and link for
each platform (`shim/net.c` and `shim/uring.c` on Linux, `shim/kqueue.c` on macOS), and
liburing on Linux, for the io_uring loop, which needs Linux 6.1
([architecture](architecture.md#completion-loop)). `goose build`
keeps the generated C under `~/.goose/build/prog/`, and the package's compiled C under
`~/.goose/build/pkg/local/`; `goose build -v` prints the commands with their paths.

TinyCC can't place thread-local storage, so it refuses to run any program that can reach
`thread_spawn`, even when the spawn isn't taken. Build the server with `goose build`,
as `scripts/build.sh` does, and as `test/run_tests.py` builds each test.

The program takes a mode and a port (default 8080):

```sh
build/server http 8080            # the HTTP server, one worker per hardware thread
WORKERS=4 build/server http 8080  # with 4 workers
LOOP=epoll build/server http 8080 # with the epoll loop, whichever root file was built
build/server echo-blocking 8080   # an echo server that serves one client at a time
build/server echo-epoll 8080      # an echo server on one edge-triggered epoll loop
```

The HTTP server also serves h2c, HTTP/2 with prior knowledge, on the port + 2 (8082
beside 8080, as HttpArena has them), on every loop but IOCP. `H2C_PORT` names another
port, and `H2C_PORT=0` turns it off. The TLS build, with `TLS_CERT` and `TLS_KEY`,
serves h2 or HTTP/1.1 over TLS, as ALPN chooses, on the port + 1 (`TLS_PORT`) and the
port + 363 (`H2_PORT`, 8443 beside 8080).

### Run every test

`scripts/test.sh` runs the whole suite, and stops at the first failure:

1. `goose --check` of each root file: `server/server.goose`, `server/server_epoll.goose`,
   `server/server_tls.goose`, and the examples listed in `scripts/test.sh`.
2. `test/run_tests.py`: the tests in `test/` ([below](#run-the-tests-in-test)). Then, but
   on Windows, one of them through the JIT, as `goose file.goose` runs a program, which
   loads the package's library: a test's extern needs a sidecar of its own, or that
   library needs the extern's C (v0.5.14).
3. For each loop, `scripts/build.sh` and then `scripts/test-http.sh`: uring and epoll on
   Linux and macOS, with `LOOP=uring-epoll` against the uring build on Linux too, and
   iocp on Windows. The uring and epoll loops' build is the TLS build (`TLS=1`), run
   with `LOOP` set to the loop, whose TLS listener the tests take too. After the epoll
   build's, `scripts/test-h2spec.sh`, which fetches
   h2spec v2.6.0 into `build/` and runs it against the h2c port, and against the h2
   over TLS port with `-t -k` and `GODEBUG=tls13=1`, since h2spec's Go 1.12 offers TLS
   1.3 only when asked and the server speaks no other. h2spec's only builds
   are x86-64: on macOS it needs Rosetta 2, and on Linux on arm64 the step is skipped,
   with a note ([run it from an x86-64 container](#docker-on-macos)). With
   `AUTOBAHN=1`, after each build's, `scripts/test-autobahn.sh`, which needs Docker:
   it runs the Autobahn test suite's fuzzing client from the
   `crossbario/autobahn-testsuite` image, pinned by digest, against the server's `/ws`,
   every case but the extension sections 12 and 13. The image is x86-64 only, so on an
   arm64 host Docker runs it under emulation; the run takes under a minute. Its report
   is in `build/autobahn/reports/`.
4. `scripts/test-echo.sh`, against the last build.
5. `scripts/test-examples.sh`: builds the examples and requests their routes on port 8080,
   including the device example with simulated hardware. ARM builds are checked
   separately ([below](#arm-under-docker)).
6. With `H3=1`, `scripts/test-h3.sh`, which needs Docker: it builds `examples/h3`,
   serves `test/fixtures/static/` with it, and runs `scripts/h3_client.py` against it
   with aioquic 1.7.0, a QUIC and TLS of its own, in a `python:3.12-slim` container:
   every route, and each file as identity, br, and gzip, byte for byte. On epoll, and
   on Linux on io_uring too. On Docker Desktop the container reaches the host's server
   as `host.docker.internal`.

```sh
scripts/test.sh
```

`GOOSE`, `GOOSE_COMMIT`, `CC`, `PORT`, and `WORKERS` pass through to the scripts it runs.
On macOS it waits for `TIME_WAIT` to drain before each run
([known issues](known-issues.md#macos)). On Windows, in Git Bash, its first step is the
Windows typecheck that [Edit on Windows](#edit-on-windows) describes. Git Bash leaves out
the load runs and the fd-limit check.

### Run the tests in test/

`test/run_tests.py` runs the tests in `test/`, which follow Goose's own convention
([decisions](decisions.md#tests-follow-gooses-convention)). It needs Python 3 and the C
compiler `goose build` uses.

- Each test is a program `test/<area>/<name>.goose`, such as `test/http/parse.goose`,
  that prints what it checks and asserts it. Its expected output is
  `test/expected/<name>.out`, so names are unique across areas. `<name>.stderr` lists
  lines its standard error must hold, and `<name>.aborts` marks a test that must exit
  with an error.
- A file with `// error: <message>` lines, in `test/errors/`, must fail to compile with
  each message in a diagnostic.
- The helpers the tests share are `test/check.goose`, which a test imports with
  `import check from "../";`.
- A test that declares the package by `mail.goose` alone has a sidecar of its own,
  `test/mail/<name>.build`, naming the C that mail needs.

The runner typechecks every file in batches, many files to one
`goose --multi-test --check`. It then builds each test with `goose build` at `-O0` and
at `-O2`, in `build/test/O<level>/<name>/`, and runs it there, the tests in parallel
(`-j`, one per processor by default). It reports every failure, with a diff against the
golden file, and a count per area:

```sh
test/run_tests.py                # every test, at -O0 and -O2
test/run_tests.py parse          # one test
test/run_tests.py http mail      # the areas http and mail
test/run_tests.py -O 2 -v parse  # at -O2 only, and print the passes too
test/run_tests.py --bless parse  # rewrite test/expected/parse.out with what it prints
```

Bless a golden file only after reading the diff that showed it changed, and commit it
with the change that changed it. `GOOSE` and `GOOSE_COMMIT` pick the compiler, as for the
scripts, and `CC` the C compiler, as for `goose build --cc`. In Git Bash, run it as
`python3 test/run_tests.py`.

### Linux

**OS:** tested only on Ubuntu 26.04.1 LTS so far (2026-10-10).

Install the C compilers, liburing, and the test tools, then run `scripts/test.sh`:

```sh
sudo apt-get install -y gcc clang libc6-dev liburing-dev git curl python3 \
    wrk nghttp2-client netcat-openbsd strace linux-perf
```

`GOOSE_COMMIT` and Linux on arm64, which has no Goose release archive, build Goose from
source, with `sudo apt-get install -y cmake ninja-build g++`.

The TLS builds of the benchmark server, `examples/tls`, and `test/tls/` import
goose-tls, which builds with CMake and OpenSSL 3's headers, and `scripts/test-http.sh`
makes its test certificate with `openssl`:

```sh
sudo apt-get install -y cmake libssl-dev openssl
```

The benchmarks need more tools ([bench/README.md](../bench/README.md#toolchain)).

On an image-based Fedora such as Bazzite or Silverblue, the tools go in a distrobox,
which shares the host's kernel and network, so perf's counters are the host's.
Fedora has no `wrk` package: build it from its tag with `make` (it vendors LuaJIT)
and copy it onto `PATH`. perf's settings
(`sysctl kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0`) run on the host,
after each boot; with them, the container's rootless `perf` counts kernel
instructions and records a CPU. Every step of `scripts/test.sh` passed this way on
Bazzite 43 (2026-10-20):

```sh
distrobox create -n goose -i registry.fedoraproject.org/fedora-toolbox:43
distrobox enter goose -- sudo dnf install -y gcc clang cmake ninja-build \
    liburing-devel openssl-devel openssl perl git curl nghttp2 perf nmap-ncat \
    strace binutils
```

| Tool | Source | Version used (2026-10-10) |
|---|---|---|
| C compilers | | gcc 15.2.0, clang 21.1.8 |
| CMake, Ninja | apt | 4.2.3, 1.13.2 |
| Python | | 3.14.4, for the test clients |
| curl | apt | 8.18.0 |
| wrk | apt | 4.1.0 (`4.1.0-4build3`) |
| h2load | apt `nghttp2-client` | 1.68.0 |
| liburing | apt `liburing-dev` | 2.14, for the io_uring loop (`LOOP=uring`) |

### macOS

**OS:** tested on macOS 26.3.1, Darwin 25.3.0 (2026-10-11).

`scripts/build.sh` defaults to the epoll loop over kqueue. `LOOP=uring` builds the
completion loop over its kqueue emulation; the benchmark server includes both loops.
The platform mapping is in
[architecture](architecture.md#completion-loop).

Install the tools with Homebrew, then run `scripts/test.sh`:

```sh
brew install cmake wrk nghttp2 openssl@3
```

The scripts fetch the `macos-arm64` or `macos-x64` release; CMake is for `GOOSE_COMMIT`
and for goose-tls, which builds with Homebrew's `openssl@3` (macOS's own `libssl` is
LibreSSL, without headers) for the TLS builds of the benchmark server, `examples/tls`,
and `test/tls/`.
TinyCC finds the SDK headers through `xcrun --show-sdk-path`, so it needs Xcode or the
Command Line Tools. `goose build --cc gcc` works because macOS's gcc is Apple clang. The
scripts' `ulimit -n 65536` fits the tested per-process fd limit.

| Tool | Version used (2026-10-11) |
|---|---|
| C compiler | Xcode Apple clang 21.0.0 (`clang-2100.0.123.102`) |
| CMake | Homebrew 4.4.4 |
| Python | Homebrew 3.14.8 |
| curl, nc | macOS curl 8.7.1, Apple's nc |
| wrk | Homebrew 4.2.0 |
| h2load | Homebrew nghttp2 1.70.0 |

### Windows

**OS:** tested on Windows 11 Pro 25H2, 10.0.26200 (2026-10-11).

The io_uring loop runs natively on Windows through `shim/iocp.c` and `shim/net_win.c`,
which `http.build` lists under `c_sources_windows`
([architecture](architecture.md#c-in-the-package)), and
`scripts/test-http.sh` and `scripts/test-echo.sh` pass there, in Git Bash. The epoll loop doesn't build on Windows. Windows isn't for benchmarks.
TLS, which IOCP doesn't serve, isn't set up on Windows: `test/run_tests.py`
leaves out `test/tls/` and the tests that import `http.h3` there, and
`scripts/test-examples.sh` `examples/tls`.

The scripts fetch the `windows-x64` release ([Get Goose](#get-goose)). `goose build`
needs the Visual Studio 2026 Build Tools: run
`winget install Microsoft.VisualStudio.BuildTools` with the
`Microsoft.VisualStudio.Workload.VCTools` workload. While a commit is pinned
([Get Goose](#get-goose)), the scripts build it with CMake, which the Build Tools
include but don't put on Git Bash's `PATH`; without it the build stops at
`cmake: command not found` (2026-10-19):

```sh
export PATH="$PATH:/c/Program Files (x86)/Microsoft Visual Studio/18/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"
```

Then, in Git Bash:

```sh
scripts/build.sh                 # LOOP=iocp, CC=msvc: build/server.exe
nice -n 19 python3 test/run_tests.py
nice -n 19 scripts/test-http.sh
nice -n 19 scripts/test-echo.sh
```

`nice -n 19` starts a native program in the Idle priority class, which keeps a test run
from slowing other work on the machine. `goose toolchain` shows the C compilers
`goose build` finds; `CC=clang-cl` picks clang-cl. `test-http.sh` leaves out the load
runs and `emfile` on Windows, and `test-echo.sh` runs only echo-blocking, without nc
([why](../tasks/006-kqueue-iocp/02-iocp-windows.md#tests)). Git Bash has traps of its
own ([known issues](known-issues.md#git-bash)).

| Tool | Source | Version used (2026-10-11) |
|---|---|---|
| C compiler | Visual Studio Build Tools 2026 (18) | MSVC 19.51 (2026-10-10); clang-cl works too |
| Shell, curl | Git for Windows | Git Bash 5.2.26, mingw curl 8.7.1 |
| Python | on `PATH` as `python3` | 3.14.6 |
| oha | its `oha-windows-amd64.exe` release, as `%USERPROFILE%\.local\bin\oha.exe` | 1.16.0, for `bench/oha.sh` (`OHA` names it) |
| VS Code | | 1.85 or later, for the Goose extension (2026-10-10) |

#### Edit on Windows

The Windows compiler typechecks the whole program without running it. With the release
fetched (`scripts/goose.sh` in Git Bash):

```powershell
build\goose-v2026.3-windows-x64\goose.exe --check server\server.goose
build\goose-v2026.3-windows-x64\goose.exe --check test\http\parse.goose
```

`--check` and `-o out.c` don't compile the generated C, so the Linux-only C in `shim/` is
no obstacle on Windows.

The Goose VS Code extension checks on save and underlines errors. Its run commands go
through TinyCC, which can't run the server ([above](#build-and-test)). Install it from
the release:

```powershell
code --install-extension build\goose-v2026.3-windows-x64\vscode\goose-language.vsix
```

It needs VS Code 1.85 or later. If `code` on PATH belongs to an older install, call the
newer install's `bin\code.cmd` directly. `.vscode/settings.json` points it at the Windows
release's compiler and stdlib in `build/` and sets `server/server.goose` as the entry
file, so a check of any file covers the whole program.

#### Check the Windows shims without Windows

With no Windows machine at hand, MinGW-w64 in a container checks that `shim/net_win.c`,
`shim/iocp.c`, and `shim/mail.c` compile, which a change to the Windows shims needs
before a run on Windows:

```sh
docker run --rm -v /tmp/work:/work -w /work ubuntu:26.04 sh -c '
  apt-get update -qq && apt-get install -y -qq gcc-mingw-w64-x86-64 >/dev/null
  for f in net_win iocp mail; do
    x86_64-w64-mingw32-gcc -std=c11 -Wall -Wextra -c shim/$f.c -o /tmp/$f.o
  done'
```

It expects two warnings ([known issues](known-issues.md#mingw-w64)). It doesn't check
MSVC's paths. Without Docker, Zig's C compiler has MinGW's headers too:
`zig cc -target x86_64-windows-gnu -std=c11 -Wall -Wextra -c shim/net_win.c -o /dev/null`,
whose headers lack `SOMAXCONN_HINT`, one error in `net_open_listener` to ignore
(Zig 0.17.0, 2026-10-19). MinGW's headers lack `winnt.h`'s `ReadAcquire`, `ReadNoFence`,
`WriteRelease`, and `ReadAcquire64`, which `shim/mail.c`'s atomics use under MSVC, so
MinGW builds `mail.c`'s C11 atomics. To type-check the MSVC branch, compile a file that
defines those four with the SDK's signatures, defines `_MSC_VER`, and includes
`shim/mail.c`.

### Linux in a VM or container

Linux also runs inside other systems. On Windows, WSL2 runs Ubuntu in a lightweight VM,
and Docker Desktop runs its engine inside WSL2. On a Mac, Docker Desktop runs Linux
containers in its own VM. The ARM tests run in Docker on either host, under emulation
where the host's CPU can't run the architecture.

#### WSL2 on Windows

**OS:** tested on WSL 3.0.3, kernel 6.18.54.1-microsoft-standard-WSL2 (since
2026-10-13).

On a Windows machine, Linux runs as Ubuntu 26.04 in WSL2; the [Linux](#linux) versions
come from there. Set it up as the Linux section describes, in a WSL shell. Run
`scripts/test.sh` for the Linux loops in a clone on WSL's own filesystem, and in Git
Bash for IOCP in the Windows checkout. The clone takes the Windows checkout as a
remote, so a branch reaches Linux without a push:

```sh
git clone /mnt/c/PATH/TO/goose-http ~/goose-http   # once; the checkout is origin
cd ~/goose-http && git fetch origin BRANCH && git checkout --detach FETCH_HEAD
```

A checkout under `/mnt/c` works too, but WSL reaches it through a network filesystem:
`test/run_tests.py` took 67 s there and 48 s in the clone (2026-10-22). Git in WSL
also can't use a Windows `git worktree`, whose `.git` file names a Windows path. Run
`cargo`, for the benchmarks' Rust servers, from a Linux directory: from the Windows
filesystem it inherits Windows configuration. Calling WSL from a Windows shell has
traps of its own ([known issues](known-issues.md#wsl-from-a-windows-shell)).

#### Docker on macOS

To build and test the Linux loops on a Mac, use an arm64 Linux image with the Linux
toolchain and test tools, plus CMake, Ninja, and g++: Goose has no arm64 Linux release,
so `scripts/goose.sh` builds the pinned release's source there. Build the image fresh
rather than reusing a named image from a previous session. The test tools are liburing,
curl, wrk, nghttp2-client, netcat-openbsd, and python3, with libssl-dev and openssl
for TLS. Benchmark builds also need
the Rust, Zig, Odin, and autotools versions of the
[benchmark toolchain](../bench/README.md#toolchain), plus util-linux and procps.

Run the container with `--security-opt seccomp=unconfined` to test native io_uring;
without it, Docker's default seccomp profile blocks io_uring and the server tests the
emulated ring. Mount the working tree read-only and build into a separate output
directory, or run from an export. Mount results separately when recording benchmark
output. To export uncommitted tracked and untracked files as one archive:

```sh
git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C /tmp/work
```

An exported tree has no git metadata, so record the source commit in the run.

h2spec has no arm64 Linux build, and its x86-64 one is linked against glibc, so
`scripts/test-h2spec.sh` skips it in an arm64 container. Run the server there, and
h2spec from an x86-64 `ubuntu:26.04` container in the server container's network
(Docker Desktop runs it under emulation), with h2spec's `linux_amd64` archive
extracted into `/tmp/h2spec`:

```sh
docker run -d --name h2c-srv ... sh -c 'LOOP=epoll scripts/build.sh && build/server http 29080'
docker run --rm --platform linux/amd64 --network container:h2c-srv -v /tmp/h2spec:/h:ro \
    ubuntu:26.04 /h/h2spec -h 127.0.0.1 -p 29082 -P /plaintext -o 2
```

For h2 over TLS, build with `TLS=1`, start the server with `TLS_CERT` and `TLS_KEY`,
and run `GODEBUG=tls13=1 /h/h2spec -t -k -h 127.0.0.1 -p 29443 -P /plaintext -o 2`
(`docker run -e GODEBUG=tls13=1 ...`).

To compare two builds' instructions per request on a Mac, where `bench/count.sh`'s
perf isn't, cross-build each server for arm64 Linux as `scripts/test-aarch64.sh` builds
the examples, and run it with `WORKERS=1` under `valgrind --tool=cachegrind
--cache-sim=no` in an arm64 `ubuntu:26.04` container with `valgrind` and
`nghttp2-client`, stopping it with SIGTERM after `h2load --h1 -n N`. The difference of
`I refs` at two values of N, divided by their difference, is a request's user
instructions, the same in every run (2026-10-22). macOS's `/usr/bin/time -l` counts
the kernel's instructions too, which vary by about 50 a request between runs.

#### ARM under Docker

**OS:** tested in `ubuntu:26.04` containers for arm64 (2026-10-14).

`scripts/test-aarch64.sh` cross-builds every example for aarch64 and runs
`scripts/test-examples.sh` on the builds in an arm64 container, with each one's peak RSS
([embedded Linux](embedded.md#without-the-board-emulated-arm64)). It needs Docker with
ARM emulation, which Docker Desktop has, and isn't part of `scripts/test.sh`.

```sh
scripts/test-aarch64.sh
```

The cross-build runs the Linux build of the compiler in an x86-64 `ubuntu:26.04`
container, which works because WSL's Ubuntu is 26.04 too, with the same glibc. Without
`GOOSE`, `scripts/test-aarch64.sh` uses the pinned release's `linux-x64` archive, which
`scripts/goose.sh` fetches on any host, macOS included. A `GOOSE` of its own must be a
Linux x86-64 build that runs on Ubuntu 26.04; for one copied away from its stdlib,
`GOOSE_STDLIB` names the stdlib.

Every Linux program needs `liburing.so.2` at run time, the epoll-only ones included,
since the package links liburing on Linux; the script's run image installs `liburing2`.
Docker's seccomp profile blocks io_uring, so `LOOP=uring` runs over the emulation in
the arm64 container. Run `scripts/test-examples.sh` in WSL itself for real io_uring.

Docker Desktop on the Mac runs arm64 containers natively in its VM, so their RSS
includes no emulator's memory and doesn't compare with RSS measured on an x86-64 host,
where qemu adds its own ([embedded Linux](embedded.md#without-the-board-emulated-arm64)).

| Tool | Source | Version used (2026-10-14) |
|---|---|---|
| ARM cross compiler | `ubuntu:26.04` in Docker, apt | `aarch64-linux-gnu-gcc` 15.2.0 (`15.2.0-16ubuntu1`), with `liburing-dev` 2.14 |
| glibc | `ubuntu:26.04`, as in WSL | 2.43 |

`test-aarch64.sh` took 53 s in WSL2 and 63 s on the Mac (2026-10-14).

### Test the HTTP server

`test/run_tests.py` runs the tests in `test/http/`, which check what the package's
`message.goose` does with bytes alone, and `test/server/server_routes.goose`, the
server's routes: the parser on good, partial, pipelined, and refused requests, the
`Date` header against dates from Python's `email.utils`, and the exact bytes of each
kind of response.

`scripts/test-http.sh` starts `build/server http` with 4 workers (`WORKERS`) and fails on
the first error. It tests whichever loop `build/server` has, so build each loop and run it
once per loop. It needs curl, wrk, h2load, `nc`, and `python3`. Against the server
it runs:

- Response bytes, keep-alive, pipelining, request framing, and hostile requests.
- Bodies and responses in pieces, upgrades, WebSocket, waiting answers, files, compression,
  client addresses, and the access log.
- Limits, timeouts, many connections, and graceful stop and restart.
- Load checks and fd exhaustion on platforms that support them.
- On the epoll loop's h2c port: responses through `curl --http2-prior-knowledge`, a body
  and a file larger than a stream's window, a short `h2load` run, and a GOAWAY to an
  idle h2c connection at a stop.

The script and `scripts/http_client.py` define the individual modes and requests;
use them for the exact coverage. File checks verify that interrupted downloads leave
no file open, and streaming checks bound peak memory on Linux and Windows.

`LOOP=uring-epoll scripts/test-http.sh`, against the `LOOP=uring` build, tests the
io_uring loop over its emulation on epoll, which it falls back to where io_uring is
blocked ([architecture](architecture.md#completion-loop)). The
fallback itself was tested (2026-10-11) by running the uring build under Docker's
default seccomp profile, with WSL's liburing mounted, and `http_client.py`'s modes from
WSL against it:

```sh
docker run -d --name ghttp -p 29097:29097 -v "$PWD/build/server:/server:ro" \
    -v /usr/lib/x86_64-linux-gnu/liburing.so.2.14:/usr/lib/x86_64-linux-gnu/liburing.so.2:ro \
    -e WORKERS=2 ubuntu:26.04 /server http 29097
python3 scripts/http_client.py 29097 pipeline
```

The io_uring loop's listener outlives its process by a moment: the kernel tears a ring
down after the process exits, and the queued multishot accept holds the listener until
then. `test-http.sh` waits up to 5 s for the port to free before each start.

The load runs check correctness, not speed; their numbers aren't measurements.
`test-http.sh` ignores wrk's timeouts, which WSL2's clock steps make up
([known issues](known-issues.md#wrks-clock-in-wsl2)), and relies on h2load, which uses
a monotonic clock.

### Test the echo servers

`scripts/test-echo.sh` starts each echo server in turn and fails on the first error.
It needs `nc` (`netcat-openbsd`) and `python3`. Against each server it runs:

- `nc` and a one-line echo.
- 10 clients that hang up while the server writes (`scripts/echo_client.py cut`). Half
  fill both directions' buffers and close with data unread, so the server's `send` fails
  with `ECONNRESET`. The other half send 24 KB and close before the echo arrives, so a
  later `send` fails with `EPIPE`, the error that raises `SIGPIPE`. The script checks
  that the server logged an `EPIPE` and is still running.
- Many clients at once, each sending random bytes and checking the echo: 20 clients of
  64 KB for the blocking server, and 2,000 of 64 KB, then 10,000 of 100 bytes, for the
  epoll server.

`PORT` picks the port (default 29080). Keep it below 32768: the many-client runs leave
thousands of client sockets in `TIME_WAIT` on ports in the kernel's ephemeral range,
and a server port among them fails to bind with `EADDRINUSE`.

### Fuzz the parsers

`fuzz/build.sh` builds four libFuzzer targets with AddressSanitizer and
UndefinedBehaviorSanitizer into `build/fuzz/`, from `fuzz/fuzz.goose`, whose comment
says what each feeds and checks: the HTTP/1.1 request head and chunked body
(`fuzz_request`), HPACK (`fuzz_hpack`), h2 frames (`fuzz_h2frame`), and
multipart/form-data (`fuzz_multipart`). Where two paths read the same bytes, as a
chunked body whole and in pieces, the target asserts they agree. The parsers call no
shim function, so the targets link only the program's C.

It needs a clang with libFuzzer: on Linux, the distribution's `clang`; on macOS,
Homebrew's `llvm`, since Apple's clang has none:

```sh
CC=$(brew --prefix llvm)/bin/clang fuzz/build.sh
mkdir -p build/fuzz/corpus-request
build/fuzz/fuzz_request -max_total_time=600 build/fuzz/corpus-request fuzz/seeds/request
```

A crash, a sanitizer report, or a failed assert is a finding; libFuzzer writes the
input to `crash-*` in the working directory, and running the target on that file alone
repeats it.

The first campaign, at `df12a627` on an M1 Pro with Homebrew's LLVM 22, ran each
target for an hour from `fuzz/seeds/` (2026-10-23): 351 M executions of
`fuzz_request`, 39 M of `fuzz_hpack`, 755 M of `fuzz_h2frame`, and 65 M of
`fuzz_multipart`, with no finding. What isn't fuzzed: the loops' connection state, h2
streams and flow control among it, which h2spec covers
([Run every test](#run-every-test)), and WebSocket frames, which Autobahn's fuzzing
client covers.

### Use the package from git

A program outside the repository imports the package as a user's does, at a pushed
commit, by its full hash: `import http from
"github.com/kaitk/goose-http@<40-hex hash>";`. Git can't fetch an abbreviated hash.
The compiler fetches it into `~/.goose/pkg/github.com/kaitk/goose-http/<12-hex
hash>/`. Check both `goose build` and `goose run`, the second with a program that calls
`http::serve` from `main`: TinyCC can't run one that reaches `thread_spawn`.

## Benchmarks

Benchmarks run on Linux. [bench/README.md](../bench/README.md) sets them up: the
competing servers' toolchains, the scripts and their settings, the measurement method,
and HttpArena under Docker on macOS. [benchmarks.md](benchmarks.md) owns the current
comparisons and the build and Goose commit each one measured
([pins](benchmarks.md#pins)), and [results.md](results.md) links their evidence.
[Known issues](known-issues.md#benchmarks) lists what can spoil a run.

## Use another compiler

Use another compiler only when the release can't do the job, such as for a Goose fix
not yet released. Two settings choose one, and the first set wins:

| Setting | Compiler |
|---|---|
| `GOOSE` | The binary it names, such as a checkout's build or a release unpacked elsewhere. |
| `GOOSE_COMMIT` | That commit of `aardappel/goose`, cloned into `build/goose-<commit>/` and built with CMake (and Ninja if installed) on first use. Give the full 40-hex hash; a shallow fetch can't resolve an abbreviated one. |

`bench/*.sh` record which compiler ran in `env.txt`: the release's tag, or a checkout's
commit.

To build a checkout by hand, clone it anywhere and point `GOOSE` at its build. Don't edit
the checkout: work around Goose's gaps in this repository, and record them in
[Goose findings](goose-findings.md). TinyCC, which lets
`goose file.goose` run a program in process, is vendored, so the checkout has no
submodules:

```sh
git clone -o upstream https://github.com/aardappel/goose.git ../goose
cmake -S ../goose -B ../goose/build-linux -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build ../goose/build-linux
export GOOSE=$PWD/../goose/build-linux/goose
```

On Windows, configure with `-G "Visual Studio 18 2026"` instead and build with
`--config Release`. The compiler is then `..\goose\build\Release\goose.exe`. CMake comes
with the Visual Studio Build Tools, at
`Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`.

A checkout's compiler finds the stdlib by walking up to four directories from its own
binary; a release's sits beside it. A compiler copied anywhere else needs
`GOOSE_STDLIB` pointing at a `stdlib/`. The compiler reads that itself and says where it
looked when it finds none.
