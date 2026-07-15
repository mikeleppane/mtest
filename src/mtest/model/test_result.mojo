"""`TestResult`: one test's node, outcome, and raw detail/timing (Layer 0).

The per-test record the protocol layer emits after parsing a report row, and
the record the console later renders from. `detail` and `timing` are stored
VERBATIM -- this module performs no interpretation, truncation, or
reformatting of either; a FAIL's assertion text and a raw timing token both
ride through unchanged for `-v`/completeness.
"""
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome


@fieldwise_init
struct TestResult(Copyable, Movable):
    """One test's identity, outcome, and raw captured detail.

    Owns its String fields, so copies are explicit via `.copy()`; reads never
    mutate or raise.
    """

    var node: NodeId
    """Which test this result concerns."""
    var outcome: Outcome
    """The test's per-test outcome (PASS/FAIL/SKIP; DESELECTED when the
    session suppresses a row)."""
    var detail: String
    """The VERBATIM failure/assertion detail for a FAIL (`""` otherwise)."""
    var timing: String
    """The raw timing token as captured, never interpreted (`""` if none)."""

    def __init__(out self, var node: NodeId, outcome: Outcome):
        """A result with no detail or timing yet: `node` and `outcome` only.

        Convenience constructor for the common PASS/SKIP case; `detail` and
        `timing` default to `""`. Never raises.
        """
        self.node = node^
        self.outcome = outcome
        self.detail = ""
        self.timing = ""
