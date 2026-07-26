"""Deterministic bounded diagnostics for top-level String-key dictionaries."""

from std.collections import Dict

from mtest.assertions._display import (
    BoundedWriter,
    DICTIONARY_KEY_BYTE_CAP,
    DISPLAY_LIMIT,
    render_value,
)


def _byte_less(lhs: String, rhs: String) -> Bool:
    var left = lhs.as_bytes()
    var right = rhs.as_bytes()
    var common = min(len(left), len(right))
    for index in range(common):
        if left[index] < right[index]:
            return True
        if left[index] > right[index]:
            return False
    return len(left) < len(right)


struct _Selection(Movable):
    """Retain the full-byte lexicographically smallest displayable keys."""

    var keys: List[String]
    var total: Int

    def __init__(out self):
        self.keys = List[String]()
        self.total = 0

    def consider(mut self, key: String):
        self.total += 1
        if len(self.keys) < DISPLAY_LIMIT:
            self.keys.append(key)
            return
        var largest = 0
        for index in range(1, len(self.keys)):
            if _byte_less(self.keys[largest], self.keys[index]):
                largest = index
        if _byte_less(key, self.keys[largest]):
            self.keys[largest] = key

    def sort(mut self):
        for first in range(len(self.keys)):
            var smallest = first
            for candidate in range(first + 1, len(self.keys)):
                if _byte_less(self.keys[candidate], self.keys[smallest]):
                    smallest = candidate
            if smallest != first:
                var temporary = self.keys[first].copy()
                self.keys[first] = self.keys[smallest]
                self.keys[smallest] = temporary^


def _dictionaries_equal[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](actual: Dict[String, V], expected: Dict[String, V],) raises -> Bool:
    if len(actual) != len(expected):
        return False
    for entry in actual.items():
        if entry.key not in expected:
            return False
        if entry.value != expected[entry.key]:
            return False
    return True


def _write_keys(
    mut output: BoundedWriter,
    title: String,
    mut selection: _Selection,
):
    selection.sort()
    if not selection.total:
        return
    output.write_trusted("\n  " + title + " keys:")
    for key in selection.keys:
        output.write_trusted("\n    ")
        output.write(key)


def _write_changed[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    mut output: BoundedWriter,
    mut selection: _Selection,
    actual: Dict[String, V],
    expected: Dict[String, V],
) raises:
    selection.sort()
    if not selection.total:
        return
    output.write_trusted("\n  changed entries:")
    for key in selection.keys:
        output.write_trusted("\n    ")
        output.write(key)
        output.write_trusted(": ")
        output.write_trusted(render_value(actual[key]))
        output.write_trusted(" != ")
        output.write_trusted(render_value(expected[key]))


def _write_opaque_dictionary_detail[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    mut output: BoundedWriter,
    actual: Dict[String, V],
    expected: Dict[String, V],
):
    output.write_trusted(
        "dictionary differs; structural key exceeds "
        + String(DICTIONARY_KEY_BYTE_CAP)
        + " bytes; deterministic value detail omitted"
        + "\n  actual entries: "
        + String(len(actual))
        + "\n  expected entries: "
        + String(len(expected))
    )


def write_dictionary_difference[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    mut output: BoundedWriter,
    actual: Dict[String, V],
    expected: Dict[String, V],
) raises -> Bool:
    """Derive equality and write deterministic bounded dictionary categories."""
    var oversized_key = False
    for entry in expected.items():
        if entry.key.byte_length() > DICTIONARY_KEY_BYTE_CAP:
            oversized_key = True
    for entry in actual.items():
        if entry.key.byte_length() > DICTIONARY_KEY_BYTE_CAP:
            oversized_key = True
    if oversized_key:
        if _dictionaries_equal(actual, expected):
            return True
        _write_opaque_dictionary_detail(output, actual, expected)
        return False

    var missing = _Selection()
    var unexpected = _Selection()
    var changed = _Selection()
    for entry in expected.items():
        if entry.key not in actual:
            missing.consider(entry.key)
        elif actual[entry.key] != entry.value:
            changed.consider(entry.key)
    for entry in actual.items():
        if entry.key not in expected:
            unexpected.consider(entry.key)

    if not missing.total and not unexpected.total and not changed.total:
        return True

    output.write_trusted(
        "dictionary differs"
        + "\n  missing: "
        + String(missing.total)
        + " total, "
        + String(max(0, missing.total - DISPLAY_LIMIT))
        + " omitted"
        + "\n  unexpected: "
        + String(unexpected.total)
        + " total, "
        + String(max(0, unexpected.total - DISPLAY_LIMIT))
        + " omitted"
        + "\n  changed: "
        + String(changed.total)
        + " total, "
        + String(max(0, changed.total - DISPLAY_LIMIT))
        + " omitted"
    )
    _write_keys(output, "missing", missing)
    _write_keys(output, "unexpected", unexpected)
    _write_changed(output, changed, actual, expected)
    return False
