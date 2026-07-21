"""Disposable scratch paths and the module-cache quarantine, for `session`.

Layer 4 plumbing beneath the orchestration itself: the binary-name mangling, the
per-invocation and per-attempt directory naming, the recursive delete, and the
`MODULAR_CACHE_DIR` restore that the build, attempt, and precompile paths share.
Every entity here is pure path arithmetic, a filesystem operation, or an
environment restore — none of it knows about outcomes, events, or verdicts, so
it imports nothing from `mtest` and sits below every other module in the
package.
"""
from std.ffi import external_call
from std.os import listdir, makedirs, remove, rmdir, setenv, unsetenv
from std.os.path import basename, dirname, exists, isdir, islink, join


def _mangle(rel: String) -> String:
    """Return the injective binary name for a root-relative file path.

    Strips the `.mojo` suffix, then escapes every `_` as `_u` and every `/` as
    `_s`, passing all other characters through, so `tests/sub/test_a.mojo`
    becomes `tests_ssub_stest_ua`. Both escapes start with `_`, so a literal `_`
    never survives unescaped and no output is ambiguous between an escaped
    separator and a literal underscore. Two distinct root-relative paths
    therefore never mangle to the same name, unlike a naive `/`-to-`__`
    replacement, which collides `a/b.mojo` with the file `a__b.mojo`.

    Args:
        rel: Root-relative path to the test file.

    Returns:
        The mangled binary name.
    """
    var noext = String(rel.removesuffix(".mojo"))
    var out = String("")
    for cp in noext.codepoint_slices():
        if cp == "_":
            out += "_u"
        elif cp == "/":
            out += "_s"
        else:
            out += String(cp)
    return out


def _ensure_dir(path: String) raises:
    """Create `path` and any missing parents; a no-op if it already exists."""
    if not exists(path):
        makedirs(path)


def _restore_cache_env(had_prev: Bool, prev_cache: String) raises:
    """Restore `MODULAR_CACHE_DIR` to its pre-quarantine value (or unset it)."""
    if had_prev:
        _ = setenv("MODULAR_CACHE_DIR", prev_cache, True)
    else:
        _ = unsetenv("MODULAR_CACHE_DIR")


def _rmtree(path: String) raises:
    """Recursively remove `path` and everything under it; a no-op if absent.

    A symlink child is unlinked, never traversed (CWE-59). Recursing into a
    symlink-to-directory would delete the target's contents, so a symlink
    planted at a predictable temp or quarantine path under `build/` could let a
    failed compile's cleanup reach outside the build tree. `islink` is checked
    before `isdir` because `isdir` follows the link and would report a
    symlink-to-directory as a directory; only real directories are recursed
    into.

    Args:
        path: The directory to remove. It is listed before anything else
            happens, so a path naming a plain file is not a supported input.

    Raises:
        Error: If a listing or removal fails.
    """
    if not exists(path):
        return
    for name in listdir(path):
        var child = join(path, name)
        if islink(child):
            remove(child)
        elif isdir(child):
            _rmtree(child)
        else:
            remove(child)
    rmdir(path)


def _discard_path(path: String):
    """Delete one disposable build artifact, ignoring any failure.

    Used for a failed precompile attempt's temp package, which is litter not
    worth failing the session over.
    """
    try:
        _rmtree(path)
    except:
        pass


def _invocation_nonce() -> String:
    """Return a per-invocation token isolating this process's scratch dirs.

    Two mtest processes over one checkout — plausible with `mtest --shard 1/2`
    and `mtest --shard 2/2` in one tree — must never collide on a temp path
    one's compiler is writing, or on a quarantine cache the other's cleanup
    would delete. The process id is stable within a run and distinct across
    concurrent runs, so it keys each invocation's disposable directories apart.

    Returns:
        This process's id, as a decimal string.
    """
    # SAFETY: `getpid` takes no arguments and returns this process's id as an
    # Int32; there is nothing to misuse and the call cannot fail.
    var pid = external_call["getpid", Int32]()
    return String(Int(pid))


def _quarantine_dir(
    prefix: String, mangled: String, attempt_index: Int, nonce: String
) -> String:
    """Return the per-attempt quarantine cache directory under `build/`.

    A crash-class compile retry rebuilds against this fresh cache directory
    instead of the shared module cache. Keying on the invocation `nonce` as well
    as the mangled source and attempt keeps a concurrent mtest process's
    `_cleanup_quarantine` from deleting this invocation's live cache
    mid-rebuild.

    Args:
        prefix: `""` for a per-file build retry, `"precompile-"` for a
            precompile step.
        mangled: The mangled source name the retry is rebuilding.
        attempt_index: The attempt number this cache belongs to.
        nonce: The per-invocation token from `_invocation_nonce`.

    Returns:
        The root-relative quarantine directory path.
    """
    return (
        "build/quarantine/"
        + prefix
        + mangled
        + "/inv-"
        + nonce
        + "/attempt-"
        + String(attempt_index)
    )


def _retry_out_bin(
    mangled: String, attempt_index: Int, nonce: String
) -> String:
    """Return the binary path a crash-class build retry rebuilds into.

    Distinct per attempt, so a retry cannot inherit a killed attempt's bytes,
    and per invocation, so two concurrent mtest processes cannot write the same
    `.attempt-N` file under each other's compiler.

    Args:
        mangled: The mangled source name being rebuilt.
        attempt_index: The attempt number this binary belongs to.
        nonce: The per-invocation token from `_invocation_nonce`.

    Returns:
        The root-relative output binary path.
    """
    return (
        "build/bin/"
        + mangled
        + ".inv-"
        + nonce
        + ".attempt-"
        + String(attempt_index)
    )


def _precompile_temp_path(
    out_path: String, src: String, attempt_index: Int, nonce: String
) -> String:
    """Return the temp path one precompile attempt of `src` builds into.

    A hidden per-step, per-attempt `.tmp` directory beside the output path,
    holding the package under the output's own basename. Deriving it from the
    output path keeps the promotion a rename within one filesystem, so it is an
    atomic replace rather than a copy, and making it distinct per attempt keeps
    a retry from inheriting a killed attempt's half-written bytes.

    Keying on the mangled source and the per-invocation `nonce` as well as the
    attempt, symmetrically with the quarantine directory, keeps two steps, two
    concurrent mtest processes over one root, or a stale directory left by a
    SIGKILLed run from colliding on one temp directory and unlinking it under
    another compiler. The output path is safe either way: a lost temp fails its
    own step's promotion and never publishes.

    The enclosing directory is what hides an unpromoted attempt from the
    `-I <dir>` scan of the output directory. The temp cannot simply be
    `<out>.tmp`, because the pinned toolchain rejects a package output path not
    ending in `.mojopkg` or `.mojoc` — `mojo precompile -o x.tmp` is a hard
    error. Keeping the required extension and moving the file out of the scanned
    directory buys the same guarantee the suffix would have.

    Args:
        out_path: The final output path the step promotes onto.
        src: The precompile step's source, mangled into the directory name.
        attempt_index: The attempt number this temp path belongs to.
        nonce: The per-invocation token from `_invocation_nonce`.

    Returns:
        The temp package path, inside its hidden per-attempt directory.
    """
    var d = dirname(out_path)
    var tmp_dir = (
        ".mtest-precompile-"
        + _mangle(src)
        + ".inv-"
        + nonce
        + ".attempt-"
        + String(attempt_index)
        + ".tmp"
    )
    if d != "":
        tmp_dir = d + "/" + tmp_dir
    return tmp_dir + "/" + String(basename(out_path))


def _cleanup_quarantine(root: String, dirs: List[String]):
    """Delete every per-attempt quarantine cache directory, ignoring failures.

    A cleanup failure never fails the session, since the directories live under
    the disposable `build/` tree. The shared module cache is never touched.

    Args:
        root: The invocation root the directories are relative to.
        dirs: The root-relative quarantine directories to remove.
    """
    for d in dirs:
        try:
            _rmtree(root + "/" + d)
        except:
            pass
