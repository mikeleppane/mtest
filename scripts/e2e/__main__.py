#!/usr/bin/env python3
"""Run mtest's guarded 59-scenario end-to-end gate.

The harness drives the real ``build/mtest`` binary against the committed
known-outcome tree under ``e2e/``. Expectations come from
``e2e/manifest.json``, and every child process is guarded by the shared runner.

Usage: ``python -m scripts.e2e``
"""

from __future__ import annotations

import os
import sys
import traceback
from dataclasses import dataclass, field

from scripts.e2e.runner import (
    MTEST,
    Scenario,
    ScenarioContext,
    ScenarioError,
    ScenarioRegistry,
    bootstrap_build_bin,
    load_manifest,
)
from scripts.e2e.scenarios import (
    annotations,
    core,
    json_reporter,
    junit_reporter,
    parallel,
    resilience,
    selection,
)


@dataclass
class Harness:
    """Run registered scenarios while containing scenario-local failures."""

    context: ScenarioContext
    results: list[tuple[str, bool, str]] = field(default_factory=list)

    def scenario(self, name: str, fn: Scenario) -> None:
        """Run one scenario and preserve its result without stopping the gate."""
        try:
            detail = fn(self.context)
            self.results.append((name, True, detail or ""))
            print(f"PASS  {name}  {detail or ''}")
        except ScenarioError as exc:
            self.results.append((name, False, str(exc)))
            print(f"FAIL  {name}\n      {exc}")
        except Exception as exc:
            # CONTAINMENT. ScenarioError above is the expected failure channel;
            # any other exception is still a real failure, but it must not hide
            # the coverage provided by every later registered scenario.
            detail = (
                f"{type(exc).__name__} escaped the scenario outside the "
                f"expected ScenarioError channel — cause undetermined, see the "
                f"traceback:\n"
                f"{traceback.format_exc()}"
            )
            self.results.append((name, False, detail))
            print(f"FAIL  {name}\n      {detail}")

    def ok(self) -> bool:
        """Return whether every attempted scenario passed."""
        return all(passed for _name, passed, _detail in self.results)


# The sole master registry, in execution order. Keep the core and resilience
# scenarios interleaved: order is user-visible gate behavior and is pinned by
# the independent layout oracle.
SCENARIOS: ScenarioRegistry = (
    ("manifest-completeness", core.s_manifest_completeness),
    ("resilience-matrix", resilience.s_resilience_matrix),
    ("default-suite", core.s_default_suite),
    ("hostile", core.s_hostile),
    ("single-pass", core.s_single_pass),
    ("exitfirst", core.s_exitfirst),
    ("maxfail", core.s_maxfail),
    ("retries-flaky", resilience.s_retries_flaky),
    ("crash-attribution", resilience.s_crash_attribution),
    (
        "attribution-reruns-crashed-binary",
        resilience.s_attribution_reruns_the_binary_that_crashed,
    ),
    ("compile-timeout", resilience.s_compile_timeout),
    ("compile-crash-signature", resilience.s_compile_crash_signature),
    ("exclude+stale", core.s_exclude_and_stale),
    ("all-excluded", core.s_all_excluded),
    ("empty-dir", core.s_empty_dir),
    ("failing-gate", core.s_failing_gate),
    ("timeout", resilience.s_timeout),
    ("timeout-escalation", resilience.s_timeout_escalation),
    ("precompile", resilience.s_precompile),
    ("precompile-timeout", resilience.s_precompile_timeout),
    ("precompile-crash-retry", resilience.s_precompile_crash_retry),
    ("precompile-promotion", resilience.s_precompile_promotion),
    ("quiet-verbose", core.s_quiet_verbose),
    ("show-output", core.s_show_output),
    ("durations", core.s_durations),
    ("color", core.s_color),
    ("usage-refusals", selection.s_usage_refusals),
    ("selection-keyword", selection.s_selection_keyword),
    ("selection-node-id", selection.s_selection_node_id),
    ("selection-union", selection.s_selection_union),
    (
        "selection-malformed-node-id",
        selection.s_selection_malformed_node_id,
    ),
    ("selection-unknown-test", selection.s_selection_unknown_test),
    ("selection-empty", selection.s_selection_empty),
    ("selection-chameleon", selection.s_selection_chameleon),
    ("single-build", selection.s_single_build),
    ("stale-recovery-two-builds", selection.s_stale_recovery_two_builds),
    ("collect", selection.s_collect),
    ("passthrough+forbidden", core.s_passthrough_and_forbidden),
    ("out-of-root", core.s_out_of_root),
    ("internal-error", resilience.s_internal_error),
    ("runtime-open-failure", resilience.s_runtime_open_failure),
    ("interrupt", resilience.s_interrupt),
    ("json-forward-compat", json_reporter.s_json_forward_compat),
    ("json-purity", json_reporter.s_json_purity),
    (
        "json-color-relocated-stderr",
        json_reporter.s_json_color_on_relocated_stderr,
    ),
    ("json-destination-taxonomy", json_reporter.s_json_destination_taxonomy),
    ("json-truncation-interrupt", json_reporter.s_json_truncation_interrupt),
    ("json-truncation-sigkill", json_reporter.s_json_truncation_sigkill),
    ("json-truncation-dead-pipe", json_reporter.s_json_truncation_dead_pipe),
    (
        "json-terminal-write-failure",
        json_reporter.s_json_terminal_write_failure,
    ),
    ("junit-scratch-cleanup", junit_reporter.s_junit_scratch_cleanup),
    ("junit-schema-gate", junit_reporter.s_junit_schema_gate),
    ("junit-determinism", junit_reporter.s_junit_determinism),
    ("junit-prior-report-intact", junit_reporter.s_junit_prior_report_intact),
    (
        "junit-finalization-and-interrupt",
        junit_reporter.s_junit_finalization_and_interrupt,
    ),
    ("annotations-modes", annotations.s_annotations_modes),
    ("annotations-caps", annotations.s_annotations_caps),
    ("annotations-conflict", annotations.s_annotations_conflict),
    ("annotations-fencing", annotations.s_annotations_fencing),
    ("parallel-projection-eq", parallel.s_parallel_projection_eq),
    ("parallel-capacity-one", parallel.s_parallel_capacity_one),
    ("parallel-window-overlap", parallel.s_parallel_window_overlap),
    ("parallel-interrupt", parallel.s_parallel_interrupt),
    ("parallel-shard-disjoint", parallel.s_parallel_shard_disjoint),
    ("collect-parallel", parallel.s_collect_parallel),
    ("parallel-auto-smoke", parallel.s_parallel_auto_smoke),
    ("parallel-json-workers", parallel.s_parallel_json_workers),
    ("parallel-j-rejected", parallel.s_parallel_j_rejected),
    ("parallel-junit-canonical-eq", parallel.s_parallel_junit_canonical_eq),
    ("parallel-progress-tty", parallel.s_parallel_progress_tty),
    ("parallel-serial-noverlap", parallel.s_parallel_serial_noverlap),
    ("parallel-serial-stale-glob", parallel.s_parallel_serial_stale_glob),
)


def main() -> int:
    """Build the runner if needed, execute every scenario, and report status."""
    if not os.path.exists(MTEST):
        # The e2e pixi task depends on build-bin, but support a bare invocation.
        print(f"building binary (missing {MTEST}) ...", flush=True)
        bootstrap_rc = bootstrap_build_bin()
        if bootstrap_rc is not None:
            return bootstrap_rc

    context = ScenarioContext(manifest=load_manifest(), registry=SCENARIOS)
    harness = Harness(context)

    print("=== mtest end-to-end gate ===", flush=True)
    for name, scenario in context.registry:
        harness.scenario(name, scenario)

    passed = sum(1 for _name, ok, _detail in harness.results if ok)
    total = len(harness.results)
    print(f"\n=== {passed}/{total} scenarios passed ===")
    if not harness.ok():
        for name, ok, detail in harness.results:
            if not ok:
                print(f"FAILED: {name}\n  {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
