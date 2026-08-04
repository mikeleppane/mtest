"""Source-neutral validation of individual configuration values.

These helpers recognize value domains without owning CLI diagnostics or
cross-key policy. Callers attach source-specific error framing after a helper
reports that one value is invalid.

Every closed vocabulary is published as a `*_choices()` list, and the matching
`parse_*_value` decides acceptance by membership in that same list. One list per
vocabulary is the point: a caller that offers the list — a help renderer, a
shell-completion renderer — offers exactly what the parser accepts, and the two
cannot drift apart because there is nothing to drift from. Each list is ordered
by discriminant, so position `i` is the vocabulary's `i`-th typed value; that
ordering is what lets membership and mapping be one lookup rather than two
tables to keep in sync.

`parse_verbosity_value` is the one named exemption: verbosity is an
`mtest.toml`-only key with no flag spelling, so nothing completes it and it
keeps its own branches.
"""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.report_style import ReportStyle
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


def parse_nonnegative_decimal(value: String) -> Optional[Int]:
    """Parse one non-negative ASCII decimal integer.

    An out-of-range value is rejected exactly like a non-decimal one. Letting
    the conversion raise instead would send a stdlib message straight past
    every caller's diagnostic framing to the top level, naming no flag, no
    expected form, and no help pointer.

    The post-conversion sign check is load-bearing, not belt-and-braces:
    `atol` does not raise across the whole out-of-range domain — at exactly
    `2^63` and `2^63 + 1` it WRAPS to `Int.MIN` and `Int.MIN + 1`. The digit
    screen above has already excluded a `-`, so a wrapped result would
    otherwise be indistinguishable from a legitimate parse and would reach
    callers that all treat it as non-negative (silently disabling `--timeout`,
    defeating `--maxfail`, corrupting `--retries`/`--durations`).

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
        var parsed = atol(value)
        if parsed < 0:  # `atol` wrapped instead of raising: out of range.
            return Optional[Int](None)
        return Optional[Int](parsed)
    except:
        return Optional[Int](None)


def _choice_index(value: String, choices: List[String]) -> Int:
    """The position of `value` in `choices`, or `-1` when it is absent.

    The one membership test every closed vocabulary here is decided by, so a
    published list and its parser can never disagree about what is legal.

    Args:
        value: The candidate spelling, compared byte-for-byte and
            case-sensitively.
        choices: The closed list, ordered by discriminant.

    Returns:
        The matching position, or `-1` when the value is outside the list.
    """
    for i in range(len(choices)):
        if choices[i] == value:
            return i
    return -1


def workers_choices() -> List[String]:
    """The closed arm of the `-n`/`--workers` value domain.

    `auto` is the whole closed arm; every other accepted value is a positive
    decimal integer, which is free text and cannot be enumerated. A completion
    renderer offers this list and nothing else.

    Returns:
        A freshly allocated list holding the closed spellings.
    """
    return ["auto"]


def parse_worker_count(value: String) -> Optional[Int]:
    """Parse `auto` or a positive decimal worker count.

    Args:
        value: The candidate worker-count spelling.

    Returns:
        `0` for `auto`, a positive count, or `None` when invalid, which
        includes an out-of-range decimal.

    Examples:

    ```mojo
    from mtest.config import parse_worker_count

    var explicit = parse_worker_count("4")
    # `auto` resolves to the `0` sentinel, not to a core count.
    var automatic = parse_worker_count("auto")
    ```
    """
    if _choice_index(value, workers_choices()) >= 0:
        return Optional[Int](0)
    var parsed = parse_nonnegative_decimal(value)
    if not parsed or parsed.value() < 1:
        return Optional[Int](None)
    return parsed


def show_output_choices() -> List[String]:
    """The closed `--show-output` vocabulary, ordered by discriminant.

    Position `i` is `ShowOutput(i)`, which is what makes this list both the
    accepted set and the mapping into the typed vocabulary.

    Returns:
        A freshly allocated list holding every accepted spelling.
    """
    return ["failures", "all", "none"]


def parse_show_output_value(value: String) -> Optional[ShowOutput]:
    """Parse one captured-output rendering mode.

    Args:
        value: The candidate `failures`, `all`, or `none` spelling.

    Returns:
        The typed mode, or `None` when invalid.
    """
    var index = _choice_index(value, show_output_choices())
    if index < 0:
        return Optional[ShowOutput](None)
    return Optional[ShowOutput](ShowOutput(index))


def annotations_choices() -> List[String]:
    """The closed `--gh-annotations` vocabulary, ordered by discriminant.

    Position `i` is `AnnotationsMode(i)`.

    Returns:
        A freshly allocated list holding every accepted spelling.
    """
    return ["off", "on", "auto"]


def parse_annotations_value(value: String) -> Optional[AnnotationsMode]:
    """Parse one GitHub annotations mode.

    Args:
        value: The candidate `off`, `on`, or `auto` spelling.

    Returns:
        The typed mode, or `None` when invalid.
    """
    var index = _choice_index(value, annotations_choices())
    if index < 0:
        return Optional[AnnotationsMode](None)
    return Optional[AnnotationsMode](AnnotationsMode(index))


def color_choices() -> List[String]:
    """The closed `--color` vocabulary, ordered by discriminant.

    Position `i` is `ColorWhen(i)`.

    Returns:
        A freshly allocated list holding every accepted spelling.
    """
    return ["auto", "always", "never"]


def parse_color_value(value: String) -> Optional[ColorWhen]:
    """Parse one color mode.

    Args:
        value: The candidate `auto`, `always`, or `never` spelling.

    Returns:
        The typed mode, or `None` when invalid.
    """
    var index = _choice_index(value, color_choices())
    if index < 0:
        return Optional[ColorWhen](None)
    return Optional[ColorWhen](ColorWhen(index))


def collect_format_choices() -> List[String]:
    """The closed `--format` vocabulary for the collect listing.

    Ordered so that position `1` is the NDJSON stream, which is what
    `parse_collect_format_value` returns `True` for.

    Returns:
        A freshly allocated list holding every accepted spelling.
    """
    return ["lines", "json"]


def parse_collect_format_value(value: String) -> Optional[Bool]:
    """Parse one collect output format into "render the collect stream".

    The domain lives here rather than in the parser so the accepted set and
    the completion list are the same list. The caller owns the refusal text,
    because nothing in this module raises.

    Args:
        value: The candidate `lines` or `json` spelling.

    Returns:
        `True` for `json`, `False` for `lines`, or `None` when invalid, an
        empty value included.
    """
    var index = _choice_index(value, collect_format_choices())
    if index < 0:
        return Optional[Bool](None)
    return Optional[Bool](index == 1)


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


def report_style_choices() -> List[String]:
    """The closed `--report-style` vocabulary, ordered by discriminant.

    Position `i` is `ReportStyle(i)`.

    Returns:
        A freshly allocated list holding every accepted spelling.
    """
    return ["concise", "full"]


def parse_report_style_value(value: String) -> Optional[ReportStyle]:
    """Parse one run-report detail style.

    Args:
        value: The candidate `concise` or `full` spelling.

    Returns:
        The typed style, or `None` when invalid.
    """
    var index = _choice_index(value, report_style_choices())
    if index < 0:
        return Optional[ReportStyle](None)
    return Optional[ReportStyle](ReportStyle(index))


@fieldwise_init
struct ReportValue(Copyable, Movable):
    """A parsed --report value: which format, where to write it."""

    var format: String
    """"md" or "html"."""
    var path: String
    """The destination path, non-empty."""


def report_format_prefixes() -> List[String]:
    """The closed `--report` value prefixes, separator included.

    A `--report` value is one of these prefixes followed by a free filesystem
    path, so the prefixes carry their `:` — that is exactly the token a
    completion renderer offers before it hands over to path completion, and
    exactly what `parse_report_value` matches on.

    Returns:
        A freshly allocated list holding every accepted prefix.
    """
    return ["md:", "html:"]


def parse_report_value(value: String) -> Optional[ReportValue]:
    """Parse one `FORMAT:PATH` report destination.

    Args:
        value: The candidate `--report` value.

    Returns:
        The typed destination, or `None` for an empty path, a missing
        separator, or a prefix outside `report_format_prefixes()`.
    """
    var sep = value.find(":")
    if sep <= 0 or sep == value.byte_length() - 1:
        return Optional[ReportValue](None)
    if (
        _choice_index(String(value[byte = : sep + 1]), report_format_prefixes())
        < 0
    ):
        return Optional[ReportValue](None)
    return Optional[ReportValue](
        ReportValue(
            format=String(value[byte=:sep]),
            path=String(value[byte = sep + 1 :]),
        )
    )


def parse_precompile_value(value: String) -> Optional[Precompile]:
    """Parse one `SRC[:OUT]` precompile value.

    Args:
        value: The candidate precompile spelling.

    Returns:
        The typed entry, or `None` when either required part is empty.

    Examples:

    ```mojo
    from mtest.config import parse_precompile_value

    # No `:OUT`, so `out` is None.
    var src_only = parse_precompile_value("tests/helper.mojo")
    var named = parse_precompile_value("tests/helper.mojo:helper")
    ```
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


def escape_control_characters(path: String) -> String:
    """Render a user-supplied path as one line, escaping nothing else.

    Control characters become their printable escapes so a crafted path cannot
    emit a terminal escape sequence or split one line into two. Nothing is
    truncated, which is what separates this from `safe_path_label`: output
    whose format is frozen — a path a caller is meant to read back — must
    survive whole, while a diagnostic may be shortened so the path cannot bury
    the message.

    Args:
        path: The user-supplied path to render.

    Returns:
        A newly allocated single-line rendering of the complete path.
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
    return escaped^


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
    var escaped = escape_control_characters(path)
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
