"""The report layer of the mtest runner: the reporter seam.

This is the only part of the runner that formats text for humans. The session
emits the closed `Event` set and nothing else; reporters consume that stream
through a single `handle` method and are composed at compile time via a
variadic type-parameter pack rather than a runtime trait-object list, because
Mojo 1.0.0b2 polymorphism is static.

The seam is two entities: `Reporter`, the trait a reporter conforms to, and
`CompositeReporter[*Rs]`, which fans one event to a comptime tuple of them.
Everything else here is a reporter behind that seam (console, JSON stream,
JUnit, GitHub annotations, and a recording test double) or a rendering
primitive those reporters share. Each submodule documents its own contract.

Every machine format splits the same way: a pure renderer module with no I/O
(`json_stream`, `junit`, `annotations`) and a stateful `Reporter` shell that
owns the destination and its failure latching (`json_stream_reporter`,
`junit_reporter`, `annotations_reporter`). Reach for the pure half to test a
format, the shell to compose a run.

The public surface is re-exported here so callers write
`from mtest.report import Reporter, CompositeReporter, ConsoleReporter, ...`.
"""
from mtest.report.reporter import Reporter
from mtest.report.composite import CompositeReporter
from mtest.report.console import ConsoleReporter
from mtest.report.recording import RecordingReporter
from mtest.report.escape import (
    contains_resume_delimiter,
    fence_region,
    gh_escape_message,
    gh_escape_property,
    json_escape_string,
    resume_delimiter,
    select_collision_free_token,
    stop_commands_opener,
    xml_escape_attribute,
    xml_escape_text,
)
from mtest.report.json_stream import serialize_event, stream_header
from mtest.report.json_stream_reporter import (
    JsonStreamReporter,
    StreamStatus,
    close_json_fd,
    open_json_fd,
)
from mtest.report.junit import (
    JunitCase,
    JunitPrimary,
    JunitRerun,
    JunitSuite,
    RenderedSuite,
    assemble,
    bounded_text_from_bytes,
    dotted_classname,
    format_seconds,
    node_sort_key,
    render_suite,
)
from mtest.report.junit_reporter import (
    JunitArtifact,
    JunitFinalizeResult,
    JunitReporter,
    JunitStatus,
    open_junit_artifact,
    open_junit_spool,
)
from mtest.report.annotations import render_annotations
from mtest.report.annotations_reporter import AnnotationsReporter
