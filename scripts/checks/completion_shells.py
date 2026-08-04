#!/usr/bin/env python3
"""Run the rendered completion scripts in real shells and read the result back.

A completion script's unit tests can only assert what the script *says*. The
defects this feature shipped all said the right thing and did the wrong one:
they completed a different file than the one named, deleted text the user had
already typed, or inserted a stray separator. Every one parsed, and every one
satisfied substring assertions over the generated source, because the source
was never what was wrong -- the line the shell produced from it was.

So this gate asks the shells: `bash -n`/`zsh -n`/`fish -n` over the rendered
script, five bash rows whose readline buffer after TAB is the assertion, three
rules asserted in all three shells, and three hostile values -- one per shell --
that nothing may evaluate.
It is a confidence gate rather than an exhaustive matrix, and says nothing
about how a candidate list is displayed, about other shells, or about any shape
not in the tables below. A defect found later earns a new row here.

`--require-all` is the default, because a blocking gate that silently skips a
shell reports on whatever the machine happened to have. `--allow-missing` is
the escape hatch for one caller, the osx-arm64 task override, since the
hermetic zsh and fish are declared under `[target.linux-64.dependencies]`. The
authoritative run is linux-64, locally through `pixi run completions-check` and
hosted in `Linux / compiled oracles`.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time


REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "build" / "mtest"

SHELLS = ("bash", "zsh", "fish")
"""Every shell `mtest completions` renders a script for."""

FIXTURE_DIRECTORIES = ("probe", "solefile", "soledir", "soledir/reports")
FIXTURE_FILES = ("probe/my report.md", "solefile/tail.md")
"""The smallest tree the rows below need: `probe` holds one spaced name, and
`solefile` and `soledir` hold exactly one entry each, so a bare `md:` prefix
has a single answer and the file and directory cases stay distinguishable.
"""

BUFFER_PROBES: tuple[tuple[str, str, str, str], ...] = (
    # Shell, directory, typed text, and the buffer one TAB must leave behind.
    # bash covers quoting and the prefixed report value.
    ("bash", "probe", "mtest my\\ rep", "mtest my\\ report.md "),
    ("bash", "probe", 'mtest --gate "my rep', 'mtest --gate "my report.md" '),
    ("bash", "probe", 'mtest --report "md:my rep', 'mtest --report "md:my report.md"'),
    ("bash", "solefile", "mtest --report md:", "mtest --report md:tail.md "),
    # A completed directory keeps its separator and takes no trailing space.
    ("bash", "soledir", "mtest --report md:", "mtest --report md:reports/"),
    # zsh has no headless API, so it asserts the candidate rows' three rules
    # here. A sole candidate landing with a terminating space proves what was
    # offered; it does not prove nothing else was, because zsh inserts the
    # unambiguous part of a shared prefix the same way.
    ("zsh", "probe", "mtest -q doctor --retr", "mtest -q doctor --retries "),
    ("zsh", "probe", "mtest config ", "mtest config show "),
    ("zsh", "probe", "mtest completions z", "mtest completions zsh "),
)

CANDIDATE_PROBES: tuple[tuple[str, tuple[str, ...], tuple[str, ...] | None], ...] = (
    # Line, candidates that must be offered, and the complete set where the
    # surface is closed -- set equality there, so an extra candidate fails too.
    # `parse_args` recognizes a subcommand at argv[0] only, so `-q doctor` is
    # a RUN with an operand named `doctor` and keeps the run surface.
    ("mtest -q doctor --retr", ("--retries",), None),
    ("mtest config ", ("show",), ("show",)),
    ("mtest completions ", SHELLS, SHELLS),
)
"""Rows run in bash and fish, the two shells with a headless completion API."""

INJECTION_PROBES: tuple[tuple[str, str, str], ...] = (
    # Shell, the hostile line, and the benign twin of the same word shape.
    #
    # The twin is what makes the row an assertion. A hostile value completes
    # to nothing whichever arm reads it, so "no marker and no candidates"
    # would pass just as well from the generic head arm -- which is what the
    # first version of this row did, because its payload carried a space,
    # `read -r -a` split it into three words, and `prev` became `md:$(touch`.
    # The twin differs from the hostile line only in the value, so a candidate
    # from the twin proves this shape reaches the prefix arm, and the marker
    # then says what that arm does with a hostile one.
    ("bash", "mtest --report md:$(touch${{IFS}}{marker})", "mtest --report md:"),
    ("fish", "mtest --report md:(touch {marker})", "mtest --report md:"),
)
"""The `--report` prefix arm, the one place candidates are assembled by hand."""

ZSH_INJECTION = "mtest --report 'md:$(touch {marker})' --retr"
"""zsh's own row, and it puts the payload in a word already typed.

Not in the word being completed, and that is not a weaker choice but the only
honest one: stock zsh expands a command substitution inside the current word
during completion, with no completion script loaded at all, so a current-word
row would fail against zle rather than against anything rendered here. What
this row covers is the position that is this script's own -- a value zsh has
tokenized and handed over, which the head resolution compares and `_arguments`
parses. That is also the shell whose actions are evaluated, which is why it
gets a row rather than a note.
"""

_ZSH_INJECTION_BUFFER = "mtest --report 'md:$(touch {marker})' --retries "

_BUFFER_REPORT = re.compile(r"BUF\{(.*?)\}END", re.DOTALL)
_CONTROL_SEQUENCE = re.compile(
    r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b."
)
_LOADED = re.compile(r"(LOADED-OK)\n")

_TIMEOUT_SECONDS = 30.0
"""How long one terminal exchange may take before the gate calls it wedged.
Generous: a flaky timeout in a blocking gate is worse than a slow one.
"""


def unusable_reason(shell: str, executable: str) -> str | None:
    """Why `shell` cannot run these rows, or None if it can.

    Present is not the same as usable, and the case that motivates this is
    macOS: `bash` is not a pixi dependency, so `shutil.which` there finds
    `/bin/bash`, which Apple froze at 3.2 to stay off GPLv3. Every bash row
    depends on `compopt` and `$READLINE_LINE`, both bash 4.0, so that shell
    cannot run them at all -- and a gate that only knows "absent" would fail
    the `--allow-missing` arm the osx-arm64 override exists to keep
    satisfiable. It is reported the way an absent shell is, so the floor
    narrows and says so instead of breaking.

    zsh and fish need nothing this new: `zle`, `zpty`, and `complete -C`
    predate every release either project still names.
    """
    if shell != "bash":
        return None
    done = _run([executable, "-c", "printf %s ${BASH_VERSINFO[0]-0}"])
    major = done.stdout.decode("utf-8", "replace").strip()
    if major.isdigit() and int(major) >= 4:
        return None
    return f"bash {major or '?'}.x has no compopt and no $READLINE_LINE (needs 4.0+)"


def resolve_shells(allow_missing: bool) -> tuple[dict[str, str], dict[str, str]]:
    """Locate every usable shell, failing unless `allow_missing` permits a gap.

    Returns:
        The usable shells by name, and the reason each unusable one was
        dropped -- "not installed", or what makes the installed one too old.

    Raises:
        AssertionError: If a shell is unusable and `allow_missing` is false.
    """
    found: dict[str, str] = {}
    skipped: dict[str, str] = {}
    for shell in SHELLS:
        path = shutil.which(shell)
        if path is None:
            skipped[shell] = "not installed"
            continue
        reason = unusable_reason(shell, path)
        if reason is not None:
            skipped[shell] = reason
            continue
        found[shell] = path
    if skipped and not allow_missing:
        detail = ", ".join(f"{shell} ({why})" for shell, why in skipped.items())
        raise AssertionError(
            f"unusable shell(s): {detail}. This gate proves the rendered "
            "scripts work by running them, so a shell it cannot run is coverage "
            "it does not have. Install them (linux-64 declares zsh and fish) or "
            "pass --allow-missing, the off-platform escape hatch"
        )
    return found, skipped


def _run(
    argv: list[str], directory: Path | None = None
) -> subprocess.CompletedProcess[bytes]:
    """Run `argv`, turning a failure to start or a hang into a gate failure.

    Raises:
        AssertionError: If the command cannot be started or exceeds 60 seconds.
    """
    try:
        return subprocess.run(
            argv, capture_output=True, cwd=directory, timeout=60, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AssertionError(f"cannot run {argv[0]}: {exc}") from exc


def render_completion_scripts(binary: Path, destination: Path) -> dict[str, Path]:
    """Write each shell's script as this build renders it, keyed by shell.

    Raises:
        AssertionError: If the binary is missing or hangs, or any render exits
            nonzero, writes stderr, or produces nothing.
    """
    scripts: dict[str, Path] = {}
    for shell in SHELLS:
        done = _run([str(binary), "completions", shell])
        if done.returncode != 0 or done.stderr or not done.stdout.strip():
            raise AssertionError(
                f"`mtest completions {shell}` exited {done.returncode} with "
                f"{len(done.stdout)} stdout byte(s): "
                + done.stderr.decode("utf-8", "replace")
            )
        scripts[shell] = destination / f"mtest.{shell}"
        scripts[shell].write_bytes(done.stdout)
    return scripts


def build_fixture(root: Path) -> None:
    """Create under `root` the tree every row completes against."""
    for directory in FIXTURE_DIRECTORIES:
        (root / directory).mkdir(parents=True, exist_ok=True)
    for name in FIXTURE_FILES:
        (root / name).write_bytes(b"")


def check_syntax(shell: str, executable: str, script: Path) -> None:
    """Parse `script` with `shell` without running it.

    Raises:
        AssertionError: If the shell refuses to parse it, or takes too long.
    """
    done = _run([executable, "-n", str(script)])
    if done.returncode != 0:
        raise AssertionError(
            f"{shell} cannot parse its own rendered script: "
            + done.stderr.decode("utf-8", "replace").strip()
        )


def _expect(descriptor: int, pattern: re.Pattern[str], pending: str) -> tuple[str, str]:
    """Read until `pattern` matches; return its last group and the leftover text.

    Raises:
        AssertionError: On timeout or an exiting shell -- both mean the
            exchange produced no verdict, which fails closed.
    """
    deadline = time.monotonic() + _TIMEOUT_SECONDS
    while True:
        found = pattern.search(pending)
        if found is not None:
            return found.group(len(found.groups())), pending[found.end() :]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(
                f"no {pattern.pattern!r} within {_TIMEOUT_SECONDS:.0f}s; "
                f"last output was {pending[-400:]!r}"
            )
        if not select.select([descriptor], [], [], min(0.25, remaining))[0]:
            continue
        try:
            chunk = os.read(descriptor, 65536)
        except OSError as exc:
            raise AssertionError(f"the shell closed its terminal: {exc}") from exc
        if not chunk:
            raise AssertionError(f"the shell exited before {pattern.pattern!r}")
        decoded = chunk.decode("utf-8", "replace")
        pending += _CONTROL_SEQUENCE.sub("", decoded).replace("\r", "")


def buffer_after(
    shell: str, executable: str, script: Path, root: Path, directory: str, typed: str
) -> str:
    """Type `typed` in `shell`, press TAB once, and return its edit buffer.

    Interactive completion exists only under a terminal, so the shell runs on a
    pseudo-terminal with `root` as HOME. A fresh one per row: nothing carries
    between rows, and nothing typed here is ever submitted, because the
    terminal closes while the line still holds it.

    Raises:
        AssertionError: If the script does not load or no buffer is reported.
    """
    environment = {
        "HOME": str(root),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        # zle refuses to run on a terminal it believes cannot address the
        # cursor; readline is happier with the minimal redraw of `dumb`.
        "TERM": "dumb" if shell == "bash" else "xterm",
        "LC_ALL": "C.UTF-8",
        "LANG": "C.UTF-8",
        "INPUTRC": "/dev/null",
    }
    # Both markers are assembled by printf rather than written literally, so
    # the terminal's echo of these very lines can never be read as a report.
    if shell == "bash":
        argv = [executable, "--norc", "--noprofile", "-i"]
        setup = (
            "PS1=''\n"
            "bind 'set show-all-if-ambiguous on'\n"
            """bind -x '"\\C-o": printf "\\nB%sUF{%s}END\\n" "" "$READLINE_LINE"'\n"""
            f"source {script} && printf 'LOADED%s-OK\\n' ''\n"
        )
    else:
        argv = [executable, "-f", "-i"]
        setup = (
            "PS1=''; unsetopt beep\n"
            f"autoload -Uz compinit && compinit -u -d {root}/zcompdump\n"
            "_mtest_probe() { printf '\\nB%sUF{%s}END\\n' '' \"$BUFFER\" }\n"
            "zle -N _mtest_probe; bindkey '^O' _mtest_probe\n"
            f"source {script} && printf 'LOADED%s-OK\\n' ''\n"
        )
    pid, descriptor = pty.fork()
    if pid == 0:  # pragma: no cover - the child never returns
        os.chdir(root / directory)
        os.execve(executable, argv, environment)
    try:
        # Wide enough that no line this gate types ever wraps: a wrapped line
        # arrives with the terminal's own break inside it and would read as a
        # completion that inserted whitespace.
        fcntl.ioctl(descriptor, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 400, 0, 0))
        os.write(descriptor, setup.encode("utf-8"))
        _, pending = _expect(descriptor, _LOADED, "")
        os.write(descriptor, (typed + "\t\x0f").encode("utf-8"))
        return _expect(descriptor, _BUFFER_REPORT, pending)[0]
    finally:
        with contextlib.suppress(OSError):
            os.close(descriptor)
        os.waitpid(pid, 0)


_BASH_DRIVER = """
source "$2"
COMP_LINE="$1"
COMP_POINT=${#COMP_LINE}
read -r -a COMP_WORDS <<< "$COMP_LINE"
case "$COMP_LINE" in *[![:space:]]) ;; *) COMP_WORDS+=("") ;; esac
COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
_mtest_complete
printf '%s\\n' ${COMPREPLY+"${COMPREPLY[@]}"}
"""
_FISH_DRIVER = "source $argv[1]; complete -C $argv[2]"
"""What each shell's completion is, without a terminal around it.

Neither driver expands the command line -- bash assigns it from a positional
parameter, fish passes it to `complete -C` as an argument -- so a hostile line
reaches the completion function as literal text rather than as something the
driver already ran.
"""


def candidates(
    shell: str, executable: str, script: Path, directory: Path, line: str
) -> tuple[str, ...]:
    """Return the candidates `shell` offers for `line`, run in `directory`.

    Raises:
        AssertionError: If the driver fails or hangs.
    """
    if shell == "bash":
        head = [executable, "--norc", "--noprofile", "-c", _BASH_DRIVER]
        argv = [*head, "-", line, str(script)]
    else:
        head = [executable, "--no-config", "-c", _FISH_DRIVER]
        argv = [*head, str(script), line]
    done = _run(argv, directory)
    if done.returncode != 0:
        raise AssertionError(
            f"{shell} completion of {line!r} exited {done.returncode}: "
            + done.stderr.decode("utf-8", "replace").strip()
        )
    text = done.stdout.decode("utf-8", "replace")
    # fish appends a tab-separated description to each candidate.
    return tuple(word.split("\t", 1)[0] for word in text.split("\n") if word != "")


def check_completion_shells(allow_missing: bool = False) -> None:
    """Run every layer against every shell that must be covered.

    Raises:
        AssertionError: If a shell is missing under require-all, a script does
            not parse, or any row fails.
    """
    found, skipped = resolve_shells(allow_missing)
    for shell, why in skipped.items():
        print(f"completions-check: SKIP {shell} - {why} (--allow-missing)")
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="mtest-completions-") as raw_root:
        root = Path(raw_root)
        scripts = render_completion_scripts(BINARY, root)
        build_fixture(root)
        for shell, executable in found.items():
            check_syntax(shell, executable, scripts[shell])
            print(f"completions-check: PASS {shell} -n")

        for shell, directory, typed, expected in BUFFER_PROBES:
            if shell not in found:
                continue
            actual = buffer_after(
                shell, found[shell], scripts[shell], root, directory, typed
            )
            if actual != expected:
                failures.append(
                    f"{shell}: {typed!r} in {directory}/ + TAB left {actual!r}, "
                    f"expected {expected!r}"
                )

        for shell in ("bash", "fish"):
            if shell not in found:
                continue
            probe = root / "probe"
            for line, offers, exact in CANDIDATE_PROBES:
                got = set(candidates(shell, found[shell], scripts[shell], probe, line))
                if exact is not None and got != set(exact):
                    failures.append(
                        f"{shell}: {line!r} offered {sorted(got)}, expected "
                        f"exactly {sorted(set(exact))}"
                    )
                elif not set(offers) <= got:
                    failures.append(
                        f"{shell}: {line!r} withheld {sorted(set(offers) - got)}; "
                        f"it offered {sorted(got)}"
                    )
        for shell, hostile_form, twin in INJECTION_PROBES:
            if shell not in found:
                continue
            sole = root / "solefile"
            marker = root / f"OWNED-{shell}"
            offered = candidates(shell, found[shell], scripts[shell], sole, twin)
            if offered != ("md:tail.md",):
                failures.append(
                    f"{shell}: the injection twin {twin!r} offered "
                    f"{sorted(offered)}, so the hostile row below proves nothing"
                )
            hostile = hostile_form.format(marker=marker)
            # bash splits the line on whitespace and nothing else, so a
            # payload carrying a space is a different word shape from the twin
            # and lands in a different arm. fish tokenizes parentheses and
            # quotes, so its payload may hold one.
            if shell == "bash" and len(hostile.split()) != len(twin.split()):
                failures.append(
                    f"bash: {hostile!r} splits into {len(hostile.split())} words "
                    f"and the twin into {len(twin.split())}, so they reach "
                    "different arms and the row proves nothing"
                )
            candidates(shell, found[shell], scripts[shell], sole, hostile)
            if marker.exists():
                failures.append(f"{shell}: completing {hostile!r} executed the value")

        if "zsh" in found:
            marker = root / "OWNED-zsh"
            typed = ZSH_INJECTION.format(marker=marker)
            actual = buffer_after(
                "zsh", found["zsh"], scripts["zsh"], root, "probe", typed
            )
            expected = _ZSH_INJECTION_BUFFER.format(marker=marker)
            if actual != expected:
                failures.append(
                    f"zsh: {typed!r} + TAB left {actual!r}, expected {expected!r}"
                )
            if marker.exists():
                failures.append(f"zsh: completing beside {typed!r} executed the value")
        print(
            f"completions-check: ran {len(BUFFER_PROBES)} buffer row(s), "
            f"{len(CANDIDATE_PROBES)} candidate row(s) per shell, and "
            f"{len(INJECTION_PROBES) + 1} injection row(s)"
        )
    if failures:
        raise AssertionError(
            f"{len(failures)} completion row(s) failed:\n  " + "\n  ".join(failures)
        )


def main(argv: list[str] | None = None) -> int:
    """Run the gate; return zero only when every covered shell agrees."""
    parser = argparse.ArgumentParser(
        prog="python -m scripts.checks.completion_shells",
        description="Run bash, zsh and fish against the rendered completion "
        "scripts and assert what they complete.",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="skip an absent shell instead of failing; linux-64 requires all",
    )
    arguments = parser.parse_args(argv)
    try:
        check_completion_shells(arguments.allow_missing)
    except AssertionError as exc:
        print(f"completions-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("completions-check: OK - every covered shell completed as specified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
