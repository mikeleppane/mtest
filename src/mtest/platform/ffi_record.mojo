"""`FfiRecord`: a zeroed, 8-byte-aligned byte record handed to foreign calls.

Every out-record and in-record mtest passes across a foreign ABI (`struct stat`,
the native adapter's spec, error, and result records) needs the same three
properties: 8-byte alignment, every byte initialized before C or Mojo reads it,
and release on every path. A `List[UInt64]` filled with zero gives all three, so
callers never allocate, zero, or free by hand. Typed field access is
bounds-checked here, the one place that reinterprets the record's bytes.
"""
from std.os import abort
from std.sys.info import size_of


struct FfiRecord(Movable):
    """A zero-initialized, 8-byte-aligned record owned by Mojo.

    The record's heap buffer never moves while the record is alive, so a
    pointer from `ptr()` stays valid across a move of the record itself.

    Examples:

    ```mojo
    from mtest.platform import FfiRecord

    var record = FfiRecord(bytes=16)
    record.store[UInt32](1, 7)
    var value = record.load[UInt32](1)  # 7
    ```
    """

    var _words: List[UInt64]

    def __init__(out self, *, bytes: Int):
        """Allocate `bytes` (rounded up to whole 8-byte words), all zero.

        Args:
            bytes: The record's ABI size in bytes; must be nonnegative.
        """
        self._words = List[UInt64](length=(bytes + 7) // 8, fill=0)

    def byte_length(self) -> Int:
        """The record's size in bytes, a whole number of 8-byte words.

        Returns:
            Eight times the word count.
        """
        return len(self._words) * 8

    def ptr(mut self) -> MutPointer[NoneType, MutAnyOrigin]:
        """The record's first byte as an opaque pointer for a foreign call.

        Returns:
            A pointer valid until the record is destroyed. The callee may
            write any byte within `byte_length()`.
        """
        # SAFETY: the list owns `len * 8` initialized, 8-aligned bytes whose
        # heap address is stable for the record's lifetime. Erasing the origin
        # drops the borrow checker's lifetime tracking, so every caller must
        # keep `self` alive for as long as the pointer is used: in a
        # synchronous foreign call, or stored in another record that is
        # destroyed no later than this one (see `_NativeBuffers`).
        return (
            self._words.unsafe_ptr()
            .unsafe_bitcast[NoneType]()
            .as_unsafe_any_origin()
        )

    def _check[T: TrivialRegisterPassable](self, index: Int):
        # Divide rather than multiply: `(index + 1) * size` can overflow.
        if index < 0 or index >= self.byte_length() // size_of[T]():
            abort("FfiRecord: field index out of bounds")

    def load[T: TrivialRegisterPassable](self, index: Int) -> T:
        """Read the `index`th `T`-sized field.

        Parameters:
            T: A fixed-width integer type of size 1, 2, 4, or 8.

        Args:
            index: The field index in units of `size_of[T]()`.

        Returns:
            The field's current value. Aborts if the field lies outside the
            record.
        """
        self._check[T](index)
        # SAFETY: `_check` keeps the field inside the initialized buffer, and
        # the buffer's 8-byte alignment covers every power-of-two `T` up to 8
        # at a `T`-sized index. Every bit pattern, zero and C-written alike, is
        # a valid value of the integer types callers read; no caller loads a
        # pointer.
        return self._words.unsafe_ptr().unsafe_bitcast[T]()[unsafe_offset=index]

    def store[T: TrivialRegisterPassable](mut self, index: Int, value: T):
        """Write the `index`th `T`-sized field.

        Parameters:
            T: A fixed-width integer or pointer type of size 1, 2, 4, or 8. A
                stored pointer must not outlive its target; see `ptr()`.

        Args:
            index: The field index in units of `size_of[T]()`.
            value: The value to write. Aborts if the field lies outside the
                record.
        """
        self._check[T](index)
        # SAFETY: as in `load`; the overwritten bytes are trivially
        # destructible scalars, so no destructor is skipped.
        self._words.unsafe_ptr().unsafe_bitcast[T]()[
            unsafe_offset=index
        ] = value
