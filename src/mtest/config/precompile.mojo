"""One `--precompile SRC[:OUT]` entry (Layer 1).

`--precompile` is repeatable; each occurrence names a source to precompile and
an optional output name. This module holds only the data shape — parsing
`SRC[:OUT]` into the two parts is the parser's concern.
"""


@fieldwise_init
struct Precompile(Copyable, Movable):
    """One `--precompile` entry: a source path and an optional output name.

    Owns its string fields, so copies are explicit; reads do not mutate or
    raise.
    """

    var src: String
    """The source path to precompile."""

    var out: Optional[String]
    """The output name, if `:OUT` was given; `None` otherwise."""
