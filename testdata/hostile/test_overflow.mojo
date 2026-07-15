"""Known-outcome fixture: a binary that floods stdout past the capture bound.

Verdict FAIL (CAPTURE-OVERFLOW), exit-class 1. It prints well over the 8 MiB
per-stream capture bound and exits 0 with NO report block anywhere — so nothing
usable survives in the retained tail. The session sees the truncation marker,
reparses the tail, finds no valid block, and refuses to trust the run: a
truncated capture never yields a successful verdict. It is a FAIL under the
CAPTURE-OVERFLOW disposition, never a PASS and never a drift.

The flood is a ~13 MiB block so it exceeds the real, un-lowered capture bound
end to end; the tail-reparse policy itself is table-tested in the unit suite.
"""


def main():
    var chunk = String("x")
    for _ in range(16):  # double 16 times: a 64 KiB line
        var more = chunk.copy()  # a distinct value: `chunk += chunk` aliases
        chunk += more
    for _ in range(200):  # ~13 MiB total, well over the 8 MiB bound
        print(chunk)
