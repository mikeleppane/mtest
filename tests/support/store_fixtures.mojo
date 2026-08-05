"""Generation fixtures shared by the build-artifact store suites.

Not a test module (no `test_` prefix, so the runner never builds it as a suite);
it is imported via `-I tests/support`. It sits beside `cache_fixtures`, which
carries the byte-level writers and the recording session, and holds the four
things more than one store suite needs: a real key over real bytes, a staged
build target, the argv shape every build site emits, and a mutation the
filesystem is proven to have recorded.
"""
from std.os import lstat
from std.time import sleep

from mtest.session.scratch import _mangle
from mtest.session.store.artifact import (
    FileKey,
    StoreBuildTarget,
    file_key,
    store_build_target,
)
from mtest.session.store.context import CacheContext

from cache_fixtures import make_executable, write_bytes
from session_fixtures import write_file


def fixture_key(root: String, rel: String, body: String) raises -> FileKey:
    """Key a REAL source file at `root/rel`, so `src_sha` describes real bytes.

    The publication guard re-digests the source and compares it to `src_sha`,
    so a key built from an invented digest would fail every publish and prove
    nothing. The context is a bare `CacheContext`, whose `prefix` is an empty
    builder: the store protocol does not care what the session prefix covers,
    only that two different sources key differently, and skipping
    `collect_env_base` keeps each of these tests off the 141 MB toolchain
    digest.

    Args:
        root: The scratch root the source is written under.
        rel: The source's root-relative path; parent directories are created.
        body: The source text to write. Two calls with different bodies at the
            same `rel` produce two keys sharing a mangled prefix — which is
            exactly what the reaping test needs.

    Returns:
        The key a session would compute for that file.

    Raises:
        Error: If the source cannot be written or keyed.
    """
    write_file(root, rel, body)
    var ctx = CacheContext()
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return key.value().copy()


def stage_binary(root: String, payload: List[UInt8]) raises -> StoreBuildTarget:
    """Stage a build target and put `payload` exactly where `-o` would land.

    The staged file is given the execute bit, because that is what `mojo build`
    leaves at `-o` and what a generation has to carry to be runnable. A probe
    checks it, so a payload without it would stand in for something the compiler
    never produces and every publish-then-hit case here would miss.

    Args:
        root: The invocation root.
        payload: The bytes standing in for a compiled binary.

    Returns:
        The staging target, with its `bin` already written and executable.

    Raises:
        Error: If the store could not stage a target.
    """
    var target = store_build_target(root, _mangle("tests/test_staged.mojo"))
    if not target.ok():
        raise Error("test: store_build_target produced no staging directory")
    write_bytes(root, target.out_rel, payload)
    make_executable(root + "/" + target.out_rel)
    return target^


def build_argv(rel: String, out_rel: String) -> List[String]:
    """The shape every build site emits: `-o` and its path as two tokens."""
    var argv = List[String]()
    argv.append("mojo")
    argv.append("build")
    argv.append("-o")
    argv.append(String(out_rel))
    argv.append(String(rel))
    return argv^


def mutate_until_witnessed(path: String, data: String) raises:
    """Write `data` to `path` and prove the filesystem recorded a change.

    Timestamps may be quantized to multi-millisecond ticks, so a write landing
    in the same tick as a prior capture is invisible to a metadata comparison.
    Rewrite-and-wait until `lstat` shows movement against the state before this
    call, so every mutation here is one the publication guard can actually see —
    a fixture that mutates microseconds after the key was taken passes on a
    fine-grained filesystem and fails on a coarse one.

    Args:
        path: The absolute path to rewrite.
        data: The bytes to leave there. Rewriting the SAME bytes is the
            interesting case and works: size holds still while `ctime` moves.

    Raises:
        Error: If the path cannot be written, or if a second of rewriting never
            moved a single field — which would mean the comparison this suite
            relies on cannot see writes at all.
    """
    var before = lstat(path)
    for _ in range(200):
        with open(path, "w") as f:
            f.write(data)
        var now = lstat(path)
        if (
            Int(now.st_ctimespec.tv_sec) != Int(before.st_ctimespec.tv_sec)
            or Int(now.st_ctimespec.tv_subsec)
            != Int(before.st_ctimespec.tv_subsec)
            or Int(now.st_size) != Int(before.st_size)
        ):
            return
        sleep(0.005)
    raise Error("test: the filesystem never recorded the mutation")
