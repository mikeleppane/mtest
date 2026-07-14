"""The pure run-outcome to process exit-code function (Layer 0).

The runner's exit code is its product: a code you cannot trust is worse than
none. This module owns the mapping from the multiset of RUN outcomes — the
outcomes of the files that actually ran, never the excluded or not-run ones — to
the three codes that mapping alone decides: 1, 5, and 0. Codes 4 (pre-run usage
error), 3 (internal error), and 2 (interrupt) are control-flow codes decided in
the session and main, not here.
"""
from mtest.model.outcome import Outcome

comptime EXIT_SUCCESS = 0
"""All run outcomes passed (or skipped): a clean run."""
comptime EXIT_FAILURE = 1
"""At least one run outcome was in the failing class."""
comptime EXIT_NOTHING_RAN = 5
"""Nothing was runnable: an empty walk, or every discovered file excluded."""


def exit_code_for(outcomes: List[Outcome]) -> Int:
    """Map a multiset of run outcomes to a process exit code.

    Total and pure over the multiset — every possible input maps to exactly one
    code, and the function performs no I/O and never raises. The rules, in
    order:

    - If any outcome is in the failing class, return 1 (EXIT_FAILURE).
    - Else if the multiset is empty (nothing was runnable), return 5
      (EXIT_NOTHING_RAN).
    - Else return 0 (EXIT_SUCCESS): every outcome passed or skipped.

    The caller passes only the outcomes of files that ran; excluded and not-run
    files are not part of this multiset.
    """
    for o in outcomes:
        if o.is_failing():
            return EXIT_FAILURE
    if len(outcomes) == 0:
        return EXIT_NOTHING_RAN
    return EXIT_SUCCESS
