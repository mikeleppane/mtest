"""How a supervised child ended (Layer 3).

The whole product rests on keeping four endings distinct, so a crash is never
read as a failure and our own deadline kill is never read as a crash:

- `Exited(code)` — the child exited normally with this code (a genuine 127 too).
- `Signaled(signo)` — the child was terminated by this signal: a crash.
- `TimedOut(final, escalated)` — OUR deadline (or an interrupt) killed it. The
  outcome LATCHES here regardless of how the child then died: `final_*` retains
  what actually happened (a clean grace exit, a SIGTERM death, or a SIGKILL
  escalation) and `escalated` records whether SIGKILL was needed.
- `SpawnFailed(errno)` — the child could not be exec'd at all (the errno from a
  failed `execve`/`chdir`, reported through the close-on-exec errno pipe).

This is one tagged struct rather than four types so it is a plain, copyable data
value that a caller matches on; it owns nothing and never raises.
"""


@fieldwise_init
struct Termination(Equatable, ImplicitlyCopyable, Movable, Writable):
    """A tagged record of how a supervised child ended. Data only; never raises.
    """

    var kind: Int
    """Which ending this is: one of EXITED, SIGNALED, TIMED_OUT, SPAWN_FAILED."""
    var value: Int
    """The exit code (EXITED), signal number (SIGNALED), or errno (SPAWN_FAILED).
    """
    var final_kind: Int
    """TIMED_OUT only: EXITED or SIGNALED — how the child actually died."""
    var final_value: Int
    """TIMED_OUT only: the exit code or signal number of that actual death."""
    var escalated: Bool
    """TIMED_OUT only: whether the polite SIGTERM had to be escalated to SIGKILL.
    """

    comptime EXITED = 0
    comptime SIGNALED = 1
    comptime TIMED_OUT = 2
    comptime SPAWN_FAILED = 3

    @staticmethod
    def exited(code: Int) -> Self:
        """A normal exit with `code` (0..255). Does not allocate or raise."""
        return Self(Self.EXITED, code, Self.EXITED, 0, False)

    @staticmethod
    def signaled(signo: Int) -> Self:
        """A death by signal `signo`: a crash. Does not allocate or raise."""
        return Self(Self.SIGNALED, signo, Self.EXITED, 0, False)

    @staticmethod
    def spawn_failed(errno: Int) -> Self:
        """The child could not be exec'd; `errno` from the failed call. Pure."""
        return Self(Self.SPAWN_FAILED, errno, Self.EXITED, 0, False)

    @staticmethod
    def timed_out(final_kind: Int, final_value: Int, escalated: Bool) -> Self:
        """Our deadline/interrupt killed the child; the run latches to timed out.

        Args:
            final_kind: EXITED or SIGNALED — how the child actually died.
            final_value: The exit code or signal number of that death.
            escalated: Whether SIGTERM had to be escalated to SIGKILL.

        Returns:
            A TIMED_OUT termination retaining the actual death in `final_*`.
            Does not allocate or raise.
        """
        return Self(Self.TIMED_OUT, 0, final_kind, final_value, escalated)

    def is_exited(self) -> Bool:
        """Whether the child exited normally. Pure."""
        return self.kind == Self.EXITED

    def is_signaled(self) -> Bool:
        """Whether the child died by a signal (a crash). Pure."""
        return self.kind == Self.SIGNALED

    def is_timed_out(self) -> Bool:
        """Whether our deadline/interrupt killed the child. Pure."""
        return self.kind == Self.TIMED_OUT

    def is_spawn_failed(self) -> Bool:
        """Whether the child could not be exec'd at all. Pure."""
        return self.kind == Self.SPAWN_FAILED

    def final_is_exited(self) -> Bool:
        """TIMED_OUT only: whether the actual death was a normal exit. Pure."""
        return self.final_kind == Self.EXITED

    def __eq__(self, other: Self) -> Bool:
        """Structural equality across every field. Pure."""
        return (
            self.kind == other.kind
            and self.value == other.value
            and self.final_kind == other.final_kind
            and self.final_value == other.final_value
            and self.escalated == other.escalated
        )

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        """Render a short debug form (for assertion messages). Pure."""
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
