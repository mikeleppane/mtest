"""The discovery layer of the mtest runner.

`discover` turns the operands, gates, and exclude globs in a `RunnerConfig`
into the concrete, ordered set of files a session will run: the gate files, the
run files, the excluded files each paired with the pattern that excluded it,
and the exclude patterns that matched nothing. It reads the filesystem to walk
directories, but emits no events, prints nothing, and runs nothing — it returns
a `DiscoveryResult` data value the session turns into events.

Two policies are load-bearing and documented at their definitions:

- Lexical-only normalization. Operands are folded to root-relative form by text
  (`.` and `..` segments), never by resolving symlinks, so a reported path
  never depends on filesystem link state.
- Symlink no-follow. Directory walks skip every symlink, whether it names a
  subdirectory or a file, because lexical normalization cannot detect a cycle.
"""
from mtest.discover.discover import discover
from mtest.discover.fnmatch import fnmatch
from mtest.discover.normalize import normalize_operand, normalize_root
from mtest.discover.result import DiscoveryResult, ExcludedEntry
from mtest.discover.walk import walk_dir
