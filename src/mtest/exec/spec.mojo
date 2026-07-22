"""What to run under supervision.

`ProcessSpec` is the whole input to `run_supervised`: an explicit argv (no
shell, so `argv[0]` is the program and the rest are literal arguments), an
optional working directory, a deadline in milliseconds, and the
SIGTERM->SIGKILL grace the supervisor honors when that deadline (or an
interrupt) fires. It also carries an optional list of `KEY=VALUE` environment
overrides the child receives on top of the inherited environment.

The grace is per-spawn rather than one global constant because the right answer
depends on what is being killed. A test binary owes nothing on the way out, so
300 ms is generous. A compiler killed mid-cache-write needs materially longer
to unwind cleanly, and SIGKILLing it early is how a half-written module cache
gets produced. The default is the run path's 300 ms, so a caller that says
nothing gets the behavior it always had.
"""


comptime DEFAULT_GRACE_MS = 300
"""The default SIGTERM->SIGKILL grace in ms: what a supervised run gets."""


@fieldwise_init
struct ProcessSpec(Copyable, Movable):
    """A command to run under supervision.

    Owns its strings, so copies are explicit.
    """

    var argv: List[String]
    """The program and its literal arguments.

    An `argv[0]` containing a slash is exec'd as that path directly; one
    without is resolved against the PATH components.
    """
    var cwd: Optional[String]
    """The working directory to `chdir` into before exec, if set."""
    var timeout_ms: Int
    """The deadline in milliseconds; 0 disables the deadline entirely."""
    var grace_ms: Int
    """Milliseconds between the process-group SIGTERM and the SIGKILL."""
    var env_extra: List[String]
    """`KEY=VALUE` environment overrides applied on top of the inherited
    environment.

    Each entry must have a `=` with a nonempty key and no NUL byte, and no key
    may repeat across the list. The adapter merges them replace-not-append: an
    override whose key is already inherited replaces every inherited occurrence,
    leaving no duplicate, and PATH-based resolution reads the merged environment
    so a `PATH=` override governs it. An empty list leaves the inherited
    environment untouched. Validation and the merge live in the C adapter; this
    field carries the raw entries across.
    """

    @staticmethod
    def command(
        var argv: List[String],
        timeout_ms: Int = 0,
        grace_ms: Int = DEFAULT_GRACE_MS,
    ) -> Self:
        """A spec for `argv` with no cwd override and the given deadline.

        Args:
            argv: The program and its arguments; must be non-empty at run time.
                Consumed; the returned spec owns it.
            timeout_ms: The deadline in milliseconds; 0 disables it.
            grace_ms: The SIGTERM->SIGKILL grace; defaults to the run path's
                300 ms.

        Returns:
            A spec with no cwd override and a freshly allocated empty
            `env_extra` list.
        """
        return Self(argv^, None, timeout_ms, grace_ms, List[String]())

    @staticmethod
    def command_in(
        var argv: List[String],
        cwd: String,
        timeout_ms: Int = 0,
        grace_ms: Int = DEFAULT_GRACE_MS,
    ) -> Self:
        """A spec for `argv` run inside `cwd` with the given deadline.

        Args:
            argv: The program and its arguments; must be non-empty at run time.
                Consumed; the returned spec owns it.
            cwd: The working directory to change into before exec.
            timeout_ms: The deadline in milliseconds; 0 disables it.
            grace_ms: The SIGTERM->SIGKILL grace; defaults to the run path's
                300 ms.

        Returns:
            A spec whose child chdirs into `cwd` before exec, with a freshly
            allocated empty `env_extra` list.
        """
        return Self(argv^, Optional(cwd), timeout_ms, grace_ms, List[String]())
