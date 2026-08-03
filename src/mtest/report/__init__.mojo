"""The report layer of the mtest runner: the reporter seam.

This is the only part of the runner that formats text for humans. The session
emits the closed `Event` set and nothing else; reporters consume that stream
through a single `handle` method and are composed at compile time via a
variadic type-parameter pack rather than a runtime trait-object list, because
Mojo 1.0.0b2 polymorphism is static.

The seam is two entities: `Reporter`, the trait a reporter conforms to, and
`CompositeReporter[*Rs]`, which fans one event to a comptime tuple of them.
A third, `ReportCoordinator`, is how the session and `main` reach this layer. It
names the lifecycle interactions that belong to specific reporters (stream
health, JUnit not-run synthesis and finalize, the annotation tail, the console's
rendered output and fence token), so no caller depends on a concrete reporter
type or on a position in a composition tuple.

Everything else here is a reporter behind that seam (console, JSON stream,
JUnit, GitHub annotations, and a recording test double) or a rendering
primitive those reporters share. Each submodule documents its own contract.

Every machine format splits the same way: a pure renderer module with no I/O
(`json_stream`, `junit`, `annotations`) and a stateful `Reporter` shell that
owns the destination and its failure latching (`json_stream_reporter`,
`junit_reporter`, `annotations_reporter`). Reach for the pure half to test a
format, the shell to compose a run. `collect_stream` is the one machine format
with no shell: collect drives no reporter, so `main` renders and prints the
listing itself.

The public surface is re-exported here so callers write
`from mtest.report import Reporter, CompositeReporter, ConsoleReporter, ...`.
"""
from mtest.report.reporter import Reporter
from mtest.report.composite import CompositeReporter
from mtest.report.coordinator import (
    RecordingCoordinator,
    ReportCoordinator,
    StandardReportCoordinator,
)
from mtest.report.collect_stream import (
    collect_finished_line,
    collect_node_line,
    collect_stream_header,
)
from mtest.report.console import ConsoleReporter
from mtest.report.recording import RecordingReporter
from mtest.report.fencing import resume_delimiter
from mtest.report.escape import html_escape_attribute, html_escape_text
from mtest.report.json_stream_reporter import (
    JsonStreamReporter,
    close_json_fd,
    open_json_fd,
)
from mtest.report.junit_reporter import (
    JunitReporter,
    open_junit_artifact,
    open_junit_spool,
)
from mtest.report.annotations_reporter import AnnotationsReporter
from mtest.report.report_text import (
    md_code_fence,
    md_code_span,
    md_escape_cell,
    normalize_detail,
)
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
    needs_action,
    outcome_label,
)
from mtest.report.report_md import (
    md_file_section,
    md_header,
    md_machine_index,
    md_not_run_line,
    md_summary_row,
    md_summary_table_header,
)
from mtest.report.report_writer import (
    REPORT_STYLE_CONCISE,
    REPORT_STYLE_FULL,
    ReportArtifact,
    ReportFinalizeResult,
    ReportWriter,
)
from mtest.report.report_html import (
    html_document_close,
    html_document_open,
    html_file_section,
    html_machine_index,
    html_not_run_line,
    html_summary_row,
)
