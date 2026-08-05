"""The report destinations one invocation will write, and their refusals.

Layer 5 owns this because a destination is named back to the reader the way the
layer that set it spells it: a `--json` flag or a `[report] json` key. Both the
run path and `doctor` ask the same three questions — which destinations are
active, does one of them name a directory that is not there, and do two of them
name one file — so the answers live once, here.

Nothing in this module prints, exits, or opens a destination. It reads the
filesystem only to answer those questions: `isdir` for a parent, and the
identity and case-folding probes two spellings of one file are compared on.
"""
from std.os.path import dirname, isdir

from mtest.cli.flag_spec import FlagId, flag_specs
from mtest.config import Provenance, ResolvedConfig, safe_path_label
from mtest.platform import (
    case_folded_identity,
    destination_identity,
    directory_ignores_case,
)


@fieldwise_init
struct Destination(Copyable, Movable):
    """One active file destination, ready to be checked against its siblings."""

    var label: String
    """The destination named the way its own layer spells it."""

    var format: String
    """The `[report]` key this destination is configured under."""

    var path: String
    """The destination as its own layer spelled it."""

    var parent: String
    """The lexical parent directory of `path`, empty for a bare filename."""

    var key: String
    """The `destination_identity` key two spellings of one file share."""


struct _CaseVerdicts(Movable):
    """One case-sensitivity answer per resolved directory, asked once each.

    The probe creates and unlinks a file, so asking it once per DESTINATION
    would touch a caller's output directory up to four times to learn one thing
    about it. Two destinations resolving into one directory also have to be
    given the same answer, which a cache makes structural rather than
    incidental.
    """

    var parents: List[String]
    """The resolved parent directories already probed, in arrival order."""

    var ignores_case: List[Bool]
    """Parallel to `parents`: what the probe answered for each."""

    def __init__(out self):
        """A cache that has probed nothing yet."""
        self.parents = List[String]()
        self.ignores_case = List[Bool]()

    def ask(mut self, parent: String) -> Bool:
        """The verdict for `parent`, probing the filesystem at most once."""
        for i in range(len(self.parents)):
            if self.parents[i] == parent:
                return self.ignores_case[i]
        var verdict = directory_ignores_case(parent)
        self.parents.append(parent)
        self.ignores_case.append(verdict)
        return verdict


def _flag_spelling(flag_id: Int) -> String:
    """The long spelling `flag_specs()` records for one flag identity.

    Read off the table rather than rebuilt from the `mtest.toml` key, so a
    diagnostic can never name a flag the parser does not accept.

    Args:
        flag_id: One of the `FlagId` integer constants.

    Returns:
        The `--`-prefixed spelling, or `--invalid` for an identity no row
        carries, which the inventory tests reject before release.
    """
    for spec in flag_specs():
        if spec.id == flag_id and spec.spelling.startswith("--"):
            return spec.spelling.copy()
    return "--invalid"


def _origin_label(
    resolved: ResolvedConfig,
    source: Provenance,
    format: String,
    flag_id: Int,
) -> String:
    """Name a resolved destination the way its own layer spells it.

    A diagnostic that says `cli: '--json'` for a value the project file set
    names a remedy the reader cannot apply: there is no such flag on their
    command line. Key off the provenance the resolver already tracked, and
    read the flag table only on the branch that needs a spelling.

    Args:
        resolved: The layered configuration carrying provenance and the file.
        source: The winning layer for this destination.
        format: The `[report]` key holding the destination.
        flag_id: The `FlagId` whose spelling writes the same destination.

    Returns:
        A complete diagnostic prefix ending in the offending value's name.
    """
    if source == Provenance.MTEST_TOML:
        var origin = resolved.config_file
        if origin == "":
            origin = String("mtest.toml")
        return "config: " + origin + ": [report] " + format
    var spelling = _flag_spelling(flag_id)
    if flag_id == FlagId.REPORT:
        # `--report` takes `FORMAT:PATH`, so the format is part of the remedy.
        spelling += " " + format + ":"
    return "cli: '" + spelling + "'"


def _append(
    mut destinations: List[Destination],
    resolved: ResolvedConfig,
    active: Bool,
    path: String,
    source: Provenance,
    format: String,
    flag_id: Int,
):
    """Record one destination, unless the command or the config leaves it out.

    The label is built after the early return, so an invocation that
    configures no destination never reads the flag table.

    Args:
        destinations: The list being built. Appended to.
        resolved: The layered configuration, for the provenance label.
        active: Whether this key belongs to the command's projection.
        path: The resolved destination, empty when there is none.
        source: The winning layer for this destination.
        format: The `[report]` key holding it.
        flag_id: The `FlagId` whose spelling writes the same destination.
    """
    if not active or path == "":
        return
    destinations.append(
        Destination(
            _origin_label(resolved, source, format, flag_id),
            format,
            path,
            String(dirname(path)),
            destination_identity(path),
        )
    )


def active_destinations(resolved: ResolvedConfig) -> List[Destination]:
    """Every active destination this run will open, keyed for comparison.

    `--json -` is deliberately absent: it names the inherited stdout stream,
    which has no filesystem identity to collide with and no parent directory to
    create. Every other configured destination is a real path that will be
    created or renamed onto.

    Every folded key starts empty. Filling one asks the filesystem a question,
    which `destination_collision` only does when there are at least two
    destinations for the answer to decide anything between.

    Args:
        resolved: The layered configuration, after the command projection was
            applied. Not mutated.

    Returns:
        A freshly allocated list in a fixed order, so the diagnostic for one
        collision is the same whichever run produced it.
    """
    var json_path = resolved.config.json_dest.copy()
    if json_path == "-":
        json_path = String("")
    var destinations = List[Destination]()
    _append(
        destinations,
        resolved,
        resolved.active_keys.json_dest,
        json_path,
        resolved.provenance.json_dest,
        "json",
        FlagId.JSON,
    )
    _append(
        destinations,
        resolved,
        resolved.active_keys.junit_dest,
        resolved.config.junit_dest,
        resolved.provenance.junit_dest,
        "junit-xml",
        FlagId.JUNIT_XML,
    )
    _append(
        destinations,
        resolved,
        resolved.active_keys.report_md_dest,
        resolved.config.report_md_dest,
        resolved.provenance.report_md_dest,
        "md",
        FlagId.REPORT,
    )
    _append(
        destinations,
        resolved,
        resolved.active_keys.report_html_dest,
        resolved.config.report_html_dest,
        resolved.provenance.report_html_dest,
        "html",
        FlagId.REPORT,
    )
    return destinations^


def destination_parent_error(
    destinations: List[Destination],
) -> Optional[String]:
    """Refuse an active destination whose parent directory does not exist.

    Every active file destination is checked, not only the ones a flag can
    spell. `--report FORMAT:PATH` is validated as the parser reads it, so a
    command-line value with a missing parent never reaches here — but a
    `[report]` destination that came from the project file has no parser of its
    own, and without this check it would sail past resolved validation into the
    session's temp creation and surface as an internal error, exit 3, where a
    pre-run usage error, exit 4, is promised. Its two sibling keys in the same
    table already give 4, so the gap was also an inconsistency between two
    halves of one feature.

    Relative parents resolve against the working directory, which is the
    invocation root the run path already acquired.

    Args:
        destinations: The active destinations, in their fixed order. Not
            mutated.

    Returns:
        A complete usage diagnostic naming the offending value the way its own
        layer spells it, or none when every parent directory is there.
    """
    for i in range(len(destinations)):
        var parent = destinations[i].parent
        if parent != "" and not isdir(parent):
            return Optional[String](
                destinations[i].label
                + " destination parent directory does not exist: '"
                + safe_path_label(parent)
                + "' (see mtest --help)"
            )
    return Optional[String](None)


def destination_collision(
    destinations: List[Destination],
) -> Optional[String]:
    """Refuse two active destinations that name one file.

    Two reporters writing one path is not a composition: each one truncates or
    renames over the other's work, and which of them survives depends on
    finalization order rather than on anything the caller asked for. The
    comparison is by resolved identity rather than by spelling, so `out.md` and
    `./out.md` are caught as the one file they are.

    Identity alone is not enough where the volume ignores case. `Run.out` and
    `run.out` are two files on Linux and one file on APFS — the default on a
    supported platform — so a spelling-only comparison would let that pair
    through, publish both documents onto one inode, and exit 0 with one
    requested artifact missing. Where a destination's own directory was
    observed to fold case, its folded key is compared too; where it was not,
    that key stays empty and nothing extra can match.

    Run-path only. `config show` resolves without touching the filesystem and
    renders a collision with both provenances instead, so the two commands are
    deliberately different here.

    Args:
        destinations: The active destinations, in their fixed order. Not
            mutated.

    Returns:
        A complete usage diagnostic naming both offending values, or none.
    """
    if len(destinations) < 2:
        return Optional[String](None)
    # Asked here rather than while the list is built: one destination can
    # collide with nothing, so a run with a single `--junit-xml` never touches
    # its output directory to learn something it cannot use.
    var folded = List[String]()
    var verdicts = _CaseVerdicts()
    for i in range(len(destinations)):
        if verdicts.ask(String(dirname(destinations[i].key))):
            folded.append(case_folded_identity(destinations[i].key))
        else:
            folded.append(String(""))
    for i in range(len(destinations)):
        for j in range(i + 1, len(destinations)):
            var same_key = destinations[i].key == destinations[j].key
            var same_folded = folded[i] != "" and folded[i] == folded[j]
            if same_key or same_folded:
                return Optional[String](
                    destinations[i].label
                    + " and "
                    + destinations[j].label
                    + " name the same destination '"
                    + safe_path_label(destinations[j].key)
                    + "'; each report needs its own path"
                    + " (see mtest --help)"
                )
    return Optional[String](None)
