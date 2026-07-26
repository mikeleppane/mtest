"""Bridge-shaped Python interop used only by the tomllib viability probe.

The function owns the complete Python-object boundary and returns a typed Mojo
value.  Merely importing this module must not initialize or map libpython.
"""

from std.python import Python


def parse_timeout(toml_text: String) raises -> Int:
    """Parse one TOML document through Python's stdlib and return its timeout.

    Args:
        toml_text: A TOML document containing an integer `run.timeout`.

    Returns:
        The parsed timeout as a native Mojo integer.

    Raises:
        Error: If Python initialization, `tomllib` import, parsing, lookup, or
            integer conversion fails.
    """
    var tomllib = Python.import_module("tomllib")
    var document = tomllib.loads(toml_text)
    return Int(py=document["run"]["timeout"])
