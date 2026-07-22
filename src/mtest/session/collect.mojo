"""The collect path: probe every discovered file for its node ids.

Layer 5's `--collect-only` answer, above the session's own run paths: it reuses
the build-and-probe pass to learn each file's test names under `--skip-all`,
running no test body, and returns a sorted `rel::name` listing plus the stderr
diagnostics for the files that could not be listed.

It drives no reporter and prints nothing — `main` prints the listing to stdout
and the diagnostics to stderr, the second sanctioned exception to the event
seam after usage errors — so stdout carries only the listing. The exit code is
resolved by the model's ranking over the same facts a run reports.
"""
from std.builtin.sort import sort

from mtest.cache import BuildRegistry
from mtest.config import RunnerConfig
from mtest.discover import discover
from mtest.exec import ExecRuntime, interrupt_requested
from mtest.model import (
    Outcome,
    TerminalFacts,
    EXIT_FAILURE,
    EXIT_NOTHING_RAN,
    EXIT_SUCCESS,
    resolve_exit_code,
)
from mtest.session.build import (
    _BuildOutcome,
    _ProbeOutcome,
    _build_for_selection,
    _probe_file,
)
from mtest.session.file_result import FileResult
from mtest.session.precompile import _run_precompile
from mtest.session.shard import partition


@fieldwise_init
struct CollectResult(Copyable, Movable):
    """What `run_collect` hands back to `main` to print outside the event seam.

    Owns its lists; copies are explicit.

    `main` prints `listing` verbatim to stdout, one node id per line, and every
    `diagnostics` line to stderr, then exits with `code`.
    """

    var listing: List[String]
    """The sorted node-id listing, and the only thing stdout carries."""
    var diagnostics: List[String]
    """Per-file error and note lines for stderr, never mixed into `listing`."""
    var code: Int
    """The resolved exit code: 2 on an interrupt, 3 on drift or an internal
    error, 1 on a failing file, 5 when nothing was collectable, else 0."""


def _collect_phrase(fr: FileResult) -> String:
    """A short stderr phrase for a probe that did not yield node ids."""
    var o = fr.outcome
    if o == Outcome.COMPILE_ERROR:
        return "compile error (probe skipped)"
    if o == Outcome.CRASH:
        return "the --skip-all probe crashed"
    if o == Outcome.TIMEOUT:
        return "the --skip-all probe timed out"
    if fr.is_drift:
        return (
            "the --skip-all probe drifted off the pinned grammar (drift,"
            " exit 3)"
        )
    return "the --skip-all probe did not list its tests (malformed suite)"


def run_collect(
    mut runtime: ExecRuntime, config: RunnerConfig, root: String
) raises -> CollectResult:
    """Probe every discovered run file for its node ids and build the listing.

    Reuses the selection probe machinery — `_build_for_selection` and
    `_probe_file`, sharing each build through a `BuildRegistry` — to learn each
    file's node ids under `--skip-all`, running no test body. A qualifying file
    contributes `rel::name` for every collected name. A compile error, crash,
    timeout, or malformed suite writes a stderr diagnostic and the listing
    continues with the other files, in the exit-1 class; an off-grammar probe is
    drift, at exit 3; a spawn or machinery failure aborts the listing, also at
    exit 3. The listing is sorted lexicographically.

    `main` prints the result outside the event seam — the second sanctioned
    exception, after usage errors — so stdout carries only the listing while
    every diagnostic goes to stderr. This function prints nothing and drives no
    reporter.

    Args:
        runtime: The exec runtime supervising every build and probe spawn.
        config: The resolved runner configuration.
        root: The invocation root the children run in.

    Returns:
        The listing, the stderr diagnostics, and the resolved exit code: 2 if
        interrupted, else 3 on any drift or internal failure, else 1 if any file
        failed to collect, else 5 if no node ids were collectable, else 0.

    Raises:
        Error: If discovery reports a `discover:` usage error, which main maps
            to exit 4. Every build and probe failure is caught here and folded
            into the result.
    """
    var disc = discover(config, root)  # a discover: usage error propagates.

    # Collect honors the same shard partition as a run: the listing is exactly
    # this shard's node ids. Gate files are never sharded (collect has none).
    if config.shard_n > 0:
        disc.run_files = partition(
            disc.run_files.copy(),
            config.shard_mode,
            config.shard_m,
            config.shard_n,
        )

    var reg = BuildRegistry()
    var includes = config.include_paths.copy()
    var node_ids = List[String]()
    var diags = List[String]()
    var any_failing = False
    var drift = False
    var internal = False
    var interrupted = False

    # `-k` is a run-time selection filter; collect prints the FULL discovered
    # listing and ignores it with a note (deterministic and documented).
    if config.keyword != "":
        diags.append(
            "collect: -k is ignored in collect mode; printing the full node-id"
            " listing for the discovered files"
        )

    # Precompile steps first, widening the include set so a file importing a
    # precompiled package can build for its probe. A failed or unspawnable step
    # is a machinery-class abort (exit 3): collection cannot proceed honestly.
    for pc in config.precompiles:
        if interrupt_requested():
            interrupted = True
            break
        try:
            var pr = _run_precompile(
                runtime, config, root, pc.src, pc.out, includes
            )
            if pr.interrupted:
                interrupted = True
                break
            if pr.internal_error or not pr.ok:
                diags.append(
                    "collect: precompile step '"
                    + pc.src
                    + "' failed; aborting collection"
                )
                internal = True
                break
            includes.append(pr.out_dir)
        except:
            # `_run_precompile`'s own machinery (e.g. the output directory could
            # not be created) raised rather than returning a result. Mirror
            # `run_session`'s handling: an internal-abort diagnostic and exit 3,
            # not a `discover:`-style usage error. Not independently unit-tested
            # here — `run_session`'s sibling except (session.mojo ~1580) has no
            # dedicated raise-path test either; both are machinery-only
            # defensive code exercised only by the `pr.internal_error`
            # return-value path in `test_session_precompile.mojo`.
            diags.append(
                "collect: precompile step '"
                + pc.src
                + "' failed; aborting collection"
            )
            internal = True
            break

    if not (interrupted or internal):
        for ri in range(len(disc.run_files)):
            if interrupt_requested():
                interrupted = True
                break
            var rel = disc.run_files[ri]
            var bo: _BuildOutcome
            try:
                bo = _build_for_selection(
                    runtime, config, root, rel, includes, reg
                )
            except:
                diags.append(
                    "collect: " + rel + ": internal build failure; aborting"
                )
                internal = True
                break
            if bo.terminal:
                if bo.result.interrupted:
                    interrupted = True
                    break
                if bo.result.internal_error:
                    diags.append(
                        "collect: " + rel + ": internal build failure; aborting"
                    )
                    internal = True
                    break
                # A compile-error terminal: a diagnostic; the listing continues.
                diags.append(
                    "collect: " + rel + ": " + _collect_phrase(bo.result)
                )
                any_failing = True
                continue

            var po: _ProbeOutcome
            try:
                po = _probe_file(
                    runtime,
                    config,
                    root,
                    rel,
                    bo.binary,
                    bo.canonical,
                    bo.build_argv,
                    bo.bdur,
                    reg,
                )
            except:
                diags.append(
                    "collect: " + rel + ": internal probe failure; aborting"
                )
                internal = True
                break
            if po.interrupted:
                interrupted = True
                break
            if po.internal_error:
                diags.append(
                    "collect: " + rel + ": internal probe failure; aborting"
                )
                internal = True
                break
            if po.qualified:
                for nm in po.universe:
                    node_ids.append(rel + "::" + nm)
                continue

            # A non-qualifying terminal probe: diagnostic, then classify. Drift
            # forces exit 3 but the listing still continues; the rest are exit-1.
            diags.append("collect: " + rel + ": " + _collect_phrase(po.result))
            if po.result.is_drift:
                drift = True
            else:
                any_failing = True

    sort(node_ids)

    # Collect's own outcome tier, in `exit_code_for`'s shape over the listing it
    # produced: a file that failed to yield node ids is failing, an empty
    # listing means nothing was collectable, else success. The control-flow
    # facts rank above it in the model resolver, exactly as they do for a run.
    # A collect probe precompiles nothing and publishes no terminal artifact, so
    # those two facts are false by construction rather than by omission.
    var outcome_code: Int
    if any_failing:
        outcome_code = EXIT_FAILURE
    elif len(node_ids) == 0:
        outcome_code = EXIT_NOTHING_RAN
    else:
        outcome_code = EXIT_SUCCESS
    var code = resolve_exit_code(
        TerminalFacts(
            interrupted=interrupted,
            internal_error=internal,
            drift=drift,
            precompile_failed=False,
            outcome_code=outcome_code,
            delivery_failed=False,
        )
    )
    return CollectResult(node_ids^, diags^, code)


def run_collect(config: RunnerConfig, root: String) raises -> CollectResult:
    """Collect with a locally owned runtime, for direct library callers.

    Args:
        config: The resolved runner configuration.
        root: The invocation root the children run in.

    Returns:
        The collect result, as the primary overload defines it.

    Raises:
        Error: If the runtime cannot be opened or closed, or if the primary
            overload raises. A close failure during error handling is appended
            to the original message.
    """
    var runtime = ExecRuntime()
    try:
        runtime.open()
        var result = run_collect(runtime, config, root)
        runtime.close()
        return result^
    except error:
        var primary = String(error)
        try:
            runtime.close()
        except cleanup_error:
            raise Error(primary + "; " + String(cleanup_error))
        raise Error(primary)
