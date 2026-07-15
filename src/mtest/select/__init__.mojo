"""The selection layer of the mtest runner: pure operand + name selection.

`select` is the pure, filesystem-free logic of the SELECTION pipeline. It parses
raw operands into a per-file intent (Stage 1) and folds a file's collected test
universe together with that intent and the `-k` keyword into the selected and
deselected name partitions (Stage 3). It imports only `model`, performs no I/O,
and never runs anything: the session drives the probe/run/reconcile around it.

The public surface is re-exported here so callers write
`from mtest.select import parse_operands, select_from, ...`.
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
