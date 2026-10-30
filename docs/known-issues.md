# Known issues

Environment traps and incidents met while building, testing, and benchmarking
goose-http, grouped by platform. A date records when an incident happened. Setup steps
are in [development](development.md).

## WSL2 on Windows

### wrk's clock in WSL2

wrk 4.1.0 times requests with the wall clock, `gettimeofday`, and WSL2 steps its wall
clock back by about a millisecond every 30 s or so. wrk then counts each request in
flight across the step as a timeout, one per connection (64 for `-c 64`), with no slow
response behind them. `scripts/test-http.sh` ignores wrk's timeouts for that reason, and
`bench/run.sh` preloads `wrk-monotonic.so` to give wrk a monotonic clock.

### Kernel and toolchain

- Windows Update can stop WSL distributions and change the kernel. Check each run's
  `env.txt`; don't compare across a kernel change as if only the server changed.
  If Docker Desktop loses its WSL engine, restore WSL integration before running
  HttpArena.
- Run cargo and Zig dependency builds from a Linux filesystem cache. Cargo under
  `/mnt/c` can inherit Windows configuration; Zig package renames there can fail
  with `AccessDenied`. `bench/build.sh` uses its Linux cache.
- perf uses the WSL kernel and needs elevated access to hardware counters. A warning
  about `/proc/schedstat` doesn't by itself mean the recording failed.
- perf 6.18 in WSL2 resolved no symbols of the server, even built with `-g`, and
  `goose build` keeps none (2026-10-19). To profile, compile the generated C
  (`~/.goose/build/prog/server-*/server.c`, the newest with the change: a build in
  another checkout writes its own there) with the shims `http.build` lists, `-I` the
  Goose checkout's `src/runtime`, `-O2 -g -fno-omit-frame-pointer -no-pie`, and
  `-luring -lm -pthread`, then resolve `perf script`'s addresses with `addr2line -f -i`.
- A Unix socket can't listen on `/mnt/c`: `listen` fails with `Operation not
  supported`. `test/run_tests.py` gives each test program a `TMPDIR` of its own in the
  system's temporary directory, and a test that listens on a Unix socket puts it there,
  as `test/outbound/outbound_loop.goose` does; one that put it in its working
  directory under `build/test/` failed from a checkout under `/mnt/c` (2026-10-19).
- Docker Desktop's host network is the Docker VM's, not WSL's loopback. HttpArena's
  readiness probes and cgroup reads use helper containers; published ports reach WSL.
  A container on the host network reaches a server in WSL at WSL's own address
  (`hostname -I`), not `127.0.0.1`, so `scripts/test-h3.sh` aims its client there
  (2026-10-24).
- The distribution's and Docker Desktop's virtual disks (`ext4.vhdx`,
  `docker_data.vhdx`) live on the Windows drive and only grow: what's deleted inside
  them frees nothing on Windows. Builds feed both. Each HttpArena run rebuilds entry
  images into Docker's build cache, and Goose keeps every program it builds under
  `~/.goose/build/prog`. On 2026-10-24 the drive filled: Docker's storage turned
  read-only during a build, and at the next start Docker Desktop took its
  still-attached data disk for an empty one and tried to format it. Prune after a
  benchmark session (`docker builder prune -af`, and `~/.goose/build/prog` folders
  older than a few days). After a large cleanup, quit Docker Desktop, run
  `wsl --shutdown`, and compact each disk with `diskpart`'s `compact vdisk`, as
  administrator. diskpart can't compact a sparse disk, and a sparse one
  (`wsl --manage --set-sparse`) makes Windows allocate as the guest writes, which
  costs writes during a run. If Docker's storage turns read-only, free space on the
  drive and run `wsl --shutdown` before starting Docker Desktop again.
- A file in WSL edited from Windows through `\\wsl.localhost` loses its execute bit,
  because the editor replaces the file. `git diff` shows the mode change; restore it
  with `chmod +x` (2026-10-24).

### WSL from a Windows shell

Name the WSL distribution explicitly: `wsl.exe -d Ubuntu`. Docker Desktop can change
the default to a distribution with no bash. For commands containing shell variables,
put them in a script and run `wsl.exe -d Ubuntu -- bash /mnt/c/.../script.sh`; the
intermediate shell can otherwise expand variables before bash sees them.

- The name `Ubuntu` isn't always 26.04: a machine can have an older distribution under
  it and 26.04 as `Ubuntu-26.04`. Check with `cat /etc/os-release` before a test run
  (2026-10-22).
- Git in WSL can't use a worktree that Windows git made: its `.git` file names a
  Windows path, and every git command there fails with "not a git repository". Test
  Linux from a clone on WSL's own filesystem instead
  ([development](development.md#wsl2-on-windows)), which also builds faster than
  `/mnt/c`.
- A fresh distribution may lack `libssl-dev`, and the TLS tests then fail at CMake's
  "Could NOT find OpenSSL". Install the Linux section's packages in it.

- Git Bash rewrites POSIX-looking arguments. Set `MSYS_NO_PATHCONV=1` for a WSL call;
  PowerShell doesn't rewrite paths.
- A non-login script doesn't read the WSL profile. Export the oha path, and `GOOSE` or
  `GOOSE_COMMIT` when not using the release, inside it.
- Run cargo with `cd ~` first, or use WSL's `--cd` option, to avoid inheriting
  configuration from parent directories on the Windows filesystem.
- Keep a long benchmark's foreground WSL call open. A detached run may end when the
  call returns; a background server may instead survive and retain its port.
- Use different `PORT` values for simultaneous Linux and Windows HTTP tests. WSL's
  localhost forwarding can make one suite's listener visible to the other's port
  probe, which reports the port taken (2026-10-14).
- Bash reads a script's later commands from the file as it runs, so editing a running
  script changes what it does. Editing a benchmark script during its builds caused an
  unexpected EOF before measurement began (2026-10-14). Prepare a separate script for
  an extension.
- `pkill -f` inside `bash -c` can match and kill that shell, and killing strace doesn't
  kill the server it started. Kill by PID.
- Windows and WSL git record different file stats. The first WSL diff after Windows
  git can reread the whole checkout, delaying benchmark startup.
- A WSL `git push` stalled after fetch had succeeded, while Git for Windows pushed
  the same commit successfully (2026-10-14). End the stalled push by PID before
  retrying from Windows; both Git installations share this checkout. The cause
  wasn't established.
- WSL's `/tmp` was empty again in a later call from Windows, after its VM restarted
  between calls (2026-10-19). Keep what a later call needs under the home directory.
- A pinned Goose commit built in WSL leaves its CMake cache in
  `build/goose-<commit>/build/`, and Git Bash's `scripts/goose.sh` then fails in the
  same tree: "The current CMakeCache.txt directory ... is different than the directory
  /mnt/c/... where CMakeCache.txt was created". A short hash in `GOOSE_COMMIT` can't be
  fetched. For Windows in the same tree, clone that checkout into another directory
  under `build/`, build it with CMake, and set `GOOSE` to its
  `build/Release/goose.exe` (2026-10-19).
- Git for Windows 2.45 writes absolute Windows paths in worktree `.git` files that
  WSL git can't follow. A relative `gitdir: ../goose-http/.git/worktrees/<name>`
  works for both.
- Windows Python defaults can write cp1252 and CRLF, and shell heredocs add another
  escaping layer ([line endings on Windows](#line-endings-on-windows)).

## Linux

### A killed io_uring server's listener outlives it

A server on io_uring that a signal kills, rather than stops, keeps its listener open
for a few milliseconds after the process has exited: the multishot accept holds a
reference to the socket, and the kernel tears the ring down on a workqueue after the
exit. A successor binds the same port beside it, since both set `SO_REUSEPORT`, and the
kernel can hand a new connection to the dying listener, which resets it as it closes.
A readiness probe that lands there passes before the successor listens, and the next
connect is refused. With `http::stop_on_signals`, `SIGTERM` stops the loop instead,
which cancels the accept and closes the listener before the process exits. The epoll
loop's listener closes with the process either way.

`scripts/test-drain.py` restarts `examples/drain.goose` on one port, from `LOOP=uring`
to `LOOP=epoll`. Before the example called `stop_on_signals`, the epoll half failed
with `ECONNRESET` or `ECONNREFUSED` in 11 of 40 runs in an arm64 Linux container with native
io_uring (kernel 7.0, Docker Desktop on macOS): `waitpid` returned with the uring
server's listener still in `/proc/net/tcp`, for 2 to 6 ms (2026-10-23).
`scripts/test-drain-turns.py` does the same with `scripts/fixtures/drain_turns.goose`,
whose epoll half failed with `ECONNRESET` once in WSL2 before the fixture called
`stop_on_signals` too (2026-10-25).

### A ring torn down with a gathered send in flight keeps its blobs' references

`ur_destroy` (`shim/uring.c`) doesn't free the sends io_uring still has in flight: only a
completion says when the kernel is done with their bytes. A gathered send among them
(`send_shared` on io_uring) keeps its shared blobs' references, so those blobs are never
freed. The ring is torn down only as its loop ends, so a process that stops leaks
nothing that outlives it; a program that runs a loop again in the same process keeps
those blobs. The emulated ring sends synchronously and frees every queued send at
teardown (2026-10-28). IOCP's `ur_destroy` (`shim/iocp.c`) frees nothing, for the same
reason, so there every gathered send still queued at teardown, in flight or not, keeps
its references (2026-10-30).

## Benchmarks

- When V fails to compile the C it generated, it downloads a V release and retries with
  it, unpinned. A missing `liburing.h` did that once; a build whose output mentions
  `v1-fallback` didn't use the pinned V, so fix the cause and rebuild.
- wrk rounds connections down to a multiple of its thread count. Give it a thread
  count dividing each cell's connection count. wrk 4.1.0 also needs a space after
  the colon in `-H "Host: tfb-server"`.
- oha with `-z` aborts the requests in flight at the deadline and lists them as
  errors. A request count avoids them.
- Check status counts when benchmarking `/later` with a small `MAIL_SLOTS`: the
  benchmark backend drops replies on `FULL`, and the resulting wait timeouts can
  dominate a fixed-count run's rate. The
  [WAKE measurement](../bench/results/2026-10-14-mail-wake-method.md#results-and-limits)
  records this with 256 connections and 64 slots per worker (2026-10-14).
- HttpArena validation can leave its watchdog holding output open until
  `VALIDATE_TIMEOUT` expires. Read output as it arrives instead of piping it to
  `tail`.
- vanilla-epoll's JSON build with `-gc none` leaks enough memory to exhaust the VM.
  Leave those cells out of unattended matrices or isolate them in their own run.
- A distribution's firewall filters loopback too. On Bazzite 43, `nf_tables` and
  `nf_conntrack` took 10-16% of a one-worker server's CPU under h2load on 127.0.0.1
  (2026-10-20), as kernel time charged to the server. Say whether such rules were
  loaded when comparing kernel instructions between machines.
- Rootless podman on Bazzite 43 can't pin a container: systemd delegates only `cpu io
  memory pids` to the user's cgroup, so `--cpuset-cpus` fails with "controller `cpuset`
  is not available" (2026-10-21). HttpArena's harness pins its server and load
  generators that way. Delegating `cpuset` too, with a drop-in for `user@.service`
  (`[Service]` and `Delegate=cpu cpuset io memory pids`) and a new login, should let it
  run; this wasn't tried. `--ulimit nofile=1048576` and `--network host` work rootless.

## macOS

- macOS holds closed client ports in `TIME_WAIT` for 30 s. Wait between large client
  runs; `scripts/test.sh` drains between stages. Count remaining sockets with
  `netstat -an -p tcp | grep -c TIME_WAIT`.
- Two checkouts' `scripts/test.sh` at once share the 16,384 ephemeral ports
  (49152-65535), and `test-http.sh`'s `many` holds 10,000 of them, then leaves them in
  `TIME_WAIT`. The second run's `many` then fails with `Can't assign requested address`
  or a connect timeout, on any loop (2026-10-19). Run one suite at a time, or wait 30 s
  after the other's `many`; a distinct `PORT` doesn't help.
- `kern.ipc.somaxconn` defaults to 128, limiting the listen backlog. The tests pass
  there; `sudo sysctl kern.ipc.somaxconn=4096` raises it until reboot.
- `lsof` resolves `/var` and `/tmp` through `/private`. Match resolved paths when
  checking open files.
- Apple's `nc -N` means keepalive probes, not OpenBSD's shutdown-after-input.
  The echo test checks nc's help and uses `-w 2` otherwise.
- Native loopback comparisons are kernel-limited; see
  [measurement limits](results.md#m1-pro-macos-native). Separate `SO_REUSEPORT`
  listeners can also leave a competing server using only one worker.
- `sample PID 5` profiles without sudo, but includes time blocked in `kevent`.
  `/usr/bin/time -l` reports retired instructions and elapsed cycles, including
  kernel work, after the process exits. It is less precise than fixed-count perf
  comparisons for changes of only a few instructions.

### Docker on macOS

- Passing an export's file list through xargs can produce several archives, and
  extraction stops after the first. Export as one archive
  ([development](development.md#docker-on-macos)).
- Transparent huge pages can inflate RSS relative to WSL. Record their setting;
  disabling them with `prctl(PR_SET_THP_DISABLE)` gives measurements with 4 KB pages.
- The VM can hide the CPU part number. `bench/build.sh` selects Zig's `apple_m1`
  rather than a generic arm64 target for this host.
- Tina can require `--security-opt seccomp=unconfined` to map its shard memory.
  Keep its `[FATAL]` lines when inspecting logs.
- A container's connection to a server on the Mac through `host.docker.internal` can
  time out while the server answers the Mac itself at once: Autobahn's fuzzing client
  lost one in section 9, after several MB of messages, in about one full run in four,
  and stopped there (2026-10-19). `scripts/test-autobahn.sh` runs the cases a run didn't
  reach again. A file the container writes to a mounted directory can also reach the
  Mac stale, and one the Mac writes reach the container stale or not at all, so the
  script passes its configuration and results through the container's stdin and
  stdout.
- The REST server, `bench/rest/goose/rest.goose`, doesn't link natively on macOS: it
  calls glibc's `mallopt`. `goose check` still type-checks it; build it and run
  `bench/rest/check.py` against it in an arm64 Linux container (2026-10-16).
- The VM's wall clock can step forward mid-run. `http_client.py` times with
  `time.time()`, and a step during `later` failed a 0.2 s reply as taking 1160 s
  (2026-10-19). Rerun the suite when a time check fails by minutes.
- Counting a request's instructions under valgrind 3.22 in an arm64 container
  ([development](development.md#docker-on-macos)) has limits by loop (2026-10-30).
  On epoll, valgrind runs out of address space after about 4,500 requests, so the two
  totals stay below that. The io_uring server doesn't exit on SIGINT or SIGTERM
  under valgrind, so cachegrind, which writes its counts at exit, gives none there;
  callgrind does, with `callgrind_control -d`, but only for some builds: d36d06c2's
  and d81c640c's servers ran out of address space at their first request, with
  137 GB mapped, and 4e7eaec3's ended at its first, while 474187c8's and bd6a7d2a's
  served 1,300 requests. Both servers run under
  `--tool=none` and natively, so the limit is callgrind's, and an io_uring
  comparison needs both builds to pass under it.

## Windows

- With only Visual Studio 2022 17.6, MSBuild rejects Goose's C standard when building a
  checkout: `Element <LanguageStandard_C> has an invalid value of "stdclatest"`
  (2026-10-12). Install the Visual Studio 2026 Build Tools.
- The Windows Performance Toolkit of the Windows 10 SDK, 10.0.20348, can't read a trace
  that `wpr` records on Windows 11 10.0.26200: `xperf -a profile` stops with
  `ISession::ProcessEvents [0x80070032]` (2026-10-12). Read it with the current Windows
  Performance Analyzer, from the Microsoft Store.
- `wpr -start CPU` and `wpr -stop file.etl` need an elevated shell. `wpr -stop` takes a
  minute or more to write the trace; Ctrl+C in that time cancels it with `0x800704c7`
  and discards the recording, and the next `wpr -stop` finds no profile running.
- `Get-Process`'s CPU times print with the locale's decimal separator, a comma in some
  locales; `bench/oha.sh` formats them with the invariant culture.
- The default listener is 127.0.0.1. Explicit IPv4 and IPv6 addresses are supported;
  listening elsewhere can raise a Windows Defender Firewall prompt.
- A connection to a port nothing listens on is refused only after Windows retries for
  about 2 s, so a client with a shorter timeout sees a timeout, not a refusal.
- Python's `os.kill(pid, signal.SIGTERM)` ends a process at once, as `TerminateProcess`
  does. For a graceful stop, start the server with `CREATE_NEW_PROCESS_GROUP` and send
  `signal.CTRL_BREAK_EVENT` to its PID; a path for `subprocess` must be absolute
  (`cygpath -m "$PWD/build/server.exe"`).
- A send to a peer that has closed fails with `WSAECONNABORTED`, which the shim reports
  as `ECONNABORTED` (103), as libuv does; Linux gives `EPIPE` or `ECONNRESET`
  (2026-10-22). A check for a closed peer takes all three.
- On IOCP, `serve` refuses a TLS listener and a second listener with `ENOSYS`, where
  the other loops refuse a TLS listener without goose-tls with `EINVAL`
  (2026-10-22).
- A program that makes an `http.client` session builds goose-tls, whose CMake step
  stops at "Could NOT find OpenSSL" without OpenSSL 3 (2026-10-22), so
  `test/run_tests.py` leaves out `test/client/client.goose` on Windows.
- h2spec v2.6.0 has a Windows release, `h2spec_windows_amd64.zip` (SHA-256
  `57b608578bd9c8c3b6b821c2ab64925a6caee16185b356fff611a7a86fe8e697`), but
  `scripts/test-h2spec.sh` fetches only the Linux and macOS ones, and the benchmark
  server serves h2c on a second listener, which IOCP doesn't take. A program that
  serves h2c on its only port (`Config.h2c`) passed all 146 tests on IOCP
  (2026-10-22).

### Line endings on Windows

With `core.autocrlf=true`, `.c`, `.goose`, and `.md` files are CRLF on disk and LF in
git, while `.gitattributes` keeps `.sh`, `.py`, and the golden files in `test/expected/`
LF. A scripted search and replace that
assumes LF finds nothing in a CRLF file, and one that writes `\n` turns a whole CRLF file
into a one-line-per-change diff. `\r`, `\n`, and `\` inside a heredoc pass through two
rounds of escaping and come out as raw control bytes or literal text. An editor that
keeps each file's endings needs no escaping.

### Git Bash

- Back-to-back runs of `scripts/test.sh` leave thousands of connections to port 29080
  in `TIME_WAIT`, which Windows keeps for 240 s. A run started before they drain fails
  at random with client connect timeouts (`TimeoutError`, `WinError 121`, or
  `WinError 52`), anywhere from `keepalive` to `many` (2026-10-12). Wait until
  `(Get-NetTCPConnection -State TimeWait | Measure-Object).Count` is low again. Windows
  has 16,384 ephemeral ports; changing the server's `PORT` doesn't replenish them.
  A drained stack isn't always enough: on 2026-10-19, `many` failed with `WinError 121`
  in two of three `scripts/test.sh` runs started with fewer than 200 connections in
  `TIME_WAIT`, while load tests ran in WSL2 on the same machine; four runs of
  `test-http.sh` alone, three under that load, with and without `nice -n 19`, passed.
  Rerun before suspecting the IOCP loop.
- A Linux build in the same tree leaves an ELF `build/server` beside `build/server.exe`,
  and Git Bash runs `build/server` first, which fails with "Exec format error". The test
  scripts name `build/server.exe` on Windows; do the same by hand.
- `ulimit -n` fails, and wouldn't reach a native program anyway.
- Git Bash's `kill` doesn't always end a native program. The test scripts end the server
  with `taskkill //F //PID` and the Windows process ID from `/proc/$pid/winpid`.
- `cd dir && build/server.exe ... &` puts the whole list in a background subshell, so
  `$!` and its `/proc/$!/winpid` name the subshell, and `taskkill` on that PID leaves the
  server running. Start the server alone with `&`, after the `cd`.
- MSYS rewrites arguments that look like paths, so `cmd /c` becomes `cmd C:/`. Run it
  with `MSYS2_ARG_CONV_EXCL='*'`. Writing `//c` with path conversion turned off
  (`MSYS_NO_PATHCONV=1`) passes `//c` through, and leaves `cmd` waiting for input.
- Git Bash's `tar` reads an archive path that starts with a drive letter, such as
  `C:\Users\...\tree.tar` from `$TEMP`, as a remote host, fails with "Cannot connect
  to C: resolve failed", and extracts nothing. Pass `--force-local`, or a `/c/...`
  path.
- Git Bash's mingw curl 8.7.1 has no HTTP/2: `--http2-prior-knowledge` fails with
  "the installed libcurl version doesn't support this" (2026-10-22).

### MinGW-w64

The [MinGW-w64 check](development.md#check-the-windows-shims-without-windows) warns
twice about code that MSVC builds as intended: MinGW has no `SOMAXCONN_HINT`
(`shim/net_win.c`), and a sign comparison in `shim/iocp.c` (2026-10-12, at `551ee19`).

## ARM under Docker

- Under Docker Desktop's file sharing, git in a container can see a mounted directory
  as another user's and refuse it ("detected dubious ownership"), which stopped the
  fetch of `examples/compress`'s package. `scripts/test-aarch64.sh` sets `safe.directory`
  through git's environment.
- `goose build --cc` takes the names `gcc`, `clang`, and `cc`, or a path, so a cross
  compiler goes by its path: `--cc /usr/bin/aarch64-linux-gnu-gcc`. A bare
  `aarch64-linux-gnu-gcc` fails with "unknown C compiler name".
- `kill %1` in a `sh -c` script does nothing, because a non-interactive `sh` has no job
  control, and a `wait` after it waits forever. Kill by `$!`.
