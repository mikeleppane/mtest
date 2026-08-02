"""The pure NDJSON serializer for the machine-readable collect stream.

Three functions, one line each: `collect_stream_header` for the frozen first
line, `collect_node_line` for one discovered test, and `collect_finished_line`
for the terminal summary. Every line is a complete, UTF-8-valid NDJSON object
with no trailing newline; the caller appends the delimiter and writes it. The
stream carries no floating-point value anywhere. The collect-stream format
integer is frozen at 1 and lives only here, the same policy the run stream's
own header follows, and the format grows only additively: a later field is a
new key at the end of an existing object, never a change to an existing key's
meaning or type, so a consumer written against today's stream keeps working
against a later one.

`report` never imports `cli`, so the version string arrives as a plain
argument rather than a shared constant, exactly as the run stream's own
header receives it.
"""
from mtest.report.escape import json_escape_string


def collect_stream_header(version: String) -> String:
    """The frozen first line of a collect NDJSON stream.

    Exactly `{"event":"collect","version":1,"generator":"mtest <version>"}`.
    The collect-stream format integer is frozen at 1 and lives only here.

    Args:
        version: The build's mtest version label, supplied by the caller so
            this module depends on no higher layer. JSON-escaped into the
            `generator` field.

    Returns:
        The complete header line, without a trailing newline.

    Examples:

    ```mojo
    from mtest.report.collect_stream import collect_stream_header

    var head = collect_stream_header("x.y.z")
    # '{"event":"collect","version":1,"generator":"mtest x.y.z"}'
    ```
    """
    return (
        '{"event":"collect","version":1,"generator":"mtest '
        + json_escape_string(version)
        + '"}'
    )


def collect_node_line(node_id: String, path: String, name: String) -> String:
    """One discovered test as one NDJSON `node` line.

    Args:
        node_id: The test's full node id (`path::name`). JSON-escaped.
        path: The test file's path, exactly as discovered. JSON-escaped.
        name: The test function's bare name. JSON-escaped.

    Returns:
        A single complete JSON object, without the trailing newline that
        delimits it in the stream; the caller appends that.

    Examples:

    ```mojo
    from mtest.report.collect_stream import collect_node_line

    var line = collect_node_line(
        "tests/test_a.mojo::test_x", "tests/test_a.mojo", "test_x"
    )
    ```
    """
    return (
        '{"event":"node","node_id":"'
        + json_escape_string(node_id)
        + '","path":"'
        + json_escape_string(path)
        + '","name":"'
        + json_escape_string(name)
        + '"}'
    )


def collect_finished_line(nodes: Int, exit_code: Int) -> String:
    """The terminal line of a collect NDJSON stream.

    Args:
        nodes: The total count of discovered tests emitted as `node` lines.
        exit_code: The collect run's own exit code.

    Returns:
        A single complete JSON object, without the trailing newline that
        delimits it in the stream; the caller appends that.

    Examples:

    ```mojo
    from mtest.report.collect_stream import collect_finished_line

    var line = collect_finished_line(3, 0)
    # '{"event":"collect_finished","nodes":3,"exit_code":0}'
    ```
    """
    return (
        '{"event":"collect_finished","nodes":'
        + String(nodes)
        + ',"exit_code":'
        + String(exit_code)
        + "}"
    )
