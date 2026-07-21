"""How a supervised child ended.

The runner keeps four endings distinct, so a crash is never read as a failure
and mtest's own deadline kill is never read as a crash:

- `Exited(code)` — the child exited normally with this code (a genuine 127 too).
- `Signaled(signo)` — the child was terminated by this signal: a crash.
- `TimedOut(final, escalated)` — mtest's deadline (or an interrupt) killed it.
  The outcome latches here regardless of how the child then died: `final_*`
  retains what actually happened (a clean grace exit, a SIGTERM death, or a
  SIGKILL escalation) and `escalated` records whether SIGKILL was needed.
- `SpawnFailed(errno)` — the child could not be exec'd at all (the errno from a
  failed `execve`/`chdir`, reported through the close-on-exec errno pipe).

This is one tagged struct rather than four types, so it is a plain copyable data
value that a caller matches on; it owns nothing and never raises.
"""


@fieldwise_init
struct Termination(Equatable, ImplicitlyCopyable, Movable, Writable):
    """A tagged record of how a supervised child ended; data only."""

    var kind: Int
    """Which ending this is: EXITED, SIGNALED, TIMED_OUT, or SPAWN_FAILED."""
    var value: Int
    """Per `kind`: the exit code for EXITED, the signal number for SIGNALED,
    the errno for SPAWN_FAILED, and always 0 for TIMED_OUT, whose payload
    lives in `final_kind`, `final_value`, and `escalated` instead.
    """
    var final_kind: Int
    """TIMED_OUT only: EXITED or SIGNALED — how the child actually died."""
    var final_value: Int
    """TIMED_OUT only: the exit code or signal number of that actual death."""
    var escalated: Bool
    """TIMED_OUT only: whether SIGTERM had to be escalated to SIGKILL."""

    comptime EXITED = 0
    comptime SIGNALED = 1
    comptime TIMED_OUT = 2
    comptime SPAWN_FAILED = 3

    @staticmethod
    def exited(code: Int) -> Self:
        """A normal exit with `code`.

        Args:
            code: The exit status the child returned, 0..255.

        Returns:
            An EXITED termination carrying `code` in `value`.
        """
        return Self(Self.EXITED, code, Self.EXITED, 0, False)

    @staticmethod
    def signaled(signo: Int) -> Self:
        """A death by signal: a crash.

        Args:
            signo: The signal number that terminated the child.

        Returns:
            A SIGNALED termination carrying `signo` in `value`.
        """
        return Self(Self.SIGNALED, signo, Self.EXITED, 0, False)

    @staticmethod
    def spawn_failed(errno: Int) -> Self:
        """The child could not be exec'd at all.

        Args:
            errno: The errno reported by the failed `execve` or `chdir`.

        Returns:
            A SPAWN_FAILED termination carrying `errno` in `value`.
        """
        return Self(Self.SPAWN_FAILED, errno, Self.EXITED, 0, False)

    @staticmethod
    def timed_out(final_kind: Int, final_value: Int, escalated: Bool) -> Self:
        """A kill by an mtest deadline or interrupt; the outcome latches here.

        Args:
            final_kind: EXITED or SIGNALED — how the child actually died.
            final_value: The exit code or signal number of that death.
            escalated: Whether SIGTERM had to be escalated to SIGKILL.

        Returns:
            A TIMED_OUT termination retaining the actual death in `final_*`.
        """
        return Self(Self.TIMED_OUT, 0, final_kind, final_value, escalated)

    def is_exited(self) -> Bool:
        """Whether the child exited normally."""
        return self.kind == Self.EXITED

    def is_signaled(self) -> Bool:
        """Whether the child died by a signal (a crash)."""
        return self.kind == Self.SIGNALED

    def is_timed_out(self) -> Bool:
        """Whether an mtest deadline or interrupt killed the child."""
        return self.kind == Self.TIMED_OUT

    def is_spawn_failed(self) -> Bool:
        """Whether the child could not be exec'd at all."""
        return self.kind == Self.SPAWN_FAILED

    def final_is_exited(self) -> Bool:
        """TIMED_OUT only: whether the actual death was a normal exit."""
        return self.final_kind == Self.EXITED

    def __eq__(self, other: Self) -> Bool:
        """Structural equality across every field."""
        return (
            self.kind == other.kind
            and self.value == other.value
            and self.final_kind == other.final_kind
            and self.final_value == other.final_value
            and self.escalated == other.escalated
        )

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        """Render a short debug form, for assertion messages."""
        if self.kind == Self.EXITED:
            writer.write("Exited(", self.value, ")")
        elif self.kind == Self.SIGNALED:
            writer.write("Signaled(", self.value, ")")
        elif self.kind == Self.SPAWN_FAILED:
            writer.write("SpawnFailed(", self.value, ")")
        else:
            var fk = String("exit") if self.final_is_exited() else String(
                "signal"
            )
            writer.write(
                "TimedOut(final=",
                fk,
                " ",
                self.final_value,
                ", escalated=",
                self.escalated,
                ")",
            )
