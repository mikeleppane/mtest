"""The discovery layer of the mtest runner (Layer 2).

`discover` turns the operands, gates, and exclude globs in a `RunnerConfig` into
the concrete, ordered set of files a session will run — the gate files, the
run files, the excluded files (with the pattern that excluded each), and the
stale exclude patterns that matched nothing. It READS the filesystem (it walks
directories) but emits no events, prints nothing, and runs nothing: it returns a
`DiscoveryResult` data value the session (a later layer) turns into events.

Two policies are load-bearing and documented at their definitions:

- **Lexical-only normalization.** Operands are folded to root-relative form by
  text (`.`/`..` segments), never by resolving symlinks — so a reported path
  never depends on filesystem link state (contract §2).
- **Symlink no-follow.** Directory walks never follow a symlink, because
  lexical normalization cannot detect a cycle; a symlinked subdirectory is not
  descended into.

The public surface is re-exported here so callers write
`from mtest.discover import discover, DiscoveryResult, ...`.
"""
from mtest.discover.discover import discover
from mtest.discover.fnmatch import fnmatch
from mtest.discover.normalize import normalize_operand, normalize_root
from mtest.discover.result import DiscoveryResult, ExcludedEntry
from mtest.discover.walk import walk_dir
