"""Unit tests for the pure SHA-256 primitive in `mtest.cache`.

The cache keys every build decision on this digest, so the primitive is pinned
against the FIPS 180-4 published vectors (empty, "abc", the 56-byte two-block
message) plus the two streaming properties the key builder depends on: feeding
in chunks equals one shot, and a copied hasher forks the running state instead
of aliasing it. The last test pins that the 32-hex short form is a true prefix
of the full 64-hex digest.
"""
from std.testing import TestSuite, assert_equal

from mtest.cache import Sha256, sha256_hex


def test_empty_vector() raises:
    assert_equal(
        sha256_hex(List[UInt8]()),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    )


def test_abc_vector() raises:
    var data = List[UInt8]()
    for b in "abc".as_bytes():
        data.append(b)
    assert_equal(
        sha256_hex(data),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )


def test_two_block_vector() raises:
    # 56 bytes forces the padding into a second block.
    var text = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    var data = List[UInt8]()
    for b in text.as_bytes():
        data.append(b)
    assert_equal(
        sha256_hex(data),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    )


def test_streaming_equals_one_shot() raises:
    var one = List[UInt8]()
    for b in "hello world, hello cache".as_bytes():
        one.append(b)
    var h = Sha256()
    var first = List[UInt8]()
    var second = List[UInt8]()
    for i in range(len(one)):
        if i < 5:
            first.append(one[i])
        else:
            second.append(one[i])
    h.update(first)
    h.update(second)
    assert_equal(h^.hex_digest(), sha256_hex(one))


def test_forked_state_diverges() raises:
    var base = Sha256()
    var prefix = List[UInt8]()
    for b in "shared-prefix".as_bytes():
        prefix.append(b)
    base.update(prefix)
    var a = base.copy()
    var b = base.copy()
    var one: List[UInt8] = [UInt8(1)]
    var two: List[UInt8] = [UInt8(2)]
    a.update(one)
    b.update(two)
    var da = a^.hex_digest()
    var db = b^.hex_digest()
    if da == db:
        raise Error("forked digests must differ")


def test_digest32_matches_full_prefix() raises:
    var data = List[UInt8]()
    for b in "digest32 prefix vector".as_bytes():
        data.append(b)
    var full = Sha256()
    full.update(data)
    var short = Sha256()
    short.update(data)
    var full_hex = full^.hex_digest()
    # No String range slicing on this toolchain: build the prefix byte by byte.
    var prefix = String("")
    for i in range(32):
        prefix += String(full_hex[byte=i])
    assert_equal(short^.hex_digest32(), prefix)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
