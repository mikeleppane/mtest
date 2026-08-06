"""The artifact store's two-phase seam, shared by all three build drivers.

Layer 4, above `store` and below every driver that compiles a test file: the
selection/collect build (`build.mojo`), the sequential attempt loop
(`attempt.mojo`), and the parallel pool (`pool.mojo`). All three ask the store
the same three questions in the same order — key this file, is a build already
stored for it, and where does a fresh compile write so publishing is one rename
— and then settle the staged directory once the compiler has spoken.

The seam is two-phase because the pool's two ends are far apart. It probes every
file in its seeding loop and publishes in its completion handler, many scheduler
iterations later, with the staging parked in that file's slot. `seam_begin` and
`seam_stage` open the seam, `seam_settle` or `seam_discard` closes it, and
closing it consumes the staging so no file can publish twice.
"""
from mtest.session.store import (
    CacheContext,
    FileKey,
    PROBE_HIT,
    PUB_FAILED,
    StoreBuildTarget,
    file_key,
    remove_tree_no_follow,
    store_build_target,
    store_probe,
    store_publish,
)


@fieldwise_init
struct SeamStaging(Copyable, Movable):
    """What one file owes the store between its probe and its publication."""

    var key: Optional[FileKey]
    """This file's store key while a publication is still owed, else nothing."""
    var target: StoreBuildTarget
    """The staging directory this file's first build writes into."""
    var hit: Bool
    """Whether the probe served a stored build, so nothing needs compiling."""
    var bin_rel: String
    """The stored binary to run, when `hit`."""
    var argv: List[String]
    """The stored build's recorded command line, when `hit`."""
    var build_seconds: Float64
    """What the stored build originally cost, when `hit`.

    Carried so the SLOW token reads the same on a warm run as on the cold one.
    """

    @staticmethod
    def none() -> Self:
        """A staging that owes the store nothing and served nothing."""
        return Self(
            Optional[FileKey](None),
            StoreBuildTarget(String(""), String("")),
            False,
            String(""),
            List[String](),
            0.0,
        )

    def take(mut self) -> Self:
        """Detach what is owed, leaving this slot owing nothing.

        The pool keeps its staging inside a per-file state array, where a
        transfer out of the slot is not expressible, so it detaches here
        instead. The slot is left empty, which is what makes a second settle or
        discard of the same file a no-op however the scheduler is later
        reshaped.

        Returns:
            The detached staging. Allocates a copy of the carried argv.
        """
        var detached = Self(
            self.key.copy(),
            self.target.copy(),
            self.hit,
            self.bin_rel,
            self.argv.copy(),
            self.build_seconds,
        )
        self.key = Optional[FileKey](None)
        self.target = StoreBuildTarget(String(""), String(""))
        return detached^


@fieldwise_init
struct SeamOutcome(Copyable, Movable):
    """What publishing one staged build left the driver to run and record."""

    var settled: Bool
    """Whether a publication was attempted at all.

    False when the file was never keyed or never staged, in which case the
    driver keeps the binary and the command line it already had.
    """
    var owned: Bool
    """Whether the store now owns the binary about to run.

    True on both a publication and an adoption. The driver needs it for one
    decision: publishing a generation reaps that source's older ones, and a
    concurrent quarantine can move a valid generation aside, so a binary that
    is no longer at its pathname is a file to compile rather than an internal
    error.
    """
    var bin_rel: String
    """The binary to run."""
    var argv: List[String]
    """The command line to record."""
    var warning: String
    """Why the build could not be published, or empty when nothing went wrong.

    A publication failure is never a verdict — the binary that was just built
    is still the binary that runs — so it travels beside the outcome.
    """


def seam_begin(mut ctx: CacheContext, root: String, rel: String) -> SeamStaging:
    """Key one file and ask the store whether it already has that build.

    Args:
        ctx: The session's cache state. Switched off if this file proves the
            store unusable; its counters are NOT touched, because the three
            drivers charge admissions at different points.
        root: The invocation root.
        rel: The root-relative path of the file about to be built.

    Returns:
        A staging carrying the hit's binary, argv, and original build duration
        on a hit; the key a later `seam_stage` needs on a miss; nothing at all
        under a disabled context. Allocates the carried argv on a hit.
    """
    var staging = SeamStaging.none()
    if not ctx.enabled:
        return staging^
    var key = file_key(ctx, root, rel)
    if not key:
        # A source that will not read is about to fail its build anyway, and a
        # key that cannot cover its own source must never be written.
        ctx.disable("cannot read the test file '" + rel + "'")
        return staging^
    var hit = store_probe(root, key.value())
    if hit.kind == PROBE_HIT:
        # Nothing staged, so nothing to publish: the generation this binary
        # came from is already the store's, and the key is deliberately not
        # carried.
        staging.hit = True
        staging.bin_rel = hit.bin_rel
        staging.argv = hit.argv.copy()
        staging.build_seconds = hit.build_seconds
        return staging^
    staging.key = key^
    return staging^


def seam_stage(
    mut ctx: CacheContext,
    mut staging: SeamStaging,
    root: String,
    mangled: String,
):
    """Claim the staging directory this file's first compile writes into.

    A no-op unless a publication is owed, so a hit, a disabled context, and an
    unkeyable source all fall through untouched. Separate from `seam_begin`
    because the pool keys and probes its whole batch before the scheduler
    starts but stages only at the build dispatch: a batch halted by `-x` or an
    interrupt would otherwise leave one orphaned directory per undispatched
    file, and nothing in the tree sweeps them.

    Args:
        ctx: The session's cache state, switched off if the store cannot be
            staged into.
        staging: The file's staging. Its `target` is filled on success; its
            `key` is dropped when the store proves unusable.
        root: The invocation root.
        mangled: The source's mangled name, which leads the directory's name.
    """
    if not staging.key:
        return
    var target = store_build_target(root, mangled)
    if target.ok():
        # Compile straight into the store, so publication is one `rename(2)`
        # and never a copy of a binary that could differ from the one that was
        # digested.
        staging.target = target^
        return
    # Cache off for the session: a store that cannot be staged into once will
    # not stage the next file either, and probing on would spend a digest per
    # file for a hit that can never be published.
    ctx.disable(
        "the cache could not create its store directory under '.mtest-cache'"
    )
    staging.key = Optional[FileKey](None)


def seam_discard(var staging: SeamStaging, root: String):
    """Close the seam on a build that produced nothing worth keeping.

    Called where the compile did NOT yield a binary this session will run — a
    compile error, a timeout kill, a spawn failure, an interrupt, a batch torn
    down mid-build. A staged directory left behind on those paths is pure
    debris: it is named after this process, so no later run can adopt or reap
    it.

    Args:
        staging: The file's staging. Consumed; a staging that owes nothing is a
            no-op.
        root: The invocation root.
    """
    if not staging.target.ok():
        return
    try:
        remove_tree_no_follow(root + "/" + staging.target.tmp_dir_rel)
    except:
        # A staging directory that will not die is litter under a directory
        # mtest owns; failing the run over it is exactly the "cache condition
        # breaks an otherwise green run" the design forbids.
        pass


def seam_settle(
    var staging: SeamStaging,
    root: String,
    build_seconds: Float64,
    argv: List[String],
) -> SeamOutcome:
    """Close the seam by publishing the staged build, atomically or not at all.

    The rule with no exceptions: run `bin_rel`, record `argv`. On `PUB_OK` the
    staging directory this build's own argv names is already gone; on
    `PUB_ADOPTED` the live binary belongs to a generation this run never built
    and whose command line it therefore cannot reconstruct; on `PUB_FAILED`
    both are this run's own staging path, which is still there and holds the
    only copy of the binary about to run. Either way the directory stops being
    the driver's to sweep.

    Args:
        staging: The file's staging. Consumed; a staging that owes nothing
            settles nothing.
        root: The invocation root.
        build_seconds: What this build cost, recorded in the generation.
        argv: The command line the build actually ran with.

    Returns:
        Which binary to run, which command line to record, whether the store
        now owns the binary, and any publication warning. Allocates the
        returned argv.
    """
    if not (staging.target.ok() and staging.key):
        return SeamOutcome(False, False, String(""), List[String](), String(""))
    var pub = store_publish(
        root, staging.key.value(), staging.target, build_seconds, argv
    )
    return SeamOutcome(
        True,
        pub.kind != PUB_FAILED,
        pub.bin_rel,
        pub.argv.copy(),
        pub.warning if pub.kind == PUB_FAILED else String(""),
    )
