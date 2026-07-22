"""The shared C-string conversion: `c_string_bytes`.

Internal to the platform boundary. Every foreign call here that takes a
`const char*` needs the same thing — an owned, NUL-terminated byte copy of a
Mojo `String` that the caller keeps alive across the call — so the conversion is
written once instead of once per call site.

A copy rather than a borrow of the string's own buffer is deliberate: a Mojo
`String` is not guaranteed NUL-terminated, and appending the terminator to a
private `List` is what makes the pointer handed to libc a valid C string.
"""


def c_string_bytes(value: String) -> List[UInt8]:
    """Return an owned NUL-terminated byte copy of `value`.

    Args:
        value: The string to copy. Not mutated.

    Returns:
        The bytes of `value` followed by a single `0` terminator. Allocates the
        returned list, which the caller owns and must keep alive for as long as
        a pointer into it is in use.
    """
    var out = List[UInt8]()
    for b in value.as_bytes():
        out.append(b)
    out.append(0)
    return out^
