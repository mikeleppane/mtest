"""The report layer of the mtest runner (Layer 2): the reporter seam.

This is the ONLY layer that formats text for humans. The session (a later
layer) emits the closed `Event` set and nothing else; reporters consume that
stream through a single `handle` method and are composed at COMPTIME — a
variadic type-parameter pack, not a runtime trait-object list, because 1.0.0b2
polymorphism is static.

The surface:

- `Reporter` — the trait every reporter conforms to (one method, `handle`).
- `CompositeReporter[*Rs]` — fans one event to a comptime-known tuple of
  reporters via static dispatch.
- `ConsoleReporter` — renders the human-facing console output into an owned,
  inspectable buffer. It learns every fact it prints from events; only the
  version string and the color/verbosity/output config are passed at
  construction (build constants, not session facts).
- `RecordingReporter` — a stateful test double that records the event stream.

The public surface is re-exported here so callers write
`from mtest.report import Reporter, CompositeReporter, ConsoleReporter, ...`.
"""
from mtest.report.reporter import Reporter
from mtest.report.composite import CompositeReporter
from mtest.report.console import ConsoleReporter
from mtest.report.recording import RecordingReporter
