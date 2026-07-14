"""The RecordingReporter test double (Layer 2).

A stateful `Reporter` that records the whole event stream in order and prints
nothing. Session and composition tests use it to assert what the session
emitted — ordering, kinds, and payload fields — without parsing rendered text.
It stores each event whole, so any field is recoverable later; the convenience
accessors cover the fields tests reach for most.
"""
from mtest.model import Event, EventKind, Outcome, ParseDisposition, TestResult

from mtest.report.reporter import Reporter


struct RecordingReporter(Reporter):
    """Records every event it handles, in emission order.

    Owns a growing list of the events seen. Copyable and Movable so it can be
    composed into a `CompositeReporter` and its recorded state read back by
    index afterwards. It records; it never renders or prints.
    """

    var events: List[Event]
    """Every event handled so far, in the order it arrived."""

    def __init__(out self):
        """An empty recorder with no events yet. Allocates its backing list."""
        self.events = List[Event]()

    def handle(mut self, e: Event):
        """Append a copy of the event to the record. Total; never raises."""
        self.events.append(e.copy())

    def count(self) -> Int:
        """How many events have been recorded. Does not mutate or raise."""
        return len(self.events)

    def kind_at(self, i: Int) -> EventKind:
        """The kind of the i-th recorded event. Does not mutate or raise."""
        return self.events[i].kind

    def outcome_at(self, i: Int) -> Outcome:
        """The outcome of the i-th recorded event. Does not mutate or raise."""
        return self.events[i].outcome

    def path_at(self, i: Int) -> String:
        """The path of the i-th recorded event. Does not mutate or raise."""
        return self.events[i].path.copy()

    def event_at(self, i: Int) -> Event:
        """A copy of the i-th recorded event, for richer assertions. Never raises.
        """
        return self.events[i].copy()

    def test_at(self, i: Int) -> TestResult:
        """The `TestResult` of the i-th recorded event. Does not mutate or raise.
        """
        return self.events[i].test.copy()

    def selected_test_total_at(self, i: Int) -> Int:
        """The selected-test total of the i-th recorded event. Never raises."""
        return self.events[i].selected_test_total

    def deselected_test_total_at(self, i: Int) -> Int:
        """The deselected-test total of the i-th recorded event. Never raises.
        """
        return self.events[i].deselected_test_total

    def parse_disposition_at(self, i: Int) -> ParseDisposition:
        """The FileFinished parse disposition of the i-th recorded event.

        Does not mutate or raise.
        """
        return self.events[i].parse_disposition
