"""The selection pipeline kernel: which step each run file needs next.

Layer 4, beneath the selection sub-session that drives it. The kernel holds
where every run file sits between being discovered and having a verdict — it
needs building, it needs probing, it has been collected, it needs running, it is
recovering from a stale name, it is finished — and answers one question:
`next_step`, the step the run wants performed now. The driver performs that step
against `exec` and hands back what happened; the kernel folds the completion
into the file's stage and the run's stop policy.

The split is deliberate: **the kernel decides what step comes next, the driver
executes it.** Admission, the stale-name recover-once budget, the `--retries`
crash-class budget, and the `-x`/`--maxfail` stop policy live here, in
`session`, and never leak into `exec` or `native`. The kernel spawns nothing,
emits no event, and owns no captured bytes; the driver owns all of that.

The kernel enforces the collection barrier that makes the run two-pass: it will
not answer `RUN_SELECTION` for any file until every file has left
`NEEDS_BUILD`/`NEEDS_PROBE` and the run-wide selected and deselected totals have
been announced. A stale-name recovery rebuild is a distinct pair of stages
(`NEEDS_REBUILD`/`NEEDS_REPROBE`) precisely so it happens *after* that barrier
without re-arming it.

Capacity is one: exactly one step is in flight, because `exec` supervises
exactly one child at a time.
"""


@fieldwise_init
struct FileStage(Equatable, ImplicitlyCopyable, Movable):
    """Where one run file sits in the build, probe, and run pipeline.

    A thin wrapper over a stable integer discriminant, holding no owned
    resources, so copies and moves are trivial.
    """

    var code: Int
    """The stable integer discriminant identifying this stage."""

    comptime NEEDS_BUILD = Self(0)
    """Discovered and admitted; the compiler has not run for it yet."""
    comptime NEEDS_PROBE = Self(1)
    """Built; its `--skip-all` probe has not run yet."""
    comptime COLLECTED = Self(2)
    """Past the front half: either terminal, or probed and selected. Waiting
    for the collection barrier and then for its own turn in the run pass."""
    comptime NEEDS_RUN = Self(3)
    """Re-probed after a stale-name recovery and ready to run again. Distinct
    from `COLLECTED` so recovery never re-arms the collection barrier."""
    comptime NEEDS_REBUILD = Self(4)
    """The suite refused a name it had just listed; rebuild it once."""
    comptime NEEDS_REPROBE = Self(5)
    """Rebuilt during a stale-name recovery; re-probe for a fresh universe."""
    comptime FINISHED = Self(6)
    """Its verdict is settled; the pipeline asks nothing more of it."""

    comptime COUNT = 7
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two stages are equal iff their discriminants match."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code


@fieldwise_init
struct StepKind(Equatable, ImplicitlyCopyable, Movable):
    """What the pipeline wants done next.

    A thin wrapper over a stable integer discriminant, holding no owned
    resources, so copies and moves are trivial.
    """

    var code: Int
    """The stable integer discriminant identifying this step kind."""

    comptime BUILD_FILE = Self(0)
    """Compile one file, either for collection or for a stale-name recovery."""
    comptime PROBE_FILE = Self(1)
    """Run one built binary under `--skip-all` to learn its test names."""
    comptime ANNOUNCE_COLLECTION = Self(2)
    """Every file is collected: publish the run-wide selected/deselected
    totals before the first test body executes."""
    comptime REPLAY_TERMINAL = Self(3)
    """Emit and account a file that never became runnable — a compile error, a
    probe crash, a probe timeout, a malformed suite, or drift."""
    comptime SKIP_DESELECTED = Self(4)
    """Account a runnable file whose every test was deselected. It is not
    executed; the file itself lands in the not-run accounting."""
    comptime RUN_SELECTION = Self(5)
    """Run one file's selected subset."""
    comptime NOTHING = Self(6)
    """No step remains: the run completed, or it halted."""

    comptime COUNT = 7
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two step kinds are equal iff their discriminants match."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code


@fieldwise_init
struct PipelineHalt(Equatable, ImplicitlyCopyable, Movable):
    """Why the pipeline stopped issuing steps.

    A thin wrapper over a stable integer discriminant, holding no owned
    resources, so copies and moves are trivial.
    """

    var code: Int
    """The stable integer discriminant identifying this halt reason."""

    comptime RUNNING = Self(0)
    """Not halted. Steps may remain: a run that finishes every file under its
    own power ends here, answering `NOTHING` because nothing is left to do."""
    comptime INTERRUPTED = Self(1)
    """An interrupt aborted the run (the session resolves exit 2)."""
    comptime INTERNAL_ERROR = Self(2)
    """A spawn or machinery failure aborted the run (exit 3)."""
    comptime LIMIT_REACHED = Self(3)
    """`-x`/`--exitfirst` or `--maxfail` stopped scheduling."""

    comptime COUNT = 4
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two halt reasons are equal iff their discriminants match."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code


@fieldwise_init
struct StepRequest(ImplicitlyCopyable, Movable):
    """One step the pipeline wants performed, naming the file it concerns.

    Holds no owned resources; the driver looks the file's payload up by index.
    """

    var kind: StepKind
    """What to do."""
    var file_index: Int
    """Which run file, as an index into the driver's collected list. `-1` for
    `ANNOUNCE_COLLECTION` and `NOTHING`, which concern no single file."""
    var attempt: Int
    """The 1-based crash-class attempt number for `RUN_SELECTION`; `0`
    otherwise. It rides the file's `AttemptFinished` and `FileFinished`."""
    var recovering: Bool
    """Whether a `BUILD_FILE` or `PROBE_FILE` step is the stale-name recovery
    pass rather than the collection pass. A recovery step's result belongs to
    the file's own verdict stream, never to the collected set."""

    @staticmethod
    def nothing() -> Self:
        """The no-step-remains request.

        Returns:
            A `NOTHING` request naming no file.
        """
        return Self(StepKind.NOTHING, -1, 0, False)


@fieldwise_init
struct _PipelineFile(Copyable, Movable):
    """One run file's position and budgets inside the pipeline."""

    var stage: FileStage
    """Where this file sits in the pipeline."""
    var terminal: Bool
    """Whether its collected result is a terminal verdict to replay rather
    than a runnable selection."""
    var deselected_only: Bool
    """Whether its selection came back empty, so it is accounted but never
    executed."""
    var rebuilt_once: Bool
    """Whether the stale-name recover-once budget has been spent."""
    var attempt: Int
    """The 1-based crash-class attempt this file's next run would be."""


struct RunPipeline(Movable):
    """The selection run's per-file pipeline state and its stop policy.

    Owns one `_PipelineFile` per run file, the collection barrier, and the
    admission budgets. It performs no I/O and emits no event: it answers
    `next_step` and folds completions the driver reports back.
    """

    var _files: List[_PipelineFile]
    """Every admitted run file, in discovery order."""
    var _announced: Bool
    """Whether the collection barrier has been passed."""
    var _halt: PipelineHalt
    """Why the pipeline stopped, or `RUNNING`."""
    var _attempts_planned: Int
    """`--retries` + 1: the crash-class attempt ceiling for one run."""
    var _exitfirst: Bool
    """Whether `-x`/`--exitfirst` stops scheduling on the first failure."""
    var _maxfail: Int
    """The `--maxfail` failing-entry ceiling, or `0` when unset."""

    def __init__(
        out self,
        file_count: Int,
        retries: Int,
        exitfirst: Bool,
        maxfail: Int,
    ):
        """Admit `file_count` run files, all needing a build.

        Args:
            file_count: How many discovered run files this run owns.
            retries: The `--retries` budget; one run is allowed
                `retries + 1` attempts.
            exitfirst: Whether `-x`/`--exitfirst` is set.
            maxfail: The `--maxfail` ceiling, or `0` when unset.

        Returns:
            A pipeline with every file at `NEEDS_BUILD`. Allocates the
            per-file list.
        """
        self._files = List[_PipelineFile]()
        for _ in range(file_count):
            self._files.append(
                _PipelineFile(FileStage.NEEDS_BUILD, False, False, False, 1)
            )
        self._announced = False
        self._halt = PipelineHalt.RUNNING
        self._attempts_planned = retries + 1
        self._exitfirst = exitfirst
        self._maxfail = maxfail

    def halt(self) -> PipelineHalt:
        """Why the pipeline stopped, or `RUNNING`.

        Returns:
            The current halt reason.
        """
        return self._halt

    def stage_of(self, index: Int) -> FileStage:
        """Where one file sits in the pipeline.

        Args:
            index: The file's index in discovery order.

        Returns:
            That file's current stage.
        """
        return self._files[index].stage

    def next_step(self) -> StepRequest:
        """The step the run wants performed now.

        Scans in discovery order, so exactly one file is in flight and the
        order matches a sequential run: each file is built and probed before
        the next is, the collection totals are announced once every file has
        left the front half, and only then does any file run.

        Returns:
            The next step, or a `NOTHING` request when the run has halted or
            every file is finished. Pure: it mutates nothing.
        """
        if self._halt != PipelineHalt.RUNNING:
            return StepRequest.nothing()

        # Front half: build then probe every file, in discovery order.
        for i in range(len(self._files)):
            var stage = self._files[i].stage
            if stage == FileStage.NEEDS_BUILD:
                return StepRequest(StepKind.BUILD_FILE, i, 0, False)
            if stage == FileStage.NEEDS_PROBE:
                return StepRequest(StepKind.PROBE_FILE, i, 0, False)

        # The collection barrier: the run-wide totals are published exactly
        # once, after the last probe and before the first test body.
        if not self._announced:
            return StepRequest(StepKind.ANNOUNCE_COLLECTION, -1, 0, False)

        # Back half: settle each file in discovery order.
        for i in range(len(self._files)):
            ref f = self._files[i]
            if f.stage == FileStage.COLLECTED:
                if f.terminal:
                    return StepRequest(StepKind.REPLAY_TERMINAL, i, 0, False)
                if f.deselected_only:
                    return StepRequest(StepKind.SKIP_DESELECTED, i, 0, False)
                return StepRequest(StepKind.RUN_SELECTION, i, f.attempt, False)
            if f.stage == FileStage.NEEDS_RUN:
                return StepRequest(StepKind.RUN_SELECTION, i, f.attempt, False)
            if f.stage == FileStage.NEEDS_REBUILD:
                return StepRequest(StepKind.BUILD_FILE, i, 0, True)
            if f.stage == FileStage.NEEDS_REPROBE:
                return StepRequest(StepKind.PROBE_FILE, i, 0, True)
        return StepRequest.nothing()

    def record_build_ready(mut self, index: Int):
        """Fold a successful build: the file is ready to be probed.

        Args:
            index: The built file's index.
        """
        if self._files[index].stage == FileStage.NEEDS_REBUILD:
            self._files[index].stage = FileStage.NEEDS_REPROBE
        else:
            self._files[index].stage = FileStage.NEEDS_PROBE

    def record_build_terminal(mut self, index: Int):
        """Fold a build that produced a terminal verdict (a compile error).

        Args:
            index: The file's index.
        """
        if self._files[index].stage == FileStage.NEEDS_REBUILD:
            self._files[index].stage = FileStage.FINISHED
        else:
            self._files[index].terminal = True
            self._files[index].stage = FileStage.COLLECTED

    def record_probe_qualified(mut self, index: Int, selection_empty: Bool):
        """Fold a probe that read as a collection listing.

        Args:
            index: The probed file's index.
            selection_empty: Whether selecting against the fresh universe
                chose no test at all. Only consulted on the collection pass; a
                recovery re-probe runs whatever it reselected, exactly as the
                recovery loop it replaces did.
        """
        if self._files[index].stage == FileStage.NEEDS_REPROBE:
            self._files[index].stage = FileStage.NEEDS_RUN
            return
        self._files[index].deselected_only = selection_empty
        self._files[index].stage = FileStage.COLLECTED

    def record_probe_terminal(mut self, index: Int):
        """Fold a probe that produced a terminal verdict.

        A crash, a timeout, a malformed suite, drift, or a capture overflow.

        Args:
            index: The probed file's index.
        """
        if self._files[index].stage == FileStage.NEEDS_REPROBE:
            self._files[index].stage = FileStage.FINISHED
        else:
            self._files[index].terminal = True
            self._files[index].stage = FileStage.COLLECTED

    def record_collection_announced(mut self):
        """Fold the published run-wide collection totals, opening the run pass.
        """
        self._announced = True

    def admit_stale_name_recovery(mut self, index: Int) -> Bool:
        """Spend the stale-name recover-once budget, if it is still unspent.

        The suite refused a test it had just listed. The first refusal buys one
        rebuild and re-probe; a second refusal after that fresh rebuild is the
        chameleon, which the driver settles as a malformed suite.

        Args:
            index: The refusing file's index.

        Returns:
            True when the budget was available and the file moved to
            `NEEDS_REBUILD`; False when it was already spent and the driver
            must settle the file itself.
        """
        if self._files[index].rebuilt_once:
            return False
        self._files[index].rebuilt_once = True
        self._files[index].stage = FileStage.NEEDS_REBUILD
        return True

    def admit_crash_retry(mut self, index: Int) -> Bool:
        """Spend one `--retries` crash-class attempt, if any remains.

        Args:
            index: The crash-class file's index.

        Returns:
            True when another attempt remains and the file's attempt counter
            advanced; False when the budget is exhausted and the driver must
            settle the file on this attempt.
        """
        if self._files[index].attempt >= self._attempts_planned:
            return False
        self._files[index].attempt += 1
        self._files[index].stage = FileStage.NEEDS_RUN
        return True

    def record_verdict(
        mut self, index: Int, outcome_is_failing: Bool, failing_total: Int
    ):
        """Settle one file and apply the `-x`/`--maxfail` stop policy.

        Args:
            index: The settled file's index.
            outcome_is_failing: Whether the file's own outcome is failing-class,
                which `-x`/`--exitfirst` stops on.
            failing_total: The failing-class entry count of the run-outcome
                multiset accumulated so far, which `--maxfail` compares
                against. The driver supplies it, so the count stays the one the
                accounting already keeps.
        """
        self._files[index].stage = FileStage.FINISHED
        if self._exitfirst and outcome_is_failing:
            self._halt = PipelineHalt.LIMIT_REACHED
            return
        if self._maxfail > 0 and failing_total >= self._maxfail:
            self._halt = PipelineHalt.LIMIT_REACHED

    def record_settled(mut self, index: Int):
        """Settle one file that carries no verdict and no stop-policy weight.

        A file whose every test was deselected: it is accounted and reported,
        but it never ran, so it neither tallies an outcome nor moves the
        `-x`/`--maxfail` counters.

        Args:
            index: The settled file's index.
        """
        self._files[index].stage = FileStage.FINISHED

    def halt_interrupted(mut self):
        """Halt the pipeline because an interrupt arrived."""
        self._halt = PipelineHalt.INTERRUPTED

    def halt_internal_error(mut self):
        """Halt the pipeline because a spawn or machinery failure occurred."""
        self._halt = PipelineHalt.INTERNAL_ERROR
