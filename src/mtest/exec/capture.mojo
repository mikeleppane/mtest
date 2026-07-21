"""Bounded per-stream capture with a head+tail truncation policy.

A supervised child can emit unbounded output, so capture is bounded in memory:
the first `head_cap` bytes and the last `tail_cap` bytes are always kept. Under
the bound (total <= head_cap + tail_cap) capture is byte-exact; nothing is lost
or reordered. Over the bound, the middle is dropped and a single-line marker is
spliced between the head and the surviving tail, naming how many bytes were
omitted.

The tail is retained deliberately: a later report parser anchors on the last
report block, so the end of the stream must never be the part that is dropped.
"""


struct BoundedCapture(Movable):
    """A memory-bounded byte sink keeping the head and tail of a stream.

    Bytes flow in through `push_byte`; `finish` materializes the retained bytes.
    Owns two backing lists: the head buffer and a tail ring. Construction
    validates the capacities before creating those lists, and can raise.
    """

    var head: List[UInt8]
    """The first `head_cap` bytes, in order."""
    var tail: List[UInt8]
    """A ring buffer of the most recent `tail_cap` post-head bytes."""
    var head_cap: Int
    """The maximum number of head bytes retained."""
    var tail_cap: Int
    """The maximum number of tail bytes retained."""
    var tail_start: Int
    """The ring index of the oldest tail byte once the ring has wrapped."""
    var tail_count: Int
    """How many bytes have entered the tail ring; may exceed `tail_cap`."""
    var total: Int
    """How many bytes have been pushed in total."""

    def __init__(out self, head_cap: Int, tail_cap: Int) raises:
        """Initialize a capture after validating both capacities.

        The two backing lists start empty and grow as bytes are pushed.

        Args:
            head_cap: Nonnegative number of leading bytes to retain.
            tail_cap: Positive number of trailing bytes to retain.

        Raises:
            Error: If `head_cap` is negative or `tail_cap` is nonpositive,
                naming the offending capacity and value.
        """
        if head_cap < 0:
            raise Error(
                "exec: head capacity must be nonnegative, got "
                + String(head_cap)
            )
        if tail_cap <= 0:
            raise Error(
                "exec: tail capacity must be positive, got " + String(tail_cap)
            )
        self.head = List[UInt8]()
        self.tail = List[UInt8]()
        self.head_cap = head_cap
        self.tail_cap = tail_cap
        self.tail_start = 0
        self.tail_count = 0
        self.total = 0

    def push_byte(mut self, b: UInt8):
        """Append one byte: into the head until it is full, then the tail ring.

        Once the tail ring is at `tail_cap` it overwrites its oldest byte, so
        pushing past the bound never grows memory further.

        Args:
            b: The next byte of the stream, in arrival order.
        """
        self.total += 1
        if len(self.head) < self.head_cap:
            self.head.append(b)
            return
        # Head is full: the byte belongs to the tail ring.
        if self.tail_count < self.tail_cap:
            self.tail.append(b)
        else:
            self.tail[self.tail_start] = b
            self.tail_start = (self.tail_start + 1) % self.tail_cap
        self.tail_count += 1

    def was_truncated(self) -> Bool:
        """True iff more bytes were pushed than the head+tail bound could keep.

        Equivalent to whether `finish()` splices the omission marker.
        """
        return self.total > self.head_cap + self.tail_cap

    def _tail_in_order(self) -> List[UInt8]:
        """The retained tail bytes, unwrapped from the ring, oldest first."""
        var out = List[UInt8]()
        if self.tail_count <= self.tail_cap:
            for i in range(len(self.tail)):
                out.append(self.tail[i])
        else:
            for i in range(self.tail_cap):
                out.append(self.tail[(self.tail_start + i) % self.tail_cap])
        return out^

    def finish(self) -> List[UInt8]:
        """Materialize the retained bytes, splicing a marker only if truncated.

        Under the bound the result is byte-exact; over the bound it is the head,
        a one-line omission marker, then the surviving tail.

        Returns:
            The retained bytes as a fresh list the caller owns.
        """
        if self.total <= self.head_cap:
            # Everything fit in the head: byte-exact.
            return self.head.copy()

        var tail_bytes = self._tail_in_order()
        if self.total <= self.head_cap + self.tail_cap:
            # No byte was ever dropped: head + tail reconstructs the stream.
            var out = self.head.copy()
            for i in range(len(tail_bytes)):
                out.append(tail_bytes[i])
            return out^

        # Truncated: splice a loud marker naming the omitted byte count.
        var omitted = self.total - self.head_cap - self.tail_cap
        var marker = (
            String("\n")
            + _marker_text(omitted, self.head_cap + self.tail_cap)
            + "\n"
        )
        var out = self.head.copy()
        var mbytes = marker.as_bytes()
        for i in range(len(mbytes)):
            out.append(mbytes[i])
        for i in range(len(tail_bytes)):
            out.append(tail_bytes[i])
        return out^


def _marker_text(omitted: Int, limit: Int) -> String:
    """The one-line truncation marker naming `omitted` bytes and the `limit`."""
    return (
        String("[mtest: output truncated — ")
        + String(omitted)
        + " bytes omitted, limit "
        + String(limit)
        + " bytes]"
    )
