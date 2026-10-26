"""Reusable per-thread lookup buffers.

A lookup needs a few buffers and two small sets. Keeping them in a
`LookupScratch` and reusing it means a lookup allocates nothing internally
once the buffers have grown to their working size. Sets are cleared in O(1)
by bumping a generation number instead of wiping their arrays.
"""

from symspell._hash import hash_codepoints
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
        return self.stamps[i] == self.generation

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
            if self.keys[i] == key:
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


struct LookupScratch(Movable):
    """Work buffers for `SymSpell.lookup`. Use one per thread."""

    var original: List[UInt32]
    var phrase: List[UInt32]
    var candidates: List[UInt32]
    var candidate_starts: List[Int]
    var current: List[UInt32]
    var delete: List[UInt32]
    var term: List[UInt32]
    var hits: List[Hit]
    var considered_deletes: _StampedSet
    var considered_terms: _StampedSet
    var osa: DamerauOsa
    var levenshtein: Levenshtein

    def __init__(out self):
        self.original = List[UInt32]()
        self.phrase = List[UInt32]()
        self.candidates = List[UInt32]()
        self.candidate_starts = List[Int]()
        self.current = List[UInt32]()
        self.delete = List[UInt32]()
        self.term = List[UInt32]()
        self.hits = List[Hit]()
        self.considered_deletes = _StampedSet()
        self.considered_terms = _StampedSet()
        self.osa = DamerauOsa()
        self.levenshtein = Levenshtein()

    def reset_candidates(mut self):
        self.candidates.clear()
        self.candidate_starts.clear()
        self.candidate_starts.append(0)
        self.considered_deletes.clear()
        self.considered_terms.clear()

    def candidate_count(self) -> Int:
        return len(self.candidate_starts) - 1

    def push_candidate(mut self, text: ImmSpan[UInt32, _]):
        self.candidates.extend(text)
        self.candidate_starts.append(len(self.candidates))

    def copy_original_to_phrase(mut self):
        self.phrase.clear()
        for cp in self.original:
            self.phrase.append(cp)

    def push_phrase_prefix(mut self, length: Int):
        """Adds the first `length` codepoints of `self.phrase` as a candidate.
        """
        for i in range(min(length, len(self.phrase))):
            self.candidates.append(self.phrase[i])
        self.candidate_starts.append(len(self.candidates))

    def load_candidate(mut self, k: Int):
        """Copies candidate `k` into `self.current`."""
        self.current.clear()
        for i in range(self.candidate_starts[k], self.candidate_starts[k + 1]):
            self.current.append(self.candidates[i])

    def add_delete_if_new(mut self) -> Bool:
        """Adds `self.delete` as a candidate unless it was seen before."""
        var h = hash_codepoints(self.delete)
        var i = self.considered_deletes.start(h)
        while self.considered_deletes.occupied(i):
            if self.considered_deletes.keys[i] == h and self._candidate_equals(
                self.considered_deletes.values[i]
            ):
                return False
            i = self.considered_deletes.next(i)
        var k = self.candidate_count()
        for cp in self.delete:
            self.candidates.append(cp)
        self.candidate_starts.append(len(self.candidates))
        self.considered_deletes.put(i, h, k)
        return True

    def _candidate_equals(self, k: Int) -> Bool:
        var start = self.candidate_starts[k]
        var end = self.candidate_starts[k + 1]
        if end - start != len(self.delete):
            return False
        for i in range(len(self.delete)):
            if self.candidates[start + i] != self.delete[i]:
                return False
        return True
