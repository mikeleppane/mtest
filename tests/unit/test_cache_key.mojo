"""Unit tests for cache key frames, generation naming, and the meta format.

Two properties carry the whole persistent cache. First, `KeyBuilder` frames
every contribution with a tag, a NUL, and a length, so no payload — however
many newlines or `tag:` lookalikes it contains — can forge a frame boundary
and make two different builds hash alike. Second, `MetaFile.parse` is total:
a truncated, corrupt, or hand-edited file returns `None` so the caller treats
the generation as a miss and rebuilds, rather than serving a wrong binary.
"""
from std.testing import TestSuite, assert_equal, assert_true

from mtest.cache import (
    ARG_FLAG,
    ARG_FILE_CANDIDATE,
    ARG_INCLUDE_DIR,
    ARG_UNKNOWN,
    ArgClass,
    KeyBuilder,
    MetaFile,
    classify_build_args,
    generation_name,
)


def test_frame_order_changes_digest() raises:
    var a = KeyBuilder()
    a.feed_str("x", "1")
    a.feed_str("y", "2")
    var b = KeyBuilder()
    b.feed_str("y", "2")
    b.feed_str("x", "1")
    if a^.digest_full() == b^.digest_full():
        raise Error("frame order must be significant")


def test_newline_payload_cannot_forge_frames() raises:
    var a = KeyBuilder()
    a.feed_str("arg", "one\narg: two")
    var b = KeyBuilder()
    b.feed_str("arg", "one")
    b.feed_str("arg", " two")
    if a^.digest_full() == b^.digest_full():
        raise Error("length-prefixed frames must not be forgeable")


def test_digest32_is_prefix_of_full() raises:
    var a = KeyBuilder()
    a.feed_str("t", "v")
    var b = a.copy()
    var short = a^.digest32()
    var full = b^.digest_full()
    assert_equal(short.byte_length(), 32)
    # No String range slicing on this toolchain: build the prefix byte by byte.
    var prefix = String("")
    for i in range(32):
        prefix += String(full[byte=i])
    assert_equal(short, prefix)


def test_generation_name_separator_is_unmanglable() raises:
    assert_equal(
        generation_name("tests_sa", "0123456789abcdef0123456789abcdef"),
        "tests_sa_h0123456789abcdef0123456789abcdef",
    )


def test_meta_round_trip() raises:
    var argv: List[String] = ["mojo", "build", "weird\nline"]
    var m = MetaFile(
        key_full=String("a") * 64,
        bin_sha=String("b") * 64,
        build_seconds=1.5,
        argv=argv.copy(),
    )
    var back = MetaFile.parse(m.render())
    assert_true(Bool(back))
    assert_equal(back.value().argv[2], "weird\nline")


def test_meta_rejects_truncation() raises:
    var argv: List[String] = ["x"]
    var m = MetaFile(
        key_full=String("a") * 64,
        bin_sha=String("b") * 64,
        build_seconds=0.0,
        argv=argv.copy(),
    )
    var text = m.render()
    # No String range slicing: copy every byte but the last four.
    var cut = String("")
    for i in range(text.byte_length() - 4):
        cut += String(text[byte=i])
    assert_true(not Bool(MetaFile.parse(cut)))


def test_classify_known_forms() raises:
    var args: List[String] = [
        "--no-optimization",
        "-O0",
        "-O1",
        "-O2",
        "-O3",
        "--debug-level",
        "3",
        "--debug-level=5",
        "-Iinclude",
        "-I",
        "vendor/include",
    ]
    var result = classify_build_args(args)
    assert_true(len(result) <= len(args))
    assert_equal(len(result), 9)
    assert_equal(result[0].kind, ARG_FLAG)
    assert_equal(result[0].value, "--no-optimization")
    assert_equal(result[1].kind, ARG_FLAG)
    assert_equal(result[1].value, "-O0")
    assert_equal(result[2].kind, ARG_FLAG)
    assert_equal(result[2].value, "-O1")
    assert_equal(result[3].kind, ARG_FLAG)
    assert_equal(result[3].value, "-O2")
    assert_equal(result[4].kind, ARG_FLAG)
    assert_equal(result[4].value, "-O3")
    assert_equal(result[5].kind, ARG_FLAG)
    assert_equal(result[5].value, "--debug-level 3")
    # The attached `--debug-level=<val>` spelling is not part of the
    # grammar's allowlist (only the two-token form is): it must be
    # conservative, not silently accepted as a flag.
    assert_equal(result[6].kind, ARG_UNKNOWN)
    assert_equal(result[6].value, "--debug-level=5")
    assert_equal(result[7].kind, ARG_INCLUDE_DIR)
    assert_equal(result[7].value, "include")
    assert_equal(result[8].kind, ARG_INCLUDE_DIR)
    assert_equal(result[8].value, "vendor/include")


def test_classify_unknown_is_conservative() raises:
    var args: List[String] = ["--totally-unrecognized-flag", "-O2"]
    var result = classify_build_args(args)
    assert_equal(len(result), 2)
    assert_equal(result[0].kind, ARG_UNKNOWN)
    assert_equal(result[0].value, "--totally-unrecognized-flag")
    assert_equal(result[1].kind, ARG_FLAG)
    assert_equal(result[1].value, "-O2")


def test_classify_missing_lookahead_is_conservative() raises:
    # A two-token introducer as the LAST argv token, with its value missing,
    # must classify as ARG_UNKNOWN rather than being dropped or matched
    # against a made-up value -- this is the property Task 6 relies on to
    # disable the cache instead of silently treating a malformed build
    # command as harmless. An empty-string token gets the same conservative
    # treatment. `len(result) <= len(args)` must still hold in every case.
    var trailing_include: List[String] = ["-O2", "-I"]
    var r1 = classify_build_args(trailing_include)
    assert_true(len(r1) <= len(trailing_include))
    assert_equal(len(r1), 2)
    assert_equal(r1[1].kind, ARG_UNKNOWN)
    assert_equal(r1[1].value, "-I")

    var trailing_linker: List[String] = ["-O2", "-Xlinker"]
    var r2 = classify_build_args(trailing_linker)
    assert_true(len(r2) <= len(trailing_linker))
    assert_equal(len(r2), 2)
    assert_equal(r2[1].kind, ARG_UNKNOWN)
    assert_equal(r2[1].value, "-Xlinker")

    var trailing_debug: List[String] = ["-O2", "--debug-level"]
    var r3 = classify_build_args(trailing_debug)
    assert_true(len(r3) <= len(trailing_debug))
    assert_equal(len(r3), 2)
    assert_equal(r3[1].kind, ARG_UNKNOWN)
    assert_equal(r3[1].value, "--debug-level")

    var empty_token: List[String] = ["-O2", ""]
    var r4 = classify_build_args(empty_token)
    assert_true(len(r4) <= len(empty_token))
    assert_equal(len(r4), 2)
    assert_equal(r4[1].kind, ARG_UNKNOWN)
    assert_equal(r4[1].value, "")


def test_classify_selfhost_invocation() raises:
    var args: List[String] = [
        "--no-optimization",
        "-Xlinker",
        "build/obj/support.o",
    ]
    var result = classify_build_args(args)
    assert_equal(len(result), 2)
    assert_equal(result[0].kind, ARG_FLAG)
    assert_equal(result[0].value, "--no-optimization")
    assert_equal(result[1].kind, ARG_FILE_CANDIDATE)
    assert_equal(result[1].value, "build/obj/support.o")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
