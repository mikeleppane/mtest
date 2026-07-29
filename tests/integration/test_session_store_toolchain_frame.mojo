"""Integration tests for what an env base frames about the toolchain.

Split out of `test_session_store.mojo` on cost. Three of these stand up a stub
toolchain and are nearly free; the fourth,
`test_env_base_frames_the_compiler_selection_environment`, collects against the
real compiler three times over and is seconds of I/O on its own. It is kept
here rather than beside `test_env_base_enabled_for_default_config`, the other
test that keys the real toolchain, so no single suite carries both into one
per-file deadline. What they have in common as subjects is what this file is
named for: the toolchain is a build input, and the key has to say so.

Whether a config collects at all lives in `test_session_store_env_base.mojo`.
"""
from std.os import getenv, setenv, unsetenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from cache_fixtures import base_digest, chmod_path, env_base, executable_stub
from session_fixtures import base_config, write_file
from tmptree import temp_root


def test_env_base_frames_a_toolchain_without_a_library_directory() raises:
    """A layout with no `lib/mojo` beside the compiler keys, it does not fail.

    A `--mojo` spelling that names a wrapper script somewhere else in the tree
    is the ordinary case here, and nothing beside it looks like a toolchain.
    The compiler's own digest still identifies it, so the absence is a fact to
    record rather than a reason to switch the cache off.
    """
    var root = temp_root()
    var stub = executable_stub(root, "tc/bin/mojo")
    var config = base_config()
    config.mojo_path = stub
    var ctx = env_base(config^, root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)


def test_env_base_disables_when_the_toolchain_libraries_cannot_be_read() raises:
    """A library directory that will not open is a question, not an absence.

    The two have to lead in opposite directions: a toolchain with no library
    directory keys perfectly well, while one whose libraries this process
    cannot read is a build input the key cannot represent, so the cache goes
    off. A single `isdir` answers False to both, which let an unreadable
    directory key as though the toolchain shipped no libraries at all.

    The path is closed at the PARENT, which is what makes the case sharp: the
    directory can then be neither listed nor even stat'd, so nothing about the
    path itself can separate it from a directory that was never there.
    """
    var root = temp_root()
    var stub = executable_stub(root, "tc/bin/mojo")
    write_file(root, "tc/lib/mojo/std.mojopkg", "# stands in for a library")
    var config = base_config()
    config.mojo_path = stub
    chmod_path("000", root + "/tc/lib")
    var ctx = env_base(config^, root)
    chmod_path("755", root + "/tc/lib")
    assert_false(
        ctx.enabled, "an unreadable library directory must disable the cache"
    )
    assert_true(
        "lib/mojo" in ctx.disable_reason,
        "reason did not name the directory: " + ctx.disable_reason,
    )


def test_env_base_frames_every_entry_of_the_library_directory() raises:
    """What ships beside the compiler's packages is toolchain too.

    Framing only the two extensions the packages happen to use left the shared
    objects, resource files, and anything else a toolchain drops in that
    directory outside the key, so replacing one of them left every stored
    generation valid. An extension list is also a guess that goes stale the
    next time the toolchain ships something new.
    """
    var root = temp_root()
    var stub = executable_stub(root, "tc/bin/mojo")
    write_file(root, "tc/lib/mojo/std.mojopkg", "# stands in for a package")
    write_file(root, "tc/lib/mojo/libsupport.so", "# one")
    var config = base_config()
    config.mojo_path = stub
    var before = env_base(config^, root)
    assert_true(before.enabled, "cache off: " + before.disable_reason)

    # A different length as well as different bytes: the content digest is
    # memoized per process on the directory's total byte count, so a
    # same-length edit inside one process is the case that memo does not see.
    write_file(root, "tc/lib/mojo/libsupport.so", "# two, and longer")
    var second = base_config()
    second.mojo_path = stub
    var after = env_base(second^, root)
    assert_true(after.enabled, "cache off: " + after.disable_reason)
    assert_not_equal(
        base_digest(before),
        base_digest(after),
        "a library outside the package extensions must still be keyed",
    )

    # An entry appearing moves the key without anything being read: names and
    # types are framed on every collection.
    write_file(root, "tc/lib/mojo/extra.dat", "# three")
    var third = base_config()
    third.mojo_path = stub
    var grown = env_base(third^, root)
    assert_true(grown.enabled, "cache off: " + grown.disable_reason)
    assert_not_equal(base_digest(after), base_digest(grown))


def test_env_base_frames_the_compiler_selection_environment() raises:
    """A variable that picks a tool the compiler invokes belongs in the key.

    `MODULAR_NVPTX_COMPILER_PATH` selects the NVIDIA assembler, and a build
    child inherits it. Two runs that differ only there are not the same build,
    so a warm entry from one of them must not answer for the other.
    """
    var root = temp_root()
    var name = String("MODULAR_NVPTX_COMPILER_PATH")
    var was_set = getenv(name, "\x01unset") != "\x01unset"
    var saved = getenv(name, "")
    var digests = List[String]()
    try:
        _ = unsetenv(name)
        digests.append(base_digest(env_base(base_config(), root)))
        _ = setenv(name, "/opt/ptxas-here", True)
        digests.append(base_digest(env_base(base_config(), root)))
        _ = setenv(name, "/opt/ptxas-there", True)
        digests.append(base_digest(env_base(base_config(), root)))
    finally:
        if was_set:
            _ = setenv(name, saved, True)
        else:
            _ = unsetenv(name)
    assert_equal(len(digests), 3)
    assert_not_equal(digests[0], digests[1])
    assert_not_equal(digests[0], digests[2])
    assert_not_equal(digests[1], digests[2])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
