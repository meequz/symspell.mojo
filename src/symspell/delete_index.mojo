"""The deletes index: delete hash -> term ids, stored CSR-style.

For each term, its deletes are all strings made by removing up to
`max_dictionary_edit_distance` codepoints from the first `prefix_length`
codepoints (docs/BEHAVIOR.md, 2.1). Each distinct delete hash is a bucket.
Buckets live in an open-addressing table; their term ids sit in one flat
`postings` array, slot by slot (CSR = compressed sparse row).

The build (`build_delete_table`) works on flat arrays, so no per-bucket lists
are allocated: it generates every delete hash, collects the distinct ones,
builds the table, then sorts (slot, term) keys so the buckets come out back
to back. Most stages run on several threads; the result does not depend on
their number (docs/DECISIONS.md, D20).
"""

from std.sys.intrinsics import prefetch

from symspell._hash import hash_codepoints, hash_finish, hash_start, hash_step
from symspell._image import RECORD_HEADER, fingerprint
from symspell._threads import run_threads

comptime EMPTY: UInt64 = 0
"""Slot hash value of an empty slot. `hash_codepoints` never returns it."""


comptime _MIN_TERMS_PER_THREAD = 4096
"""Below this many terms per thread, extra threads cost more than they save."""

comptime _MIN_KEYS_PER_THREAD = 65536
"""Below this many keys per thread, extra threads cost more than they save."""

comptime _AHEAD = 16
"""How many items ahead the build loops prefetch."""


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
    """Enumerates the delete hashes of terms, reusing its buffers."""

    var max_distance: Int
    var prefix_length: Int
    var hashes: List[UInt64]
    var _positions: List[Int]
    var _prefix_hashes: List[UInt64]

    def __init__(out self, max_distance: Int, prefix_length: Int):
        self.max_distance = max_distance
        self.prefix_length = prefix_length
        self.hashes = List[UInt64]()
        self._positions = List[Int]()
        self._prefix_hashes = List[UInt64]()

    def generate(mut self, term: ImmSpan[UInt32, _]):
        """Fills `self.hashes` with the delete hashes of `term`.

        Enumerates every set of up to `max_distance` positions to remove from
        the prefix and hashes the rest. Hashing starts from the stored hash of
        the part before the first removed position. A delete that several
        position sets make (as in "letter") appears once per set; the build
        removes such repeats after sorting (`build_delete_table`).
        """
        self.hashes.clear()
        var n = min(len(term), self.prefix_length)
        var text = term.unsafe_ptr()
        self._positions.resize(max(self.max_distance, 1), 0)
        var removed = self._positions.unsafe_ptr()
        self._prefix_hashes.resize(n + 1, 0)
        var prefix = self._prefix_hashes.unsafe_ptr()
        prefix[] = hash_start()
        for i in range(n):
            prefix[unsafe_offset=i + 1] = hash_step(
                prefix[unsafe_offset=i], text[unsafe_offset=i]
            )
        self.hashes.append(hash_finish(prefix[unsafe_offset=n], n))
        for k in range(1, min(self.max_distance, n) + 1):
            for i in range(k):
                removed[unsafe_offset=i] = i
            while True:
                var first = removed[]
                var h = prefix[unsafe_offset=first]
                var next = 1
                for i in range(first + 1, n):
                    if next < k and removed[unsafe_offset=next] == i:
                        next += 1
                    else:
                        h = hash_step(h, text[unsafe_offset=i])
                self.hashes.append(hash_finish(h, n - k))
                # Advance to the next k-subset of range(n).
                var j = k - 1
                while j >= 0 and removed[unsafe_offset=j] == n - k + j:
                    j -= 1
                if j < 0:
                    break
                removed[unsafe_offset=j] += 1
                for m in range(j + 1, k):
                    removed[unsafe_offset=m] = removed[unsafe_offset=m - 1] + 1


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


struct HashSet(Movable):
    """Open-addressing set of hashes, growing as needed (build pass 1)."""

    var hashes: List[UInt64]
    var size: Int

    def __init__(out self, expected: Int = 0):
        self.hashes = List[UInt64](length=slot_count_for(expected), fill=EMPTY)
        self.size = 0

    def prefetch(self, h: UInt64):
        """Starts loading the slot that `insert(h)` will look at first."""
        var i = probe_start(h, len(self.hashes))
        prefetch(self.hashes.unsafe_ptr().unsafe_offset(i))

    def insert(mut self, h: UInt64):
        var mask = len(self.hashes) - 1
        var hashes = self.hashes.unsafe_ptr()  # indices are masked: in range
        var i = probe_start(h, len(self.hashes))
        while hashes[unsafe_offset=i] != EMPTY and hashes[unsafe_offset=i] != h:
            i = (i + 1) & mask
        if hashes[unsafe_offset=i] == EMPTY:
            hashes[unsafe_offset=i] = h
            self.size += 1
            if self.size * 4 > len(self.hashes) * 3:
                self._grow()

    def _grow(mut self):
        var old = self.hashes^
        var slots = len(old) * 2
        self.hashes = List[UInt64](length=slots, fill=EMPTY)
        var hashes = self.hashes.unsafe_ptr()
        var mask = slots - 1
        for h in old:
            if h == EMPTY:
                continue
            var i = probe_start(h, slots)
            while hashes[unsafe_offset=i] != EMPTY:
                i = (i + 1) & mask
            hashes[unsafe_offset=i] = h


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
    threads: Int,
) raises -> DeleteTable:
    """Builds the deletes index over term records (see `_image.TERM_RECORDS`).

    Postings hold record offsets, in term id order within each bucket, each
    term at most once per bucket. Ghosts are deleted terms, as plain
    codepoints with offsets. Their deletes add (empty) buckets, so that
    `entry_count` matches symspellpy, which keeps such keys. The work runs on
    up to `threads` threads (at least 1).
    """
    var term_count = len(record_offsets)

    # Generate every posting's delete hash, in term order:
    # `keys[ends[t - 1] : ends[t]]` for term t. The same array later holds
    # the (slot, term) sort keys.
    var keys = List[UInt64]()
    var ends = List[UInt32]()
    _generate_deletes(
        records,
        record_offsets,
        max_distance,
        prefix_length,
        threads,
        keys,
        ends,
    )
    var total = len(keys)
    if total > Int(UInt32.MAX):
        raise Error("dictionary too large: more than 2**32 index postings")

    # Collect the distinct delete hashes, in partitions.
    var sets = _distinct_deletes(keys, threads)
    var generator = DeleteGenerator(max_distance, prefix_length)
    var ghosts = Span(ghost_codepoints)
    for i in range(len(ghost_offsets) - 1):
        generator.generate(
            ghosts[Int(ghost_offsets[i]) : Int(ghost_offsets[i + 1])]
        )
        for h in generator.hashes:
            sets[_partition(h)].insert(h)

    # Fold the exact hashes into the fingerprint table, partition by
    # partition. Hashes that share a fingerprint share a bucket; lookups
    # verify every term anyway (D3).
    var entry_count = 0
    for p in range(_PARTITIONS):
        entry_count += sets[p].size
    var slot_count = slot_count_for(entry_count)
    var mask = slot_count - 1
    var slots = List[UInt32](length=2 * (slot_count + 1), fill=0)
    var table = slots.unsafe_ptr()  # all indices below are masked: in range
    for p in range(_PARTITIONS):
        var hashes = sets[p].hashes.unsafe_ptr()
        var set_slots = len(sets[p].hashes)
        for k in range(set_slots):
            if k + _AHEAD < set_slots:
                var ahead = hashes[unsafe_offset=k + _AHEAD]
                prefetch(
                    table.unsafe_offset(2 * (Int(fingerprint(ahead)) & mask))
                )
            var h = hashes[unsafe_offset=k]
            if h == EMPTY:
                continue
            var f = fingerprint(h)
            var i = Int(f) & mask
            while (
                table[unsafe_offset=2 * i] != 0
                and table[unsafe_offset=2 * i] != f
            ):
                i = (i + 1) & mask
            table[unsafe_offset=2 * i] = f
    _ = sets^  # free them before pass 2

    # Pass 2: group the postings by slot, keeping term order within a slot.
    # Each hash becomes a (slot, term) key; a stable radix sort of the keys
    # then puts the buckets back to back, with sequential memory access.
    _resolve_slots(keys, ends, slots, mask, threads)
    _sort_by_high_half(keys, slot_count, threads)
    var term_lengths = List[UInt8](capacity=term_count)
    for offset in record_offsets:
        term_lengths.append(UInt8(min(Int(records[Int(offset)]), 255)))
    # Write the buckets, dropping repeated (slot, term) keys: a term whose
    # deletes coincide (as in "letter"), or whose different deletes share a
    # fingerprint, appears once per bucket. Each slot's start is set as the
    # keys reach it.
    var key = keys.unsafe_ptr()
    var postings = List[UInt32](unsafe_uninit_length=total)
    var lengths = List[UInt8](unsafe_uninit_length=total)
    var posting = postings.unsafe_ptr()
    var length_of = lengths.unsafe_ptr()
    var offset_of = record_offsets.unsafe_ptr()
    var length_of_term = term_lengths.unsafe_ptr()
    var written = 0
    var next_slot = 0  # slots below this have their start set
    for k in range(total):
        var v = key[unsafe_offset=k]
        if k > 0 and v == key[unsafe_offset=k - 1]:
            continue
        var slot = Int(v >> 32)
        while next_slot <= slot:
            table[unsafe_offset=2 * next_slot + 1] = UInt32(written)
            next_slot += 1
        var t = Int(v & 0xFFFFFFFF)
        posting[unsafe_offset=written] = offset_of[unsafe_offset=t]
        length_of[unsafe_offset=written] = length_of_term[unsafe_offset=t]
        written += 1
    while next_slot <= slot_count:  # the closing pair too
        table[unsafe_offset=2 * next_slot + 1] = UInt32(written)
        next_slot += 1
    postings.resize(written, 0)
    lengths.resize(written, 0)
    return DeleteTable(slots^, slot_count, postings^, lengths^, entry_count)


struct _GenerateJob(Movable):
    """One thread's share of `_generate_deletes`: terms `first` to `last`.

    It writes their hashes from `hashes[start]` on, and each term's end
    (an index into `hashes`) to `ends[t]`.
    """

    var records: Int
    """Address of the records `List[UInt32]`."""
    var record_offsets: Int
    """Address of the record offsets `List[UInt32]`."""
    var hashes: Int
    """Address of the first hash slot."""
    var ends: Int
    """Address of the first term end."""
    var first: Int
    var last: Int
    var start: Int
    var max_distance: Int
    var prefix_length: Int

    def __init__(
        out self,
        records: Int,
        record_offsets: Int,
        hashes: Int,
        ends: Int,
        first: Int,
        last: Int,
        start: Int,
        max_distance: Int,
        prefix_length: Int,
    ):
        self.records = records
        self.record_offsets = record_offsets
        self.hashes = hashes
        self.ends = ends
        self.first = first
        self.last = last
        self.start = start
        self.max_distance = max_distance
        self.prefix_length = prefix_length

    def run(self):
        ref records = ImmPointer[List[UInt32], ImmUntrackedOrigin](
            unsafe_from_address=self.records
        )[]
        ref record_offsets = ImmPointer[List[UInt32], ImmUntrackedOrigin](
            unsafe_from_address=self.record_offsets
        )[]
        var out = MutPointer[UInt64, MutUntrackedOrigin](
            unsafe_from_address=self.hashes
        )
        var ends = MutPointer[UInt32, MutUntrackedOrigin](
            unsafe_from_address=self.ends
        )
        var generator = DeleteGenerator(self.max_distance, self.prefix_length)
        var all_records = Span(records)
        var at = self.start
        for t in range(self.first, self.last):
            generator.generate(record_text(all_records, record_offsets[t]))
            for h in generator.hashes:
                out[unsafe_offset=at] = h
                at += 1
            ends[unsafe_offset=t] = UInt32(at)


def _generate_worker(address: Int) abi("C") -> Int:
    ImmPointer[_GenerateJob, ImmUntrackedOrigin](
        unsafe_from_address=address
    )[].run()
    return 0


def _delete_bounds(max_distance: Int, prefix_length: Int) -> List[Int]:
    """`bounds[n]`: the most deletes a term with an n-codepoint prefix has.

    It is the number of ways to remove up to `max_distance` of n positions.
    """
    var bounds = List[Int](capacity=prefix_length + 1)
    for n in range(prefix_length + 1):
        var total = 0
        var ways = 1  # C(n, k), starting at k = 0
        for k in range(min(max_distance, n) + 1):
            total += ways
            ways = ways * (n - k) // (k + 1)
        bounds.append(total)
    return bounds^


def _generate_deletes(
    records: List[UInt32],
    record_offsets: List[UInt32],
    max_distance: Int,
    prefix_length: Int,
    threads: Int,
    mut hashes: List[UInt64],
    mut ends: List[UInt32],
) raises:
    """Sets `hashes` to the delete hashes of all terms, in term order, and
    `ends[t]` to where term t's hashes end.

    Terms are split into `threads` contiguous ranges, one per thread. Each
    range writes into its own region, sized by `_delete_bounds`; the regions
    are then moved together. The result is the same for any thread count.
    """
    var n = len(record_offsets)
    var bounds = _delete_bounds(max_distance, prefix_length)
    var count = max(1, min(threads, n // _MIN_TERMS_PER_THREAD))
    var starts = List[Int](capacity=count + 1)
    var bound = 0
    for j in range(count):
        starts.append(bound)
        for t in range(j * n // count, (j + 1) * n // count):
            var length = Int(records[Int(record_offsets[t])])
            bound += bounds[min(length, prefix_length)]
    starts.append(bound)
    hashes = List[UInt64](unsafe_uninit_length=bound)
    ends = List[UInt32](unsafe_uninit_length=n)
    var jobs = List[_GenerateJob](capacity=count)
    for j in range(count):
        jobs.append(
            _GenerateJob(
                Int(Pointer(to=records)),
                Int(Pointer(to=record_offsets)),
                Int(hashes.unsafe_ptr()),
                Int(ends.unsafe_ptr()),
                j * n // count,
                (j + 1) * n // count,
                starts[j],
                max_distance,
                prefix_length,
            )
        )
    if count == 1:
        jobs[0].run()
    else:
        var addresses = List[Int](capacity=count)
        for j in range(count):
            addresses.append(Int(jobs.unsafe_ptr().unsafe_offset(j)))
        run_threads(_generate_worker, addresses)
    _ = len(jobs)  # the threads used the jobs through their addresses
    # Move each region down to where the previous one ended.
    var out = hashes.unsafe_ptr()
    var end = ends.unsafe_ptr()
    var filled = 0
    for j in range(count):
        var first = j * n // count
        var last = (j + 1) * n // count
        var region_end = (
            Int(end[unsafe_offset=last - 1]) if last > first else starts[j]
        )
        var shift = starts[j] - filled
        if shift > 0:
            for k in range(starts[j], region_end):
                out[unsafe_offset=k - shift] = out[unsafe_offset=k]
            for t in range(first, last):
                end[unsafe_offset=t] -= UInt32(shift)
        filled = region_end - shift
    hashes.resize(filled, 0)


comptime _PARTITIONS = 8
"""Delete hashes are counted in this many partitions, by their top bits.

Threads take whole partitions. A fixed number keeps the index the same for
any number of threads.
"""


@inline(.always)
def _partition(h: UInt64) -> Int:
    return Int(h >> 61)  # the top 3 bits: 8 partitions


struct _DistinctJob(Movable):
    """Collects the hashes of partitions `first` to `last`, scanning all keys.
    """

    var keys: Int
    """Address of the first hash."""
    var total: Int
    var first: Int
    var last: Int
    var sets: List[HashSet]

    def __init__(out self, keys: Int, total: Int, first: Int, last: Int):
        self.keys = keys
        self.total = total
        self.first = first
        self.last = last
        self.sets = List[HashSet](capacity=last - first)
        # English has about one distinct delete per three keys.
        for _ in range(first, last):
            self.sets.append(HashSet(total // (3 * _PARTITIONS)))

    def run(mut self):
        var key = ImmPointer[UInt64, ImmUntrackedOrigin](
            unsafe_from_address=self.keys
        )
        var sets = self.sets.unsafe_ptr()  # index p - first: in range
        for k in range(self.total):
            if k + _AHEAD < self.total:
                var ahead = key[unsafe_offset=k + _AHEAD]
                var p = _partition(ahead)
                if p >= self.first and p < self.last:
                    sets[unsafe_offset=p - self.first].prefetch(ahead)
            var h = key[unsafe_offset=k]
            var p = _partition(h)
            if p >= self.first and p < self.last:
                sets[unsafe_offset=p - self.first].insert(h)


def _distinct_worker(address: Int) abi("C") -> Int:
    MutPointer[_DistinctJob, MutUntrackedOrigin](
        unsafe_from_address=address
    )[].run()
    return 0


def _distinct_deletes(keys: List[UInt64], threads: Int) raises -> List[HashSet]:
    """The distinct hashes in `keys`, as one set per partition."""
    var total = len(keys)
    var count = max(1, min(threads, _PARTITIONS, total // _MIN_KEYS_PER_THREAD))
    var jobs = List[_DistinctJob](capacity=count)
    for j in range(count):
        jobs.append(
            _DistinctJob(
                Int(keys.unsafe_ptr()),
                total,
                j * _PARTITIONS // count,
                (j + 1) * _PARTITIONS // count,
            )
        )
    if count == 1:
        jobs[0].run()
    else:
        var addresses = List[Int](capacity=count)
        for j in range(count):
            addresses.append(Int(jobs.unsafe_ptr().unsafe_offset(j)))
        run_threads(_distinct_worker, addresses)
    var sets = List[HashSet](capacity=_PARTITIONS)
    for j in range(count):
        while len(jobs[j].sets) > 0:
            sets.append(jobs[j].sets.pop(0))
    return sets^


struct _ResolveJob(Movable):
    """Turns the hashes of terms `first` to `last` into (slot, term) keys."""

    var keys: Int
    """Address of the first hash."""
    var ends: Int
    """Address of the first term end."""
    var table: Int
    """Address of the first slot pair."""
    var mask: Int
    var first: Int
    var last: Int

    def __init__(
        out self,
        keys: Int,
        ends: Int,
        table: Int,
        mask: Int,
        first: Int,
        last: Int,
    ):
        self.keys = keys
        self.ends = ends
        self.table = table
        self.mask = mask
        self.first = first
        self.last = last

    def run(self):
        var key = MutPointer[UInt64, MutUntrackedOrigin](
            unsafe_from_address=self.keys
        )
        var ends = ImmPointer[UInt32, ImmUntrackedOrigin](
            unsafe_from_address=self.ends
        )
        var table = ImmPointer[UInt32, ImmUntrackedOrigin](
            unsafe_from_address=self.table
        )
        var k = 0 if self.first == 0 else Int(
            ends[unsafe_offset=self.first - 1]
        )
        var end = 0 if self.last == 0 else Int(
            ends[unsafe_offset=self.last - 1]
        )
        for t in range(self.first, self.last):
            for _ in range(k, Int(ends[unsafe_offset=t])):
                if k + _AHEAD < end:
                    var ahead = fingerprint(key[unsafe_offset=k + _AHEAD])
                    prefetch(table.unsafe_offset(2 * (Int(ahead) & self.mask)))
                var f = fingerprint(key[unsafe_offset=k])
                var i = Int(f) & self.mask
                while table[unsafe_offset=2 * i] != f:  # every hash is there
                    i = (i + 1) & self.mask
                key[unsafe_offset=k] = (UInt64(i) << 32) | UInt64(t)
                k += 1


def _resolve_worker(address: Int) abi("C") -> Int:
    ImmPointer[_ResolveJob, ImmUntrackedOrigin](
        unsafe_from_address=address
    )[].run()
    return 0


def _resolve_slots(
    mut keys: List[UInt64],
    ends: List[UInt32],
    slots: List[UInt32],
    mask: Int,
    threads: Int,
) raises:
    """Replaces each hash in `keys` with a (slot << 32 | term) key."""
    var n = len(ends)
    var count = max(1, min(threads, n // _MIN_TERMS_PER_THREAD))
    var jobs = List[_ResolveJob](capacity=count)
    for j in range(count):
        jobs.append(
            _ResolveJob(
                Int(keys.unsafe_ptr()),
                Int(ends.unsafe_ptr()),
                Int(slots.unsafe_ptr()),
                mask,
                j * n // count,
                (j + 1) * n // count,
            )
        )
    if count == 1:
        jobs[0].run()
    else:
        var addresses = List[Int](capacity=count)
        for j in range(count):
            addresses.append(Int(jobs.unsafe_ptr().unsafe_offset(j)))
        run_threads(_resolve_worker, addresses)
    _ = len(jobs)  # the threads used the jobs through their addresses


comptime _DIGIT = 10
comptime _RADIX = 1 << _DIGIT


struct _RadixJob(Movable):
    """One thread's chunk `lo` to `hi` of a radix sort pass."""

    var src: Int
    """Address of the first key to read."""
    var dst: Int
    """Address of the first key to write."""
    var lo: Int
    var hi: Int
    var shift: Int
    var scatter: Bool
    """False: count digits into `counts`. True: move keys to the positions
    that `counts` then holds."""
    var counts: List[Int]

    def __init__(out self, lo: Int, hi: Int):
        self.src = 0
        self.dst = 0
        self.lo = lo
        self.hi = hi
        self.shift = 0
        self.scatter = False
        self.counts = List[Int](length=_RADIX, fill=0)

    def run(mut self):
        var src = ImmPointer[UInt64, ImmUntrackedOrigin](
            unsafe_from_address=self.src
        )
        var count = self.counts.unsafe_ptr()  # digits are masked: in range
        var shift = UInt64(self.shift)
        if not self.scatter:
            for d in range(_RADIX):
                count[unsafe_offset=d] = 0
            for i in range(self.lo, self.hi):
                var d = Int(src[unsafe_offset=i] >> shift) & (_RADIX - 1)
                count[unsafe_offset=d] += 1
            return
        var dst = MutPointer[UInt64, MutUntrackedOrigin](
            unsafe_from_address=self.dst
        )
        for i in range(self.lo, self.hi):
            var v = src[unsafe_offset=i]
            var d = Int(v >> shift) & (_RADIX - 1)
            dst[unsafe_offset=count[unsafe_offset=d]] = v
            count[unsafe_offset=d] += 1


def _radix_worker(address: Int) abi("C") -> Int:
    MutPointer[_RadixJob, MutUntrackedOrigin](
        unsafe_from_address=address
    )[].run()
    return 0


def _run_radix_jobs(mut jobs: List[_RadixJob]) raises:
    if len(jobs) == 1:
        jobs[0].run()
        return
    var addresses = List[Int](capacity=len(jobs))
    for j in range(len(jobs)):
        addresses.append(Int(jobs.unsafe_ptr().unsafe_offset(j)))
    run_threads(_radix_worker, addresses)


def _sort_by_high_half(mut keys: List[UInt64], limit: Int, threads: Int) raises:
    """Stable LSD radix sort of `keys` by their upper 32 bits, all < `limit`.

    Each pass splits the keys into one chunk per thread. A thread counts the
    digits of its chunk, then moves its keys; chunks keep their order, so
    the sort is stable and the result does not depend on the thread count.
    """
    var n = len(keys)
    var buffer = List[UInt64](unsafe_uninit_length=n)
    var src = Int(keys.unsafe_ptr())
    var dst = Int(buffer.unsafe_ptr())
    var count = max(1, min(threads, n // _MIN_KEYS_PER_THREAD))
    var jobs = List[_RadixJob](capacity=count)
    for j in range(count):
        jobs.append(_RadixJob(j * n // count, (j + 1) * n // count))
    var passes = 0
    var shift = 32
    while (1 << (shift - 32)) < limit:
        for j in range(count):
            jobs[j].src = src
            jobs[j].dst = dst
            jobs[j].shift = shift
            jobs[j].scatter = False
        _run_radix_jobs(jobs)
        # Digit-major, chunk-minor offsets keep equal digits in chunk order.
        var sum = 0
        for d in range(_RADIX):
            for j in range(count):
                var c = jobs[j].counts[d]
                jobs[j].counts[d] = sum
                sum += c
        for j in range(count):
            jobs[j].scatter = True
        _run_radix_jobs(jobs)
        var swap = src
        src = dst
        dst = swap
        shift += _DIGIT
        passes += 1
    _ = len(buffer)  # the passes used it through its address
    if passes % 2 == 1:  # the result is in `buffer`
        keys = buffer^


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
