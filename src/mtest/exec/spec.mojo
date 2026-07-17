"""What to run under supervision (Layer 3).

`ProcessSpec` is the whole input to `run_supervised`: an explicit argv (no shell,
so `argv[0]` is the program and the rest are literal arguments), an optional
working directory, a deadline in milliseconds, and the SIGTERM->SIGKILL grace the
supervisor honors when that deadline (or an interrupt) fires. It carries a
reserved env-extension field that is present so the shape is stable but is NOT
read this phase — child environment mutation is unproven and out of scope.

The grace is per-spawn rather than one global constant because the right answer
depends on what is being killed. A test binary owes us nothing on the way out, so
300 ms is generous. A COMPILER killed mid-cache-write needs materially longer to
unwind cleanly, and SIGKILLing it early is exactly how a half-written module cache
would be produced. The default is the run path's 300 ms, so a caller that says
nothing gets the behavior it always had.
"""


comptime DEFAULT_GRACE_MS = 300
"""The default SIGTERM->SIGKILL grace: what a supervised RUN gets."""


@fieldwise_init
struct ProcessSpec(Copyable, Movable):
    """A command to run under supervision. Owns its strings; copies are explicit.
    """

    var argv: List[String]
    """The program and its literal arguments; `argv[0]` is exec'd via PATH."""
    var cwd: Optional[String]
    """The working directory to `chdir` into before exec, if set."""
    var timeout_ms: Int
    """The deadline in milliseconds; 0 disables the deadline entirely."""
    var grace_ms: Int
    """Milliseconds between the process-group SIGTERM and the SIGKILL."""
    var env_extra: List[String]
    """RESERVED — not read this phase; reserved for future env extension."""

    @staticmethod
    def command(
        var argv: List[String],
        timeout_ms: Int = 0,
        grace_ms: Int = DEFAULT_GRACE_MS,
    ) -> Self:
        """A spec for `argv` with no cwd override and the given deadline.

        Args:
            argv: The program and its arguments; must be non-empty at run time.
            timeout_ms: The deadline in milliseconds; 0 disables it.
            grace_ms: The SIGTERM->SIGKILL grace; defaults to the run path's
                300 ms.

        Returns:
            A spec with no cwd and an empty reserved env list. Allocates the
            owned lists; does not raise.
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
            cwd: The working directory to change into before exec.
            timeout_ms: The deadline in milliseconds; 0 disables it.
            grace_ms: The SIGTERM->SIGKILL grace; defaults to the run path's
                300 ms.

        Returns:
            A spec whose child chdirs into `cwd` before exec. Allocates the owned
            lists; does not raise.
        """
        return Self(argv^, Optional(cwd), timeout_ms, grace_ms, List[String]())
