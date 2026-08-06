"""The complete tag namespace, and the frame that spells a value's absence.

Layer 4 (`session`), inside `store`. Every tag any part of the store feeds is
declared here, and `cache_key_tags` returns exactly that set.

`KeyBuilder.feed` frames a contribution as the tag length, the tag bytes, the
payload length, then the payload, so no byte a tag or payload holds can forge a
boundary. What framing cannot separate is two contributions that choose the same
tag: `feed_file` derives `tag + ".size"` and `tag + ".sha"` from the base tag it
is given, so a base tag literally spelled `something.size` collides with another
tag's derived frames, as do two equal tags — either of which makes two different
builds key alike and serves a stale binary. Anyone adding a tag adds it in this
one place, and the suite re-checks the whole set.
"""
from mtest.cache import KEY_FORMAT_TAG, KeyBuilder


comptime TAG_TOOLCHAIN = "toolchain"
"""The resolved compiler, as a file frame (adds `.size` and `.sha`)."""

comptime TAG_TOOLCHAIN_VERSION = "toolchain-version"
"""The raw stdout bytes of `<compiler> --version`."""

comptime TAG_TOOLCHAIN_LIB_COUNT = "toolchain-lib-count"
"""How many entries the toolchain library directory holds, or `absent` for no
library directory at all."""

comptime TAG_TOOLCHAIN_LIB = "toolchain-lib"
"""One entry of the toolchain library directory, as `<st_mode type>:<name>`.

The type leads and is decimal digits terminated by the `:`, so a name can never
be read as part of it — an entry that turns from a regular file into a symlink
moves this frame even under an unchanged name. Every entry gets one, whatever
its type, so an added or removed entry moves the key without anything being
read.
"""

comptime TAG_TOOLCHAIN_LIB_CONTENT = "toolchain-lib-content"
"""The digest of every REGULAR file in that directory, folded in whole.

One frame rather than a file frame per library, because the digest is computed
once per process and reused: the directory is the same for every session in a
process, and reading it again per session would buy nothing. The sub-digest is
built from a file frame per regular entry, in the same byte order the entry
frames above use.
"""

comptime TAG_ENV_MODULAR_HOME = "env-MODULAR_HOME"
"""`MODULAR_HOME`, present-or-absent."""

comptime TAG_ENV_MODULAR_CACHE_DIR = "env-MODULAR_CACHE_DIR"
"""`MODULAR_CACHE_DIR`, present-or-absent."""

comptime TAG_ENV_MODULAR_DERIVED_PATH = "env-MODULAR_DERIVED_PATH"
"""`MODULAR_DERIVED_PATH`, present-or-absent."""

comptime TAG_ENV_MODULAR_NVPTX_COMPILER_PATH = "env-MODULAR_NVPTX_COMPILER_PATH"
"""`MODULAR_NVPTX_COMPILER_PATH`, present-or-absent."""

comptime TAG_ENV_XDG_CACHE_HOME = "env-XDG_CACHE_HOME"
"""`XDG_CACHE_HOME`, present-or-absent."""

comptime TAG_ROOT = "root"
"""The canonicalized invocation root."""

comptime TAG_ARG = "arg"
"""One classified build argument that hashes verbatim."""

comptime TAG_ARG_FILE = "argfile"
"""One build argument naming a file, as a file frame (adds `.size` and
`.sha`)."""

comptime TAG_INCLUDE = "include"
"""One include root, named as configured, before its walk."""

comptime TAG_WALK_FILE = "walkfile"
"""One file an include walk found, as a file frame (adds `.size` and `.sha`).
Its path is relative to the walked root, so the same tree keys alike wherever
it is checked out."""

comptime TAG_SOURCE = "source"
"""The test file being keyed, as a file frame (adds `.size` and `.sha`). What
distinguishes two files of one session that sit in the same directory."""

comptime TAG_SOURCE_DIR = "source-dir"
"""The directory the test file lives in, named relative to the invocation root.

The compiler resolves a bare `from helper import ...` against the SOURCE FILE'S
OWN DIRECTORY, with no `-I` involved, so that directory is a search path of
every build and what sits in it is a build input."""

comptime TAG_SOURCE_DIR_WALK = "source-dir-walk"
"""The digest of that directory's walk, folded in whole.

One frame rather than a `walkfile` frame per entry, because the walk is shared
by every test file in the directory and is therefore performed once for all of
them; its own digest is what gets forked into each file's key."""

comptime TAG_PRECOMPILE_STEP = "precompile-step"
"""One configured precompile step's source, named as configured, before its
walked closure. `precompile_key`'s only, and the frame that separates a step's
inputs from the include roots framed after them."""

comptime TAG_PRECOMPILE_OUT = "precompile-out"
"""One precompile step's output path, named as the compiler's `-o` receives it.

The spelling alone, never the contents: the output is what the step PRODUCES, so
digesting it would key the step on its own result.
"""

comptime TAG_PRECOMPILE_SRC = "precompile-src"
"""A precompile step's source when it is a single file, as a file frame (adds
`.size` and `.sha`). A directory source contributes `walkfile` frames instead."""

comptime TAG_PRECOMPILE_SRC_DIR = "precompile-src-dir"
"""The directory a single-file precompile source sits in, before its walk.

The compiler resolves a bare import against the source file's own directory, so
a module beside `lib/pkg.mojo` is compiled into the package that step produces
just as surely as the named file is. A directory source needs no such frame:
its own walk already covers everything beside it.
"""

comptime TAG_PRECOMPILE_PRIOR = "precompile-prior"
"""One earlier step's promoted output, as a file frame (adds `.size` and
`.sha`).

Earlier steps run first and their packages are on this step's include path, so
they are inputs to it. They are framed explicitly rather than left to the include
walk, because the walk covers a directory and a prior output can be excluded from
one — or sit somewhere the walk never reaches.
"""

comptime TAG_PRECOMPILE_INCLUDE_ABSENT = "precompile-include-absent"
"""One include root that did not exist yet when the step was keyed.

`precompile_key`'s only, and the frame that keeps a cold tree from switching the
whole cache off. A configured `-I build` is ordinarily created BY a precompile
step, so on a first run the directory genuinely is not there when the step is
keyed — and "not there" is a fact about the build, not a failure to read one.

It is a positive frame rather than silence because absent and present-but-empty
must not key alike: if the directory later exists with contents, the walk emits
`walkfile` frames where this run emitted this one, so the key differs and the
next run takes a MISS rather than a stale hit.
"""


def cache_key_tags() -> List[String]:
    """Every tag the cache key uses, including the one `KeyBuilder` feeds itself.

    Exposed so the suite can re-check the whole namespace for frame safety
    rather than trusting a comment. A new tag belongs in the `TAG_*` block above
    and in this list; there is no third place to look.

    Returns:
        The complete tag set, in declaration order. Derived `.size` / `.sha`
        frames are not listed: they are `feed_file`'s, not a call site's.

    Examples:

    ```mojo
    from mtest.session.store.tags import cache_key_tags

    for tag in cache_key_tags():
        pass  # assert it carries no NUL and ends in neither .size nor .sha
    ```
    """
    var tags: List[String] = [
        String(KEY_FORMAT_TAG),
        String(TAG_TOOLCHAIN),
        String(TAG_TOOLCHAIN_VERSION),
        String(TAG_TOOLCHAIN_LIB_COUNT),
        String(TAG_TOOLCHAIN_LIB),
        String(TAG_TOOLCHAIN_LIB_CONTENT),
        String(TAG_ENV_MODULAR_HOME),
        String(TAG_ENV_MODULAR_CACHE_DIR),
        String(TAG_ENV_MODULAR_DERIVED_PATH),
        String(TAG_ENV_MODULAR_NVPTX_COMPILER_PATH),
        String(TAG_ENV_XDG_CACHE_HOME),
        String(TAG_ROOT),
        String(TAG_ARG),
        String(TAG_ARG_FILE),
        String(TAG_INCLUDE),
        String(TAG_WALK_FILE),
        String(TAG_SOURCE),
        String(TAG_SOURCE_DIR),
        String(TAG_SOURCE_DIR_WALK),
        String(TAG_PRECOMPILE_STEP),
        String(TAG_PRECOMPILE_OUT),
        String(TAG_PRECOMPILE_SRC),
        String(TAG_PRECOMPILE_SRC_DIR),
        String(TAG_PRECOMPILE_PRIOR),
        String(TAG_PRECOMPILE_INCLUDE_ABSENT),
    ]
    return tags^


comptime _MARK_ABSENT = UInt8(0)
"""Leading payload byte of a present-or-absent frame for an unset value."""

comptime _MARK_PRESENT = UInt8(1)
"""Leading payload byte of a present-or-absent frame for a set value."""


def _feed_optional(mut kb: KeyBuilder, tag: String, value: Optional[String]):
    """Feed one present-or-absent frame.

    The payload leads with a marker byte, so an unset variable and one set to
    the empty string produce different payloads. The frame's length prefix
    already delimits, so the marker cannot be confused with value bytes.

    Args:
        kb: The builder to feed.
        tag: The contribution's name.
        value: The value, or `None` for "not set at all".
    """
    var payload = List[UInt8]()
    if value:
        payload.append(_MARK_PRESENT)
        var text = value.value()
        for b in text.as_bytes():
            payload.append(b)
    else:
        payload.append(_MARK_ABSENT)
    kb.feed(tag, payload)
