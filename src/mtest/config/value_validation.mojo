"""Source-neutral validation of individual configuration values.

These helpers recognize value domains without owning CLI diagnostics or
cross-key policy. Callers attach source-specific error framing after a helper
reports that one value is invalid.
"""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.show_output import ShowOutput


def parse_nonnegative_decimal(value: String) raises -> Optional[Int]:
    """Parse one non-negative ASCII decimal integer.

    Args:
        value: The candidate decimal spelling.

    Returns:
        The parsed integer, or `None` for an empty or non-decimal value.

    Raises:
        Error: If a digit-only value is outside the platform `Int` range.
    """
    if value.byte_length() == 0:
        return Optional[Int](None)
    for cp in value.codepoints():
        var digit = Int(cp)
        if digit < 48 or digit > 57:
            return Optional[Int](None)
    return Optional[Int](atol(value))


def parse_worker_count(value: String) raises -> Optional[Int]:
    """Parse `auto` or a positive decimal worker count.

    Args:
        value: The candidate worker-count spelling.

    Returns:
        `0` for `auto`, a positive count, or `None` when invalid.

    Raises:
        Error: If a digit-only value is outside the platform `Int` range.
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
