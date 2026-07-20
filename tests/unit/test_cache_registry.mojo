"""BuildProducts registry invariants: keying, atomic replacement, once-ness.

The registry is a passive, session-scoped store keyed by root-relative path. These
tests pin the exact bookkeeping the session relies on: a keyed lookup returns the
stored product, a rebuild replaces the WHOLE entry (no stale field survives), a
compile-error entry short-circuits, a probe attaches to an existing entry, and the
check-then-record pattern yields exactly ONE build (and one probe) per file.
"""
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from mtest.cache import BuildProduct, BuildRegistry


def _listing(a: String, b: String) -> List[String]:
    var xs = List[String]()
    xs.append(a)
    xs.append(b)
    return xs^


def test_keying_records_and_reads_back_exactly() raises:
    var reg = BuildRegistry()
    assert_false(reg.has("a/x.mojo"))
    reg.record_build(
        BuildProduct.built("a/x.mojo", "build/bin/ax", "/repo/a/x.mojo")
    )
    assert_true(reg.has("a/x.mojo"))
    assert_equal(reg.size(), 1)
    var p = reg.get("a/x.mojo")
    assert_equal(p.rel_path, "a/x.mojo")
    assert_equal(p.binary_path, "build/bin/ax")
    assert_equal(p.canonical_source, "/repo/a/x.mojo")
    assert_false(p.compile_error)
    assert_false(p.probed)
    # A different rel is independent.
    assert_false(reg.has("a/y.mojo"))


def test_atomic_replacement_no_stale_field_survives() raises:
    var reg = BuildRegistry()
    # v1 built AND probed to a qualified listing.
    reg.record_build(
        BuildProduct.built("f.mojo", "build/bin/v1", "/repo/v1/f.mojo")
    )
    reg.record_probe("f.mojo", True, _listing("f::test_a", "f::test_b"))
    # v2 rebuild with different binary + canonical source, not probed.
    reg.record_build(
        BuildProduct.built("f.mojo", "build/bin/v2", "/repo/v2/f.mojo")
    )
    assert_equal(reg.size(), 1)  # replaced in place, not appended
    var p = reg.get("f.mojo")
    assert_equal(p.binary_path, "build/bin/v2")
    assert_equal(p.canonical_source, "/repo/v2/f.mojo")
    # Every prior field is gone: the probe state reset because v2 did not carry it.
    assert_false(p.probed)
    assert_false(p.qualified)
    assert_equal(len(p.listing), 0)
    assert_false(p.compile_error)


def test_compile_error_entry_short_circuits() raises:
    var reg = BuildRegistry()
    reg.record_compile_error("bad.mojo", "error: something broke")
    assert_true(reg.has("bad.mojo"))
    var p = reg.get("bad.mojo")
    assert_true(p.compile_error)
    assert_equal(p.compile_output, "error: something broke")


def test_probe_attaches_to_existing_entry() raises:
    var reg = BuildRegistry()
    reg.record_build(
        BuildProduct.built("p.mojo", "build/bin/p", "/repo/p.mojo")
    )
    reg.record_probe("p.mojo", True, _listing("p::test_one", "p::test_two"))
    var p = reg.get("p.mojo")
    assert_true(p.probed)
    assert_true(p.qualified)
    assert_equal(len(p.listing), 2)
    assert_equal(p.listing[0], "p::test_one")
    # The built fields are untouched by the probe.
    assert_equal(p.binary_path, "build/bin/p")


def test_probe_before_build_raises() raises:
    var reg = BuildRegistry()
    with assert_raises(contains="never.mojo"):
        reg.record_probe("never.mojo", False, List[String]())


def test_once_built_check_then_record_yields_one_build() raises:
    var reg = BuildRegistry()
    var builds = 0
    # The session's reuse pattern: build only when the entry is absent.
    for _ in range(5):
        if not reg.has("once.mojo"):
            builds += 1
            reg.record_build(
                BuildProduct.built(
                    "once.mojo", "build/bin/once", "/repo/once.mojo"
                )
            )
    assert_equal(builds, 1)  # exactly one build across five passes
    # A forced rebuild (stale-name recovery) is the only way past the guard.
    reg.record_build(
        BuildProduct.built("once.mojo", "build/bin/once2", "/repo/once.mojo")
    )
    builds += 1
    assert_equal(builds, 2)
    assert_equal(reg.size(), 1)


def test_once_probed_check_then_record_yields_one_probe() raises:
    var reg = BuildRegistry()
    reg.record_build(
        BuildProduct.built("q.mojo", "build/bin/q", "/repo/q.mojo")
    )
    var probes = 0
    for _ in range(4):
        if not reg.get("q.mojo").probed:
            probes += 1
            reg.record_probe("q.mojo", True, _listing("q::t1", "q::t2"))
    assert_equal(probes, 1)  # exactly one probe across four passes
