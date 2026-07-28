"""Pure streaming SHA-256, the primitive every cache key is built from.

Layer 2 (`cache`): no I/O, no process spawning, no platform reach. Bytes go in
through `update`, a lowercase hex digest comes out. The implementation is
FIPS 180-4 verbatim, kept deliberately small and dependency-free so a cache key
never depends on anything that can fail.

Two properties beyond plain hashing matter to callers. First, the hasher is
`Copyable`, and a copy forks the running state: a key builder can absorb a
shared prefix once and then fork per-file, which is why `copy()` must duplicate
`_h`, `_tail`, and `_length` rather than alias them. Second, the digest methods
consume the hasher (`deinit self`), so a caller that still needs the running
state forks it first and finalizes the fork.

The public surface is re-exported from `mtest.cache`.
"""

comptime _K: InlineArray[UInt32, 64] = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
]
"""The 64 SHA-256 round constants of FIPS 180-4 section 4.2.2."""

comptime _BLOCK = 64
"""Bytes in one SHA-256 message block."""

comptime _HEX_DIGITS = "0123456789abcdef"
"""Lowercase nibble alphabet for digest rendering."""


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    """Rotate `x` right by `n` bits.

    Args:
        x: The word to rotate.
        n: The rotation distance, strictly between 0 and 32 — every SHA-256
            call site passes a literal in that range, so the `32 - n` left
            shift never reaches the undefined full-width case.

    Returns:
        `x` rotated right by `n` bits.
    """
    return (x >> n) | (x << (32 - n))


def _compress(mut h: InlineArray[UInt32, 8], block: List[UInt8], offset: Int):
    """Absorb one 64-byte block into the state, per FIPS 180-4 section 6.2.2.

    Args:
        h: The eight-word running state, updated in place.
        block: A byte buffer holding the block.
        offset: Index of the block's first byte in `block`; the caller
            guarantees `offset + 64` bytes are present.
    """
    var w = InlineArray[UInt32, 64](fill=0)
    for i in range(16):
        var base = offset + i * 4
        w[i] = (
            (UInt32(block[base]) << 24)
            | (UInt32(block[base + 1]) << 16)
            | (UInt32(block[base + 2]) << 8)
            | UInt32(block[base + 3])
        )
    for i in range(16, 64):
        var x = w[i - 15]
        var y = w[i - 2]
        var s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3)
        var s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1

    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    var f = h[5]
    var g = h[6]
    var hh = h[7]

    for i in range(64):
        var s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
        var ch = (e & f) ^ (~e & g)
        var temp1 = hh + s1 + ch + _K[i] + w[i]
        var s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
        var maj = (a & b) ^ (a & c) ^ (b & c)
        var temp2 = s0 + maj
        hh = g
        g = f
        f = e
        e = d + temp1
        d = c
        c = b
        b = a
        a = temp1 + temp2

    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh


def _hex_words(h: InlineArray[UInt32, 8], count: Int) -> String:
    """Render the first `count` state words as lowercase hex, 8 digits each.

    Rendering word by word is what lets `hex_digest32` exist without string
    range slicing, which this toolchain does not have.

    Args:
        h: The finalized state.
        count: How many leading words to render, at most 8.

    Returns:
        A string of exactly `count * 8` lowercase hex digits.
    """
    var out = String("")
    for word in range(count):
        var value = h[word]
        for i in range(8):
            var shift = UInt32((7 - i) * 4)
            var nibble = Int((value >> shift) & 0xF)
            out += String(_HEX_DIGITS[byte=nibble])
    return out^


struct Sha256(Copyable, Movable):
    """A streaming SHA-256 hasher whose copies fork the running state.

    Feed bytes with `update` as often as you like, then finalize with
    `hex_digest` or `hex_digest32`. Finalizing consumes the hasher; copy it
    first if the pre-finalization state is still needed.

    Examples:

    ```mojo
    from mtest.cache import Sha256

    var h = Sha256()
    h.update(prefix_bytes)
    var forked = h.copy()      # same absorbed prefix, independent from here
    forked.update(file_bytes)
    var key = forked^.hex_digest32()
    ```
    """

    var _h: InlineArray[UInt32, 8]
    """The eight-word running state."""

    var _tail: List[UInt8]
    """Absorbed bytes that do not yet form a full 64-byte block."""

    var _length: UInt64
    """Total bytes absorbed, for the big-endian bit-length suffix."""

    def __init__(out self):
        """Start a hasher at the FIPS 180-4 section 5.3.3 initial state."""
        self._h = [
            0x6A09E667,
            0xBB67AE85,
            0x3C6EF372,
            0xA54FF53A,
            0x510E527F,
            0x9B05688C,
            0x1F83D9AB,
            0x5BE0CD19,
        ]
        self._tail = List[UInt8]()
        self._length = 0

    def update(mut self, data: List[UInt8]):
        """Absorb `data` into the running state.

        Chunking is invisible to the result: any sequence of `update` calls
        yields the digest of their concatenation.

        Args:
            data: The bytes to absorb; an empty list is a no-op.
        """
        self._length += UInt64(len(data))
        for b in data:
            self._tail.append(b)
            if len(self._tail) == _BLOCK:
                _compress(self._h, self._tail, 0)
                self._tail.clear()

    def _finalized(self) -> InlineArray[UInt32, 8]:
        """Return the state after padding, leaving `self` untouched.

        Appends the 0x80 marker, zero-pads to 56 bytes modulo 64, then the
        64-bit big-endian bit length, and absorbs the resulting one or two
        blocks into a copy of the state.

        Returns:
            The eight finalized state words.
        """
        var h = self._h.copy()
        var block = self._tail.copy()
        block.append(0x80)
        while len(block) % _BLOCK != 56:
            block.append(0)
        var bits = self._length * 8
        for i in range(8):
            block.append(UInt8((bits >> UInt64((7 - i) * 8)) & 0xFF))
        var offset = 0
        while offset < len(block):
            _compress(h, block, offset)
            offset += _BLOCK
        return h^

    def hex_digest(deinit self) -> String:
        """Finalize and return the full digest as 64 lowercase hex digits.

        Returns:
            The 64-character hex rendering of all eight state words.
        """
        return _hex_words(self._finalized(), 8)

    def hex_digest32(deinit self) -> String:
        """Finalize and return the first four state words as 32 hex digits.

        This is a true prefix of `hex_digest()`, rendered directly from the
        state words rather than sliced out of the 64-character string.

        Returns:
            The 32-character hex rendering of the leading four state words.
        """
        return _hex_words(self._finalized(), 4)


def sha256_hex(data: List[UInt8]) -> String:
    """Return the full SHA-256 of `data` as 64 lowercase hex digits.

    The one-shot convenience over `Sha256`; identical to constructing a hasher,
    calling `update(data)` once, and finalizing.

    Args:
        data: The bytes to hash.

    Returns:
        The 64-character lowercase hex digest.

    Examples:

    ```mojo
    from mtest.cache import sha256_hex

    var digest = sha256_hex(List[UInt8]())
    # "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ```
    """
    var h = Sha256()
    h.update(data)
    return h^.hex_digest()
