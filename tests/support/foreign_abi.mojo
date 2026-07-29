"""The one declaration site for foreign symbols more than one suite needs.

Two classified modules that each wrote their own `external_call` for the same
symbol were compiled into two separate binaries, so a disagreement between
those declarations in arity or parameter type was a compile error nowhere:
each module built clean on its own, nothing linked them together, and so
nothing ever compared them. Only the module whose declaration was wrong paid,
and it paid at run time, by passing garbage across the ABI boundary rather
than by failing to build. `.agents/lessons.md` records that failure mode under
"Mojo language, pinned toolchain".

Declaring each such symbol exactly once, here, retires the disagreement
instead of detecting it. With one declaration there is no second one for it to
disagree with, and every suite that needs the symbol reaches it through this
wrapper and therefore through that same declaration. The property that used to
be established by co-linking the sharing modules into a throwaway binary --
which cost a real compiler, the precompiled package, and the native test
object on the hosted preflight path -- is now a consequence of where the
declaration lives.

The arrangement does not rest on being noticed. `pixi run abi-probe-check`
fails when any `external_call` symbol is declared in two files anywhere under
`tests/`, which is the only shape the old drift could take, and it does so by
reading the sources rather than by building them. This file is inside the
range it scans, not exempt from it: re-declaring a symbol that already lives
here is the likeliest way to reintroduce the drift, so it has to be the
loudest. A symbol exactly one suite declares carries no such risk -- nothing
exists to disagree with it -- and may stay in that suite behind its own local
proof; the moment a second suite needs it, that check requires it to move
here.

Consolidating also narrows what has to be right. Co-linking proved that N
declarations agreed with each other and could not tell whether all N were
wrong together; one declaration is one thing to review against the C header,
which is quoted in each proof below.

This is the test-only counterpart to `src/mtest/platform`, and it is
deliberately just as narrow. It holds no fixture, no assertion helper, and no
policy: every entry is one foreign call plus the argument that the call is
sound. Anything a suite wants to do with the result belongs in the suite.
"""
from std.ffi import external_call


def native_test_constant(constant_id: Int) -> Int32:
    """Read one platform-header value from the native testing adapter.

    Args:
        constant_id: An `MTEST_EXEC_TEST_CONSTANT_*` discriminator.

    Returns:
        The C-header value the adapter records for that discriminator.
    """
    # SAFETY: `int32_t mtest_exec_test_constant(uint32_t constant_id)` is a
    # fixed arity of one with no variadic tail, so the NON-variadic call
    # `external_call` emits is the correct one on every target these suites
    # build for, Darwin arm64 included. The single argument is a scalar passed
    # by value in a register: no pointer is formed, so provenance, ownership,
    # alignment, initialization, bounds, escape, and callee retention are all
    # vacuous, and neither side allocates anything that the success or the
    # unrecognized-identifier path would have to free. The adapter range-checks
    # `constant_id` against its own closed enumeration and answers an
    # unrecognized one with a sentinel rather than indexing out of bounds. The
    # result is a plain `int32_t` by value; every bit pattern of it is a valid
    # `Int32`.
    return external_call["mtest_exec_test_constant", Int32](UInt32(constant_id))


def reset_native_faults():
    """Clear the native testing adapter's fault table and its counters."""
    # SAFETY: `void mtest_exec_test_fault_reset(void)` is a fixed arity of zero
    # with no variadic tail and no result, so the NON-variadic call
    # `external_call` emits is correct on every target these suites build for.
    # Nothing crosses the boundary in either direction: no pointer is formed,
    # leaving provenance, ownership, lifetime, bounds, alignment, escape, and
    # retention vacuous, and there is nothing for either side to free on any
    # path. The call mutates only the adapter's own fault configuration, which
    # every suite here drives from a single thread between supervised runs,
    # never while a child is live.
    external_call["mtest_exec_test_fault_reset", NoneType]()


def configure_native_fault(
    operation: Int, occurrence: Int, error_number: Int
) raises:
    """Make one visit to one adapter operation fail with one errno.

    Args:
        operation: The `MTEST_EXEC_OP_*` discriminator to fault.
        occurrence: Which visit to that operation fails, counting from 1.
        error_number: The errno the faulted operation reports.

    Raises:
        Error: The adapter rejected the configuration.
    """
    # SAFETY: `int32_t mtest_exec_test_fault_configure(uint32_t operation,
    # uint32_t occurrence, int32_t error_number, int64_t result_value)` is a
    # fixed arity of four with no variadic tail, so the NON-variadic call
    # `external_call` emits is correct on every target these suites build for,
    # and the four widths written here are the header's. All four arguments are
    # scalars passed by value, so provenance, ownership, alignment,
    # initialization, bounds, escape, and callee retention are vacuous, and
    # nothing is allocated that the accepted or the rejected path would have to
    # free. `operation` and `occurrence` are closed discriminators the adapter
    # validates itself, returning nonzero rather than indexing its table out of
    # bounds. The result payload is fixed at zero because a faulted operation
    # reports an errno and never a value, which is the shape the adapter
    # requires for an error. The status is a plain `int32_t` by value.
    var status = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(operation), UInt32(occurrence), Int32(error_number), Int64(0)
    )
    if status != 0:
        raise Error(
            "the testing adapter rejected a fault on operation "
            + String(operation)
            + " occurrence "
            + String(occurrence)
        )


def configure_secondary_native_fault(
    operation: Int, occurrence: Int, error_number: Int
) raises:
    """Fault a second, later visit to an already-faulted adapter operation.

    Args:
        operation: The `MTEST_EXEC_OP_*` discriminator to fault, which must
            already carry a primary fault.
        occurrence: Which visit fails, counting from 1, after the primary.
        error_number: The errno the faulted operation reports.

    Raises:
        Error: The adapter rejected the configuration.
    """
    # SAFETY: `int32_t mtest_exec_test_fault_configure_secondary(uint32_t
    # operation, uint32_t occurrence, int32_t error_number, int64_t
    # result_value)` is a fixed arity of four with no variadic tail, matching
    # its primary counterpart above field for field, so the NON-variadic call
    # `external_call` emits is correct on every target these suites build for.
    # All four arguments are scalars passed by value: no pointer is formed, so
    # provenance, ownership, alignment, initialization, bounds, escape, and
    # retention are vacuous, and neither path allocates anything to free. The
    # adapter rejects an operation with no primary fault, and range-checks the
    # discriminator itself rather than indexing out of bounds. The result
    # payload is fixed at zero, as an error injection requires.
    var status = external_call[
        "mtest_exec_test_fault_configure_secondary", Int32
    ](UInt32(operation), UInt32(occurrence), Int32(error_number), Int64(0))
    if status != 0:
        raise Error(
            "the testing adapter rejected a secondary fault on operation "
            + String(operation)
            + " occurrence "
            + String(occurrence)
        )


def native_fault_seen(operation: Int) -> Int:
    """How many visits the adapter counted for one configured operation.

    Args:
        operation: The `MTEST_EXEC_OP_*` discriminator to read.

    Returns:
        The recorded visit count, or zero when that operation carries no
        configured fault.
    """
    # SAFETY: `uint32_t mtest_exec_test_fault_seen(uint32_t operation)` is a
    # fixed arity of one with no variadic tail, so the NON-variadic call
    # `external_call` emits is correct on every target these suites build for.
    # The argument is a scalar passed by value and the counter comes back by
    # value, so no pointer is formed on either side: provenance, ownership,
    # alignment, initialization, bounds, escape, and retention are vacuous, and
    # nothing is allocated for either side to free. The adapter range-checks
    # `operation` and answers an out-of-range or unconfigured one with zero
    # rather than reading past its table. Every bit pattern of the returned
    # `uint32_t` is a valid `UInt32`, and the counter is bounded by the visits
    # one supervised run can make, so widening it to `Int` cannot overflow.
    return Int(
        external_call["mtest_exec_test_fault_seen", UInt32](UInt32(operation))
    )


def configure_monotonic_wait(occurrence: Int, max_wait_ms: Int) raises:
    """Make one monotonic-clock read inside the adapter block before returning.

    Args:
        occurrence: Which clock read waits, counting from 1.
        max_wait_ms: The ceiling on that wait, in milliseconds.

    Raises:
        Error: The adapter rejected the configuration.
    """
    # SAFETY: `int32_t mtest_exec_test_monotonic_wait_configure(uint32_t
    # occurrence, uint32_t max_wait_ms)` is a fixed arity of two with no
    # variadic tail, so the NON-variadic call `external_call` emits is correct
    # on every target these suites build for. Both arguments are scalars passed
    # by value, so provenance, ownership, alignment, initialization, bounds,
    # escape, and retention are vacuous, and neither the accepted nor the
    # rejected path allocates anything to free. The adapter rejects a zero
    # occurrence, a zero wait, and any wait above its own compiled ceiling,
    # returning nonzero instead of storing an unbounded delay, so this call
    # cannot arm a wait that outlives the run that configured it. Only adapter
    # clock-wait state is touched; no Mojo object is read or mutated.
    var status = external_call[
        "mtest_exec_test_monotonic_wait_configure", Int32
    ](UInt32(occurrence), UInt32(max_wait_ms))
    if status != 0:
        raise Error(
            "the testing adapter rejected a monotonic wait at occurrence "
            + String(occurrence)
        )


def monotonic_wait_fired() -> Bool:
    """Whether the configured monotonic-clock wait actually ran."""
    # SAFETY: `uint32_t mtest_exec_test_monotonic_wait_fired(void)` is a fixed
    # arity of zero with no variadic tail, so the NON-variadic call
    # `external_call` emits is correct on every target these suites build for.
    # Nothing is passed, so provenance, ownership, alignment, initialization,
    # bounds, escape, and retention are vacuous, and nothing is allocated for
    # either side to free. The adapter returns a flag it stores as zero or one;
    # reading it neither mutates adapter state nor touches any Mojo object, and
    # every bit pattern of the returned `uint32_t` is a valid `UInt32`.
    return external_call["mtest_exec_test_monotonic_wait_fired", UInt32]() != 0


def reap_child(pid: Int32, options: Int32) -> Int32:
    """Wait on one child and discard its status word.

    Callers here ask only which child was reaped, so the status is written into
    storage this function owns and then dropped. Owning it here is what lets
    every caller drop the heap allocation the status word used to need.

    Args:
        pid: The exact child to wait for, or -1 for any child.
        options: The POSIX option bits, for example `WNOHANG` as 1, or 0 to
            block until the child is waitable.

    Returns:
        The pid that was reaped, or -1 when `waitpid` reports no such child.
    """
    var status = Int32(0)
    # SAFETY: `pid_t waitpid(pid_t pid, int *status, int options)` is a fixed
    # arity of three with no variadic tail on both Linux and Darwin, so the
    # NON-variadic call `external_call` emits is the correct one on every
    # target these suites build for; `pid_t` and `int` are each 32-bit signed
    # there, which is what `Int32` passes. `status` is a local this function
    # uniquely owns, completely initialized before the pointer is formed and
    # live across the whole synchronous call, so the pointer's provenance is
    # that local and it is correctly aligned for `int` because `Int32` carries
    # `int`'s alignment and width. The callee writes at most that one `int`
    # through it, reads nothing through it, and neither stores it for a later
    # call nor retains it past its return, so the pointer cannot escape the
    # frame that owns the storage. Nothing is heap-allocated, so the reaped,
    # the ECHILD, and the interrupted paths all clean up identically by
    # returning. Passing `pid` unchanged means a caller naming an exact child
    # cannot consume a different one, and the result is a plain `pid_t` by
    # value.
    return external_call["waitpid", Int32](
        pid, UnsafePointer(to=status), options
    )
