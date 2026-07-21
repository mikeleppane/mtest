"""`TestResult`: one test's node, outcome, and raw detail and timing.

The per-test record the protocol layer emits after parsing a report row, and
the record the console later renders from. `detail` and `timing` are stored
verbatim: this module interprets, truncates, and reformats neither, so a FAIL's
assertion text and a raw timing token both ride through unchanged.
"""
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome


@fieldwise_init
struct TestResult(Copyable, Movable):
    """One test's identity, outcome, and raw captured detail.

    Owns its String fields, so copies are explicit via `.copy()`.
    """

    var node: NodeId
    """Which test this result concerns."""
    var outcome: Outcome
    """The test's outcome; the report parser only ever sets PASS, FAIL, or
    SKIP, the three row kinds the grammar carries."""
    var detail: String
    """The verbatim failure or assertion detail for a FAIL (`""` otherwise)."""
    var timing: String
    """The raw timing token as captured, never interpreted (`""` if none)."""

    def __init__(out self, var node: NodeId, outcome: Outcome):
        """Construct a result with no detail or timing yet.

        A convenience for the common PASS/SKIP case, where `detail` and
        `timing` are both `""`.

        Args:
            node: Which test this result concerns. Consumed.
            outcome: The test's outcome.
        """
        self.node = node^
        self.outcome = outcome
        self.detail = ""
        self.timing = ""
