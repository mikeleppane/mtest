#!/usr/bin/env python3
"""Retry-then-crash `--mojo` stand-in — drives the BUILD-RETRY attribution path.

Stands in for the real `mojo` binary the same way the adjacent
`fake_slow_mojo.py` does. It routes every child
mtest spawns through this script first. It exists to reach ONE otherwise
unreachable state: a file whose CRASH verdict was earned by a binary at
`build/bin/<mangled>.attempt-N` rather than `build/bin/<mangled>`.

mtest gets there on its own: a crash-class BUILD failure is retried, and the
retry rebuilds to a FRESH `.attempt-N` output path and then RUNS that binary. If
that rebuilt binary crashes at runtime, the mangled name never names the thing
that died. Crash attribution must rerun the binary that actually crashed, so this
shim makes the divergence real and observable:

* `build`, marker ABSENT (the first attempt) — drop the marker, TRUNCATE the `-o`
  path (a real compiler owns that path from the moment it starts), write one
  progress line to stderr, then sleep far past any deadline. mtest's
  `--compile-timeout` kills it; that kill is crash-class, so `--retries 1` buys a
  second attempt at a NEW `-o` (`...attempt-2`). SIGTERM exits promptly, well
  inside the 5-second compile grace.
* `build`, marker PRESENT (the retry) — write a working test binary at `-o` and
  exit 0. The binary speaks the pinned report grammar and is keyed to the
  fixture's real tests: it segfaults when run whole (so the file's verdict is
  CRASH), lists its three tests under `--skip-all`, segfaults under
  `--only test_boom`, and passes under any other selection. That is exactly the
  behavior of the REAL fixture it stands in for — the shim relocates the binary,
  it does not invent a different truth.
* anything else (`--version`, ...) — EXECS the real `mojo` on PATH with the
  untouched argv, so this stays a transparent stand-in outside the one path it
  exists to bend.

Truncating `-o` on the killed first attempt is what makes the scenario
DISCRIMINATING: it leaves `build/bin/<mangled>` present but non-runnable, so a
runner that reconstructed the mangled name (instead of carrying the binary that
ran) reports PROBE_FAILED and the assertion fails loudly — rather than silently
passing because a stale binary from an earlier scenario happened to be lying
there and happened to name the same culprit.

Stdlib only, no third-party imports — this is build-time harness code, not part
of the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import signal
import stat
import sys
import time

SLEEP_SECONDS = 300.0
SIGTERM_EXIT = 128 + signal.SIGTERM

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
MARKER = os.path.join(REPO_ROOT, "build", "e2e-scratch", "retry_crash_build_marker")

# The fixture's tests, in source order, and the one that dies. Kept in step with
# e2e/attribution/test_deterministic_crasher.mojo by the e2e scenario, which
# asserts the culprit by name.
NAMES = ("test_alpha_ok", "test_boom", "test_gamma_ok")
CULPRIT = "test_boom"

# The emitted binary. It speaks the toolchain's pinned report grammar (trailing
# spaces are load-bearing) for the canonical source path baked in at write time.
FAKE_BINARY = '''#!/usr/bin/env python3
"""Written by fake_retry_crash_mojo.py — not a committed artifact."""
import os
import signal
import sys

SRC = {src!r}
NAMES = {names!r}
CULPRIT = {culprit!r}


def die():
    """Die by a real signal: the supervisor must observe SIGNALED."""
    os.kill(os.getpid(), signal.SIGSEGV)
    signal.pause()


def report(rows):
    passed = sum(1 for outcome, _ in rows if outcome == "PASS")
    failed = sum(1 for outcome, _ in rows if outcome == "FAIL")
    skipped = sum(1 for outcome, _ in rows if outcome == "SKIP")
    lines = ["", "Running %d tests for %s " % (len(rows), SRC)]
    for outcome, name in rows:
        lines.append("    %s [ 0.000001 ] %s" % (outcome, name))
    lines.append("--------")
    lines.append(
        "Summary [ 0.000010 ] %d tests run: %d passed , %d failed , %d skipped "
        % (len(rows), passed, failed, skipped)
    )
    sys.stdout.write("\\n".join(lines) + "\\n")
    sys.stdout.flush()


args = sys.argv[1:]
if "--skip-all" in args:
    # Collection: every test listed, no body run.
    report([("SKIP", n) for n in NAMES])
    raise SystemExit(0)
if "--only" in args:
    selected = args[args.index("--only") + 1 :]
    if CULPRIT in selected:
        die()
    report([("PASS", n) if n in selected else ("SKIP", n) for n in NAMES])
    raise SystemExit(0)
# The whole-file run: the crash the file's CRASH verdict is earned on.
die()
'''


def _on_sigterm(_signum: int, _frame: object) -> None:
    sys.stderr.write("fake_retry_crash_mojo.py: SIGTERM received; exiting\n")
    sys.stderr.flush()
    os._exit(SIGTERM_EXIT)


def _out_path(args: list[str]) -> str | None:
    return args[args.index("-o") + 1] if "-o" in args else None


def _source(args: list[str]) -> str | None:
    return next((a for a in args if a.endswith(".mojo")), None)


def _first_build_hangs(args: list[str]) -> int:
    """Attempt 1: own (and destroy) `-o`, then never finish. mtest kills us."""
    signal.signal(signal.SIGTERM, _on_sigterm)
    os.makedirs(os.path.dirname(MARKER), exist_ok=True)
    with open(MARKER, "w", encoding="utf-8") as handle:
        handle.write("first build killed\n")
    out = _out_path(args)
    if out:
        parent = os.path.dirname(out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(out, "wb") as handle:
            handle.write(b"fake_retry_crash_mojo.py: PARTIAL OUTPUT, NEVER COMPLETED\n")
    sys.stderr.write(
        "fake_retry_crash_mojo.py: build: lowering module (this will not finish)\n"
    )
    sys.stderr.flush()
    time.sleep(SLEEP_SECONDS)
    return 1


def _retry_build_succeeds(args: list[str]) -> int:
    """Attempt 2: emit a working binary at the RETRY's fresh `-o` path."""
    out = _out_path(args)
    source = _source(args)
    if not out or not source:
        sys.stderr.write(f"fake_retry_crash_mojo.py: unexpected build argv: {args}\n")
        return 1
    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    # The report's identity key is the canonical source path the compiler bakes
    # in, so the shim must bake in the same one the real compiler would.
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(
            FAKE_BINARY.format(
                src=os.path.realpath(source), names=NAMES, culprit=CULPRIT
            )
        )
    os.chmod(out, os.stat(out).st_mode | stat.S_IXUSR)
    sys.stderr.write("fake_retry_crash_mojo.py: build: retry succeeded\n")
    sys.stderr.flush()
    return 0


def main() -> int:
    args = sys.argv[1:]
    if len(args) > 0 and args[0] == "build":
        if os.path.exists(MARKER):
            return _retry_build_succeeds(args)
        return _first_build_hangs(args)

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_retry_crash_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    return 1  # unreachable: a successful os.execv never returns


if __name__ == "__main__":
    sys.exit(main())
