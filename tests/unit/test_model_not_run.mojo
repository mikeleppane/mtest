"""Tests for the NOT_RUN classification vocabulary (Layer 0).

`not_run_reason_label` is asserted total over the whole closed vocabulary plus
an out-of-band code. `classify_not_run` is the pure precedence function the
session's classification site calls per selected file; every rank of the
precedence chain is pinned individually, then three named cases where two
facts from different ranks are both true at once are pinned by name, since
that is exactly where a wrong precedence would first show a wrong answer.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import (
    NotRunFacts,
    NotRunReason,
    NotRunRecord,
    classify_not_run,
    not_run_reason_label,
)


def test_label_is_exact_for_every_known_reason() raises:
    assert_equal(
        not_run_reason_label(NotRunReason.GATE_CASUALTY), "gate casualty"
    )
    assert_equal(
        not_run_reason_label(NotRunReason.GATE_ABORT),
        "gate aborted the session",
    )
    assert_equal(
        not_run_reason_label(NotRunReason.LIMIT_REACHED),
        "stopped early (-x/--maxfail)",
    )
    assert_equal(not_run_reason_label(NotRunReason.INTERRUPTED), "interrupted")
    assert_equal(
        not_run_reason_label(NotRunReason.INTERNAL_ERROR), "internal error"
    )
    assert_equal(
        not_run_reason_label(NotRunReason.PRECOMPILE_CASUALTY),
        "precompile casualty",
    )
    assert_equal(
        not_run_reason_label(NotRunReason.DRIFT_HALT),
        "protocol drift halted the session",
    )
    assert_equal(
        not_run_reason_label(NotRunReason.DELIVERY_ABORT),
        "terminal stream died; scheduling stopped",
    )


def test_label_is_total_over_an_unclassified_code() raises:
    var unclassified = NotRunReason(99)
    assert_true("unclassified" in not_run_reason_label(unclassified))


def test_vocabulary_codes_0_through_7_are_distinct() raises:
    var all = [
        NotRunReason.GATE_CASUALTY,
        NotRunReason.GATE_ABORT,
        NotRunReason.LIMIT_REACHED,
        NotRunReason.INTERRUPTED,
        NotRunReason.INTERNAL_ERROR,
        NotRunReason.PRECOMPILE_CASUALTY,
        NotRunReason.DRIFT_HALT,
        NotRunReason.DELIVERY_ABORT,
    ]
    assert_equal(len(all), 8)
    for i in range(len(all)):
        assert_equal(all[i].code, i)
        for j in range(len(all)):
            if i == j:
                assert_true(all[i] == all[j])
            else:
                assert_true(all[i] != all[j])


def test_not_run_record_holds_path_and_reason() raises:
    var rec = NotRunRecord("tests/test_a.mojo", NotRunReason.GATE_CASUALTY)
    assert_equal(rec.path, "tests/test_a.mojo")
    assert_true(rec.reason == NotRunReason.GATE_CASUALTY)


# --- classify_not_run: every rank of the precedence chain, individually. -----


def test_classify_interrupt_outranks_every_other_latch() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=True,
            internal_error=True,
            drift=True,
            precompile_failed=True,
            gate_abort=True,
            stream_dead=True,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.INTERRUPTED)


def test_classify_internal_error_outranks_drift_and_below() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=True,
            drift=True,
            precompile_failed=True,
            gate_abort=True,
            stream_dead=True,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.INTERNAL_ERROR)


def test_classify_drift_outranks_precompile_failed_and_below() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=True,
            precompile_failed=True,
            gate_abort=True,
            stream_dead=True,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.DRIFT_HALT)


def test_classify_precompile_failed_outranks_gate_abort_and_below() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=True,
            gate_abort=True,
            stream_dead=True,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.PRECOMPILE_CASUALTY)


def test_classify_gate_abort_on_a_gate_file_is_gate_casualty() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=True,
            stream_dead=False,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.GATE_CASUALTY)


def test_classify_gate_abort_on_a_run_file_is_gate_abort() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=True,
            stream_dead=False,
            is_gate_file=False,
        )
    )
    assert_true(reason == NotRunReason.GATE_ABORT)


def test_classify_stream_dead_alone_is_delivery_abort() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=False,
            stream_dead=True,
            is_gate_file=False,
        )
    )
    assert_true(reason == NotRunReason.DELIVERY_ABORT)


def test_classify_bare_gate_file_with_no_latch_is_gate_casualty() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=False,
            stream_dead=False,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.GATE_CASUALTY)


def test_classify_no_fact_at_all_is_limit_reached() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=False,
            stream_dead=False,
            is_gate_file=False,
        )
    )
    assert_true(reason == NotRunReason.LIMIT_REACHED)


# --- Cross-rank overlap: two facts from different ranks, both true at once. --


def test_classify_stream_dead_beats_gate_file_when_gate_abort_unlatched() raises:
    # A gate file that never ran because the STREAM died, with no gate ever
    # aborting, is a delivery casualty, not a gate casualty.
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=False,
            stream_dead=True,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.DELIVERY_ABORT)


def test_classify_precompile_failed_beats_stream_dead() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=True,
            gate_abort=False,
            stream_dead=True,
            is_gate_file=False,
        )
    )
    assert_true(reason == NotRunReason.PRECOMPILE_CASUALTY)


def test_classify_gate_abort_on_a_gate_file_beats_stream_dead() raises:
    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=True,
            stream_dead=True,
            is_gate_file=True,
        )
    )
    assert_true(reason == NotRunReason.GATE_CASUALTY)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
