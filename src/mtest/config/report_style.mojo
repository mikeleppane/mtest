"""The run-report detail vocabulary.

Controls how much of a run the `--report` document carries: `concise` gives
every file a summary row and reserves a per-file section for the files that
need a second look, while `full` gives every file both. It names a document
choice rather than a run outcome, which is why it lives in config and not in
model — and it is deliberately separate from `Verbosity`, which shapes the
live console instead of the written report.
"""


@fieldwise_init
struct ReportStyle(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--report-style` closed vocabulary.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value.

    Examples:

    ```mojo
    from mtest.config import ReportStyle, RunnerConfig

    var config = RunnerConfig.default()
    config.report_style = ReportStyle.FULL
    ```
    """

    var value: Int
    """The stable integer discriminant identifying this style."""

    comptime CONCISE = Self(0)
    """Summary rows for every file; a section only where one is warranted."""
    comptime FULL = Self(1)
    """Summary rows and a per-file section for every file."""

    def __eq__(self, other: Self) -> Bool:
        """Whether both styles carry the same discriminant."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the two styles carry different discriminants."""
        return self.value != other.value
