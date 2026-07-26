"""One `--precompile SRC[:OUT]` entry.

`--precompile` is repeatable; each occurrence names a source to precompile and
an optional output name. This module holds the data shape; the config layer's
source-neutral validator splits `SRC[:OUT]` into the two parts.
"""


@fieldwise_init
struct Precompile(Copyable, Movable):
    """One `--precompile` entry: a source path and an optional output name.

    Owns its string fields, so every copy is an explicit `.copy()`.

    Examples:

    ```mojo
    from mtest.config import Precompile

    var src_only = Precompile(src="tests/helper.mojo", out=Optional[String](None))
    var named = Precompile(
        src="tests/helper.mojo", out=Optional[String]("helper")
    )
    ```
    """

    var src: String
    """The source path to precompile."""

    var out: Optional[String]
    """The output name, if `:OUT` was given; `None` otherwise."""
