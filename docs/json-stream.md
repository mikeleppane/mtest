# The `--json` machine event stream (v1)

This is the **normative** specification of the machine-readable event stream
mtest writes under `--json PATH` or `--json -`. It is the stable contract a CI
system or other tool consumes instead of parsing the informal console text. The
console reporter's layout is free to change; **this stream is not** — everything
below is frozen at stream `version` 1 except where the versioning rules (§11)
explicitly permit additive growth.

The stream is the machine twin of the console: it carries the *same* typed
events the session emits, one event per line. The console renders them as
English; this renders them as JSON.

---

## 1. Framing

The stream is **NDJSON**: a sequence of UTF-8 lines, each a single complete JSON
**object**, each terminated by a single `\n` (`U+000A`). There is no wrapping
array, no comma between records, no pretty-printing, and no blank line. Every
string value is valid, escaped UTF-8; a value that originates as raw
child-process bytes is decoded lossily to UTF-8 (invalid sequences become
`U+FFFD`) **before** escaping, so a record can never carry a raw control byte or
an unpaired surrogate.

The v1 stream carries **no floating-point values at all** — no `Infinity`,
`-Infinity`, or `NaN`, and no fractional number. Every quantity is an integer, a
boolean, a string, or an object/array of those. A strict consumer should
configure its JSON parser to *reject* the non-finite tokens and to *reject*
duplicate object keys; a well-formed record never produces either.

### 1.1 The header line

The **first** line of every stream is the header:

```json
{"event":"stream","version":1,"generator":"mtest <version>"}
```

`version` is the integer stream version (frozen at `1`). `generator` is
`"mtest "` followed by the mtest version string, JSON-escaped. The header is the
only record whose `event` is `stream`; every subsequent record is one session
event.

---

## 2. The events

Every record after the header opens with `"event":"<name>"` in `snake_case` and
then mirrors the landed event's payload fields **1:1** under their own names,
with a single naming exception (the `*_us` duration rule, §3). Closed-vocabulary
values (`outcome`, `parse_disposition`, `attribution_disposition`) serialize as
their frozen lowercase string **tokens**; counts, indices, and the termination
discriminants serialize as bare integers; booleans as `true`/`false`.

The event names, in the order they can appear (§7):

`session_started`, `warning`, `precompile_failed`, `file_started`,
`attempt_finished`, `file_finished`, `crash_attribution`, `collection_known`,
`internal_error`, `test_reported`, `session_finished`.

The model's `progress` kind is **not** on this list and never appears on the
wire: it is ephemeral and console-only, rendered live to a TTY counter and
never serialized. The stream reporter drops it before serialization, so a
consumer never sees a `progress` record and never a blank line in its place.

### 2.1 `session_started`

| field | type | notes |
|---|---|---|
| `root` | string | invocation root |
| `toolchain` | string | resolved compiler path |
| `selected_count` | int | files selected to run |
| `excluded_count` | int | files removed by `--exclude` |
| `shard_label` | string | e.g. `"2/5"`, or `""` when unsharded |
| `sharded_out_count` | int | files handed to other shards |
| `workers` | int | resolved worker count; `1` for a sequential run |

### 2.2 `warning`

| field | type | notes |
|---|---|---|
| `warning_kind` | string | e.g. `stale-exclusion`, `compile-kill-residual` |
| `warning_pattern` | string | the offending pattern / detail |

### 2.3 `precompile_failed`

| field | type | notes |
|---|---|---|
| `step` | string | the precompile source |
| `compiler_output` | string | head+tail bounded (§4) |
| `compiler_output_omitted_bytes` | int | omission metadata for the above |
| `casualty_count` | int | authoritative dependent-file count |
| `casualties` | array&lt;string&gt; | bounded list (§4) of dependent files |
| `casualties_omitted` | int | entries elided from `casualties` |
| `casualties_omitted_bytes` | int | bytes elided from the kept entries (§4) |
| `ending_known` | bool | whether `term_*` names a real ending |
| `term_kind` | int | termination discriminant (§6) |
| `term_value` | int | termination value (§6) |
| `escalated` | bool | SIGKILL escalation at the deadline |
| `timeout_us` | int | the enforced compile deadline (§3) |
| `attempts_used` | int | attempts the retry budget spent |

### 2.4 `file_started`

| field | type | notes |
|---|---|---|
| `path` | string | root-relative file path |

### 2.5 `attempt_finished`

One per **non-final** crash-class retry attempt (a `TRY` line on the console).

| field | type | notes |
|---|---|---|
| `path` | string | root-relative file path |
| `step` | string | `build`, `run`, or `precompile` |
| `attempt_index` | int | 1-based attempt number |
| `attempts_planned` | int | total planned attempts |
| `term_kind` | int | this attempt's termination discriminant (§6) |
| `term_value` | int | this attempt's termination value (§6) |
| `term_final_kind` | int | the FINAL disposition discriminant (§6) |
| `term_final_value` | int | the FINAL disposition value (§6) |
| `escalated` | bool | SIGKILL escalation |
| `retry_eligible` | bool | whether the failure class is retried |
| `classification` | string | the retry-class label |
| `duration_us` | int | attempt wall time (§3) |
| `captured_stdout` | string | bounded at capture; no omission field |
| `captured_stderr` | string | bounded at capture; no omission field |
| `stdout_truncated` | bool | capture-level overflow flag |
| `stderr_truncated` | bool | capture-level overflow flag |
| `attempt_argv` | array&lt;string&gt; | bounded list (§4) |
| `attempt_argv_omitted` | int | entries elided from `attempt_argv` |
| `attempt_argv_omitted_bytes` | int | bytes elided from the kept entries (§4) |

### 2.6 `file_finished`

The file's verdict.

| field | type | notes |
|---|---|---|
| `path` | string | root-relative file path |
| `outcome` | outcome token | §5 |
| `duration_us` | int | run wall time (§3) |
| `build_argv` | array&lt;string&gt; | bounded list (§4) |
| `build_argv_omitted` | int | entries elided from `build_argv` |
| `build_argv_omitted_bytes` | int | bytes elided from the kept entries (§4) |
| `build_duration_us` | int | build wall time (§3) |
| `captured_stdout` | string | head+tail bounded (§4) |
| `stdout_capture_bytes` | int | retained stdout bytes (pre-escape) |
| `stdout_stream_omitted_bytes` | int | bytes elided from the inlined window |
| `captured_stderr` | string | head+tail bounded (§4) |
| `stderr_capture_bytes` | int | retained stderr bytes (pre-escape) |
| `stderr_stream_omitted_bytes` | int | bytes elided from the inlined window |
| `stdout_truncated` | bool | capture-level overflow flag (authoritative) |
| `stderr_truncated` | bool | capture-level overflow flag (authoritative) |
| `signal_number` | int | terminating signal for a CRASH (else 0) |
| `exit_status` | int | exit code for a FAIL (else 0) |
| `timeout_us` | int | the enforced deadline for a TIMEOUT (§3) |
| `exclusion_pattern` | string | the pattern for an EXCLUDED file |
| `parse_disposition` | disposition token | §5 |
| `passed_tests` | int | per-test tally |
| `failed_tests` | int | per-test tally |
| `skipped_tests` | int | per-test tally |
| `deselected_tests` | int | per-test tally |
| `attempts_used` | int | attempts spent |
| `flaky` | bool | passed only after a crash-class retry |
| `slow` | bool | a step crossed the SLOW threshold |
| `escalated` | bool | SIGKILL escalation on a TIMEOUT |
| `serial` | bool | ran on the sequential path rather than a worker |

### 2.7 `crash_attribution`

Secondary diagnostic evidence for one crashed file; never a verdict.

| field | type | notes |
|---|---|---|
| `path` | string | root-relative file path |
| `attribution_disposition` | disposition token | §5 |
| `culprit_test` | string | the named culprit, when attributed |
| `isolation_reruns` | int | isolation reruns performed |
| `attribution_us` | int | attribution wall time (§3) |

### 2.8 `collection_known`

| field | type | notes |
|---|---|---|
| `selected_test_total` | int | selected tests |
| `deselected_test_total` | int | deselected tests |

### 2.9 `internal_error`

| field | type | notes |
|---|---|---|
| `step` | string | `build`, `run`, or `precompile` |
| `program` | string | the program mtest tried to spawn |
| `errno` | int | spawn errno, or 0 for a machinery failure |

### 2.10 `test_reported`

One per retrospective per-test row of a parsed report.

| field | type | notes |
|---|---|---|
| `path` | string | the file's root-relative path |
| `name` | string | the test name |
| `outcome` | outcome token | §5 |
| `detail` | string | head+tail bounded (§4) assertion detail |
| `detail_omitted_bytes` | int | bytes elided from `detail` |
| `timing` | string | the raw timing string |

### 2.11 `session_finished`

The single terminal record (§8).

| field | type | notes |
|---|---|---|
| `summary` | object | 13 outcome-token keys → int (see below) |
| `wall_time_us` | int | session wall time (§3) |
| `exit_code` | int | the exit code resolved at session end; the process exit is authoritative and may be escalated afterward (§9) |
| `test_counts` | object | `{passed,failed,skipped,deselected}` → int |
| `flaky_files` | int | files that passed only after a retry |

`summary` is a stable, fully-enumerated object of the 13 outcome tokens in
discriminant order:

```json
{"pass":N,"fail":N,"skip":N,"crash":N,"timeout":N,"compile_error":N,
 "compile_timeout":N,"malformed_suite":N,"precompile_error":N,"flaky":N,
 "deselected":N,"excluded":N,"not_run":N}
```

---

## 3. Durations: the `*_seconds` → `*_us` rule (the SOLE naming exception)

Every duration the model carries as `*_seconds` is emitted as an
integer-**microsecond** `*_us` field — the one place a serialized field name
differs from its model name — because the v1 stream carries no floats. The
conversion clamps a negative (or NaN) input to `0`, rounds half **away from
zero**, and saturates at `2**63 - 1`.

The `*_us` fields, exhaustively:

| field | kinds |
|---|---|
| `duration_us` | `file_finished`, `attempt_finished` |
| `build_duration_us` | `file_finished` |
| `wall_time_us` | `session_finished` |
| `attribution_us` | `crash_attribution` |
| `timeout_us` | `precompile_failed`, `file_finished` |

`timeout_us` is derived from an integer-second **configured** deadline (exact
`× 1_000_000`), not from a measured elapsed time; the other four are measured
wall times.

---

## 4. Bounds, omission metadata, and the worst-case line

Every variable-length field is **individually bounded** at serialization, so no
single field — and therefore no single line — can grow without limit. There is
no unbounded field anywhere in the stream.

| bounded field | bound | retained bytes (pre-escape) |
|---|---|---|
| `captured_stdout` / `captured_stderr` (`file_finished`) | 64 KiB head + 64 KiB tail | ≤ 131 075 each |
| `compiler_output`, `detail` | 64 KiB head + 64 KiB tail | ≤ 131 075 |
| `build_argv` / `attempt_argv` / `casualties` | 256 entries × 4 KiB head+tail | ≤ 1 049 344 |
| runner strings (`path`, `toolchain`, patterns, names, `timing`, …) | 3 KiB head + 1 KiB tail window | ≤ 4 099 |
| `captured_stdout` / `captured_stderr` (`attempt_finished`) | whole (clamped at capture) | ≤ 131 072 each |

A head+tail window keeps the first 64 KiB and the last 64 KiB with a visible
elision marker (`…`) between them.

**Derivable omission metadata.** A bounded field rides beside metadata a
consumer can use to detect and quantify elision — never an invented "original
total":

- `*_omitted_bytes` (`compiler_output_omitted_bytes`, `detail_omitted_bytes`,
  `stdout_stream_omitted_bytes`, `stderr_stream_omitted_bytes`) — bytes elided
  from an inlined text/stream window.
- `*_capture_bytes` (`stdout_capture_bytes`, `stderr_capture_bytes`) — the
  bytes actually retained by capture (pre-escape).
- `*_omitted` (`build_argv_omitted`, `attempt_argv_omitted`,
  `casualties_omitted`) — entries elided from a bounded list.
- `*_omitted_bytes` on a bounded LIST (`build_argv_omitted_bytes`,
  `attempt_argv_omitted_bytes`, `casualties_omitted_bytes`) — total bytes
  elided from the KEPT entries by the per-element 4 KiB bound, so per-element
  truncation of a user-supplied value (a long `build_argv` entry) is quantifiable,
  not just the count of whole entries dropped. A capped element itself is kept as
  a head+tail window with the visible elision marker (`…`) between, never a silent
  cut; the scalar runner strings use the same visible marker (a formality cap that
  carries no separate count, since their truncation is self-evident in the value).
- the capture-level truncation booleans (`stdout_truncated`,
  `stderr_truncated`) — the authoritative statement that capture itself
  overflowed, distinct from the serializer's own window elision.

**The real worst-case line.** Because each captured stream is bounded by a
64 KiB head **and** a 64 KiB tail, the worst-case single line is bounded but is
**not** under 1 MiB. A `file_finished` whose two captured streams are entirely
C0 control bytes escapes each retained 128 KiB window roughly six-fold (each
control byte becomes a `\u00XX` escape), to ≈ 0.77 MiB per stream — ≈ 1.5 MiB
from the two streams together — and a maximally-populated `build_argv`
(256 × 4 KiB, likewise escapable) adds more on top. The guarantee is that every
field is individually bounded, not that a pathological line stays under any
particular round number. Realistic lines are a few KiB.

---

## 5. Token vocabularies

`outcome` — one of:
`pass`, `fail`, `skip`, `crash`, `timeout`, `compile_error`, `compile_timeout`,
`malformed_suite`, `precompile_error`, `flaky`, `deselected`, `excluded`,
`not_run`.

`parse_disposition` — one of:
`parsed`, `no_report`, `ambiguous`, `drift`, `capture_overflow`.

`attribution_disposition` — one of:
`attributed`, `no_reproduction`, `probe_failed`, `run_cap`, `time_budget`.

These tokens are frozen at v1.

---

## 6. The termination discriminants (`term_*`)

`term_kind`, `term_value`, `term_final_kind`, and `term_final_value` are plain
**integers**, not tokens: the model carries a child's termination as a decomposed
integer pair, and the stream mirrors it so the record stays self-describing.

`term_kind` (and `term_final_kind`) vocabulary:

| value | meaning | `term_value` (and `term_final_value`) carries |
|---|---|---|
| `0` | **EXITED** | the process exit code |
| `1` | **SIGNALED** | the terminating signal number |
| `2` | **TIMED_OUT** | a deadline mtest enforced (value carries no code) |
| `3` | **SPAWN_FAILED** | the `errno` from a failed spawn |

On `attempt_finished`, the `term_*` pair is *this* attempt's raw termination and
the `term_final_*` pair is the disposition after any SIGKILL escalation.

---

## 7. Ordering

Informally, a stream reads as a timeline: the header, then the run begins, files
are built and run in scheduling order, and the session ends. Formally, these
**split invariants** are frozen:

**Per session:**
1. the `stream` header is line 1;
2. `session_started` is the first event;
3. every precompile attempt/warning and any `precompile_failed` precede any
   per-file event;
4. `crash_attribution` records (the bounded post-pass) follow every per-file
   verdict;
5. `session_finished` is **last** (§8).

**Per file:**
6. a file's `test_reported` rows are **contiguous** and immediately precede that
   file's `file_finished`;
7. a file's `attempt_finished` records appear in strictly increasing
   `attempt_index` order and all precede that file's `file_finished`.

The stream is otherwise the session's emission order.

---

## 8. Terminal semantics

The session **dispatches exactly one** `session_finished` event in every
scenario — a normal finish, an interrupt, or a fatal abort — carrying the final
resolved `exit_code`. The stream therefore carries **zero or one** parseable
terminal record:

- **one** on any stream that survived to finalization;
- **zero** (or a torn final fragment) on a stream whose destination died before
  the terminal was written.

That **absence is the truncation signal**, never a defect. A consumer that
reaches EOF without a `session_finished` record — or with a trailing fragment
that does not parse — knows the run was cut short (interrupted, killed, or its
destination went away), and should treat the run as incomplete rather than
assume success.

An interrupt (SIGINT/SIGTERM) during a run still ends the stream **with** the
terminal record and `exit_code` `2`.

---

## 9. Writing, truncation, and dead destinations

Each line is written to the destination through a **`write_all` loop** that
advances on a partial write and retries `EINTR`; the writer never assumes one
system call drains the buffer. A record is only *committed* when its terminating
`\n` is written, so a stream that is cut mid-write leaves complete lines plus **at
most one** torn (unterminated) final fragment — never a corrupt interior line.

`SIGPIPE` is **ignored** for the run's duration, so a write to a broken
destination pipe returns `EPIPE` instead of killing mtest. A latched write
failure on the stream — a `--json -` consumer that closed early (`mtest --json -
| head`), a full or unwritable file — is a **fatal abort**: mtest stops
scheduling, best-effort finalizes the other artifacts, and resolves exit **3**.
It never dies at 141, and it never runs to completion writing into a void.

When the stream is an **owned file destination** (`--json PATH`, not `-`), the
`session_finished` record carries the `exit_code` resolved at session end, then
that file is closed. A destination that defers its error to `close(2)` — an
`ENOSPC`/`EIO` a network filesystem reports only at close — is detected *after*
the terminal record is already committed, and **escalates the process exit to
3** (it never lowers a resolved `2`/`3`). So the committed record can read
`"exit_code": 0` while the process exits `3`: the **process exit status is
authoritative**, and a consumer that also cares about durability should treat a
nonzero process exit as overriding a `0` in the record. On `--json -` there is
no owned close, so this divergence cannot arise.

---

## 10. Determinism: the comparison projection

Two runs of the same inputs produce streams that are **equal under a closed
projection** — the projection a determinism check should compare, ignoring the
fields that legitimately vary run to run.

**Included** (deterministic; compare these):

- every `outcome`, `parse_disposition`, and `attribution_disposition` token;
- the per-test set from `test_reported` (`path`, `name`, `outcome`);
- the counts and totals (`passed_tests`/`failed_tests`/`skipped_tests`/
  `deselected_tests`, `test_counts`, the `summary` object, `selected_count`/
  `excluded_count`/`sharded_out_count`, `collection_known`);
- the boolean flags (`flaky`, `slow`, `escalated`, `retry_eligible`,
  `stdout_truncated`, `stderr_truncated`, `ending_known`);
- the casualty list (`casualties`) and `casualty_count`;
- `attempts_used`, `attempt_index`, `attempts_planned`, `flaky_files`;
- the configured `timeout_us` (derived from a config integer);
- the final `exit_code`.

**Excluded** (vary run to run; do NOT compare):

- every **measured** `*_us` duration: `duration_us`, `build_duration_us`,
  `wall_time_us`, `attribution_us`;
- every byte-payload field and its omission metadata: `captured_stdout`,
  `captured_stderr`, `compiler_output`, `detail`, together with
  `stdout_capture_bytes`, `stderr_capture_bytes`, `stdout_stream_omitted_bytes`,
  `stderr_stream_omitted_bytes`, `compiler_output_omitted_bytes`,
  `detail_omitted_bytes`, `build_argv`/`attempt_argv`/`casualties` byte content
  and their `*_omitted` counts;
- the `generator` string (carries the version label).

The excluded set is exactly the run-to-run-variable surface; everything else is
byte-stable for identical inputs.

---

## 11. Versioning

The stream is versioned by the single integer on the header line, and **only**
there. Version `1` freezes: the NDJSON framing, the header shape, every event
name, every field name and its meaning, the token vocabularies (§5), and the
termination discriminants (§6).

Growth within a major version is **additive only**: a later v1 stream may add
new fields to existing records and new event kinds. A consumer **MUST ignore**
unknown fields and unknown event kinds — that tolerance is the compatibility
contract, and a conforming consumer never rejects a record merely for carrying a
field or an `event` value it does not recognize. Any **removal** or
meaning-change of a frozen field, or a framing change, bumps the header
`version`.

---

## 12. A worked consumer skeleton

The following demonstrates the required discipline: strict where the format is
frozen, tolerant of unknown fields and kinds.

```python
import json

def _reject_non_finite(tok):
    raise ValueError(f"non-finite token forbidden in the v1 stream: {tok}")

def _reject_dupes(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError(f"duplicate key: {k}")
        out[k] = v
    return out

def consume(fileobj):
    records, terminal, torn = [], None, False
    header_seen = False
    pending = None            # a line not yet known to be newline-terminated
    for raw in fileobj:       # iterating yields lines WITH their trailing "\n"
        if not raw.endswith("\n"):
            torn = True        # a final fragment with no newline: truncation
            break
        line = raw[:-1]
        rec = json.loads(line, parse_constant=_reject_non_finite,
                         object_pairs_hook=_reject_dupes)
        if not header_seen:
            assert rec.get("event") == "stream" and rec.get("version") == 1
            header_seen = True
            continue
        kind = rec.get("event")
        if kind == "session_finished":
            assert terminal is None            # exactly one terminal
            terminal = rec
        elif kind == "file_finished":
            handle_verdict(rec)                # KNOWN fields only
        # ANY other 'kind' — including one this consumer has never heard of —
        # is silently ignored: that is the forward-compatibility contract.
    if terminal is None:
        report_truncated_run(torn)             # absence == truncation signal
    return records, terminal
```

The consumer reads unknown kinds without failing, treats a missing terminal as a
truncated run, and rejects the two things the format forbids (non-finite tokens,
duplicate keys). That is the whole contract.
