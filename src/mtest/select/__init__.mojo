"""The selection layer of the mtest runner: operand and name selection.

`selection` is the pure, filesystem-free logic of the selection pipeline. It
parses raw operands into a per-file intent, then folds a file's collected test
universe together with that intent and the `-k` keyword into the selected and
deselected name partitions. It imports only `model`, performs no I/O, and never
runs anything: the session drives the probe, run, and reconcile around it.

Its public surface is re-exported below. `failure_selection` holds the
last-failed filter and the failed-first ordering; it is pure as well, reads
`config` for the persisted records, and callers import it by its own path.
`shuffle` holds the deterministic `--shuffle` order randomizer, a pure leaf
with no dependency on the rest of this package; callers import it by its own
path too, `mtest.select.shuffle`.
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
