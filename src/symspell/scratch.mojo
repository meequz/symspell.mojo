"""Reusable per-thread lookup buffers.

A lookup needs a few buffers and two small sets. Keeping them in a
`LookupScratch` and reusing it means a lookup allocates nothing internally
once the buffers have grown to their working size. Sets are cleared in O(1)
by bumping a generation number instead of wiping their arrays.
"""

from symspell._hash import hash_finish, hash_start, hash_step
from symspell.distance import DamerauOsa, Levenshtein


struct _StampedSet(Movable):
    """Open-addressing set of 64-bit keys with O(1) clear."""

    var keys: List[UInt64]
    var values: List[Int]
    var stamps: List[UInt32]
    var generation: UInt32
    var size: Int

    def __init__(out self):
        self.keys = List[UInt64](length=64, fill=0)
        self.values = List[Int](length=64, fill=0)
        self.stamps = List[UInt32](length=64, fill=0)
        self.generation = 1
        self.size = 0

    def clear(mut self):
        self.size = 0
        self.generation += 1
        if self.generation == 0:
            for i in range(len(self.stamps)):
                self.stamps[i] = 0
            self.generation = 1

    def start(self, key: UInt64) -> Int:
        return Int((key * 0x9E3779B97F4A7C15) >> 40) & (len(self.keys) - 1)

    def next(self, i: Int) -> Int:
        return (i + 1) & (len(self.keys) - 1)

    def occupied(self, i: Int) -> Bool:
        # `i` always comes from `start` or `next`, so it is in range.
        return self.stamps.unsafe_ptr()[unsafe_offset=i] == self.generation

    def key_at(self, i: Int) -> UInt64:
        return self.keys.unsafe_ptr()[unsafe_offset=i]

    def put(mut self, i: Int, key: UInt64, value: Int):
        """Stores at free slot `i` (found by probing), growing if needed."""
        self.keys[i] = key
        self.values[i] = value
        self.stamps[i] = self.generation
        self.size += 1
        if self.size * 2 > len(self.keys):
            self._grow()

    def insert_if_absent(mut self, key: UInt64) -> Bool:
        """Adds `key`; returns False if it was already present."""
        var i = self.start(key)
        while self.occupied(i):
            if self.key_at(i) == key:
                return False
            i = self.next(i)
        self.put(i, key, 0)
        return True

    def _grow(mut self):
        var old_keys = self.keys^
        var old_values = self.values^
        var old_stamps = self.stamps^
        var slots = len(old_keys) * 2
        self.keys = List[UInt64](length=slots, fill=0)
        self.values = List[Int](length=slots, fill=0)
        self.stamps = List[UInt32](length=slots, fill=0)
        for k in range(len(old_keys)):
            if old_stamps[k] != self.generation:
                continue
            var i = self.start(old_keys[k])
            while self.occupied(i):
                i = self.next(i)
            self.keys[i] = old_keys[k]
            self.values[i] = old_values[k]
            self.stamps[i] = self.generation


@fieldwise_init
struct Hit(ImplicitlyCopyable):
    """A lookup result before its term string is materialized."""

    var kind: Int
    var term_id: Int
    var distance: Int
    var count: Int

    comptime TERM = 0
    """A dictionary term (`term_id`)."""
    comptime PHRASE = 1
    """The (possibly lowercased) phrase."""
    comptime ORIGINAL = 2
    """The phrase exactly as given."""

    def precedes(self, other: Self) -> Bool:
        """Order of symspellpy: distance ascending, then count descending."""
        if self.distance == other.distance:
            return self.count > other.count
        return self.distance < other.distance


def sort_hits(mut hits: List[Hit], mut buffer: List[Hit]):
    """Stable merge sort, like Python's `list.sort` (ties keep their order)."""
    var n = len(hits)
    if n < 2:
        return
    buffer.resize(n, hits[0])
    var src = hits.unsafe_ptr()
    var dst = buffer.unsafe_ptr()
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            for k in range(lo, hi):
                # Take from the right only if it strictly precedes: stable.
                if j < hi and (
                    i >= mid
                    or src[unsafe_offset=j].precedes(src[unsafe_offset=i])
                ):
                    dst[unsafe_offset=k] = src[unsafe_offset=j]
                    j += 1
                else:
                    dst[unsafe_offset=k] = src[unsafe_offset=i]
                    i += 1
            lo += 2 * width
        for k in range(n):
            src[unsafe_offset=k] = dst[unsafe_offset=k]
        width *= 2


struct LookupScratch(Movable):
    """Work buffers for `SymSpell.lookup`. Use one per thread."""

    var original: List[UInt32]
    var phrase: List[UInt32]
    var candidates: List[UInt32]
    var candidate_starts: List[Int]
    var candidate_hashes: List[UInt64]
    var survivors: List[Int]
    var hits: List[Hit]
    var sort_buffer: List[Hit]
    var considered_deletes: _StampedSet
    var considered_terms: _StampedSet
    var osa: DamerauOsa
    var levenshtein: Levenshtein

    def __init__(out self):
        self.original = List[UInt32]()
        self.phrase = List[UInt32]()
        self.candidates = List[UInt32]()
        self.candidate_starts = List[Int]()
        self.candidate_hashes = List[UInt64]()
        self.survivors = List[Int]()
        self.hits = List[Hit]()
        self.sort_buffer = List[Hit]()
        self.considered_deletes = _StampedSet()
        self.considered_terms = _StampedSet()
        self.osa = DamerauOsa()
        self.levenshtein = Levenshtein()

    def set_phrase(mut self, text: ImmSpan[UInt32, _]):
        """Uses `text` as both the original and the search phrase."""
        self.original.clear()
        self.phrase.clear()
        for cp in text:
            self.original.append(cp)
            self.phrase.append(cp)

    def copy_original_to_phrase(mut self):
        self.phrase.clear()
        for cp in self.original:
            self.phrase.append(cp)

    # --- Candidates: deletes of the phrase prefix, stored back to back ---

    def reset_candidates(mut self):
        self.candidates.clear()
        self.candidate_starts.clear()
        self.candidate_starts.append(0)
        self.candidate_hashes.clear()
        self.considered_deletes.clear()
        self.considered_terms.clear()

    def candidate_count(self) -> Int:
        return len(self.candidate_hashes)

    def candidate(self, k: Int) -> ImmSpan[UInt32, ImmUntrackedOrigin]:
        """Candidate `k`. Valid until the next `add_deletes_of` call."""
        var start = self.candidate_starts[k]
        return ImmSpan[UInt32, ImmUntrackedOrigin](
            unsafe_ptr=self.candidates.unsafe_ptr()
            .as_imm()
            .unsafe_origin_cast[ImmUntrackedOrigin]()
            .unsafe_offset(start),
            length=self.candidate_starts[k + 1] - start,
        )

    def candidate_hash(self, k: Int) -> UInt64:
        return self.candidate_hashes[k]

    def push_phrase_prefix(mut self, length: Int):
        """Adds the first `length` codepoints of `self.phrase` as a candidate.
        """
        var n = min(length, len(self.phrase))
        var h = hash_start()
        for i in range(n):
            self.candidates.append(self.phrase[i])
            h = hash_step(h, self.phrase[i])
        self.candidate_starts.append(len(self.candidates))
        self.candidate_hashes.append(hash_finish(h, n))

    def add_deletes_of(mut self, k: Int):
        """Adds each one-codepoint delete of candidate `k` not seen before.

        Deletes are written straight into the candidate buffer and hashed while
        they are copied. A delete seen before is rolled back.
        """
        var start = self.candidate_starts[k]
        var n = self.candidate_starts[k + 1] - start
        # Enough room for all n deletes, so the buffer does not move while we
        # read candidate `k` from it.
        self.candidates.reserve(len(self.candidates) + n * n)
        var source = self.candidates.unsafe_ptr().unsafe_offset(start)
        for i in range(n):
            var out = len(self.candidates)
            var h = hash_start()
            for j in range(n):
                if j != i:
                    var cp = source[unsafe_offset=j]
                    self.candidates.append(cp)
                    h = hash_step(h, cp)
            h = hash_finish(h, n - 1)
            var slot = self._find_delete(h, out, n - 1)
            if slot < 0:
                self.candidates.resize(out, 0)  # seen before
                continue
            self.considered_deletes.put(slot, h, self.candidate_count())
            self.candidate_starts.append(len(self.candidates))
            self.candidate_hashes.append(h)

    def _find_delete(self, h: UInt64, start: Int, length: Int) -> Int:
        """Returns a free slot for a new delete, or -1 if it was seen before.

        The delete is `candidates[start:start + length]`.
        """
        ref seen = self.considered_deletes
        var i = seen.start(h)
        while seen.occupied(i):
            if seen.key_at(i) == h:
                var other = seen.values[i]
                var other_start = self.candidate_starts[other]
                if self.candidate_starts[other + 1] - other_start == length:
                    var p = self.candidates.unsafe_ptr()
                    var same = True
                    for c in range(length):
                        if (
                            p[unsafe_offset=other_start + c]
                            != p[unsafe_offset=start + c]
                        ):
                            same = False
                            break
                    if same:
                        return -1
            i = seen.next(i)
        return i
