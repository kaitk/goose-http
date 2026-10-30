#!/usr/bin/env python3
"""Runs the tests under test/<area>/, as Goose's own test/run_tests.py does.

Each test/<area>/<name>.goose is a program. The runner typechecks them in
batches, a `goose --multi-test --check` run per batch; builds each with
`goose build` at -O0 and at -O2, which compiles the C the package's sidecar
(http.build), or a test's own, names for the platform; and runs each as a
process of its own, all in parallel. A run passes when its stdout is
test/expected/<name>.out, every nonblank line of test/expected/<name>.stderr,
if there is one, occurs in its stderr, and it exits 0, or not 0 where
test/expected/<name>.aborts exists. Each test builds and runs in a directory
of its own, build/test/O<level>/<name>/, so files it writes meet no other's,
and each run gets a fresh TMPDIR of its own in the system's temporary
directory, for files such as Unix sockets that the checkout's filesystem may
not hold (WSL's /mnt/c).

A file with `// error: <message>` lines is a fixture that must not compile:
`goose --multi-test --check` must exit 1, with each message in its diagnostics.

Every failure is reported, with a count per area at the end. GOOSE or
GOOSE_COMMIT names the compiler (default: the pinned release,
scripts/goose.sh), and CC the C compiler, as for `goose build --cc`.

    test/run_tests.py [-j N] [-O LEVEL] [--bless] [-v] [AREA | NAME ...]
"""

import argparse
import concurrent.futures
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
EXPECTED = HERE / "expected"
OUT = ROOT / "build" / "test"
WINDOWS = os.name == "nt"
EXE = ".exe" if WINDOWS else ""
LEVELS = (0, 2)
# Long enough for the mail tests' threads on a loaded machine; a test that
# hangs fails rather than stopping the run.
TIMEOUT = 300

# What `goose --multi-test` ends each file's part of stdout and of stderr with,
# on a line of its own, followed by the file's exit code and name.
MULTIMARK = "==== goose --multi-test: exit"


def run(argv, cwd=None, env=None):
    """(exit code, stdout, stderr) of argv, as text with LF line endings."""
    try:
        r = subprocess.run([str(a) for a in argv], cwd=cwd, env=env, capture_output=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, "", f"timed out after {TIMEOUT} s"
    def text(b):
        return b.decode("utf-8", errors="replace").replace("\r\n", "\n")
    return r.returncode, text(r.stdout), text(r.stderr)


def joined(text):
    """Output as it is compared and blessed: no trailing blank lines."""
    return text.rstrip("\n")


def find_goose():
    goose = os.environ.get("GOOSE")
    if not goose:
        code, out, err = run(["sh", ROOT / "scripts" / "goose.sh"])
        if code != 0:
            sys.exit(f"scripts/goose.sh failed:\n{err}")
        goose = out.strip()
    # Git Bash's shell gives its own form of a path, /c/..., which Windows
    # programs don't read.
    if WINDOWS and goose.startswith("/"):
        goose = run(["cygpath", "-w", goose])[1].strip()
    return goose


def split_multi(text, files):
    """{file: (exit code, what it printed)} for each of `files` that a
    `goose --multi-test` stream has the mark of."""
    parts, pos = {}, 0
    for f in files:
        m = re.compile(rf"\n{re.escape(MULTIMARK)} (-?\d+) {re.escape(str(f))}\n").search(text, pos)
        if not m:
            break
        parts[f] = (int(m[1]), text[pos:m.start()])
        pos = m.end()
    return parts


def multi_test(goose, args, files):
    """{file: (exit code, stdout, stderr)} for each of `files`, as a run of
    `goose *args file` of its own would give it, from one `goose --multi-test`
    run. A file that run didn't get through, because the compiler crashed on
    it or before it, runs alone."""
    code, out, err = run([goose, "--multi-test", *args, *files], cwd=ROOT)
    outs, errs = split_multi(out, files), split_multi(err, files)
    done = {}
    for f in files:
        if f in outs and f in errs:
            done[f] = (outs[f][0], outs[f][1], errs[f][1])
        else:
            done[f] = run([goose, *args, f], cwd=ROOT)
    return done


def batches(files, jobs):
    size = max(1, -(-len(files) // jobs))
    return [files[i:i + size] for i in range(0, len(files), size)]


def arg(test):
    """A test's path as the compiler is given it, and prints it back."""
    return test.relative_to(ROOT).as_posix()


class Tests:
    def __init__(self, goose, cc, jobs, levels, bless, verbose):
        self.goose, self.cc, self.levels = goose, cc, levels
        self.bless, self.verbose = bless, verbose
        self.pool = concurrent.futures.ThreadPoolExecutor(jobs)
        self.jobs = jobs
        self.failed = set()

    def report(self, test, label, problem=None, detail=""):
        name = f"{test.parent.name}/{test.stem}"
        if problem is None:
            if self.verbose:
                print(f"ok   {name} {label}")
            return
        self.failed.add(test)
        print(f"FAIL {name} {label}: {problem}")
        if detail.strip():
            print("    " + joined(detail).replace("\n", "\n    "))

    def typecheck(self, tests):
        """{test: (exit code, stdout, stderr)} of `goose --check` on each."""
        futures = [self.pool.submit(multi_test, self.goose, ["--check"], [arg(t) for t in b])
                   for b in batches(tests, self.jobs)]
        results = {}
        for future in futures:
            results.update(future.result())
        return {t: results[arg(t)] for t in tests}

    def check_errors(self, fixtures, checked):
        """Each fixture must fail to compile with each of its `// error:`
        messages in a diagnostic, a line `file:line: error: message`, rather
        than in the source the compiler echoes."""
        for f in fixtures:
            code, out, err = checked[f]
            markers = re.findall(r"^// error: (.+)$", f.read_text(encoding="utf-8"), re.MULTILINE)
            diagnostics = "\n".join(re.findall(r"^\S.*:\d+(?::\d+)?: error: (.*)$",
                                               err, re.MULTILINE))
            missing = [m for m in markers if m not in diagnostics]
            if code != 1:
                self.report(f, "--check", f"compiler exit {code}, expected 1", out + err)
            elif missing:
                self.report(f, "--check", f"no diagnostic {missing}", err)
            else:
                self.report(f, "--check")

    def build_and_run(self, test):
        """{level: (build failure, or None; exit code, stdout, stderr of the
        run)}. The levels build one after another: goose build writes a
        program's C to the same file under ~/.goose/build/prog/ at each."""
        results = {}
        for level in self.levels:
            work = OUT / f"O{level}" / test.stem
            work.mkdir(parents=True, exist_ok=True)
            exe = work / test.stem
            cc = ["--cc", self.cc] if self.cc else []
            code, out, err = run([self.goose, "build", f"-O{level}", *cc, "-o", exe,
                                  test.as_posix()], cwd=work)
            if code != 0:
                results[level] = (out + err, None)
            else:
                tmp = tempfile.mkdtemp(prefix=f"goose-http-{test.stem}-")
                try:
                    results[level] = (None, run([exe.with_name(test.stem + EXE)], cwd=work,
                                                env={**os.environ, "TMPDIR": tmp}))
                finally:
                    shutil.rmtree(tmp, ignore_errors=True)
        return results

    def check_programs(self, programs, checked):
        runs = {}
        for f in programs:
            code, out, err = checked[f]
            if code != 0:
                self.report(f, "--check", "doesn't compile", out + err)
            else:
                runs[f] = self.pool.submit(self.build_and_run, f)
        for f, future in sorted(runs.items(), key=lambda r: str(r[0])):
            for level, (failure, result) in future.result().items():
                if failure is not None:
                    self.report(f, f"-O{level}", "goose build failed", failure)
                else:
                    self.check_run(f, level, *result)

    def check_run(self, test, level, code, out, err):
        label = f"-O{level}"
        expected = EXPECTED / f"{test.stem}.out"
        aborts = (EXPECTED / f"{test.stem}.aborts").exists()
        if aborts and code == 0:
            return self.report(test, label, "exit 0, expected an abort", out + err)
        if not aborts and code != 0:
            return self.report(test, label, f"exit {code}", out + err)
        stderr_file = EXPECTED / f"{test.stem}.stderr"
        if stderr_file.exists():
            lines = [l.strip() for l in stderr_file.read_text(encoding="utf-8").splitlines()]
            missing = [l for l in lines if l and l not in err]
            if missing:
                return self.report(test, label, f"stderr lacks {missing}", err)
        if self.bless and level == self.levels[0]:
            if not expected.exists() or joined(expected.read_text(encoding="utf-8")) != joined(out):
                EXPECTED.mkdir(exist_ok=True)
                with open(expected, "w", encoding="utf-8", newline="\n") as f:
                    f.write(joined(out) + "\n")
                print(f"blessed {expected.relative_to(ROOT).as_posix()}")
        if not expected.exists():
            return self.report(test, label, f"no {expected.relative_to(ROOT).as_posix()}")
        want = joined(expected.read_text(encoding="utf-8").replace("\r\n", "\n"))
        got = joined(out)
        if got != want:
            diff = difflib.unified_diff(want.splitlines(), got.splitlines(),
                                        "expected", "got", lineterm="")
            return self.report(test, label, "stdout differs", "\n".join(diff))
        self.report(test, label)


def find_tests(names):
    """test/<area>/*.goose, or those of them whose area or name is in `names`."""
    tests = sorted(p for p in HERE.glob("*/*.goose") if p.parent != EXPECTED)
    # test/tls/'s programs, client/client, and those that import http.h3 build
    # goose-tls, which builds with OpenSSL, not yet set up on Windows
    # (docs/development.md, "OpenSSL"). outbound_loop, timeout_tag, and
    # client/client listen on Unix sockets and serve on serve_epoll, which
    # Windows lacks.
    if WINDOWS:
        skip = {"outbound_loop", "timeout_tag", "client"}
        tests = [t for t in tests if t.parent.name != "tls" and t.stem not in skip
                 and "import http.h3;" not in t.read_text(encoding="utf-8")]
    stems = {}
    for t in tests:
        if t.stem in stems:
            sys.exit(f"two tests named {t.stem}: {stems[t.stem]} and {t}; "
                     "test/expected/ needs each name once")
        stems[t.stem] = t
    if names:
        wanted = [Path(n).stem for n in names]
        tests = [t for t in tests if t.stem in wanted or t.parent.name in wanted]
        if not tests:
            sys.exit(f"no test or area named {', '.join(names)}")
    return tests


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("names", nargs="*", metavar="AREA | NAME",
                    help="run only these areas (http) or tests (parse)")
    ap.add_argument("-j", "--jobs", type=int, default=min(32, os.cpu_count() or 1),
                    help="how many things to do at once (default: one per processor)")
    ap.add_argument("-O", dest="level", type=int, choices=LEVELS,
                    help="build at this level only (default: -O0 and -O2)")
    ap.add_argument("--bless", action="store_true",
                    help="write each run's stdout to its test/expected/<name>.out")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the passes too")
    args = ap.parse_args()

    tests = find_tests(args.names)
    errors = [t for t in tests if re.search(r"^// error: ", t.read_text(encoding="utf-8"),
                                            re.MULTILINE)]
    programs = [t for t in tests if t not in errors]
    goose = find_goose()
    levels = (args.level,) if args.level is not None else LEVELS
    suite = Tests(goose, os.environ.get("CC"), args.jobs, levels, args.bless, args.verbose)
    checked = suite.typecheck(tests)
    if errors:
        suite.check_errors(errors, checked)
    if programs:
        suite.check_programs(programs, checked)
    suite.pool.shutdown()

    for area in sorted({t.parent.name for t in tests}):
        n = sum(1 for t in tests if t.parent.name == area)
        bad = sum(1 for t in suite.failed if t.parent.name == area)
        print(f"== {area}: {n - bad} passed" + (f", {bad} failed" if bad else ""))
    print(f"== {len(tests)} tests at " + ", ".join(f"-O{l}" for l in levels) + ": "
          + (f"{len(suite.failed)} failed" if suite.failed else "all passed"))
    sys.exit(1 if suite.failed else 0)


if __name__ == "__main__":
    main()
