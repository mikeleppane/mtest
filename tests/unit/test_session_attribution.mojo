"""Unit tests for the PURE bounds policy of the crash-attribution post-pass.

The post-pass re-runs a crashed file's tests one at a time to name the culprit.
It is SECONDARY evidence: it never changes the file's CRASH verdict or the exit
code, so the only thing that can go wrong here is the pass running too long. The
bounds are therefore the whole safety argument, and this table pins them: the
32-run cap, the 120 s per-file and 600 s per-session wall budgets, and the
min(--timeout, 60 s) isolation deadline (60 s when `--timeout 0` disables the run
deadline — an unbounded isolation rerun would hang the pass).

`attribution_step` is pure — no processes, no clock, no filesystem: the caller
passes the facts in. ATTRIBUTED and PROBE_FAILED are NOT this function's
decisions (a rerun that dies by signal names the culprit; a probe that cannot
recover the listing fails the file), so they are pinned where they are decided —
the console rendering in `tests/unit/test_report_console.mojo` and the e2e honesty
pair.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.model import AttributionDisposition
from mtest.session import (
    ATTRIBUTION_FILE_BUDGET_SECONDS,
    ATTRIBUTION_SESSION_BUDGET_SECONDS,
    ISOLATION_RUN_CAP,
    ISOLATION_TIMEOUT_CAP_SECS,
    attribution_step,
    isolation_timeout_secs,
)


def test_bounds_are_the_pinned_stable_intent_defaults() raises:
    # The bounds themselves are the contract; a silent widening is a regression.
    assert_equal(ISOLATION_RUN_CAP, 32)
    assert_equal(ISOLATION_TIMEOUT_CAP_SECS, 60)
    assert_equal(ATTRIBUTION_FILE_BUDGET_SECONDS, 120.0)
    assert_equal(ATTRIBUTION_SESSION_BUDGET_SECONDS, 600.0)


def test_isolation_timeout_is_min_of_configured_and_cap() raises:
    assert_equal(isolation_timeout_secs(1), 1)
    assert_equal(isolation_timeout_secs(59), 59)
    assert_equal(isolation_timeout_secs(60), 60)
    assert_equal(isolation_timeout_secs(61), 60)
    assert_equal(isolation_timeout_secs(3600), 60)


def test_isolation_timeout_bounds_a_disabled_run_deadline() raises:
    # `--timeout 0` disables the RUN deadline. An isolation rerun must still be
    # bounded, or a hanging test would hang the whole pass.
    assert_equal(isolation_timeout_secs(0), 60)
    # Total over a nonsense negative too (the CLI refuses these, but the policy
    # is total by construction).
    assert_equal(isolation_timeout_secs(-1), 60)


def test_a_fresh_pass_with_tests_left_continues() raises:
    var s = attribution_step(3, 0, 0.0, 0.0)
    assert_false(s.should_stop)


def test_exhausting_the_listing_is_no_reproduction() raises:
    var s = attribution_step(0, 3, 1.0, 1.0)
    assert_true(s.should_stop)
    assert_true(s.disposition == AttributionDisposition.NO_REPRODUCTION)


def test_an_exhausted_listing_beats_every_budget() raises:
    # Every test ran and none crashed: the search COMPLETED. Saying it was cut
    # short by a budget it happened to also cross would be a lie.
    var s = attribution_step(0, 99, 999.0, 999.0)
    assert_true(s.should_stop)
    assert_true(s.disposition == AttributionDisposition.NO_REPRODUCTION)


def test_the_session_budget_stops_the_pass() raises:
    var s = attribution_step(5, 1, 1.0, ATTRIBUTION_SESSION_BUDGET_SECONDS)
    assert_true(s.should_stop)
    assert_true(s.disposition == AttributionDisposition.TIME_BUDGET)


def test_the_file_budget_stops_the_pass() raises:
    var s = attribution_step(5, 1, ATTRIBUTION_FILE_BUDGET_SECONDS, 1.0)
    assert_true(s.should_stop)
    assert_true(s.disposition == AttributionDisposition.TIME_BUDGET)


def test_just_under_each_budget_continues() raises:
    var s = attribution_step(5, 1, 119.999, 599.999)
    assert_false(s.should_stop)


def test_the_run_cap_stops_the_pass() raises:
    var s = attribution_step(5, ISOLATION_RUN_CAP, 1.0, 1.0)
    assert_true(s.should_stop)
    assert_true(s.disposition == AttributionDisposition.RUN_CAP)


def test_one_run_below_the_cap_continues() raises:
    var s = attribution_step(5, ISOLATION_RUN_CAP - 1, 1.0, 1.0)
    assert_false(s.should_stop)


def test_the_session_budget_guards_the_pre_listing_check() raises:
    # The pass checks the session budget BEFORE recovering a file's listing, in
    # exactly this shape: no runs spent, no file time yet, and one notional test
    # left so only the session budget can fire. Recovering a listing can itself
    # cost a probe, so an exhausted pass must be able to render TIME_BUDGET for a
    # remaining file WITHOUT spawning anything for it.
    var spent = attribution_step(1, 0, 0.0, ATTRIBUTION_SESSION_BUDGET_SECONDS)
    assert_true(spent.should_stop)
    assert_true(spent.disposition == AttributionDisposition.TIME_BUDGET)
    # ... and a pass with budget left never blocks the listing.
    var fresh = attribution_step(1, 0, 0.0, 0.0)
    assert_false(fresh.should_stop)


def test_a_time_budget_beats_the_run_cap() raises:
    # Both are exhausted: the budget is named, because the pass would have been
    # stopped by the clock whether or not the cap existed.
    var s = attribution_step(5, ISOLATION_RUN_CAP, 200.0, 700.0)
    assert_true(s.should_stop)
    assert_true(s.disposition == AttributionDisposition.TIME_BUDGET)
