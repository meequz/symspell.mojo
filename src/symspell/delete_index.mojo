"""The deletes index: delete hash -> term ids, stored CSR-style.

For each term, its deletes are all strings made by removing up to
`max_dictionary_edit_distance` codepoints from the first `prefix_length`
codepoints (docs/BEHAVIOR.md, 2.1). Each distinct delete hash is a bucket.
Buckets live in an open-addressing table; their term ids sit in one flat
`postings` array, slot by slot (CSR = compressed sparse row).

The index is built in two passes, so no per-bucket lists are allocated:
pass 1 counts postings per hash, pass 2 fills them in term id order.
"""

from symspell._hash import hash_codepoints

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


def find_slot(hashes: ImmSpan[UInt64, _], h: UInt64) -> Int:
    """Returns the slot holding `h`, or -1. For tables with unique hashes."""
    var mask = len(hashes) - 1
    var i = probe_start(h, len(hashes))
    while True:
        var found = hashes[i]
        if found == h:
            return i
        if found == EMPTY:
            return -1
        i = (i + 1) & mask


# ===----------------------------------------------------------------------=== #
# Delete enumeration
# ===----------------------------------------------------------------------=== #


struct DeleteGenerator(Movable):
    """Enumerates the distinct delete hashes of terms, reusing its buffers."""

    var max_distance: Int
    var prefix_length: Int
    var hashes: List[UInt64]
    var _positions: List[Int]
    var _buffer: List[UInt32]

    def __init__(out self, max_distance: Int, prefix_length: Int):
        self.max_distance = max_distance
        self.prefix_length = prefix_length
        self.hashes = List[UInt64]()
        self._positions = List[Int]()
        self._buffer = List[UInt32]()

    def generate(mut self, term: ImmSpan[UInt32, _]):
        """Fills `self.hashes` with the distinct delete hashes of `term`.

        Enumerates every set of up to `max_distance` positions to remove from
        the prefix. Duplicate strings give duplicate hashes, which are removed.
        Two distinct deletes with the same hash share one bucket anyway.
        """
        self.hashes.clear()
        var prefix = term[: min(len(term), self.prefix_length)]
        var n = len(prefix)
        for k in range(min(self.max_distance, n) + 1):
            self._positions.clear()
            for i in range(k):
                self._positions.append(i)
            while True:
                self._emit(prefix)
                if not self._next_combination(n):
                    break
        sort(self.hashes)
        var unique = 0
        for i in range(len(self.hashes)):
            if i == 0 or self.hashes[i] != self.hashes[i - 1]:
                self.hashes[unique] = self.hashes[i]
                unique += 1
        self.hashes.resize(unique, 0)

    def _emit(mut self, prefix: ImmSpan[UInt32, _]):
        """Hashes `prefix` without the codepoints at `self._positions`."""
        self._buffer.clear()
        var p = 0
        for i in range(len(prefix)):
            if p < len(self._positions) and self._positions[p] == i:
                p += 1
            else:
                self._buffer.append(prefix[i])
        self.hashes.append(hash_codepoints(self._buffer))

    def _next_combination(mut self, n: Int) -> Bool:
        """Advances `self._positions` to the next k-subset of range(n)."""
        var k = len(self._positions)
        var i = k - 1
        while i >= 0 and self._positions[i] == n - k + i:
            i -= 1
        if i < 0:
            return False
        self._positions[i] += 1
        for j in range(i + 1, k):
            self._positions[j] = self._positions[j - 1] + 1
        return True


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
    var j = 0
    for i in range(prefix_len):
        if j < len(candidate) and term[i] == candidate[j]:
            j += 1
    return j == len(candidate)


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

    def take_hashes(deinit self) -> List[UInt64]:
        return self.hashes^

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

    var slot_hashes: List[UInt64]
    var slot_starts: List[UInt32]
    var postings: List[UInt32]
    var entry_count: Int


def build_delete_table(
    terms: List[List[UInt32]],
    ghosts: List[List[UInt32]],
    max_distance: Int,
    prefix_length: Int,
) raises -> DeleteTable:
    """Builds the deletes index for `terms` (term id = position).

    `ghosts` are deleted terms. Their deletes add (empty) buckets, so that
    `entry_count` matches symspellpy, which keeps such keys.
    """
    var generator = DeleteGenerator(max_distance, prefix_length)
    var counter = HashCounter(len(terms) * 8)
    # Pass 1: count postings per delete hash.
    for term in terms:
        generator.generate(term)
        for h in generator.hashes:
            counter.add(h, 1)
    for term in ghosts:
        generator.generate(term)
        for h in generator.hashes:
            counter.add(h, 0)
    var slots = len(counter.hashes)
    var starts = List[UInt32](capacity=slots + 1)
    var total = 0
    for i in range(slots):
        starts.append(UInt32(total))
        total += Int(counter.counts[i])
    starts.append(UInt32(total))
    if total > Int(UInt32.MAX):
        raise Error("dictionary too large: more than 2**32 index postings")
    # Pass 2: fill postings in term id order.
    var cursor = List[UInt32](starts[:slots])
    var postings = List[UInt32](length=total, fill=0)
    for term_id in range(len(terms)):
        generator.generate(terms[term_id])
        for h in generator.hashes:
            var slot = find_slot(counter.hashes, h)
            postings[Int(cursor[slot])] = UInt32(term_id)
            cursor[slot] += 1
    var entry_count = counter.size
    return DeleteTable(counter^.take_hashes(), starts^, postings^, entry_count)
