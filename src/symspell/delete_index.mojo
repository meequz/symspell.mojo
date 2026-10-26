"""The deletes index: delete hash -> term ids, stored CSR-style.

For each term, its deletes are all strings made by removing up to
`max_dictionary_edit_distance` codepoints from the first `prefix_length`
codepoints (docs/BEHAVIOR.md, 2.1). Each distinct delete hash is a bucket.
Buckets live in an open-addressing table; their term ids sit in one flat
`postings` array, slot by slot (CSR = compressed sparse row).

The index is built in two passes, so no per-bucket lists are allocated:
pass 1 counts postings per hash, pass 2 fills them in term id order.
"""

from std.sys.intrinsics import prefetch

from symspell._hash import hash_codepoints, hash_finish, hash_start, hash_step
from symspell._image import RECORD_HEADER, fingerprint

comptime EMPTY: UInt64 = 0
"""Slot hash value of an empty slot. `hash_codepoints` never returns it."""


def slot_count_for(items: Int) -> Int:
    """Table size for `items` keys: a power of two with load factor <= 0.75."""
    var slots = 8
    while slots * 3 < items * 4:
        slots *= 2
    return slots


def probe_start(h: UInt64, slots: Int) -> Int:
    return Int(h & UInt64(slots - 1))


# ===----------------------------------------------------------------------=== #
# Delete enumeration
# ===----------------------------------------------------------------------=== #


struct DeleteGenerator(Movable):
    """Enumerates the distinct delete hashes of terms, reusing its buffers."""

    var max_distance: Int
    var prefix_length: Int
    var hashes: List[UInt64]
    var _seen: List[UInt64]
    var _stamps: List[UInt32]
    var _generation: UInt32
    var _positions: List[Int]

    def __init__(out self, max_distance: Int, prefix_length: Int):
        self.max_distance = max_distance
        self.prefix_length = prefix_length
        self.hashes = List[UInt64]()
        self._seen = List[UInt64](length=64, fill=0)
        self._stamps = List[UInt32](length=64, fill=0)
        self._generation = 0
        self._positions = List[Int]()

    def generate(mut self, term: ImmSpan[UInt32, _]):
        """Fills `self.hashes` with the distinct delete hashes of `term`.

        Enumerates every set of up to `max_distance` positions to remove from
        the prefix and hashes the rest in one pass. Equal strings give equal
        hashes, which are removed; two distinct deletes with the same hash
        share one bucket anyway.
        """
        self.hashes.clear()
        self._generation += 1
        if self._generation == 0:
            for i in range(len(self._stamps)):
                self._stamps[i] = 0
            self._generation = 1
        var n = min(len(term), self.prefix_length)
        var text = term.unsafe_ptr()
        self._positions.resize(max(self.max_distance, 1), 0)
        var removed = self._positions.unsafe_ptr()
        for k in range(min(self.max_distance, n) + 1):
            for i in range(k):
                removed[unsafe_offset=i] = i
            while True:
                var h = hash_start()
                var next = 0
                for i in range(n):
                    if next < k and removed[unsafe_offset=next] == i:
                        next += 1
                    else:
                        h = hash_step(h, text[unsafe_offset=i])
                self._add(hash_finish(h, n - k))
                # Advance to the next k-subset of range(n).
                var j = k - 1
                while j >= 0 and removed[unsafe_offset=j] == n - k + j:
                    j -= 1
                if j < 0:
                    break
                removed[unsafe_offset=j] += 1
                for m in range(j + 1, k):
                    removed[unsafe_offset=m] = removed[unsafe_offset=m - 1] + 1

    def _add(mut self, h: UInt64):
        """Appends `h` to `hashes` unless this term already produced it."""
        if len(self.hashes) * 2 >= len(self._seen):
            self._grow()
        var mask = len(self._seen) - 1
        var seen = self._seen.unsafe_ptr()  # indices are masked: in range
        var stamps = self._stamps.unsafe_ptr()
        var i = Int(h) & mask
        while stamps[unsafe_offset=i] == self._generation:
            if seen[unsafe_offset=i] == h:
                return
            i = (i + 1) & mask
        seen[unsafe_offset=i] = h
        stamps[unsafe_offset=i] = self._generation
        self.hashes.append(h)

    def _grow(mut self):
        var size = len(self._seen) * 2
        self._seen = List[UInt64](length=size, fill=0)
        self._stamps = List[UInt32](length=size, fill=0)
        self._generation = 1
        var mask = size - 1
        for h in self.hashes:
            var i = Int(h) & mask
            while self._stamps[i] == self._generation:
                i = (i + 1) & mask
            self._seen[i] = h
            self._stamps[i] = self._generation


def is_delete_of(
    candidate: ImmSpan[UInt32, _],
    term: ImmSpan[UInt32, _],
    max_distance: Int,
    prefix_length: Int,
) -> Bool:
    """Whether `candidate` is one of `term`'s deletes (exact, no hashing).

    True if `candidate` is a subsequence of `term[:prefix_length]` that is at
    most `max_distance` codepoints shorter. Used to drop terms that share a
    bucket only because of a hash collision (docs/DECISIONS.md, D3).
    """
    var prefix_len = min(len(term), prefix_length)
    if (
        len(candidate) > prefix_len
        or prefix_len - len(candidate) > max_distance
    ):
        return False
    var n = len(candidate)
    if n == 0:
        return True
    var c = candidate.unsafe_ptr()
    var t = term.unsafe_ptr()
    var j = 0
    for i in range(prefix_len):  # i < len(term), j < n: no bounds checks needed
        if t[unsafe_offset=i] == c[unsafe_offset=j]:
            j += 1
            if j == n:
                return True
    return False


# ===----------------------------------------------------------------------=== #
# Tables
# ===----------------------------------------------------------------------=== #


struct HashCounter(Movable):
    """Open-addressing map: hash -> count, growing as needed (build pass 1)."""

    var hashes: List[UInt64]
    var counts: List[UInt32]
    var size: Int

    def __init__(out self, expected: Int = 0):
        var slots = slot_count_for(expected)
        self.hashes = List[UInt64](length=slots, fill=EMPTY)
        self.counts = List[UInt32](length=slots, fill=0)
        self.size = 0

    def prefetch(self, h: UInt64):
        """Starts loading the slot that `add(h, ...)` will look at first."""
        var i = probe_start(h, len(self.hashes))
        prefetch(self.hashes.unsafe_ptr().unsafe_offset(i))
        prefetch(self.counts.unsafe_ptr().unsafe_offset(i))

    def add(mut self, h: UInt64, amount: UInt32):
        """Adds `amount` to the count of `h`, inserting it if new."""
        var mask = len(self.hashes) - 1
        var i = probe_start(h, len(self.hashes))
        while self.hashes[i] != EMPTY and self.hashes[i] != h:
            i = (i + 1) & mask
        if self.hashes[i] == EMPTY:
            self.hashes[i] = h
            self.size += 1
        self.counts[i] += amount
        if self.size * 4 > len(self.hashes) * 3:
            self._grow()

    def _grow(mut self):
        var old_hashes = self.hashes^
        var old_counts = self.counts^
        var slots = len(old_hashes) * 2
        self.hashes = List[UInt64](length=slots, fill=EMPTY)
        self.counts = List[UInt32](length=slots, fill=0)
        var mask = slots - 1
        for k in range(len(old_hashes)):
            if old_hashes[k] == EMPTY:
                continue
            var i = probe_start(old_hashes[k], slots)
            while self.hashes[i] != EMPTY:
                i = (i + 1) & mask
            self.hashes[i] = old_hashes[k]
            self.counts[i] = old_counts[k]


@fieldwise_init
struct IdTable(Movable):
    """Open-addressing table: hash -> id. Equal hashes may occupy several slots.
    """

    var hashes: List[UInt64]
    var ids: List[UInt32]


def build_id_table(item_hashes: ImmSpan[UInt64, _]) -> IdTable:
    """Builds a table where `item_hashes[id]` maps to `id`."""
    var slots = slot_count_for(len(item_hashes))
    var hashes = List[UInt64](length=slots, fill=EMPTY)
    var ids = List[UInt32](length=slots, fill=0)
    var mask = slots - 1
    for item in range(len(item_hashes)):
        var h = item_hashes[item]
        var i = probe_start(h, slots)
        while hashes[i] != EMPTY:
            i = (i + 1) & mask
        hashes[i] = h
        ids[i] = UInt32(item)
    return IdTable(hashes^, ids^)


@fieldwise_init
struct DeleteTable(Movable):
    """The finished deletes index arrays."""

    var slots: List[UInt32]
    """(fingerprint, start) pairs, see `_image.DELETE_SLOTS`."""
    var slot_count: Int
    var postings: List[UInt32]
    var lengths: List[UInt8]
    var entry_count: Int


def record_text(
    records: ImmSpan[UInt32, _], offset: UInt32
) -> ImmSpan[UInt32, records.origin]:
    """The codepoints of the term record at `offset`."""
    var start = Int(offset) + RECORD_HEADER
    return records[start : start + Int(records[Int(offset)])]


def build_delete_table(
    records: List[UInt32],
    record_offsets: List[UInt32],
    ghost_codepoints: List[UInt32],
    ghost_offsets: List[UInt32],
    max_distance: Int,
    prefix_length: Int,
) raises -> DeleteTable:
    """Builds the deletes index over term records (see `_image.TERM_RECORDS`).

    Postings hold record offsets, in term id order within each bucket. Ghosts
    are deleted terms, as plain codepoints with offsets. Their deletes add
    (empty) buckets, so that `entry_count` matches symspellpy, which keeps such
    keys.
    """
    var generator = DeleteGenerator(max_distance, prefix_length)
    var counter = HashCounter(len(record_offsets) * 8)
    var all_records = Span(records)
    var ghosts = Span(ghost_codepoints)

    # Pass 1: count postings per delete hash. Each term's slots are
    # prefetched first, so the cache misses overlap.
    for offset in record_offsets:
        generator.generate(record_text(all_records, offset))
        for h in generator.hashes:
            counter.prefetch(h)
        for h in generator.hashes:
            counter.add(h, 1)
    for i in range(len(ghost_offsets) - 1):
        generator.generate(
            ghosts[Int(ghost_offsets[i]) : Int(ghost_offsets[i + 1])]
        )
        for h in generator.hashes:
            counter.add(h, 0)
    # Fold the exact hashes into the fingerprint table. Hashes that share a
    # fingerprint share a bucket; lookups verify every term anyway (D3).
    var entry_count = counter.size
    var slot_count = slot_count_for(entry_count)
    var mask = slot_count - 1
    var slots = List[UInt32](length=2 * (slot_count + 1), fill=0)
    var bucket_sizes = List[UInt32](length=slot_count, fill=0)
    for k in range(len(counter.hashes)):
        var h = counter.hashes[k]
        if h == EMPTY:
            continue
        var f = fingerprint(h)
        var i = Int(f) & mask
        while slots[2 * i] != 0 and slots[2 * i] != f:
            i = (i + 1) & mask
        slots[2 * i] = f
        bucket_sizes[i] += counter.counts[k]
    _ = counter^  # free it before pass 2
    var total = 0
    for i in range(slot_count):
        slots[2 * i + 1] = UInt32(total)
        total += Int(bucket_sizes[i])
    slots[2 * slot_count + 1] = UInt32(total)
    if total > Int(UInt32.MAX):
        raise Error("dictionary too large: more than 2**32 index postings")
    # Pass 2: fill postings in term id order.
    var cursor = List[UInt32](capacity=slot_count)
    for i in range(slot_count):
        cursor.append(slots[2 * i + 1])
    var postings = List[UInt32](length=total, fill=0)
    var lengths = List[UInt8](length=total, fill=0)
    var term_slots = List[Int]()
    for offset in record_offsets:
        var text = record_text(all_records, offset)
        var length = UInt8(min(len(text), 255))
        generator.generate(text)
        for h in generator.hashes:
            prefetch(
                slots.unsafe_ptr().unsafe_offset(
                    2 * (Int(fingerprint(h)) & mask)
                )
            )
        term_slots.clear()
        for h in generator.hashes:
            var slot = find_fingerprint(slots, mask, fingerprint(h))
            term_slots.append(slot)
            prefetch(cursor.unsafe_ptr().unsafe_offset(slot))
        for slot in term_slots:
            var at = Int(cursor[slot])
            postings[at] = offset
            lengths[at] = length
            cursor[slot] += 1
    return DeleteTable(slots^, slot_count, postings^, lengths^, entry_count)


def find_fingerprint(slots: ImmSpan[UInt32, _], mask: Int, f: UInt32) -> Int:
    """The slot holding fingerprint `f` in a (fingerprint, start) table, or -1.
    """
    var i = Int(f) & mask
    while True:
        var found = slots[2 * i]
        if found == f:
            return i
        if found == 0:
            return -1
        i = (i + 1) & mask
