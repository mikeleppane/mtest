"""The `--gh-annotations` vocabulary of the mtest runner (Layer 1).

Controls whether the runner emits GitHub Actions annotation workflow-command
lines: never (`off`), always (`on`), or automatically (`auto`, on iff the run is
inside GitHub Actions). The environment probe itself belongs to `main`; the pure
resolution of a mode plus that probe's boolean into "annotations on/off" lives
here so it is table-testable without touching the environment.
"""


@fieldwise_init
struct AnnotationsMode(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--gh-annotations` closed vocabulary.

    A thin wrapper over a stable integer discriminant so the vocabulary is a
    closed set of named constants that compare by value. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var value: Int
    """The stable integer discriminant identifying this choice."""

    comptime OFF = Self(0)
    comptime ON = Self(1)
    comptime AUTO = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Two choices are equal iff their discriminants match. Pure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.value != other.value


def annotations_resolved_on(
    mode: AnnotationsMode, github_actions: Bool
) -> Bool:
    """Whether annotations render, from the mode and the GitHub-Actions probe.

    `off` is never on; `on` is always on; `auto` is on IFF `github_actions`
    (which `main` derives from `GITHUB_ACTIONS=true`). Pure; total; never raises.

    Args:
        mode: The resolved `--gh-annotations` choice.
        github_actions: Whether the run is inside GitHub Actions
            (`GITHUB_ACTIONS=true`), probed by `main`.

    Returns:
        True iff the annotation tail should render.
    """
    if mode == AnnotationsMode.OFF:
        return False
    if mode == AnnotationsMode.ON:
        return True
    return github_actions
