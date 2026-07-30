"""The discovery layer of the mtest runner.

`discover` turns the operands, gates, and exclude globs in a `RunnerConfig`
into the ordered set of files a session will run: the gate files, the run
files, the excluded files each paired with the pattern that excluded it, and
the exclude patterns that matched nothing. It reads the filesystem to walk
directories, but emits no events, prints nothing, and runs nothing. It returns
a `DiscoveryResult` data value the session turns into events.

Two policies are load-bearing and documented at their definitions:

- Lexical-only normalization. Operands are folded to root-relative form by text
  (`.` and `..` segments), never by resolving symlinks, so a reported path
  never depends on filesystem link state.
- Symlinks, by kind. A directory walk never descends a symlinked directory,
  because lexical normalization cannot detect a cycle; it collects a symlinked
  regular test file exactly like a real one, keeping the link's own path; and
  it refuses a dangling `test_*.mojo` link. Every refusal is reported, never
  silent.
- Walk totality. Each listed entry is characterized once by a raising `lstat`,
  so an entry that cannot be inspected refuses discovery rather than folding
  into an empty subtree, and a test-named entry that is not a runnable file is
  reported rather than dropped.
"""
from mtest.discover.discover import discover
from mtest.discover.fnmatch import fnmatch
from mtest.discover.normalize import normalize_operand, normalize_root
from mtest.discover.result import DiscoveryResult, ExcludedEntry
from mtest.discover.walk import is_discovered_test_name, walk_dir
