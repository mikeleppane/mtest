"""Deterministic bounded diagnostics for top-level String-key dictionaries."""

from std.collections import Dict

from mtest.assertions._display import (
    _render_projection,
    _render_unequal_pair,
    BoundedWriter,
    DICTIONARY_KEY_BYTE_CAP,
    DISPLAY_LIMIT,
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
    var projections: List[String]
    var total: Int
    var key_display_omissions: Int

    def __init__(out self):
        self.keys = List[String]()
        self.projections = List[String]()
        self.total = 0
        self.key_display_omissions = 0

    def consider(mut self, key: String):
        self.total += 1
        if key.byte_length() > DICTIONARY_KEY_BYTE_CAP:
            self.key_display_omissions += 1
            return
        var projection = _render_projection(key)
        if projection.truncated:
            self.key_display_omissions += 1
            return
        if len(self.keys) < DISPLAY_LIMIT:
            self.keys.append(key)
            self.projections.append(projection.text.copy())
            return
        var largest = 0
        for index in range(1, len(self.keys)):
            if _byte_less(self.keys[largest], self.keys[index]):
                largest = index
        if _byte_less(key, self.keys[largest]):
            self.keys[largest] = key
            self.projections[largest] = projection.text.copy()

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
                var temporary_projection = self.projections[first].copy()
                self.projections[first] = self.projections[smallest]
                self.projections[smallest] = temporary_projection^


def _write_keys(
    mut output: BoundedWriter,
    title: String,
    mut selection: _Selection,
):
    selection.sort()
    if not len(selection.keys):
        return
    output.write_trusted("\n  " + title + " keys:")
    for index in range(len(selection.keys)):
        output.write_trusted('\n    "' + selection.projections[index] + '"')
        if output.truncated:
            break


def _write_changed[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    mut output: BoundedWriter,
    mut selection: _Selection,
    actual: Dict[String, V],
    expected: Dict[String, V],
) raises:
    selection.sort()
    if not len(selection.keys):
        return
    output.write_trusted("\n  changed entries:")
    for index in range(len(selection.keys)):
        var key = selection.keys[index]
        output.write_trusted(
            '\n    "'
            + selection.projections[index]
            + '": '
            + _render_unequal_pair(actual[key], expected[key])
        )
        if output.truncated:
            break


def write_dictionary_difference[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    mut output: BoundedWriter,
    actual: Dict[String, V],
    expected: Dict[String, V],
) raises -> Bool:
    """Derive equality and write deterministic bounded dictionary categories."""
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
        + String(
            max(
                0,
                missing.total - missing.key_display_omissions - DISPLAY_LIMIT,
            )
        )
        + " omitted by entry limit"
        + "\n  unexpected: "
        + String(unexpected.total)
        + " total, "
        + String(
            max(
                0,
                unexpected.total
                - unexpected.key_display_omissions
                - DISPLAY_LIMIT,
            )
        )
        + " omitted by entry limit"
        + "\n  changed: "
        + String(changed.total)
        + " total, "
        + String(
            max(
                0,
                changed.total - changed.key_display_omissions - DISPLAY_LIMIT,
            )
        )
        + " omitted by entry limit"
    )
    if (
        missing.key_display_omissions
        or unexpected.key_display_omissions
        or changed.key_display_omissions
    ):
        output.write_trusted(
            "\n  omitted by key display limit: missing "
            + String(missing.key_display_omissions)
            + ", unexpected "
            + String(unexpected.key_display_omissions)
            + ", changed "
            + String(changed.key_display_omissions)
        )
    _write_keys(output, "missing", missing)
    _write_keys(output, "unexpected", unexpected)
    _write_changed(output, changed, actual, expected)
    return False
