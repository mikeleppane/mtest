"""The build-artifact cache: what its key covers, when it switches itself off,
and the protocol that reads and writes the store.

Layer 4 (`session`). This package is where the persistent build cache touches
the world: it opens files, lists directories, canonicalizes paths, and spawns
one child, all through the Layer 0 `platform` boundary and the Layer 3 `exec`
supervisor. The framing it feeds — `KeyBuilder`, `Sha256`, the build-arg
grammar — is Layer 2 (`mtest.cache`) and stays pure; no read is ever pushed down
into it.

Two properties carry everything here.

**Fail closed.** A cache that is merely OFF costs a rebuild. A cache that is ON
when it should not be serves a stale binary and reports a green run that never
happened. So every question this package cannot answer resolves to
`ctx.disable(reason)`: an unrecognized build flag, a compiler that will not
resolve, a file that will not read, a directory that will not list. `disable` is
idempotent and the FIRST reason wins, because the first cause is the one the
user can act on; a later symptom would bury it.

**Frame order is the wire contract.** `KeyBuilder` frames each contribution as
tag bytes, one `0x00`, an eight-byte little-endian length, then the payload, so
the stream is self-delimiting and no payload can forge a boundary. What framing
does NOT do is make order irrelevant: two runs that feed the same facts in a
different order digest differently and lose every hit. The order is therefore
fixed, and changing it invalidates every stored key:

1. `KEY_FORMAT_TAG` — an empty-payload frame `KeyBuilder.__init__` writes.
2. Toolchain identity — the resolved compiler's canonical path, size, and
   content digest.
3. Toolchain version — the raw bytes of `<compiler> --version` on stdout.
4. Toolchain libraries — a count frame (or the absence marker), then one
   name-and-type frame per entry of `<compiler dir>/../lib/mojo` in byte order,
   then one frame holding the digest of every regular file among them.
5. Environment — `MODULAR_HOME`, `MODULAR_CACHE_DIR`, `MODULAR_DERIVED_PATH`,
   `MODULAR_NVPTX_COMPILER_PATH`, `XDG_CACHE_HOME`, each as a present-or-absent
   frame, in that order.
6. The canonical invocation root.
7. The classified build arguments, in command-line order.

The submodules, bottom up. `support` holds the leaf helpers the rest share,
including the byte ordering the wire contract depends on. `tags` holds the
complete tag namespace. `walk` turns trees into frames and witnesses that they
held still. `context` owns `CacheContext` and builds frames 1-7 and the include
frames on top of them. `filesystem` owns the cache root, its
deletion-authorization marker, and no-follow deletion. `artifact` owns per-file
keys and the stage/probe/publish/retain protocol. `stamps` owns precompile-step
stamps.

The public surface is re-exported here, so callers keep writing
`from mtest.session.store import CacheContext, file_key, store_probe`.
"""
from mtest.session.store.artifact import (
    PROBE_HIT,
    PUB_FAILED,
    PUB_OK,
    FileKey,
    StoreBuildTarget,
    _rewrite_output,
    file_key,
    store_build_target,
    store_probe,
    store_publish,
)
from mtest.session.store.context import (
    CacheContext,
    collect_env_base,
    finalize_includes,
)
from mtest.session.store.filesystem import (
    STORE_DIR,
    STORE_FAULT_ENV,
    cache_rebuild_note,
    clear_cache_root,
    ensure_cache_root,
    remove_tree_no_follow,
)
from mtest.session.store.stamps import (
    PRECOMPILE_SUBDIR,
    precompile_key,
    precompile_probe,
    precompile_publish,
)
