# A `--json` report option for `std.testing.TestSuite` — draft proposal

**Status: draft, unfiled.** This document is written as if addressed to the
Mojo stdlib maintainers, and lives in this repo as a record of the idea. It
has not been submitted, posted, or opened as an issue anywhere. Whether and
when it goes further than this file is a decision for the repo's maintainer
to make later, on its own timeline — this text makes no claim about that
decision either way.

## The case

`TestSuite` today emits one thing: a human-oriented text report, printed on
success and raised (as the payload of an "Unhandled exception" line) on
failure. That's a reasonable default for a person watching a terminal. It's
a much rougher deal for a tool that wants to consume the result
programmatically.

mtest is that tool, and a good chunk of its internals exist only because the
report is text meant for a person, not a machine. The protocol layer has to
byte-scan for a header line, find the last one that's actually followed by a
`Summary` (because a test's own `print` output can produce a lookalike
earlier in the stream), scan backward from the end for the terminal framing,
reconcile three independent counts against each other to catch a forged
extra row, and treat two well-formed report blocks back to back as an
attack rather than a coincidence. None of that complexity is incidental —
it's the direct cost of the report being designed for eyes, not for parsers.
A `--json` output wouldn't remove all of it (a tool still has to decide what
to do with a malformed or truncated stream), but it would remove the part
that's pure archaeology: finding the report in the first place, and
believing it's really there.

The benefit isn't just mtest's. Any tool that wants structured results —
an IDE test explorer, a CI dashboard, a coverage aggregator — is doing the
same screen-scraping today, or avoiding the problem by not integrating at
all. A stable, versioned event stream would be strictly easier for the
stdlib to keep working across releases than an implicit contract on exact
text formatting is, if the stdlib author wants to keep the text report's
wording flexible.

## An event-schema sketch

This is illustrative, not a specification. The goal is to show the shape of
what would help, drawn from the event vocabulary mtest already had to invent
on the *consuming* side (`src/mtest/model/events.mojo`) — a session-start, a
per-file start, per-test results, a per-file finish, and a session finish.
TestSuite operates within a single file, so its own natural scope is
narrower than mtest's, but the same idea applies: line-delimited JSON, one
event object per line, so a consumer can start reacting before the run
finishes rather than waiting for one giant document.

```jsonc
// One line per event, in the order they occur.

{"event": "suite_started", "path": "src/foo/test_bar.mojo", "test_count": 3}

{"event": "test_started", "name": "test_alpha"}

{"event": "test_finished", "name": "test_alpha", "outcome": "pass",
 "duration_seconds": 0.014}

{"event": "test_finished", "name": "test_beta", "outcome": "fail",
 "duration_seconds": 0.043,
 "detail": {"message": "`left == right` comparison failed",
            "left": "1", "right": "2",
            "location": {"line": 14, "col": 17}}}

{"event": "test_finished", "name": "test_gamma", "outcome": "skip"}

{"event": "suite_finished", "path": "src/foo/test_bar.mojo",
 "passed": 2, "failed": 1, "skipped": 1,
 "duration_seconds": 0.058}
```

A few properties worth calling out in a sketch like this, because they map
directly to problems mtest's text parser has to solve today:

- **One JSON object per line**, not one document for the whole run — so a
  long-running suite can be streamed and a consumer never has to guess
  whether the stream is "done" by watching for a terminal marker.
- **`outcome` is a closed, named set** (`pass` / `fail` / `skip`, and
  whatever native-skip and error cases the stdlib already distinguishes
  internally) rather than something a consumer infers from prose.
- **A `test_count` on `suite_started`** would let a consumer detect a
  truncated stream by comparing the declared count against how many
  `test_finished` events actually arrived — the JSON equivalent of the
  triple count-reconciliation mtest's text parser does by hand today.
- **Failure detail as structured fields** (message, both sides of a
  comparison, location) rather than an indented text blob a consumer has to
  re-parse, which is exactly what mtest's "verbatim, minus TestSuite's own
  indentation" rendering has to reconstruct from text now.

None of the field names, the event list, or the framing above should be
read as final. The actual design work — what belongs in v1, what's
reserved, how it interacts with native skip and with `discover_tests`,
whether it replaces or sits alongside the text report — is exactly the kind
of thing that would need to happen in the open with the stdlib maintainers,
not be pre-decided by an outside consumer.

## mtest does not, and will not, depend on this

To be explicit about the one thing that actually matters for this repo:
mtest's text-report parser is the supported path today and stays the
supported path regardless of what happens to this proposal. mtest was built
to work against the report format TestSuite actually ships, byte-attentive
corruption defenses included, and that remains true whether this idea is
never filed, filed and rejected, or filed and eventually shipped in some
different shape than sketched here. A `--json` output would be a nice-to-have
that lets mtest simplify its protocol layer someday; it is not, and will
never be treated as, a precondition for mtest working correctly.
