"""The cache layer of the mtest runner: in-session build and collection reuse.

A leaf data module: it performs no I/O and imports at most `model`. Its whole
job is to let `collect`, `probe`, and `run` share one build per file. The
session builds and probes, then records the results in the passive
`BuildRegistry` here.

Alongside it sits the pure SHA-256 primitive every persistent cache key is
built from — still no I/O: bytes in, hex digest out — plus the key framing,
generation naming, and meta-record format layered on top of it, which turn
digests into the names and validation records a cross-run store needs. The
import scanner is the same shape: source bytes in, module names out, and an
explicit refusal to answer for anything it cannot lex, which is what lets the
key be precise where it can prove precision is safe.

The public surface is re-exported so callers write
`from mtest.cache import ARG_FLAG, ARG_FILE_CANDIDATE, ARG_INCLUDE_DIR,
ARG_UNKNOWN, ArgClass, BuildProduct, BuildRegistry, ImportScan, KeyBuilder,
MetaFile, Sha256, classify_build_args, generation_name, scan_imports,
sha256_hex`.
"""
from mtest.cache.build_products import BuildProduct, BuildRegistry
from mtest.cache.imports import ImportScan, scan_imports
from mtest.cache.key import (
    ARG_FLAG,
    ARG_FILE_CANDIDATE,
    ARG_INCLUDE_DIR,
    ARG_UNKNOWN,
    KEY_FORMAT_TAG,
    META_HEADER,
    ArgClass,
    KeyBuilder,
    MetaFile,
    classify_build_args,
    generation_name,
)
from mtest.cache.sha256 import Sha256, sha256_hex
