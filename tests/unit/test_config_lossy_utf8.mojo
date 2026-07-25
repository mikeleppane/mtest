"""Byte-exact characterization of `lossy_utf8`, the runner's only byte decoder.

Every captured child stream reaches the console, the JSON reporter, and the
JUnit reporter through this one function, so its replacement policy is a
user-visible contract rather than an implementation detail. These tables pin
that contract row by row: each row carries the exact input `List[UInt8]` and the
complete expected `String`, never a length and never a substring.

The pinned rule is RFC 3629 validity with one U+FFFD per byte the current
algorithm consumes on failure, and the algorithm consumes exactly one byte
whenever a leader is illegal or a sequence fails to validate. A truncated
sequence therefore yields one replacement per byte of the truncated prefix,
which is deliberately not what Python's `bytes.decode(errors="replace")` or
Rust's `String::from_utf8_lossy` produce — both collapse a maximal truncated
prefix into a single replacement. These rows record what mtest does, so any
later change to it has to move these tables in the same commit.
"""
from std.testing import assert_equal

from mtest.config import lossy_utf8

# The replacement character the decoder substitutes for every invalid byte.
comptime RPL: StaticString = "�"


def _assert_decode(raw: List[UInt8], expected: String, label: String) raises:
    """Assert `lossy_utf8(raw)` is byte-for-byte `expected`.

    Args:
        raw: The exact captured bytes making up one table row.
        expected: The complete decoded text the row must produce.
        label: The row name, surfaced when the row drifts.

    Raises:
        Error: The decoded text differed from `expected`.
    """
    assert_equal(lossy_utf8(raw), expected, label)


def test_lossy_utf8_empty_input_is_the_empty_string() raises:
    _assert_decode(List[UInt8](), "", "empty")


def test_lossy_utf8_passes_every_ascii_byte_through() raises:
    # The whole 0x00..0x7F range, in order, decodes to itself.
    var raw = List[UInt8]()
    var expected = String("")
    for v in range(0, 128):
        raw.append(UInt8(v))
        expected += chr(v)
    _assert_decode(raw, expected, "ascii 0x00..0x7f sweep")

    _assert_decode([0x00], chr(0x00), "ascii NUL")
    _assert_decode([0x7F], chr(0x7F), "ascii DEL")
    _assert_decode([0x41, 0x42, 0x43], "ABC", "ascii ABC")


def test_lossy_utf8_keeps_the_boundary_scalars() raises:
    # Minimum and maximum scalar for each of the 2-, 3-, and 4-byte forms.
    _assert_decode([0xC2, 0x80], chr(0x80), "2-byte min U+0080")
    _assert_decode([0xDF, 0xBF], chr(0x7FF), "2-byte max U+07FF")
    _assert_decode([0xE0, 0xA0, 0x80], chr(0x800), "3-byte min U+0800")
    _assert_decode([0xEF, 0xBF, 0xBF], chr(0xFFFF), "3-byte max U+FFFF")
    _assert_decode([0xF0, 0x90, 0x80, 0x80], chr(0x10000), "4-byte min U+10000")
    _assert_decode(
        [0xF4, 0x8F, 0xBF, 0xBF], chr(0x10FFFF), "4-byte max U+10FFFF"
    )
    # The scalars either side of the surrogate hole are both valid.
    _assert_decode([0xED, 0x9F, 0xBF], chr(0xD7FF), "last before surrogates")
    _assert_decode([0xEE, 0x80, 0x80], chr(0xE000), "first after surrogates")


def test_lossy_utf8_replaces_each_lone_continuation_byte() raises:
    # 0x80..0xBF can never begin a sequence; each is consumed on its own.
    _assert_decode([0x80], RPL, "lone continuation 0x80")
    _assert_decode([0xBF], RPL, "lone continuation 0xBF")
    _assert_decode([0x80, 0xA0, 0xBF], "���", "three lone continuations")


def test_lossy_utf8_replaces_each_illegal_leader_byte() raises:
    # 0xC0/0xC1 lead only overlong forms; 0xF5..0xFF lead only >U+10FFFF.
    _assert_decode([0xC0], RPL, "illegal leader 0xC0")
    _assert_decode([0xC1], RPL, "illegal leader 0xC1")
    _assert_decode([0xF5], RPL, "illegal leader 0xF5")
    _assert_decode([0xFE, 0xFF], "��", "illegal leaders 0xFE 0xFF")


def test_lossy_utf8_rejects_overlong_encodings_byte_by_byte() raises:
    # Every byte of a rejected overlong sequence is consumed on its own, so the
    # replacement count equals the attempted sequence length.
    _assert_decode([0xC0, 0x80], "��", "overlong U+0000 as 2 bytes")
    _assert_decode([0xC1, 0xBF], "��", "overlong U+007F as 2 bytes")
    _assert_decode([0xE0, 0x80, 0xAF], "���", "overlong U+002F as 3 bytes")
    _assert_decode([0xE0, 0x9F, 0xBF], "���", "overlong U+07FF as 3 bytes")
    _assert_decode(
        [0xF0, 0x8F, 0xBF, 0xBF], "����", "overlong U+FFFF as 4 bytes"
    )


def test_lossy_utf8_rejects_surrogate_code_points_byte_by_byte() raises:
    # 0xED with a 0xA0..0xBF first continuation would encode D800..DFFF.
    _assert_decode([0xED, 0xA0, 0x80], "���", "surrogate U+D800")
    _assert_decode([0xED, 0xBF, 0xBF], "���", "surrogate U+DFFF")
    _assert_decode(
        [0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80],
        "������",
        "CESU-8 surrogate pair",
    )


def test_lossy_utf8_rejects_scalars_above_u10ffff_byte_by_byte() raises:
    _assert_decode([0xF4, 0x90, 0x80, 0x80], "����", "U+110000 via 0xF4")
    _assert_decode([0xF5, 0x80, 0x80, 0x80], "����", "U+140000 via 0xF5")
    _assert_decode([0xF7, 0xBF, 0xBF, 0xBF], "����", "U+1FFFFF via 0xF7")


def test_lossy_utf8_replaces_one_per_byte_at_every_truncation() raises:
    # Truncated by end of input: the leader fails the length check, then each
    # orphaned continuation fails again as an illegal leader.
    _assert_decode([0xC2], RPL, "2-byte truncated after 1")
    _assert_decode([0xE2], RPL, "3-byte truncated after 1")
    _assert_decode([0xE2, 0x82], "��", "3-byte truncated after 2")
    _assert_decode([0xF0], RPL, "4-byte truncated after 1")
    _assert_decode([0xF0, 0x9F], "��", "4-byte truncated after 2")
    _assert_decode([0xF0, 0x9F, 0x98], "���", "4-byte truncated after 3")

    # Cut short by a following ASCII byte rather than by end of input: the same
    # one-per-byte count, with the interrupting byte kept verbatim.
    _assert_decode([0xC2, 0x41], "�A", "2-byte cut by ASCII after 1")
    _assert_decode([0xE2, 0x41], "�A", "3-byte cut by ASCII after 1")
    _assert_decode([0xE2, 0x82, 0x41], "��A", "3-byte cut by ASCII after 2")
    _assert_decode([0xF0, 0x41], "�A", "4-byte cut by ASCII after 1")
    _assert_decode([0xF0, 0x9F, 0x41], "��A", "4-byte cut by ASCII after 2")
    _assert_decode(
        [0xF0, 0x9F, 0x98, 0x41], "���A", "4-byte cut by ASCII after 3"
    )


def test_lossy_utf8_keeps_valid_neighbours_around_an_invalid_byte() raises:
    _assert_decode([0x41, 0xFF, 0x42], "A�B", "ascii invalid ascii")
    _assert_decode(
        [0xC3, 0xA9, 0x80, 0xE2, 0x82, 0xAC], "é�€", "2-byte invalid 3-byte"
    )
    _assert_decode(
        [0xE2, 0x98, 0x83, 0xC0, 0xF0, 0x9F, 0x98, 0x80],
        "☃�😀",
        "3-byte invalid 4-byte",
    )
    _assert_decode(
        [0xF0, 0x9F, 0x98, 0x80, 0x41, 0xE2, 0x98, 0x83],
        "😀A☃",
        "4-byte ascii 3-byte, all valid",
    )
    # A truncated sequence sandwiched between intact text.
    _assert_decode(
        [0x41, 0xE2, 0x82, 0xE2, 0x98, 0x83],
        "A��☃",
        "ascii truncated-3 3-byte",
    )


def test_lossy_utf8_replaces_a_whole_binary_run() raises:
    # A run of high bytes, no part of which can start a sequence.
    _assert_decode([0xFF, 0xFE, 0xFD, 0xFC], "����", "four illegal leaders")
    # An ELF magic prefix is entirely ASCII and survives untouched.
    _assert_decode(
        [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00],
        chr(0x7F) + "ELF" + chr(0x02) + chr(0x01) + chr(0x01) + chr(0x00),
        "ELF header bytes are all ASCII",
    )
