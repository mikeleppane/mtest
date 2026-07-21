"""The cache layer of the mtest runner: in-session build and collection reuse.

A leaf data module: it performs no I/O and imports at most `model`. Its whole
job is to let `collect`, `probe`, and `run` share one build per file — the
session builds and probes, then records the results in the passive
`BuildRegistry` here.

The public surface is re-exported so callers write
`from mtest.cache import BuildProduct, BuildRegistry`.
"""
from mtest.cache.build_products import BuildProduct, BuildRegistry
