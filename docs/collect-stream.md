# The `collect --format json` stream (v1)

This is the **normative** specification of the machine-readable listing mtest
writes under `mtest collect --format json`. It is the stable contract a CI
system or an editor integration consumes instead of splitting the plain
listing's lines. The console's own text is free to change; **this stream is
not** — everything below is frozen at collect-stream `version` 1 except where
the versioning rules (§6) explicitly permit additive growth.

The stream is the collect listing's machine twin: it carries the *same* node
ids, in the *same* order, that `--format lines` prints one per line. The
default format renders them as bare text; this renders them as JSON, and adds
a header and a terminal the text format has no room for.

---

## 1. Framing

The stream is **NDJSON**: a sequence of UTF-8 lines, each a single complete
JSON **object**, each terminated by a single `\n` (`U+000A`). There is no
wrapping array, no comma between records, no pretty-printing, and no blank
line. Every string value is valid, escaped UTF-8.

The stream carries **no floating-point values at all** — no `Infinity`,
`-Infinity`, or `NaN`, and no fractional number. Every quantity is an integer
or a string. A strict consumer should configure its JSON parser to *reject* the
non-finite tokens and to *reject* duplicate object keys; a well-formed record
never produces either.

Two runs over the same inputs produce **byte-identical** streams — a stronger
promise than the run stream makes, because collection measures no wall clock
and reports no build-cache counters, so it has nothing that legitimately varies
between two runs (§5).

Diagnostics are **not** on this stream. A file that fails to compile, crashes,
times out, or reports off-grammar writes the same human text to **stderr**
under either format, and stdout carries only stream bytes. Both formats keep
that split, so a consumer piping stdout gets records and nothing else.

**Collection is expensive.** Producing this stream compiles every discovered
file and probes each one as a real process, serially. It is a command to run
when a test set changes, not a query to issue per keystroke; an integration
that calls it on every edit will spend a compiler run on every edit.

### 1.1 The header line

The **first** line of every stream is the header:

```json
{"event":"collect","version":1,"generator":"mtest x.y.z"}
```

`version` is the integer collect-stream version (frozen at `1`). `generator` is
`"mtest "` followed by the mtest version string, JSON-escaped. A consumer
**must not** pin `generator`: it moves with every release, and reading it as
anything but a diagnostic label breaks on the next one.

---

## 2. Events

Every record opens with `"event":"<name>"` in `snake_case`. Three names exist
at version 1: `collect`, `node`, and `collect_finished`.

### 2.1 `collect` — the header

| field | type | notes |
|---|---|---|
| `event` | string | always `collect`; the header is the only record with this kind |
| `version` | int | the collect-stream version, frozen at `1` |
| `generator` | string | `"mtest "` plus the version label; never pinned by a consumer |

### 2.2 `node` — one discovered test

One record per node id, in listing order.

| field | type | notes |
|---|---|---|
| `event` | string | always `node` |
| `node_id` | string | the canonical `path::name` identity, byte-identical to the line `--format lines` prints |
| `path` | string | the test file's root-relative path, exactly as discovered |
| `name` | string | the test function's bare name |

`node_id`, `path`, and `name` are derived from one splitting of one listing
entry, so `node_id` always equals `path` + `::` + `name`. A consumer may read
whichever of the three it needs without reconciling them.

`name` never contains `::`; it is a test function's bare identifier. That is
the wire-format rule, and the one a consumer may verify the triple against: a
`name` carrying a separator means the producer split `node_id` at the wrong
one, which concatenation alone cannot detect.

`path` is unconstrained by this format. As a property of **this** producer it
never carries `::` either, because §5 of the CLI contract refuses to collect a
file whose path does. Splitting `node_id` at its last separator is therefore
the rule to write, and against an mtest stream the first and the last are the
same separator anyway.

### 2.3 `collect_finished` — the terminal

| field | type | notes |
|---|---|---|
| `event` | string | always `collect_finished` |
| `nodes` | int | how many `node` records the stream carries |
| `exit_code` | int | **the final process exit code, teardown included** |

`exit_code` is not a provisional verdict that a later step may revise. Resource
teardown — which can still escalate a collection to the internal-error code —
runs *before* the first byte of this stream is written, so the value in this
record is the value the process exits with. A consumer may gate on it without
also reading `$?`, and the two can never disagree.

The collect exit codes are the runner's ordinary ones: `0` when everything
listed, `1` when a file failed to collect, `2` when the collection was
interrupted, `3` on protocol drift or an internal failure, `5` when nothing was
collectable, `4` for a usage error refused before any collection began. A usage
error produces **no stream at all**: the refusal goes to stderr and stdout stays
empty, so there is no header and no terminal to read.

`2` is worth expecting rather than treating as impossible. A `SIGINT` or
`SIGTERM` that arrives while files are still being probed ends the collection
where it stands, and the stream that follows is well-formed: a header, however
many `node` records the finished files produced, and a terminal reading
`{"event":"collect_finished","nodes":0,"exit_code":2}` when nothing had been
listed yet. A consumer that gates on `exit_code` therefore needs no separate
signal handling to notice it was cut short — but see §5 on truncation, which is
the different case where the terminal never arrives at all.

---

## 3. Ordering

1. the `collect` header is line 1;
2. every `node` record follows, in the listing's own **lexicographic** node-id
   order — the same order, byte for byte, that `--format lines` prints;
3. `collect_finished` is **last** (§4).

There is no other record kind at version 1, so the stream is exactly a header,
zero or more nodes, and a terminal.

---

## 4. Terminal semantics

A collection that reaches its end emits **exactly one** `collect_finished`
record. The stream therefore carries **zero or one** parseable terminal:

- **one** on any stream that ran to completion;
- **zero** (or a torn final fragment) on a stream whose destination died before
  the terminal was written.

That **absence is the truncation signal**, never a defect. A consumer that
reaches EOF without a `collect_finished` record — or with a trailing fragment
that does not parse — knows the listing was cut short, and should treat it as
incomplete rather than as an empty test set. A write failure after some bytes
were already emitted leaves complete lines plus at most one torn fragment: the
stream goes silent rather than lying about how many nodes there were.

Going silent is all that happens. `mtest` ignores `SIGPIPE` around every direct
write, so a consumer that closes the stream early — `mtest collect --format
json | head -1` — leaves the writer to absorb the `EPIPE` and exit with the
code §9 gives the collection. Death at signal 13, which a shell reports as 141,
is not a status this command can produce.

---

## 5. Determinism

Two runs of the same command over the same tree produce **byte-identical**
streams, the whole stream compared, with one exception: the header's
`generator` carries the release version, so streams from two different builds
differ there. Everything else — the node set, the node order, the `nodes`
count, and `exit_code` — is stable.

Nothing here needs a comparison projection. Collection reports no measured
duration, no captured child bytes, and no build-cache split, which are the
three families the run stream has to exclude from its own determinism claim.

---

## 6. Versioning

The stream is versioned by the single integer on the header line, and **only**
there. Version `1` freezes: the NDJSON framing, the header shape, every event
name, and every field name and its meaning.

Growth within a major version is **additive only**: a later v1 stream may add
new fields to existing records and new event kinds. A consumer **MUST ignore**
unknown fields and unknown event kinds — that tolerance is the compatibility
contract, and a conforming consumer never rejects a record merely for carrying
a field or an `event` value it does not recognize. Any **removal** or
meaning-change of a frozen field, or a framing change, bumps the header
`version`.

---

## 7. A worked consumer skeleton

The following demonstrates the required discipline: strict where the format is
frozen, tolerant of unknown fields and kinds.

```python
import json

def collected(fileobj):
    nodes, terminal, header = [], None, False
    for raw in fileobj:                # lines arrive WITH their trailing "\n"
        if not raw.endswith("\n"):
            break                      # a final fragment: the listing was cut
        if terminal is not None:
            raise ValueError("a record was committed after the terminal")
        record = json.loads(raw[:-1])
        kind = record.get("event")
        if not header:                 # the header is line 1, or there is none
            if kind != "collect" or record.get("version") != 1:
                raise ValueError(f"not a version-1 collect stream: {record!r}")
            header = True
            continue
        if kind == "collect":
            raise ValueError("a second header: two streams spliced together")
        if kind == "node":
            nodes.append(record["node_id"])
        elif kind == "collect_finished":
            terminal = record
        # ANY other kind — including one this consumer has never heard of —
        # is silently ignored: that is the forward-compatibility contract.
    if terminal is None:
        raise ValueError("the collection was truncated")
    return nodes, terminal["exit_code"]
```

The consumer validates the header and its version before anything else,
enforces a unique terminal that is genuinely last, treats a missing terminal as
a truncated listing, and still ignores unknown kinds and unknown fields. A
production consumer adds the two rejections the format forbids — non-finite
tokens and duplicate keys — and verifies each `node`'s triple, exactly as
`scripts/checks/reports/collect_stream.py` in this repository does; that module
is the reference reader this specification is checked against.
