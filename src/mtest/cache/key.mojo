"""Cache key framing, build-arg classification, generation naming, and the
on-disk meta record.

Layer 2 (`cache`): pure, no I/O. Strings and byte lists go in, strings come
out; opening, reading, and renaming the files this module describes belongs to
the session layer.

Two properties carry the whole persistent build cache.

`KeyBuilder` frames every contribution as the tag length, the tag bytes, the
payload length, then the payload, each length eight little-endian bytes.
`Sha256.update` is raw concatenation with no framing of its own, so without
those lengths the contributions `("ab", "c")` and `("a", "bc")` would hash
alike — and a key collision here silently serves a stale binary. Because both
lengths lead, neither a payload full of newlines nor a tag holding any byte at
all can forge a boundary: the frame is injective over the pair.

`MetaFile.parse` is total. It reads text that came off disk, where a truncated
write, an interrupted rename, a hand edit, or a stale format version are all
possible, so every deviation returns `None` rather than raising or handing back
a half-filled record. `None` means "treat this generation as a miss and
rebuild", which is always safe; a partially parsed record would not be.

`classify_build_args` sorts a build command line into rows a cache key can
safely absorb: a flag hashes verbatim, a file or include-dir token gets
resolved and digested by a later layer, and anything unrecognized becomes
`ARG_UNKNOWN` — because an unrecognized flag might change what gets built in a
way the key cannot see, treating it as harmless would be wrong.

The public surface is re-exported from `mtest.cache`.
"""

from mtest.cache.sha256 import Sha256

comptime KEY_FORMAT_TAG = "mtest-build-key-v1"
"""The domain-separation tag every `KeyBuilder` absorbs before anything else."""

comptime META_HEADER = "mtest-meta v1"
"""The first line of every rendered meta file."""

comptime _HEX_DIGITS = "0123456789abcdef"
"""Lowercase nibble alphabet; the meta format admits no uppercase."""

comptime _SECS_DECIMALS = 6
"""Fractional digits in the `secs` field — microsecond resolution."""

comptime _SECS_SCALE = 1000000
"""`10 ** _SECS_DECIMALS`, the fixed-point scale of the `secs` field."""

comptime _SECS_CEIL = 1000000000000000
"""Saturation point in microseconds (about 31 years), well inside Int64."""

comptime _SECS_MAX_WHOLE_DIGITS = 16
"""Whole-part digit cap on parse, keeping the accumulator inside Int64."""


def _digit(b: UInt8) -> Int:
    """Return the value of one ASCII decimal byte, or -1 if it is not one.

    Args:
        b: The candidate byte.

    Returns:
        `0`..`9`, or `-1` when `b` is not an ASCII digit.
    """
    if b >= 0x30 and b <= 0x39:
        return Int(b) - 0x30
    return -1


def _hex_nibble(b: UInt8) -> Int:
    """Return the value of one lowercase hex byte, or -1 if it is not one.

    Uppercase is deliberately rejected: `_hex_encode` only ever emits
    lowercase, so uppercase in a file on disk is a deviation like any other.

    Args:
        b: The candidate byte.

    Returns:
        `0`..`15`, or `-1` when `b` is not a lowercase hex digit.
    """
    if b >= 0x30 and b <= 0x39:
        return Int(b) - 0x30
    if b >= 0x61 and b <= 0x66:
        return Int(b) - 0x61 + 10
    return -1


def _hex_encode(text: String) -> String:
    """Render `text`'s bytes as two lowercase hex digits each.

    Args:
        text: The token to encode; any byte value is representable.

    Returns:
        A string of exactly `2 * text.byte_length()` lowercase hex digits.
    """
    var out = String("")
    for b in text.as_bytes():
        out += String(_HEX_DIGITS[byte=Int(b >> 4)])
        out += String(_HEX_DIGITS[byte=Int(b & 0xF)])
    return out^


def _hex_decode(hex_text: String) -> Optional[String]:
    """Decode lowercase hex back into a string, or `None` if it is not one.

    Rejects an odd digit count, any non-lowercase-hex digit, and bytes that do
    not form well-formed UTF-8. The last check matters because the encoder's
    input was a `String` and therefore valid UTF-8 by construction, so invalid
    UTF-8 on the way back is corruption.

    Args:
        hex_text: The candidate hex digits; empty decodes to the empty string.

    Returns:
        The decoded string, or `None` on any deviation.
    """
    var bytes = hex_text.as_bytes()
    if len(bytes) % 2 != 0:
        return None
    if len(bytes) == 0:
        return Optional[String](String(""))
    var raw = List[UInt8]()
    var i = 0
    while i < len(bytes):
        var hi = _hex_nibble(bytes[i])
        var lo = _hex_nibble(bytes[i + 1])
        if hi < 0 or lo < 0:
            return None
        raw.append(UInt8(hi * 16 + lo))
        i += 2
    var decoded: String
    try:
        decoded = String(StringSlice(from_utf8=Span(raw)))
    except:
        return None
    return Optional[String](decoded^)


def _is_hex64(text: String) -> Bool:
    """Whether `text` is exactly 64 lowercase hex digits.

    Args:
        text: The candidate digest field.

    Returns:
        True only for a full-length lowercase SHA-256 rendering.
    """
    var bytes = text.as_bytes()
    if len(bytes) != 64:
        return False
    for b in bytes:
        if _hex_nibble(b) < 0:
            return False
    return True


def _render_seconds(seconds: Float64) -> String:
    """Format a duration as fixed six-decimal seconds with no exponent.

    A negative or NaN input renders as zero and a pathologically large one
    saturates, so the field is always the same shape and `_parse_seconds`
    accepts everything this emits.

    Args:
        seconds: The wall-clock build duration.

    Returns:
        `"<whole>.<6 digits>"`, for example `"1.500000"`.
    """
    var micros: Int
    if not (seconds > 0.0):
        micros = 0
    else:
        var scaled = seconds * Float64(_SECS_SCALE)
        if scaled >= Float64(_SECS_CEIL):
            micros = _SECS_CEIL
        else:
            micros = Int(scaled + 0.5)
    var whole = micros // _SECS_SCALE
    var frac = micros % _SECS_SCALE
    var fs = String(frac)
    var out = String(whole) + "."
    for _ in range(_SECS_DECIMALS - fs.byte_length()):
        out += "0"
    out += fs
    return out^


def _parse_seconds(text: String) -> Optional[Float64]:
    """Parse exactly the fixed-point form `_render_seconds` emits.

    Deliberately narrow: one `.`, a whole part with no redundant leading zero
    and at most `_SECS_MAX_WHOLE_DIGITS` digits, and exactly
    `_SECS_DECIMALS` fractional digits. No sign, no exponent, no whitespace.
    Anything else is a deviation, and a deviation is a miss.

    Args:
        text: The candidate `secs` value.

    Returns:
        The duration in seconds, or `None` on any deviation.
    """
    var bytes = text.as_bytes()
    var dot = -1
    for i in range(len(bytes)):
        if bytes[i] == 0x2E:
            if dot >= 0:
                return None
            dot = i
    if dot <= 0 or dot > _SECS_MAX_WHOLE_DIGITS:
        return None
    if len(bytes) - dot - 1 != _SECS_DECIMALS:
        return None
    if dot > 1 and bytes[0] == 0x30:
        return None
    var whole = 0
    for i in range(dot):
        var d = _digit(bytes[i])
        if d < 0:
            return None
        whole = whole * 10 + d
    var frac = 0
    for i in range(dot + 1, len(bytes)):
        var d = _digit(bytes[i])
        if d < 0:
            return None
        frac = frac * 10 + d
    return Optional[Float64](
        Float64(whole) + Float64(frac) / Float64(_SECS_SCALE)
    )


def unsafe_tag_reason(tags: List[String]) -> String:
    """Why `tags` cannot frame a cache key safely, or empty when they can.

    The frame `feed` writes is injective over `(tag, payload)`, so no payload
    and no tag byte can forge a boundary. What framing cannot rule out is two
    call sites choosing the SAME tag spelling, and that is what these rules
    cover.

    `feed_file` feeds `tag`, `tag + ".size"` and `tag + ".sha"`, so a BASE tag
    already spelled `something.size` produces exactly the frame another tag's
    file contribution derives, and two different builds key alike — which
    serves a stale binary and reports a green run that never happened. Those
    two derived spellings are exactly what `feed` must keep accepting: the rule
    applies to the base tags a namespace declares, never to the frames
    `feed_file` builds out of them.

    An empty tag names nothing, and a tag carrying a `0x00` cannot be quoted
    into a diagnostic. Tags are source-level constants, so either one is a
    mistake in mtest's own source rather than anything a tree being keyed can
    cause.

    Neither method can refuse on its own: both are total by contract, as is
    every caller of theirs in the store's key path. The refusal therefore
    belongs to whoever owns the namespace, which reads this before feeding
    anything and switches its cache off.

    Args:
        tags: The base contribution names a namespace declares, in declaration
            order. Not mutated.

    Returns:
        A reason naming the offending tag, or an empty string when every tag is
        safe. The NUL and empty cases name the POSITION rather than the tag,
        because neither can be quoted into a diagnostic. Total; allocates only
        the returned string. Says nothing about uniqueness, which is a property
        of the set rather than of any tag and has no counterpart rule here.
    """
    for i in range(len(tags)):
        var tag = tags[i]
        if tag.byte_length() == 0:
            return "cache key tag " + String(i) + " is empty"
        for b in tag.as_bytes():
            if b == 0:
                return "cache key tag " + String(i) + " contains a NUL byte"
    for tag in tags:
        for suffix in [String(".size"), String(".sha")]:
            if tag.endswith(suffix):
                return (
                    "cache key tag '"
                    + tag
                    + "' ends in the reserved '"
                    + suffix
                    + "' suffix"
                )
    return String("")


def _append_u64le(mut frame: List[UInt8], value: UInt64):
    """Append `value` as eight little-endian bytes.

    Args:
        frame: The frame under construction; eight bytes are appended.
        value: The length being written.
    """
    for i in range(8):
        frame.append(UInt8((value >> UInt64(i * 8)) & 0xFF))


struct KeyBuilder(Copyable, Movable):
    """Accumulates unambiguously framed contributions into one cache key.

    Every `feed` writes the tag length, the tag bytes, the payload length, then
    the payload, each length as eight little-endian bytes. Both parts are
    delimited by a length that precedes them, so two different contribution
    sequences can never hash alike whatever the tags and payloads contain.

    Copies fork the running state, which is what lets a caller absorb a shared
    prefix once and then branch per file. Finalizing consumes the builder.

    Examples:

    ```mojo
    from mtest.cache import KeyBuilder, sha256_hex

    var base = KeyBuilder()
    base.feed_str("compiler", "/usr/bin/mojo")
    var per_file = base.copy()
    var sha_hex = sha256_hex(List[UInt8]())
    per_file.feed_file("src", "tests/a.mojo", 128, sha_hex)
    var name = per_file^.digest32()
    ```
    """

    var _hasher: Sha256
    """The running digest over the framed contribution stream."""

    def __init__(out self):
        """Start a builder that has already absorbed `KEY_FORMAT_TAG`.

        The format tag is fed as an ordinary empty-payload frame, so a key
        built by a future format revision can never equal one built by this
        revision even if every later contribution matches.
        """
        self._hasher = Sha256()
        self.feed(KEY_FORMAT_TAG, List[UInt8]())

    def feed(mut self, tag: String, payload: List[UInt8]):
        """Absorb one framed contribution.

        Args:
            tag: The contribution's name; any byte sequence frames
                unambiguously. Tags come from call sites, never from data, and
                the namespace that declares them keeps them distinct through
                `unsafe_tag_reason`.
            payload: The contribution's bytes; may be empty and may contain
                any byte value, including `0x00` and newlines.
        """
        var frame = List[UInt8]()
        var tag_bytes = tag.as_bytes()
        _append_u64le(frame, UInt64(len(tag_bytes)))
        for b in tag_bytes:
            frame.append(b)
        _append_u64le(frame, UInt64(len(payload)))
        for b in payload:
            frame.append(b)
        self._hasher.update(frame)

    def feed_str(mut self, tag: String, payload: String):
        """Absorb one framed contribution whose payload is text.

        Args:
            tag: The contribution's name; see `feed`.
            payload: The contribution's text, absorbed as its UTF-8 bytes.
        """
        var bytes = List[UInt8]()
        for b in payload.as_bytes():
            bytes.append(b)
        self.feed(tag, bytes)

    def feed_file(
        mut self, tag: String, path: String, size: Int, sha_hex: String
    ):
        """Absorb a file's identity as three frames: path, size, and digest.

        The size frame is redundant given the content digest and is fed anyway:
        it costs nothing and makes a truncated read visible in the key.

        Args:
            tag: The base contribution name; the size and digest frames are
                `tag + ".size"` and `tag + ".sha"`, so a base tag already
                wearing either suffix collides with another tag's. See
                `unsafe_tag_reason`.
            path: The file's path as the caller names it.
            size: The file's length in bytes.
            sha_hex: The file's content digest as hex.
        """
        self.feed_str(tag, path)
        self.feed_str(tag + ".size", String(size))
        self.feed_str(tag + ".sha", sha_hex)

    def digest32(deinit self) -> String:
        """Finalize and return the leading 32 hex digits of the key.

        Returns:
            A 32-character lowercase hex string, a true prefix of
            `digest_full()` over the same contributions.
        """
        return self._hasher^.hex_digest32()

    def digest_full(deinit self) -> String:
        """Finalize and return the whole key.

        Returns:
            A 64-character lowercase hex string.
        """
        return self._hasher^.hex_digest()


comptime ARG_FLAG = 0
"""A compiler switch with no filesystem meaning; the token(s) hash verbatim."""

comptime ARG_FILE_CANDIDATE = 1
"""A token naming a file the key must resolve and digest against run root."""

comptime ARG_INCLUDE_DIR = 2
"""A token naming a directory the key must resolve against run root."""

comptime ARG_UNKNOWN = 3
"""An argument the grammar does not recognize; the cache must not be trusted."""


@fieldwise_init
struct ArgClass(Copyable, Movable):
    """One classified build argument, ready for the cache context to fold into a key.

    Each instance is one LOGICAL argument: a two-token form like `-I <dir>` or
    `-Xlinker <tok>` collapses to a single row, so `classify_build_args` never
    returns more rows than it was given tokens.
    """

    var kind: Int
    """One of `ARG_FLAG`, `ARG_FILE_CANDIDATE`, `ARG_INCLUDE_DIR`,
    `ARG_UNKNOWN`."""

    var value: String
    """The row's payload: the flag's own spelling for `ARG_FLAG` (both
    tokens, space-joined, for a two-token flag), the bare path with any `-I`
    or `-Xlinker` prefix stripped for `ARG_FILE_CANDIDATE` /
    `ARG_INCLUDE_DIR`, or the offending token verbatim for `ARG_UNKNOWN`."""


def _is_known_bare_flag(token: String) -> Bool:
    """Whether `token` is a recognized single-token flag.

    Args:
        token: One argv element.

    Returns:
        True for known warning and optimization switches. Their exact spelling
        remains included in the digest.
    """
    return (
        token == "--Werror"
        or token == "--no-optimization"
        or token == "-O0"
        or token == "-O1"
        or token == "-O2"
        or token == "-O3"
    )


def classify_build_args(args: List[String]) -> List[ArgClass]:
    """Classify a build command line into rows a cache key can safely absorb.

    Walks `args` left to right with one token of lookahead for the two-token
    forms (`--debug-level <val>`, `-Xlinker <tok>`, `-I <dir>`), so every
    logical argument yields exactly one row and `len(result) <= len(args)`.
    Anything the grammar does not recognize classifies as `ARG_UNKNOWN`
    rather than being silently folded into a known kind: an unrecognized flag
    means the cache cannot prove the build is reproducible.

    Args:
        args: The build command line's tokens, in order.

    Returns:
        One `ArgClass` per logical argument, in the same order they appeared.

    Examples:

    ```mojo
    from mtest.cache import ARG_FLAG, ARG_FILE_CANDIDATE, classify_build_args

    var argv: List[String] = ["--no-optimization", "-Xlinker", "obj/a.o"]
    var rows = classify_build_args(argv)
    # rows[0].kind == ARG_FLAG, rows[0].value == "--no-optimization"
    # rows[1].kind == ARG_FILE_CANDIDATE, rows[1].value == "obj/a.o"
    ```
    """
    var result = List[ArgClass]()
    var n = len(args)
    var i = 0
    while i < n:
        var token = args[i]
        if _is_known_bare_flag(token):
            result.append(ArgClass(kind=ARG_FLAG, value=token))
            i += 1
        elif token == "--debug-level":
            if i + 1 < n:
                result.append(
                    ArgClass(kind=ARG_FLAG, value=token + " " + args[i + 1])
                )
                i += 2
            else:
                result.append(ArgClass(kind=ARG_UNKNOWN, value=token))
                i += 1
        elif token == "-Xlinker":
            if i + 1 < n:
                result.append(
                    ArgClass(kind=ARG_FILE_CANDIDATE, value=args[i + 1])
                )
                i += 2
            else:
                result.append(ArgClass(kind=ARG_UNKNOWN, value=token))
                i += 1
        elif token == "-I":
            if i + 1 < n:
                result.append(ArgClass(kind=ARG_INCLUDE_DIR, value=args[i + 1]))
                i += 2
            else:
                result.append(ArgClass(kind=ARG_UNKNOWN, value=token))
                i += 1
        elif token.startswith("-I") and token.byte_length() > 2:
            result.append(
                ArgClass(
                    kind=ARG_INCLUDE_DIR, value=String(token.removeprefix("-I"))
                )
            )
            i += 1
        else:
            result.append(ArgClass(kind=ARG_UNKNOWN, value=token))
            i += 1
    return result^


def generation_name(mangled: String, digest32: String) -> String:
    """Join a mangled test-file name to a key prefix into a generation name.

    The `_h` separator cannot be forged from the left: the name mangler escapes
    every literal `_`, so no mangled name contains `_h` and the split point is
    always the last one.

    Args:
        mangled: The mangled test-file stem.
        digest32: The 32-hex key prefix from `KeyBuilder.digest32`.

    Returns:
        `mangled + "_h" + digest32`.

    Examples:

    ```mojo
    from mtest.cache import generation_name

    var name = generation_name("tests_sa", "0123456789abcdef0123456789abcdef")
    # "tests_sa_h0123456789abcdef0123456789abcdef"
    ```
    """
    return mangled + "_h" + digest32


@fieldwise_init
struct MetaFile(Copyable, Movable):
    """The record written beside a cached binary and checked before reusing it.

    The rendered form is one line per field, terminated by `end`, with every
    argv token hex-encoded so a token containing a newline cannot break the
    line structure:

    ```text
    mtest-meta v1
    key <64 hex>
    bin <64 hex>
    secs <fixed 6-decimal>
    arg <hex>
    end
    ```

    `render` assumes the fields are well formed — the store fills them from real
    digests — while `parse` assumes nothing at all.

    Examples:

    ```mojo
    from mtest.cache import MetaFile

    var text = MetaFile(key, sha, 1.5, argv^).render()
    var parsed = MetaFile.parse(text)
    if not Bool(parsed):
        pass  # corrupt or truncated: treat the generation as a miss
    ```
    """

    var key_full: String
    """The full 64-hex cache key this generation was built for."""

    var bin_sha: String
    """The 64-hex content digest of the cached binary."""

    var build_seconds: Float64
    """Wall-clock seconds the original build took, to microsecond resolution."""

    var argv: List[String]
    """The exact build command line, one token per element."""

    def render(self) -> String:
        """Render the record as meta-file text.

        Returns:
            The full file contents, including the trailing newline after `end`.
        """
        var out = String(META_HEADER) + "\n"
        out += "key " + self.key_full + "\n"
        out += "bin " + self.bin_sha + "\n"
        out += "secs " + _render_seconds(self.build_seconds) + "\n"
        for token in self.argv:
            out += "arg " + _hex_encode(token) + "\n"
        out += "end\n"
        return out^

    @staticmethod
    def parse(text: String) -> Optional[MetaFile]:
        """Parse meta-file text, returning `None` on any deviation at all.

        Wrong version line, a missing or misplaced field, a digest that is not
        64 lowercase hex digits, an argv token that is not even-length
        lowercase hex or does not decode to UTF-8, a `secs` value outside the
        exact rendered shape, anything after `end`, or a missing `end` (which
        is what makes a truncated write detectable) all yield `None`. This
        never raises: the caller's only job is to rebuild.

        Args:
            text: Arbitrary text read from disk.

        Returns:
            The parsed record, or `None` if `text` is not exactly a rendering
            of one.
        """
        var lines = text.split("\n")
        # Header, key, bin, secs, end, and the empty tail after the final
        # newline: six elements even when argv is empty.
        if len(lines) < 6:
            return None
        if String(lines[0]) != String(META_HEADER):
            return None
        if String(lines[len(lines) - 1]).byte_length() != 0:
            return None
        var terminator = len(lines) - 2
        if String(lines[terminator]) != "end":
            return None

        var key_line = String(lines[1])
        if not key_line.startswith("key "):
            return None
        var key_full = String(key_line.removeprefix("key "))
        if not _is_hex64(key_full):
            return None

        var bin_line = String(lines[2])
        if not bin_line.startswith("bin "):
            return None
        var bin_sha = String(bin_line.removeprefix("bin "))
        if not _is_hex64(bin_sha):
            return None

        var secs_line = String(lines[3])
        if not secs_line.startswith("secs "):
            return None
        var seconds = _parse_seconds(String(secs_line.removeprefix("secs ")))
        if not Bool(seconds):
            return None

        var argv = List[String]()
        for i in range(4, terminator):
            var arg_line = String(lines[i])
            if not arg_line.startswith("arg "):
                return None
            var token = _hex_decode(String(arg_line.removeprefix("arg ")))
            if not Bool(token):
                return None
            argv.append(token.value().copy())

        return MetaFile(
            key_full=key_full^,
            bin_sha=bin_sha^,
            build_seconds=seconds.value(),
            argv=argv^,
        )
