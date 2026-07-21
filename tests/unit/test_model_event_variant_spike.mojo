"""Spike: a closed `Variant` of typed payload arms reproduces the NDJSON bytes.

De-risks the event-representation refactor before it touches the whole event
set. It proves, on the pinned toolchain, that the intended shape compiles and
behaves: one payload struct per kind holding only that kind's fields, held in a
closed `Variant`, dispatched by arm, serializes to bytes identical to the frozen
`--json` records the flat-field `Event` produces today.

Two kinds are enough to prove the mechanics — the `Copyable`/`Movable` arm
bounds, the arm dispatch, and reading a field back through the typed arm. The
asserted bytes are the exact records pinned in `test_report_json_stream.mojo`;
if the `Variant` shape could not reproduce them the refactor's premise would be
false. The permanent per-kind byte oracle stays `test_report_json_stream.mojo`.
"""
from std.utils import Variant

from std.testing import assert_equal, assert_false, assert_true

from mtest.report.escape import json_escape_string


@fieldwise_init
struct _SessionStartedArm(Copyable, Movable):
    """The `session_started` payload: only that kind's fields."""

    var root: String
    var toolchain: String
    var selected_count: Int
    var excluded_count: Int
    var shard_label: String
    var sharded_out_count: Int


@fieldwise_init
struct _WarningArm(Copyable, Movable):
    """The `warning` payload: only that kind's fields."""

    var warning_kind: String
    var warning_pattern: String


comptime _Payload = Variant[_SessionStartedArm, _WarningArm]


def _ser_session_started(p: _SessionStartedArm) -> String:
    var s = String('{"event":"session_started"')
    s += ',"root":"' + json_escape_string(p.root) + '"'
    s += ',"toolchain":"' + json_escape_string(p.toolchain) + '"'
    s += ',"selected_count":' + String(p.selected_count)
    s += ',"excluded_count":' + String(p.excluded_count)
    s += ',"shard_label":"' + json_escape_string(p.shard_label) + '"'
    s += ',"sharded_out_count":' + String(p.sharded_out_count)
    s += "}"
    return s^


def _ser_warning(p: _WarningArm) -> String:
    var s = String('{"event":"warning"')
    s += ',"warning_kind":"' + json_escape_string(p.warning_kind) + '"'
    s += ',"warning_pattern":"' + json_escape_string(p.warning_pattern) + '"'
    s += "}"
    return s^


def _serialize(p: _Payload) -> String:
    """Dispatch on the active arm and serialize through the typed payload."""
    if p.isa[_SessionStartedArm]():
        return _ser_session_started(p[_SessionStartedArm])
    return _ser_warning(p[_WarningArm])


def test_variant_session_started_reproduces_bytes() raises:
    var p = _Payload(_SessionStartedArm("root/dir", "mojo 1.0", 3, 1, "2/5", 4))
    assert_equal(
        _serialize(p),
        '{"event":"session_started","root":"root/dir","toolchain":"mojo'
        + ' 1.0","selected_count":3,"excluded_count":1,"shard_label":"2/5",'
        + '"sharded_out_count":4}',
    )


def test_variant_warning_reproduces_bytes() raises:
    var p = _Payload(_WarningArm("stale_exclude", "*.mojo"))
    assert_equal(
        _serialize(p),
        '{"event":"warning","warning_kind":"stale_exclude",'
        + '"warning_pattern":"*.mojo"}',
    )


def test_variant_dispatch_selects_the_active_arm() raises:
    var a = _Payload(_SessionStartedArm("r", "t", 0, 0, "", 0))
    var b = _Payload(_WarningArm("k", "p"))
    assert_true(a.isa[_SessionStartedArm]())
    assert_false(a.isa[_WarningArm]())
    assert_true(b.isa[_WarningArm]())
    # A copied variant keeps its arm and its bytes: the arms are Copyable.
    assert_equal(_serialize(a.copy()), _serialize(a))
