"""Precompile one source into a package and promote it atomically.

Layer 4, the session-level step that runs before any test file is built: it
compiles a source with `mojo precompile` into a per-attempt temp path and
renames that onto the output only after the attempt exits 0, so a killed,
crashed, or rejected attempt never touches a package a dependent might build
against. A failed step is a precompile error at exit 1 and its success widens
the include set every later build sees.

It reuses the attempt machinery's retry policy, event shapes, and residual
warning so a session-level step's attempt line carries the same identity a file
build's does, and it sits below `session` and `collect`, which both run the
configured steps before their own work.
"""
from std.os.path import basename, dirname

from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    Termination,
    interrupt_requested,
    run_supervised,
)
from mtest.model import Event
from mtest.platform import rename_path
from mtest.session.attempt import (
    _AttemptResult,
    _compile_crash_residual,
    _make_attempt_finished,
)
from mtest.session.build import _COMPILE_GRACE_MS
from mtest.session.retry_class import retry_classify
from mtest.session.scratch import (
    _cleanup_quarantine,
    _discard_path,
    _ensure_dir,
    _invocation_nonce,
    _mangle,
    _precompile_temp_path,
    _quarantine_dir,
)


@fieldwise_init
struct PrecompileResult(Copyable, Movable):
    """The outcome of one precompile step, plus its control signals.

    On success `ok` is set and `out_dir` is the include directory added to every
    subsequent build. On failure `compiler_output` holds the captured compiler
    output, and `term`/`timeout_seconds` carry how the final attempt ended so
    the banner can name that ending in words. `internal_error` and `interrupted`
    short-circuit as in `FileResult`. The caller emits `events` in order before
    acting on the outcome.
    """

    var out_dir: String
    """The output directory to add to the include set on success."""
    var compiler_output: String
    """The captured compiler output on a failed step."""
    var ok: Bool
    """Whether the step built cleanly."""
    var internal_error: Bool
    """Whether a spawn failure occurred (routes to internal-error exit 3)."""
    var interrupted: Bool
    """Whether an interrupt aborted the step (routes to exit 2)."""
    var errno: Int
    """The spawn errno on an internal error, so the diagnostic names the real
    cause (e.g. ENOENT for a nonexistent compiler); 0 otherwise."""
    var program: String
    """The program the step tried to spawn on an internal error, else empty."""
    var events: List[Event]
    """The step's attempt events and warnings, in emission order."""
    var term: Termination
    """The final attempt's raw termination (meaningful on a failed step)."""
    var timeout_seconds: Int
    """The compile deadline mtest enforced, for a step killed at it; else 0."""
    var attempts_used: Int
    """How many attempts the step spent (1 when it ran once with no retry)."""
    var ending_known: Bool
    """Whether `term` is the real ending of a compiler that ran and failed.

    False when the step failed for a reason the compiler never expressed, such
    as a failed promotion where the compiler exited 0 and only the rename lost.
    The banner then says nothing about an ending rather than reporting `term`'s
    Exited(0) as "exited 0" on a step that failed."""

    @staticmethod
    def _blank() -> Self:
        """Return a result with every field at its neutral value."""
        return Self(
            "",
            "",
            False,
            False,
            False,
            0,
            "",
            List[Event](),
            Termination.exited(0),
            0,
            1,
            False,
        )

    @staticmethod
    def interrupt(var events: List[Event]) -> Self:
        """Build an interrupted step, which routes the session to exit 2.

        Args:
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.

        Returns:
            The interrupted `PrecompileResult`.
        """
        var r = Self._blank()
        r.interrupted = True
        r.events = events^
        return r^

    @staticmethod
    def internal(errno: Int, program: String, var events: List[Event]) -> Self:
        """Build a spawn failure, which routes the session to exit 3.

        Args:
            errno: The spawn errno, so the diagnostic names the real cause.
            program: The program that could not be spawned.
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.

        Returns:
            The internal-error `PrecompileResult`.
        """
        var r = Self._blank()
        r.internal_error = True
        r.errno = errno
        r.program = program
        r.events = events^
        return r^

    @staticmethod
    def success(
        out_dir: String, var events: List[Event], attempts_used: Int
    ) -> Self:
        """Build a successful step whose `out_dir` widens the include set.

        Args:
            out_dir: The directory holding the promoted package.
            events: The step's events, emitted before the session continues.
                Consumed; the returned `PrecompileResult` owns them.
            attempts_used: How many attempts the step spent.

        Returns:
            The successful `PrecompileResult`.
        """
        var r = Self._blank()
        r.ok = True
        r.out_dir = out_dir
        r.events = events^
        r.attempts_used = attempts_used
        return r^

    @staticmethod
    def failure(
        compiler_output: String,
        var events: List[Event],
        term: Termination,
        timeout_seconds: Int,
        attempts_used: Int,
    ) -> Self:
        """Build a failed step, reported as a precompile error and exit 1.

        Args:
            compiler_output: The captured compiler output for the banner.
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.
            term: How the compiler ended, so the banner names that ending.
            timeout_seconds: The compile deadline enforced, when the step was
                killed at it; 0 otherwise.
            attempts_used: How many attempts the step spent.

        Returns:
            The failed `PrecompileResult`, with `ending_known` set.
        """
        var r = Self._blank()
        r.compiler_output = compiler_output
        r.events = events^
        r.term = term
        r.timeout_seconds = timeout_seconds
        r.attempts_used = attempts_used
        r.ending_known = True
        return r^

    @staticmethod
    def promotion_failure(
        compiler_output: String, var events: List[Event], attempts_used: Int
    ) -> Self:
        """Build a step where the compiler succeeded but promotion failed.

        Still a precompile error at exit 1, since no package was published, but
        there is no compiler ending to name: the attempt exited 0. Leaving
        `ending_known` False keeps the banner from reporting "exited 0" on a
        failed step and sends the reader to `compiler_output`, which explains
        that the rename lost and that the output directory was left untouched.

        Args:
            compiler_output: The captured output explaining the failed rename.
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.
            attempts_used: How many attempts the step spent.

        Returns:
            The failed `PrecompileResult`, with `ending_known` left False.
        """
        var r = Self._blank()
        r.compiler_output = compiler_output
        r.events = events^
        r.attempts_used = attempts_used
        return r^


def _run_precompile(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    src: String,
    out_name: Optional[String],
    include_paths: List[String],
) raises -> PrecompileResult:
    """Precompile one source into a package, promoted atomically on success.

    Builds `mojo precompile <src> -o <temp>`, forwarding the include paths and
    build args. Every attempt writes a temp path derived from the output path
    (see `_precompile_temp_path`) and is renamed onto it only after the attempt
    exits 0, so a killed, crashed, or rejected attempt never touches the output:
    a good package from an earlier run survives a failed step unchanged, and no
    dependent ever builds against a half-written package. Failed temps are
    deleted best-effort, and a cleanup failure never fails the session.

    The step is bounded by `--compile-timeout` with the compile-specific grace,
    the same treatment per-file builds get, and gets the same crash-class
    `--retries` budget: up to `config.retries + 1` attempts, retried only when
    `retry_classify("precompile", ...)` calls the failure crash-class. Each
    retry writes a fresh temp path and is quarantined against a fresh
    per-attempt module cache, with a residual warning.

    Precompile attempts are session-level: their `AttemptFinished` events name
    the `src` spelling and carry `step="precompile"`. There is no flaky verdict
    and no file counter, so a success after a crash-class attempt emits a
    warning instead.

    Args:
        runtime: The exec runtime supervising the compiler spawns.
        config: The resolved runner configuration.
        root: The invocation root the compiler runs in.
        src: The source to precompile.
        out_name: The output package path, or None to default to
            `build/<name>.mojopkg` where `name` is `src`'s `.mojo`-stripped
            basename.
        include_paths: Directories passed to the compiler as `-I`.

    Returns:
        The step's result, in one of four caller-visible states: a success
        carrying the include directory; a failure, either a compiler failure
        that names its ending or a promotion failure that has none to name,
        both reported as a precompile error at exit 1; a spawn failure at
        exit 3; or an interrupt at exit 2.

    Raises:
        Error: If the `exec` machinery itself fails, or the output or temp
            directory cannot be made. The caller catches these and resolves
            exit 3.
    """
    var name = String(basename(src).removesuffix(".mojo"))
    var out_path: String
    if out_name:
        out_path = out_name.value().copy()
    else:
        out_path = String("build/") + name + ".mojopkg"

    # The temp lives beside OUT, so its parent must exist before the first
    # attempt writes it (and the rename stays within one directory).
    var parent = dirname(out_path)
    if parent != "":
        _ensure_dir(root + "/" + parent)

    var nonce = _invocation_nonce()
    var attempts_planned = config.retries + 1
    var events = List[Event]()
    var quarantine_dirs = List[String]()
    var quarantine_dir = String("")
    var had_retry = False
    var attempt_index = 1

    while True:
        var tmp_path = _precompile_temp_path(
            out_path, src, attempt_index, nonce
        )
        var tmp_dir = dirname(tmp_path)
        _ensure_dir(root + "/" + tmp_dir)
        var argv = List[String]()
        argv.append(config.mojo_path)
        argv.append("precompile")
        argv.append(src)
        argv.append("-o")
        argv.append(tmp_path)
        for p in include_paths:
            argv.append("-I")
            argv.append(p)
        for a in config.build_args:
            argv.append(a)

        # NARROW quarantine: only a post-compile-kill retry redirects the module
        # cache, exactly as the file build path does. The override rides the
        # CHILD's environment via `env_extra`, so the parent's environment is
        # never touched and two quarantined spawns can never clobber each other's
        # cache directory.
        var env_extra = List[String]()
        if quarantine_dir != "":
            env_extra.append("MODULAR_CACHE_DIR=" + quarantine_dir)

        var res: ProcessResult
        try:
            res = run_supervised(
                runtime,
                ProcessSpec.command_in(
                    argv.copy(),
                    root,
                    config.compile_timeout_secs * 1000,
                    _COMPILE_GRACE_MS,
                    env_extra^,
                ),
            )
        except e:
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            raise e^

        var dur = Float64(res.duration_ms) / 1000.0
        # An interrupt during the step group-kills it (a TimedOut bail-out). It
        # is answered BEFORE the termination is read, so an interrupt is never
        # mistaken for a deadline — whatever the supervisor had to do to stop it.
        if interrupt_requested():
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            return PrecompileResult.interrupt(events^)

        var term = res.termination
        if term.is_spawn_failed():
            # Could not spawn the compiler at all: carry the real errno and
            # program so the diagnostic names the cause, exactly as the
            # build/run paths do.
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            return PrecompileResult.internal(
                term.value, config.mojo_path, events^
            )

        if term.is_exited() and term.value == 0:
            # PROMOTE: the package is real, so publish it indivisibly. A rename
            # that fails leaves OUT untouched — the step is honestly a failure,
            # never a half-published package.
            try:
                rename_path(root + "/" + tmp_path, root + "/" + out_path)
            except:
                # The COMPILER exited 0; only the rename lost (e.g. OUT is a
                # directory, or its parent is read-only). There is no compiler
                # ending to name, so this result carries none.
                _discard_path(root + "/" + tmp_dir)
                _cleanup_quarantine(root, quarantine_dirs)
                return PrecompileResult.promotion_failure(
                    String(
                        "mtest: the precompile of '"
                        + src
                        + "' succeeded, but its package could not be promoted"
                        " from '"
                    )
                    + tmp_path
                    + "' to '"
                    + out_path
                    + "'. The compiler is not at fault: check that OUT is a"
                    " writable file path (a directory or a read-only parent at"
                    " OUT will fail here). OUT was left untouched.\n",
                    events^,
                    attempt_index,
                )
            if had_retry:
                # No FLAKY verdict exists for a session-level step, so the
                # warning IS the signal that this package was not built cleanly
                # the first time.
                events.append(
                    Event.warning(
                        "precompile-succeeded-after-retry",
                        (
                            "the precompile step '"
                            + src
                            + "' succeeded only on attempt "
                            + String(attempt_index)
                            + " of "
                            + String(attempts_planned)
                            + "; its earlier attempt(s) were killed or crashed,"
                            " so treat this package as suspect"
                        ),
                    )
                )
            # The promoted package left the temp directory empty; take it away
            # too, so a successful step leaves the OUT tree exactly as an
            # unpromoted run would have.
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            var d = dirname(out_path)
            if d == "":
                d = String(".")
            return PrecompileResult.success(d, events^, attempt_index)

        # The attempt failed. Classify it for retry eligibility under the BUILD
        # rules (`interrupted` is False: an interrupt was short-circuited above,
        # so a TimedOut reaching here is a genuine deadline).
        var rc = retry_classify("precompile", term, False, res.stderr_bytes)
        var more_attempts = attempt_index < attempts_planned
        if rc.retry_eligible and more_attempts:
            had_retry = True
            var att = _AttemptResult._build_failed(
                argv.copy(), term, res.stderr_bytes.copy(), dur, tmp_path
            )
            events.append(
                _make_attempt_finished(
                    src,
                    rc,
                    att,
                    attempt_index,
                    attempts_planned,
                    step_override="precompile",
                )
            )
            # A compile kill: the shared module cache MAY be suspect. Warn
            # loudly and run the NEXT attempt quarantined against a fresh
            # per-attempt cache, into a fresh temp path.
            events.append(
                Event.warning(
                    "compile-kill-residual",
                    _compile_crash_residual("precompile", src, rc, term),
                )
            )
            _discard_path(root + "/" + tmp_dir)
            quarantine_dir = _quarantine_dir(
                "precompile-", _mangle(src), attempt_index + 1, nonce
            )
            _ensure_dir(root + "/" + quarantine_dir)
            quarantine_dirs.append(quarantine_dir)
            attempt_index += 1
            continue

        # Final attempt: the step is a PRECOMPILE-ERROR. OUT was never written.
        _discard_path(root + "/" + tmp_dir)
        _cleanup_quarantine(root, quarantine_dirs)
        var timeout_seconds = 0
        if term.is_timed_out():
            timeout_seconds = config.compile_timeout_secs
        return PrecompileResult.failure(
            lossy_utf8(res.stderr_bytes),
            events^,
            term,
            timeout_seconds,
            attempt_index,
        )
