"""Protocol-snapshot loading helpers for the protocol parser tests.

Pure fixture plumbing shared by the `protocol` test modules: read a committed
snapshot, carve out its stdout section (the lines between the `--- stdout ---` and
`--- stderr ---` markers), and derive the byte-exact `source_path` token the
report header carries. This module imports NOTHING from `src/mtest/protocol`, so
it cannot bias the parser it feeds; the transcript smoke test does not import it
either, so the transcript oracle stays independent of the parser under test.

Not a test module (no `test_` prefix, so the runner never builds it as a suite);
it is imported via `-I tests/support`.
"""

comptime TX_DIR = "tests/snapshots/protocol/"


def read_snapshot(name: String) raises -> String:
    """Read a committed protocol snapshot by file name.

    Args:
        name: The transcript's file name under `tests/snapshots/protocol/`.

    Returns:
        The whole file's bytes as a String. Allocates.

    Raises:
        Error: If the file cannot be opened or read.
    """
    return open(TX_DIR + name, "r").read()


def read_manifest() raises -> List[String]:
    """The transcript names listed in `tests/snapshots/protocol/MANIFEST.txt`.

    One name per line, stripped, empty lines skipped — the same enumeration the
    transcript smoke test uses, so a snapshot present on disk but missing from the
    manifest cannot escape coverage. Reimplemented here (not imported from the
    smoke test) to keep the oracle independent.

    Returns:
        The manifest's file names in order. Allocates.

    Raises:
        Error: If the manifest cannot be opened or read.
    """
    var names = List[String]()
    for line in read_snapshot("MANIFEST.txt").split("\n"):
        var s = String(String(line).strip())
        if s.byte_length() > 0:
            names.append(s)
    return names^


def report_region(snapshot_text: String) -> String:
    """The section of a snapshot the session hands the report parser.

    A passing suite prints its report to stdout; a failing one raises it, and
    the runtime prints that to stderr. So a snapshot whose `termination:` line
    reads `exit 0` yields the lines strictly between `--- stdout ---` and
    `--- stderr ---`, and any other yields the lines after `--- stderr ---`,
    rejoined with `\\n` exactly as the session decodes a stream.

    Args:
        snapshot_text: A whole protocol snapshot's bytes.

    Returns:
        The report stream as one String. Allocates; never raises.
    """
    var lines = snapshot_text.split("\n")
    var passed = False
    var stdout_at = len(lines)
    var stderr_at = len(lines)
    for i in range(len(lines)):
        var line = String(lines[i])
        if line == "termination: exit 0":
            passed = True
        elif line == "--- stdout ---":
            stdout_at = i
        elif line == "--- stderr ---":
            stderr_at = i
            break
    var start = stdout_at + 1 if passed else stderr_at + 1
    var end = stderr_at if passed else len(lines)
    var out = String("")
    for i in range(start, end):
        if i > start:
            out += "\n"
        out += String(lines[i])
    return out


def source_path_for(snapshot_name: String) -> String:
    """The normalized fixture path token a snapshot's header carries.

    Derived independently of the parser from the snapshot's file name (the part
    before the `--` scenario separator is the fixture), so a test never asks the
    parser for the identity it is about to verify.

    Args:
        snapshot_name: A transcript file name like `passing--default.txt`.

    Returns:
        The normalized source-path token. Allocates; never raises.
    """
    var fixture = String(snapshot_name.split("--")[0])
    return "<REPO>/tests/fixtures/protocol/" + fixture + ".mojo"
