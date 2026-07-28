"""Executable resolution with execve/PATH semantics: `resolve_executable`.

Part of the narrow platform-I/O boundary, Layer 0. The build-artifact cache
keys an artifact on WHICH compiler produced it, and the compiler is named by
`config.mojo_path`, whose default is the bare literal `"mojo"`
(`config/runner_config.mojo`, `config/mojo_path.mojo`). A bare name is not a
file, so nothing can be digested from it; the cache first has to answer the
question the kernel answers at `execve` time — given this spelling and this
environment, which file actually runs? `exec.source_identity_key` is no help:
it canonicalizes SOURCE paths and never performs a PATH search.

The answer must match the supervisor's own resolution byte for byte, because a
key that names a different file than the one that ran is worse than no key at
all: the cache would then serve artifacts built by another toolchain. The C
adapter (`native/mtest_exec_native.c`, `mtest_build_candidates`) builds its
candidate list exactly this way, and this module mirrors it:

- an `argv[0]` containing `/` is one candidate, taken verbatim and resolved
  against the process working directory — never PATH-searched;
- otherwise `PATH` is split on `:` into `separators + 1` components, tried in
  order, and an EMPTY component means the working directory, not "skip me".
  `"a::b"` is three components, the middle one being cwd. Collapsing it into
  two is the classic way to resolve the wrong binary.

Where the adapter then `execve`s each candidate and steps past `EACCES` and the
search misses, this module cannot spawn anything, so it asks `access(2)` the
same question instead: is this a regular file the caller may execute? The two
agree except under a race, and the first candidate that answers yes is the one
returned, canonicalized.

The single foreign call here is `access(2)`; nothing in the standard library at
the pinned toolchain answers the executability question (`std.os.path` offers
`exists`/`isfile`/`isdir` only, and `std.os.stat`'s `st_mode` would require
reimplementing the effective-uid/gid permission check by hand).
"""
from std.ffi import external_call
from std.os import getenv
from std.os.path import isfile, realpath

from mtest.platform.cstring import c_string_bytes


comptime _X_OK = Int32(1)
"""`access(2)`'s execute-permission bit.

`X_OK` is `1` on Linux and on Darwin alike, and POSIX fixes the value, so the
constant needs no per-target branch.
"""


def _is_executable_file(path: String) raises -> Bool:
    """Whether `path` is a regular file the caller is permitted to execute.

    Both halves are needed. `access(X_OK)` alone says yes for a DIRECTORY the
    caller may search, and `/usr/bin` is searchable by everyone, so a `PATH`
    component holding a subdirectory named `mojo` would otherwise resolve as the
    compiler. `isfile` alone says yes for a data file, which `execve` rejects
    with `EACCES` and the supervisor walks straight past.

    Args:
        path: The candidate path; may be relative, in which case it is resolved
            against the process working directory, exactly as `execve` would.

    Returns:
        True iff `path` names a regular file (symlinks followed) that the caller
        may execute.

    Raises:
        Error: If the underlying `isfile` query itself fails.
    """
    if not isfile(path):
        return False
    var c = c_string_bytes(path)
    # SAFETY: libc `access` has the exact ABI
    # `int access(const char*, int)` on both Linux and Darwin — a fixed arity of
    # two with no variadic tail, so the non-variadic call `external_call` emits
    # is the correct one on every target this runner builds for. The first
    # argument points at a complete, fully initialized NUL-terminated byte copy
    # this function uniquely owns: `c_string_bytes` allocates it here and nothing
    # else holds a reference, so provenance is local and the pointer aliases
    # nothing. `c` is still a live local at the call and is consumed only after
    # it returns, which keeps the pointer valid for the whole synchronous call;
    # it does not escape, because `access` is documented to read the path string
    # and retain nothing past its return, and it writes through the pointer not
    # at all. The bytes read stop at the terminator, inside the initialized
    # region. The mode is a plain scalar. The call has no side effect to unwind
    # and allocates nothing for the callee to free; on both the permitted and the
    # denied path the only cleanup is releasing the byte list, which Mojo does
    # when it is consumed below. The result is a plain scalar status, and every
    # nonzero value — `EACCES`, `ENOENT`, `ELOOP`, `ENOTDIR` — means the same
    # thing to this caller: not a candidate. `errno` is deliberately not read,
    # so no ordering constraint against the free exists.
    var rc = external_call["access", Int32](c.unsafe_ptr(), _X_OK)
    _ = c^
    return rc == 0


def _canonical_if_executable(candidate: String) raises -> Optional[String]:
    """The canonical path of `candidate` if it is executable, else nothing.

    Args:
        candidate: A candidate path, absolute or relative.

    Returns:
        `realpath(candidate)` when `candidate` is an executable regular file,
        otherwise `None`. A candidate that passes the executability check but
        whose canonicalization fails — it was unlinked in between, or a symlink
        loop appeared — also reads as `None`, because the resolver's contract is
        that a name it cannot pin down is a miss, not an error.

    Raises:
        Error: If the executability query itself fails.
    """
    if not _is_executable_file(candidate):
        return None
    try:
        return Optional(realpath(candidate))
    except:
        return None


def resolve_executable(
    spelling: String, path_env: Optional[String] = None
) raises -> Optional[String]:
    """Resolve `spelling` to the canonical file `execve` would run for it.

    Mirrors the candidate order `native/mtest_exec_native.c` builds, so the file
    this names is the file the supervisor spawns: a spelling containing `/` is
    taken verbatim against the working directory and never PATH-searched;
    otherwise every `PATH` component is tried left to right, an empty component
    meaning the working directory. The first candidate that is a regular file
    the caller may execute wins, and the result is canonicalized so that two
    spellings of one binary — `mojo`, `/usr/bin/mojo`, a symlink into a pixi
    environment — collapse to a single cache-key identity.

    Args:
        spelling: The program as written, for example `config.mojo_path`'s
            default literal `"mojo"`, or an absolute path.
        path_env: The `PATH` value to search, for injection from tests. Defaults
            to `None`, which reads the process environment through `getenv`, so
            production call sites pass one argument and get the real search
            path. An unset `PATH` reads as empty here, which is one cwd
            component; the C adapter falls back to `confstr(_CS_PATH)` in that
            case, so the two diverge only for a process launched with no `PATH`
            at all.

    Returns:
        The canonical absolute path of the first matching candidate, or `None`
        when no component holds an executable of that name. `None` is the
        ordinary "not found" answer and is never an error: an uninstalled
        compiler, a typo, and a data file shadowing the name on `PATH` all
        report it alike.

    Raises:
        Error: Only if a filesystem query fails outright while probing a
            candidate. A missing path, a permission denial, and a failed
            canonicalization are all answers, not failures.

    Examples:

    ```mojo
    from mtest.platform import resolve_executable

    # Production: the real PATH, one argument.
    var compiler = resolve_executable("mojo")
    if compiler:
        var identity = compiler.value()  # digest this file into the cache key

    # Tests: an injected PATH, no process environment touched.
    var stub = resolve_executable("tool", "/tmp/a:/tmp/b")
    ```
    """
    var search = path_env.value() if path_env else getenv("PATH", "")
    if "/" in spelling:
        return _canonical_if_executable(spelling)
    for component in search.split(":"):
        var directory = String(component)
        var candidate = (
            spelling if directory == "" else directory + "/" + spelling
        )
        var hit = _canonical_if_executable(candidate)
        if hit:
            return hit^
    return None
