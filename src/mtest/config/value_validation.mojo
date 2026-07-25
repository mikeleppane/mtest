"""Source-neutral validation of individual configuration values.

These helpers recognize value domains without owning CLI diagnostics or
cross-key policy. Callers attach source-specific error framing after a helper
reports that one value is invalid.
"""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


def parse_nonnegative_decimal(value: String) -> Optional[Int]:
    """Parse one non-negative ASCII decimal integer.

    An out-of-range value is rejected exactly like a non-decimal one. Letting
    the conversion raise instead sent a stdlib message — naming no flag, no
    expected form, and no help pointer — straight past every caller's
    diagnostic framing to the top level.

    Args:
        value: The candidate decimal spelling.

    Returns:
        The parsed integer, or `None` for an empty, non-decimal, or
        out-of-range value.
    """
    if value.byte_length() == 0:
        return Optional[Int](None)
    for cp in value.codepoints():
        var digit = Int(cp)
        if digit < 48 or digit > 57:
            return Optional[Int](None)
    try:
        return Optional[Int](atol(value))
    except:
        return Optional[Int](None)


def parse_worker_count(value: String) -> Optional[Int]:
    """Parse `auto` or a positive decimal worker count.

    Args:
        value: The candidate worker-count spelling.

    Returns:
        `0` for `auto`, a positive count, or `None` when invalid, which
        includes an out-of-range decimal.
    """
    if value == "auto":
        return Optional[Int](0)
    var parsed = parse_nonnegative_decimal(value)
    if not parsed or parsed.value() < 1:
        return Optional[Int](None)
    return parsed


def parse_show_output_value(value: String) -> Optional[ShowOutput]:
    """Parse one captured-output rendering mode.

    Args:
        value: The candidate `failures`, `all`, or `none` spelling.

    Returns:
        The typed mode, or `None` when invalid.
    """
    if value == "failures":
        return Optional[ShowOutput](ShowOutput.FAILURES)
    if value == "all":
        return Optional[ShowOutput](ShowOutput.ALL)
    if value == "none":
        return Optional[ShowOutput](ShowOutput.NONE)
    return Optional[ShowOutput](None)


def parse_annotations_value(value: String) -> Optional[AnnotationsMode]:
    """Parse one GitHub annotations mode.

    Args:
        value: The candidate `off`, `on`, or `auto` spelling.

    Returns:
        The typed mode, or `None` when invalid.
    """
    if value == "off":
        return Optional[AnnotationsMode](AnnotationsMode.OFF)
    if value == "on":
        return Optional[AnnotationsMode](AnnotationsMode.ON)
    if value == "auto":
        return Optional[AnnotationsMode](AnnotationsMode.AUTO)
    return Optional[AnnotationsMode](None)


def parse_color_value(value: String) -> Optional[ColorWhen]:
    """Parse one color mode.

    Args:
        value: The candidate `auto`, `always`, or `never` spelling.

    Returns:
        The typed mode, or `None` when invalid.
    """
    if value == "auto":
        return Optional[ColorWhen](ColorWhen.AUTO)
    if value == "always":
        return Optional[ColorWhen](ColorWhen.ALWAYS)
    if value == "never":
        return Optional[ColorWhen](ColorWhen.NEVER)
    return Optional[ColorWhen](None)


def parse_verbosity_value(value: String) -> Optional[Verbosity]:
    """Parse one file-config verbosity level.

    Args:
        value: The candidate `quiet`, `normal`, or `verbose` spelling.

    Returns:
        The typed level, or `None` when invalid.
    """
    if value == "quiet":
        return Optional[Verbosity](Verbosity.QUIET)
    if value == "normal":
        return Optional[Verbosity](Verbosity.NORMAL)
    if value == "verbose":
        return Optional[Verbosity](Verbosity.VERBOSE)
    return Optional[Verbosity](None)


def parse_precompile_value(value: String) -> Optional[Precompile]:
    """Parse one `SRC[:OUT]` precompile value.

    Args:
        value: The candidate precompile spelling.

    Returns:
        The typed entry, or `None` when either required part is empty.
    """
    var colon = value.find(":")
    if colon == -1:
        if value.byte_length() == 0:
            return Optional[Precompile](None)
        return Optional[Precompile](
            Precompile(src=value, out=Optional[String](None))
        )
    var parts = value.split(":", 1)
    var src = String(parts[0])
    var out = String(parts[1])
    if src.byte_length() == 0 or out.byte_length() == 0:
        return Optional[Precompile](None)
    return Optional[Precompile](
        Precompile(src=src^, out=Optional[String](out^))
    )


def build_arg_rejection(token: String) -> Optional[String]:
    """Describe why one build argument violates runner ownership.

    Args:
        token: One candidate compiler argument or positional value.

    Returns:
        A source-neutral rejection body, or `None` when allowed.
    """
    if token == "-o" or token.startswith("-o="):
        return Optional[String](
            "forbidden build argument '"
            + token
            + "': mtest owns output selection"
        )
    if token == "--emit" or token.startswith("--emit="):
        return Optional[String](
            "forbidden build argument '"
            + token
            + "': mtest owns emit-type selection"
        )
    if (
        token == "-j"
        or token.startswith("-j=")
        or token == "--num-threads"
        or token.startswith("--num-threads=")
    ):
        return Optional[String](
            "forbidden build argument '"
            + token
            + "': mtest owns build parallelism (set the worker count with"
            " -n/--workers)"
        )
    if not token.startswith("-") and (
        token.endswith(".mojo") or token.endswith(".🔥")
    ):
        return Optional[String](
            "forbidden build argument '"
            + token
            + "': mtest owns the source list"
        )
    return Optional[String](None)


def safe_path_label(path: String) -> String:
    """Render a user-supplied path safely inside a one-line diagnostic.

    Control characters are escaped so a crafted path cannot emit a terminal
    escape sequence or split one diagnostic into two, and the result is
    truncated so a very long path cannot bury the message. Shared by every
    layer that names a path back to the user, so the escaping cannot hold on
    one path and be forgotten on another.

    Args:
        path: The user-supplied path to label.

    Returns:
        A newly allocated single-line label of at most 240 codepoints.
    """
    var escaped = String("")
    comptime HEX = "0123456789abcdef"
    for cp in path.codepoints():
        var value = Int(cp)
        if value == 10:
            escaped += "\\n"
        elif value == 13:
            escaped += "\\r"
        elif value == 9:
            escaped += "\\t"
        elif (value >= 0 and value < 32) or value == 127:
            escaped += "\\x"
            escaped += String(HEX[byte=value // 16])
            escaped += String(HEX[byte=value % 16])
        else:
            escaped += String(cp)
    if escaped.count_codepoints() <= 240:
        return escaped
    var shortened = String("")
    var count = 0
    for cp in escaped.codepoint_slices():
        if count == 237:
            break
        shortened += String(cp)
        count += 1
    return shortened + "..."
