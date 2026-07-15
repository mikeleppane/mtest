"""Golden-transcript loading helpers for the protocol parser tests.

Pure fixture plumbing shared by the `protocol` test modules: read a committed
golden, carve out its stdout section (the lines between the `--- stdout ---` and
`--- stderr ---` markers), and derive the byte-exact `source_path` token the
report header carries. This module imports NOTHING from `src/mtest/protocol`, so
it cannot bias the parser it feeds; the transcript smoke test does not import it
either, so the transcript oracle stays independent of the parser under test.

Not a test module (no `test_` prefix, so the runner never builds it as a suite);
it is imported via `-I tests`.
"""

comptime TX_DIR = "goldens/transcripts/"


def read_golden(name: String) raises -> String:
    """Read a committed golden transcript by file name.

    Args:
        name: The transcript's file name under `goldens/transcripts/`.

    Returns:
        The whole file's bytes as a String. Allocates.

    Raises:
        Error: If the file cannot be opened or read.
    """
    return open(TX_DIR + name, "r").read()


def read_manifest() raises -> List[String]:
    """The transcript file names listed in `goldens/transcripts/MANIFEST.txt`.

    One name per line, stripped, empty lines skipped — the same enumeration the
    transcript smoke test uses, so a golden present on disk but missing from the
    manifest cannot escape coverage. Reimplemented here (not imported from the
    smoke test) to keep the oracle independent.

    Returns:
        The manifest's file names in order. Allocates.

    Raises:
        Error: If the manifest cannot be opened or read.
    """
    var names = List[String]()
    for line in read_golden("MANIFEST.txt").split("\n"):
        var s = String(String(line).strip())
        if s.byte_length() > 0:
            names.append(s)
    return names^


def stdout_region(golden_text: String) -> String:
    """The captured-stdout section of a golden, rejoined with newlines.

    Carves out the lines strictly between the `--- stdout ---` and
    `--- stderr ---` markers and rejoins them with `\\n`, mirroring exactly what
    the session hands the parser (the child's decoded stdout, no envelope).

    Args:
        golden_text: A whole golden transcript's bytes.

    Returns:
        The stdout region as one String. Allocates; never raises.
    """
    var lines = golden_text.split("\n")
    var start = 0
    var end = len(lines)
    for i in range(len(lines)):
        if String(lines[i]) == "--- stdout ---":
            start = i + 1
        elif String(lines[i]) == "--- stderr ---":
            end = i
            break
    var out = String("")
    for i in range(start, end):
        if i > start:
            out += "\n"
        out += String(lines[i])
    return out


def source_path_for(golden_name: String) -> String:
    """The `<REPO>/fixtures/<fixture>.mojo` path token a golden's header carries.

    Derived independently of the parser from the golden's file name (the part
    before the `--` scenario separator is the fixture), so a test never asks the
    parser for the identity it is about to verify.

    Args:
        golden_name: A transcript file name like `passing--default.txt`.

    Returns:
        The normalized source-path token. Allocates; never raises.
    """
    var fixture = String(golden_name.split("--")[0])
    return "<REPO>/fixtures/" + fixture + ".mojo"
