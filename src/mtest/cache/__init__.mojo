"""The cache layer of the mtest runner: in-session build and collection reuse.

A leaf data module: it performs no I/O and imports at most `model`. Its whole
job is to let `collect`, `probe`, and `run` share one build per file. The
session builds and probes, then records the results in the passive
`BuildRegistry` here.

Alongside it sits the pure SHA-256 primitive every persistent cache key is
built from — still no I/O: bytes in, hex digest out — plus the key framing,
generation naming, and meta-record format layered on top of it, which turn
digests into the names and validation records a cross-run store needs.

The public surface is re-exported so callers write
`from mtest.cache import BuildProduct, BuildRegistry, KeyBuilder, MetaFile,
Sha256, generation_name, sha256_hex`.
"""
from mtest.cache.build_products import BuildProduct, BuildRegistry
from mtest.cache.key import KEY_FORMAT_TAG, META_HEADER, KeyBuilder, MetaFile
from mtest.cache.key import generation_name
from mtest.cache.sha256 import Sha256, sha256_hex
