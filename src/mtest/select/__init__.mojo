"""The selection layer of the mtest runner: operand and name selection.

`select` is the pure, filesystem-free logic of the selection pipeline. It
parses raw operands into a per-file intent, then folds a file's collected test
universe together with that intent and the `-k` keyword into the selected and
deselected name partitions. It imports only `model`, performs no I/O, and never
runs anything: the session drives the probe, run, and reconcile around it.
"""
from mtest.select.selection import (
    FileIntent,
    NamedTarget,
    OperandParse,
    SelectionResult,
    contains_ci,
    parse_operands,
    select_from,
    selection_active,
)
