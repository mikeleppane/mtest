"""The `--gh-annotations` vocabulary.

Controls whether the runner emits GitHub Actions annotation workflow-command
lines: never (`off`), always (`on`), or automatically (`auto`, on only when the
run is inside GitHub Actions). Probing the environment belongs to `main`;
resolving a mode plus that probe into "annotations on or off" happens here, as
a function of its inputs alone.
"""


@fieldwise_init
struct AnnotationsMode(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--gh-annotations` closed vocabulary.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value.
    """

    var value: Int
    """The stable integer discriminant identifying this choice."""

    comptime OFF = Self(0)
    comptime ON = Self(1)
    comptime AUTO = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Whether both choices carry the same discriminant."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the two choices carry different discriminants."""
        return self.value != other.value


def annotations_resolved_on(
    mode: AnnotationsMode, github_actions: Bool
) -> Bool:
    """Whether annotations render, from the mode and the GitHub-Actions probe.

    Args:
        mode: The resolved `--gh-annotations` choice. `off` never renders, `on`
            always renders, and `auto` defers to `github_actions`.
        github_actions: Whether the run is inside GitHub Actions, which `main`
            derives from `GITHUB_ACTIONS=true`.

    Returns:
        True when the annotation tail should render.
    """
    if mode == AnnotationsMode.OFF:
        return False
    if mode == AnnotationsMode.ON:
        return True
    return github_actions
