"""Tests for the machine-text escaping primitives (Layer 2).

These are pure, table-driven tests over the escapers three future reporters
(JSON/NDJSON, JUnit XML, GitHub annotations) will share: every control byte
0x00-0x1F in every context, the quote/backslash/angle/percent storms, the
NCR triple in XML attributes, U+FFFD passthrough and replacement, and the
collision-proof stop-commands fencing helper (forced collision + regeneration,
and the always-emitted resume delimiter).
"""
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mtest.report.escape import (
    contains_resume_delimiter,
    fence_region,
    gh_escape_message,
    gh_escape_property,
    json_escape_string,
    resume_delimiter,
    select_collision_free_token,
    stop_commands_opener,
    xml_escape_attribute,
    xml_escape_text,
)

# --- JSON string escaping ---------------------------------------------------


def test_json_escapes_quote_and_backslash() raises:
    assert_equal(json_escape_string('a"b'), 'a\\"b')
    assert_equal(json_escape_string("a\\b"), "a\\\\b")


def test_json_escapes_short_form_controls() raises:
    assert_equal(json_escape_string("a\nb"), "a\\nb")
    assert_equal(json_escape_string("a\rb"), "a\\rb")
    assert_equal(json_escape_string("a\tb"), "a\\tb")


def test_json_escapes_every_other_control_byte_as_u00xx() raises:
    var hexchars: List[String] = [
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "7",
        "8",
        "9",
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
    ]
    for v in range(0x20):
        if v == 0x0A or v == 0x0D or v == 0x09:
            continue
        var s = chr(v)
        var got = json_escape_string(s)
        var want = "\\u00" + hexchars[v >> 4] + hexchars[v & 0xF]
        assert_equal(got, want)


def test_json_passes_through_other_bytes_and_fffd() raises:
    assert_equal(json_escape_string("plain text 123"), "plain text 123")
    assert_equal(json_escape_string("café"), "café")
    assert_equal(json_escape_string("�"), "�")


def test_json_quote_backslash_storm() raises:
    var q = '"'
    var bs = "\\"
    var input = q + bs + q + bs + q + bs
    var esc_q = '\\"'
    var esc_bs = "\\\\"
    var want = esc_q + esc_bs + esc_q + esc_bs + esc_q + esc_bs
    assert_equal(json_escape_string(input), want)


def test_json_hostile_corpus() raises:
    var s = '"<&>%:,\n\r\t\x00\x1fcafé�'
    var got = json_escape_string(s)
    assert_true('\\"' in got)
    assert_true("<&>%:," in got)
    assert_true("\\n" in got)
    assert_true("\\r" in got)
    assert_true("\\t" in got)
    assert_true("\\u0000" in got)
    assert_true("\\u001f" in got)
    assert_true("café" in got)
    assert_true("�" in got)


# --- XML text-context escaping ----------------------------------------------


def test_xml_text_escapes_amp_lt_gt() raises:
    assert_equal(xml_escape_text("a&b<c>d"), "a&amp;b&lt;c&gt;d")


def test_xml_text_does_not_escape_quote() raises:
    assert_equal(xml_escape_text('a"b'), 'a"b')


def test_xml_text_preserves_literal_tab_lf_cr() raises:
    assert_equal(xml_escape_text("a\tb\nc\rd"), "a\tb\nc\rd")


def test_xml_text_control_bytes_become_fffd() raises:
    for v in range(0x20):
        if v == 0x09 or v == 0x0A or v == 0x0D:
            continue
        var got = xml_escape_text(chr(v))
        assert_equal(got, "�")


def test_xml_text_angle_storm() raises:
    assert_equal(
        xml_escape_text("<<<>>>&&&"),
        "&lt;&lt;&lt;&gt;&gt;&gt;&amp;&amp;&amp;",
    )


def test_xml_text_noncharacters_become_fffd() raises:
    # U+FFFE/U+FFFF are valid UTF-8 scalars but excluded by XML 1.0's Char
    # production, so `xmllint` rejects a document that inlines them; they are
    # replaced with U+FFFD. Adjacent code points that ARE valid XML 1.0 Chars —
    # U+FFFD itself and the U+FDD0 noncharacter — must pass through untouched.
    assert_equal(xml_escape_text(chr(0xFFFE)), "�")
    assert_equal(xml_escape_text(chr(0xFFFF)), "�")
    assert_equal(xml_escape_text("a" + chr(0xFFFE) + "b" + chr(0xFFFF)), "a�b�")
    assert_equal(xml_escape_text(chr(0xFFFD)), chr(0xFFFD))
    assert_equal(xml_escape_text(chr(0xFDD0)), chr(0xFDD0))


# --- XML attribute-context escaping -----------------------------------------


def test_xml_attribute_escapes_amp_lt_gt_quote() raises:
    assert_equal(xml_escape_attribute('a&b<c>d"e'), "a&amp;b&lt;c&gt;d&quot;e")


def test_xml_attribute_ncr_triple_for_tab_lf_cr() raises:
    assert_equal(xml_escape_attribute("\t"), "&#9;")
    assert_equal(xml_escape_attribute("\n"), "&#10;")
    assert_equal(xml_escape_attribute("\r"), "&#13;")


def test_xml_attribute_other_control_bytes_become_fffd() raises:
    for v in range(0x20):
        if v == 0x09 or v == 0x0A or v == 0x0D:
            continue
        var got = xml_escape_attribute(chr(v))
        assert_equal(got, "�")


def test_xml_attribute_quote_storm() raises:
    assert_equal(xml_escape_attribute('"""'), "&quot;&quot;&quot;")


def test_xml_attribute_noncharacters_become_fffd() raises:
    assert_equal(xml_escape_attribute(chr(0xFFFE)), "�")
    assert_equal(xml_escape_attribute(chr(0xFFFF)), "�")
    assert_equal(
        xml_escape_attribute("a" + chr(0xFFFE) + "b" + chr(0xFFFF)), "a�b�"
    )
    assert_equal(xml_escape_attribute(chr(0xFFFD)), chr(0xFFFD))
    assert_equal(xml_escape_attribute(chr(0xFDD0)), chr(0xFDD0))


def test_xml_both_contexts_hostile_corpus() raises:
    var s = 'path/"a"<b>&c\t\n\r\x00\x1f' + chr(0xFFFE) + chr(0xFFFF)
    var text_got = xml_escape_text(s)
    var attr_got = xml_escape_attribute(s)
    # The XML-forbidden noncharacters never survive raw in either context.
    assert_false(chr(0xFFFE) in text_got)
    assert_false(chr(0xFFFF) in text_got)
    assert_false(chr(0xFFFE) in attr_got)
    assert_false(chr(0xFFFF) in attr_got)
    # TEXT: literal quote passes, tab/lf/cr pass literally, control -> FFFD.
    assert_true('"a"' in text_got)
    assert_true("&lt;b&gt;" in text_got)
    assert_true("&amp;c" in text_got)
    assert_true("\t\n\r" in text_got)
    assert_true("�" in text_got)
    # ATTRIBUTE: quote entity-escaped, tab/lf/cr become NCRs, control -> FFFD.
    assert_true("&quot;a&quot;" in attr_got)
    assert_true("&#9;&#10;&#13;" in attr_got)
    assert_true("�" in attr_got)
    assert_false("\t" in attr_got)
    assert_false("\n" in attr_got)
    assert_false("\r" in attr_got)


# --- GitHub annotation escaping ---------------------------------------------


def test_gh_message_escapes_percent_cr_lf() raises:
    assert_equal(gh_escape_message("100%"), "100%25")
    assert_equal(gh_escape_message("a\rb"), "a%0Db")
    assert_equal(gh_escape_message("a\nb"), "a%0Ab")


def test_gh_message_escapes_percent_first_no_double_escape() raises:
    # Escaping '%' first means a literal CR/LF's own '%'-bearing replacement
    # is never re-escaped, and a literal '%0D' in the input is escaped once.
    assert_equal(gh_escape_message("\r"), "%0D")
    assert_equal(gh_escape_message("%0D"), "%250D")


def test_gh_message_does_not_escape_colon_or_comma() raises:
    assert_equal(gh_escape_message("a:b,c"), "a:b,c")


def test_gh_property_adds_colon_and_comma_on_message_set() raises:
    assert_equal(gh_escape_property("a:b,c"), "a%3Ab%2Cc")
    assert_equal(gh_escape_property("100%"), "100%25")
    assert_equal(gh_escape_property("a\rb\nc"), "a%0Db%0Ac")


def test_gh_storm_and_hostile_corpus() raises:
    var s = "%%%\r\r\n\n::,,::"
    var msg = gh_escape_message(s)
    assert_true("%25%25%25" in msg)
    assert_true("%0D%0D" in msg)
    assert_true("%0A%0A" in msg)
    assert_true("::,,::" in msg)  # colon/comma untouched in message context

    var prop = gh_escape_property(s)
    assert_true("%25%25%25" in prop)
    assert_true("%3A" in prop)
    assert_true("%2C" in prop)
    assert_false(":" in prop)
    assert_false("," in prop)


# --- Stop-commands fencing: pure predicate + regeneration + assembly -------


def test_resume_delimiter_is_exact_bracketed_token() raises:
    assert_equal(resume_delimiter("abc123"), "::abc123::")


def test_contains_resume_delimiter_true_and_false() raises:
    assert_true(contains_resume_delimiter("noise ::tok:: more", "tok"))
    assert_false(contains_resume_delimiter("noise :tok: more", "tok"))
    assert_false(contains_resume_delimiter("nothing here", "tok"))


def test_select_collision_free_token_skips_forced_collision() raises:
    var region = "junk ::badtoken:: junk"
    var candidates: List[String] = ["badtoken", "goodtoken"]
    var picked = select_collision_free_token(region, candidates)
    assert_equal(picked, "goodtoken")


def test_select_collision_free_token_returns_first_when_clean() raises:
    var region = "nothing dangerous here"
    var candidates: List[String] = ["first", "second"]
    var picked = select_collision_free_token(region, candidates)
    assert_equal(picked, "first")


def test_select_collision_free_token_raises_when_all_candidates_collide() raises:
    var region = "::onlyone::"
    var candidates: List[String] = ["onlyone"]
    with assert_raises():
        _ = select_collision_free_token(region, candidates)


def test_stop_commands_opener_is_exact_prefix_plus_token() raises:
    assert_equal(stop_commands_opener("xyz"), "::stop-commands::xyz")


def test_fence_region_always_contains_resume_delimiter() raises:
    var out = fence_region("tok1", "captured child output, benign")
    assert_true(out.endswith("::tok1::"))
    assert_true("::stop-commands::tok1" in out)
    assert_true("captured child output, benign" in out)


def test_fence_region_epilogue_present_even_with_hostile_region() raises:
    # Error-path restoration, pure form: no matter what garbage the region
    # holds (including forged GH commands), the assembled output still ends
    # with the resume delimiter -- the epilogue is never omitted.
    var hostile = "::error ::pwned\n::stop-commands::forged\nmore junk"
    var out = fence_region("realtoken", hostile)
    assert_true(out.endswith("::realtoken::"))
    assert_true(hostile in out)
