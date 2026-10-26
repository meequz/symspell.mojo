"""The frozen, read-only SymSpell index and `lookup`.

All data lives in one byte image (see `_image.mojo`). The index never changes
after construction, so any number of threads can look up concurrently, each
with its own `LookupScratch`.
"""

from std.sys import size_of
from std.sys.intrinsics import prefetch

from symspell._bitparallel import levenshtein_distance, osa_distance
from symspell._hash import hash_codepoints
from symspell._image import (
    BIGRAM_ARENA,
    BIGRAM_COUNTS,
    BIGRAM_OFFSETS,
    BIGRAM_SLOT_HASHES,
    BIGRAM_SLOT_IDS,
    COUNTS,
    DELETE_SLOTS,
    POSTINGS,
    TERM_ARENA,
    POSTING_LENGTHS,
    RECORD_HEADER,
    TERM_RECORD_OFFSETS,
    TERM_RECORDS,
    TERM_OFFSETS,
    TERM_SLOT_HASHES,
    TERM_SLOT_IDS,
    Header,
    Section,
    fingerprint,
    parse_image,
    validate_image,
)
from symspell._mmap import MappedFile
from symspell.casing import case_transfer_similar
from symspell.config import DistanceAlgorithm, SymSpellConfig
from symspell.delete_index import EMPTY, is_delete_of, probe_start
from symspell.scratch import Hit, LookupScratch, sort_hits
from symspell.suggestion import Composition, Suggestion
from symspell.compound import lookup_compound as compound_impl
from symspell.batch import lookup_batch as batch_impl
from symspell.segmentation import word_segmentation as segmentation_impl
from symspell.text import decode, lower, to_codepoints, to_string
from symspell.tokenize import TokenPredicate
from symspell.verbosity import Verbosity

comptime _Ptr = ImmPointer[_, ImmUntrackedOrigin]
comptime _Span = ImmSpan[_, ImmUntrackedOrigin]


def _at[
    T: TrivialRegisterPassable
](base: _Ptr[UInt8], sections: List[Section], section: Int) -> _Ptr[T]:
    return base.unsafe_offset(sections[section].offset).unsafe_bitcast[T]()


@fieldwise_init
struct _Tables(ImplicitlyCopyable):
    """Raw pointers to the sections of a validated image, set up once.

    Hot loops index them without bounds checks; the image was validated (or
    built by this library), so every index they use is in range.
    """

    var term_offsets: _Ptr[UInt32]
    var term_bytes: _Ptr[UInt8]
    var record_offsets: _Ptr[UInt32]
    var records: _Ptr[UInt32]
    var counts: _Ptr[Int64]
    var term_hashes: _Ptr[UInt64]
    var term_ids: _Ptr[UInt32]
    var term_mask: Int
    var delete_slots: _Ptr[UInt32]
    var postings: _Ptr[UInt32]
    var posting_lengths: _Ptr[UInt8]
    var delete_mask: Int
    var bigram_offsets: _Ptr[UInt32]
    var bigram_bytes: _Ptr[UInt8]
    var bigram_counts: _Ptr[Int64]
    var bigram_hashes: _Ptr[UInt64]
    var bigram_ids: _Ptr[UInt32]
    var bigram_mask: Int

    @staticmethod
    def create(
        base: _Ptr[UInt8], header: Header, sections: List[Section]
    ) -> _Tables:
        return _Tables(
            _at[UInt32](base, sections, TERM_OFFSETS),
            _at[UInt8](base, sections, TERM_ARENA),
            _at[UInt32](base, sections, TERM_RECORD_OFFSETS),
            _at[UInt32](base, sections, TERM_RECORDS),
            _at[Int64](base, sections, COUNTS),
            _at[UInt64](base, sections, TERM_SLOT_HASHES),
            _at[UInt32](base, sections, TERM_SLOT_IDS),
            header.term_slots - 1,
            _at[UInt32](base, sections, DELETE_SLOTS),
            _at[UInt32](base, sections, POSTINGS),
            _at[UInt8](base, sections, POSTING_LENGTHS),
            header.delete_slots - 1,
            _at[UInt32](base, sections, BIGRAM_OFFSETS),
            _at[UInt8](base, sections, BIGRAM_ARENA),
            _at[Int64](base, sections, BIGRAM_COUNTS),
            _at[UInt64](base, sections, BIGRAM_SLOT_HASHES),
            _at[UInt32](base, sections, BIGRAM_SLOT_IDS),
            header.bigram_slots - 1,
        )


def _py_char(text: ImmSpan[UInt32, _], index: Int) raises -> UInt32:
    """Python `text[index]` (negative indices count from the end)."""
    var i = index + len(text) if index < 0 else index
    if i < 0 or i >= len(text):
        raise Error("IndexError: string index out of range")
    return text[i]


def _py_tail_equal(
    a: ImmSpan[UInt32, _], a_start: Int, b: ImmSpan[UInt32, _], b_start: Int
) -> Bool:
    """Python `a[a_start:] == b[b_start:]`."""

    def clamp(start: Int, length: Int) -> Int:
        if start < 0:
            return max(start + length, 0)
        return min(start, length)

    var i = clamp(a_start, len(a))
    var j = clamp(b_start, len(b))
    if len(a) - i != len(b) - j:
        return False
    while i < len(a):
        if a[i] != b[j]:
            return False
        i += 1
        j += 1
    return True


def _spans_equal(a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _]) -> Bool:
    if len(a) != len(b):
        return False
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    for i in range(len(a)):
        if pa[unsafe_offset=i] != pb[unsafe_offset=i]:
            return False
    return True


struct SymSpell(Movable):
    """A frozen SymSpell index.

    Build one with `SymSpellBuilder`, or load a saved one with `SymSpell.open`.
    """

    # The image lives either in `_storage` (built or read into memory) or in
    # `_mapping` (memory-mapped file). `_base` points to its first byte; the
    # bytes never move, so it stays valid when the index is moved.
    var _storage: List[UInt8]
    var _mapping: Optional[MappedFile]
    var _base: ImmPointer[UInt8, ImmUntrackedOrigin]
    var _size: Int
    var _header: Header
    var _t: _Tables

    def __init__(out self, var image: List[UInt8]) raises:
        """Wraps a freshly built image. Use `SymSpellBuilder.build()` instead.
        """
        var parsed = parse_image(image, verify_checksum=False)
        self._header = parsed[0].copy()
        self._base = (
            image.unsafe_ptr().as_imm().unsafe_origin_cast[ImmUntrackedOrigin]()
        )
        self._t = _Tables.create(self._base, self._header, parsed[1])
        self._size = len(image)
        self._storage = image^
        self._mapping = None

    def __init__(
        out self, var mapping: MappedFile, verify_checksum: Bool, trusted: Bool
    ) raises:
        """Wraps a mapped file after validating it. Use `SymSpell.open`."""
        var data = mapping.bytes()
        var parsed = parse_image(data, verify_checksum and not trusted)
        if not trusted:
            validate_image(data, parsed[0], parsed[1])
        self._header = parsed[0].copy()
        self._base = data.unsafe_ptr()
        self._t = _Tables.create(self._base, self._header, parsed[1])
        self._size = len(data)
        self._storage = List[UInt8]()
        self._mapping = mapping^

    @staticmethod
    def open(
        path: StringSlice,
        verify_checksum: Bool = True,
        use_mmap: Bool = True,
        trusted: Bool = False,
    ) raises -> SymSpell:
        """Loads an index written by `save`.

        The file is memory-mapped, so opening is fast and the operating system
        shares the pages between processes. With `use_mmap=False`, or where
        mmap fails, the file is read into memory instead.

        Raises for a missing, truncated, corrupted or incompatible file. The
        structure is always validated, so a bad file cannot cause
        out-of-bounds reads. `verify_checksum=False` skips the checksum, which
        saves one pass over the file but lets random corruption through as
        wrong results.

        `trusted=True` skips the checksum and the structural checks, so even a
        very large index opens in milliseconds: pages load lazily, on first
        use. Only use it for files you wrote yourself and that cannot have
        been damaged or replaced; a bad file can then crash the process.
        The header and section table are still checked.
        """
        var file = String(path)
        if use_mmap:
            var mapping: Optional[MappedFile] = None
            try:
                mapping = MappedFile(file)
            except:
                pass  # fall back to reading the file below
            if mapping:
                return SymSpell(mapping.take(), verify_checksum, trusted)
        var image: List[UInt8]
        with open(file, "r") as f:
            image = f.read_bytes()
        var parsed = parse_image(image, verify_checksum and not trusted)
        if not trusted:
            validate_image(image, parsed[0], parsed[1])
        return SymSpell(image^)

    def save(self, path: StringSlice) raises:
        """Writes the index to a file that `SymSpell.open` can load."""
        with open(String(path), "w") as f:
            f.write_bytes(self._bytes())

    def _bytes(self) -> ImmSpan[UInt8, ImmUntrackedOrigin]:
        return ImmSpan[UInt8, ImmUntrackedOrigin](
            unsafe_ptr=self._base, length=self._size
        )

    def is_memory_mapped(self) -> Bool:
        """Whether the index reads directly from a memory-mapped file."""
        return Bool(self._mapping)

    # --- Term access ---

    def _record_cps(self, record: Int) -> _Span[UInt32]:
        """The codepoints of the term record at offset `record`."""
        return _Span[UInt32](
            unsafe_ptr=self._t.records.unsafe_offset(record + RECORD_HEADER),
            length=Int(self._t.records[unsafe_offset=record]),
        )

    def _record_term_id(self, record: Int) -> Int:
        return Int(self._t.records[unsafe_offset=record + 1])

    def _term_cps(self, term_id: Int) -> _Span[UInt32]:
        """The codepoints of a term (no decoding)."""
        return self._record_cps(
            Int(self._t.record_offsets[unsafe_offset=term_id])
        )

    def term(self, term_id: Int) -> StringSlice[ImmUntrackedOrigin]:
        """The UTF-8 text of a term (zero-copy)."""
        var start = Int(self._t.term_offsets[unsafe_offset=term_id])
        var end = Int(self._t.term_offsets[unsafe_offset=term_id + 1])
        return StringSlice(
            unsafe_from_utf8=_Span[UInt8](
                unsafe_ptr=self._t.term_bytes.unsafe_offset(start),
                length=end - start,
            )
        )

    def _count(self, term_id: Int) -> Int:
        return Int(self._t.counts[unsafe_offset=term_id])

    # --- Properties ---

    def config(self) -> SymSpellConfig:
        """The configuration the index was built with."""
        return SymSpellConfig(
            self._header.max_dictionary_edit_distance,
            self._header.prefix_length,
            self._header.count_threshold,
            DistanceAlgorithm(self._header.distance_algorithm),
        )

    def word_count(self) -> Int:
        """Number of correctly spelled words."""
        return self._header.word_count

    def entry_count(self) -> Int:
        """Number of distinct delete strings in the index."""
        return self._header.entry_count

    def max_length(self) -> Int:
        """Length in codepoints of the longest word."""
        return self._header.max_length

    def bigram_count_min(self) -> Int:
        """The smallest loaded bigram count (2**63 - 1 if none was loaded)."""
        return self._header.bigram_count_min

    def bigram_size(self) -> Int:
        """Number of bigrams."""
        return self._header.bigram_count

    # --- Exact lookups ---

    def _find_term(self, text: ImmSpan[UInt32, _]) -> Int:
        """Term id of `text`, or -1."""
        var h = hash_codepoints(text)
        var i = probe_start(h, self._t.term_mask + 1)
        while True:
            var found = self._t.term_hashes[unsafe_offset=i]
            if found == EMPTY:
                return -1
            if found == h:
                var term_id = Int(self._t.term_ids[unsafe_offset=i])
                if _spans_equal(self._term_cps(term_id), text):
                    return term_id
            i = (i + 1) & self._t.term_mask

    def contains(self, term: StringSlice) -> Bool:
        """Whether `term` is a correctly spelled word."""
        return self._find_term(to_codepoints(term)) >= 0

    def count(self, term: StringSlice) -> Optional[Int]:
        """The count of a correctly spelled word, or None."""
        var term_id = self._find_term(to_codepoints(term))
        if term_id < 0:
            return None
        return self._count(term_id)

    def bigram_count(self, bigram: StringSlice) -> Optional[Int]:
        """The count of a bigram ("word1 word2"), or None."""
        var h = hash_codepoints(to_codepoints(bigram))
        var i = probe_start(h, self._t.bigram_mask + 1)
        while True:
            var found = self._t.bigram_hashes[unsafe_offset=i]
            if found == EMPTY:
                return None
            if found == h:
                var b = Int(self._t.bigram_ids[unsafe_offset=i])
                var start = Int(self._t.bigram_offsets[unsafe_offset=b])
                var end = Int(self._t.bigram_offsets[unsafe_offset=b + 1])
                var key = StringSlice(
                    unsafe_from_utf8=_Span[UInt8](
                        unsafe_ptr=self._t.bigram_bytes.unsafe_offset(start),
                        length=end - start,
                    )
                )
                if key == bigram:
                    return Int(self._t.bigram_counts[unsafe_offset=b])
            i = (i + 1) & self._t.bigram_mask

    def _bucket(self, h: UInt64) -> Tuple[Int, Int]:
        """The range of `postings` for delete hash `h` (empty if absent)."""
        var f = fingerprint(h)
        var slots = self._t.delete_slots
        var i = Int(f) & self._t.delete_mask
        while True:
            var found = slots[unsafe_offset=2 * i]
            if found == f:
                return (
                    Int(slots[unsafe_offset=2 * i + 1]),
                    Int(slots[unsafe_offset=2 * i + 3]),
                )
            if found == 0:
                return (0, 0)
            i = (i + 1) & self._t.delete_mask

    def _prefetch_bucket(self, h: UInt64):
        """Starts loading the table slot that `_bucket(h)` will read first."""
        var i = Int(fingerprint(h)) & self._t.delete_mask
        prefetch(self._t.delete_slots.unsafe_offset(2 * i))

    def _bucket_terms(self, delete: StringSlice) -> List[String]:
        """Terms that have `delete` among their deletes (a test hook)."""
        var out = List[String]()
        var cps = to_codepoints(delete)
        var bucket = self._bucket(hash_codepoints(cps))
        for k in range(bucket[0], bucket[1]):
            var record = Int(self._t.postings[unsafe_offset=k])
            var term_id = self._record_term_id(record)
            if is_delete_of(
                cps,
                self._record_cps(record),
                self._header.max_dictionary_edit_distance,
                self._header.prefix_length,
            ):
                out.append(String(self.term(term_id)))
        return out^

    # --- Fuzzy lookup ---

    def lookup(
        self,
        phrase: StringSlice,
        verbosity: Verbosity,
        max_edit_distance: Optional[Int] = None,
        include_unknown: Bool = False,
        ignore_token: Optional[TokenPredicate] = None,
        transfer_casing: Bool = False,
    ) raises -> List[Suggestion]:
        """Finds spelling suggestions for one word.

        Allocates a fresh `LookupScratch`; pass your own with the `scratch`
        keyword to avoid that in loops.
        """
        var scratch = LookupScratch()
        return self.lookup(
            phrase,
            verbosity,
            max_edit_distance,
            include_unknown,
            ignore_token,
            transfer_casing,
            scratch=scratch,
        )

    def lookup(
        self,
        phrase: StringSlice,
        verbosity: Verbosity,
        max_edit_distance: Optional[Int] = None,
        include_unknown: Bool = False,
        ignore_token: Optional[TokenPredicate] = None,
        transfer_casing: Bool = False,
        *,
        mut scratch: LookupScratch,
    ) raises -> List[Suggestion]:
        """Finds spelling suggestions for one word.

        Suggestions are sorted by distance, then by descending count. Raises if
        `max_edit_distance` exceeds the index's `max_dictionary_edit_distance`.
        If `ignore_token` returns True for the phrase, the phrase itself is
        returned with distance 0 and count 1 (symspellpy's `ignore_token` regex).
        See docs/BEHAVIOR.md, section 4, for the exact rules.
        """
        var med = max_edit_distance.or_else(
            self._header.max_dictionary_edit_distance
        )
        if med > self._header.max_dictionary_edit_distance:
            raise Error("distance too large")
        decode(phrase, scratch.original)
        scratch.phrase.clear()
        if transfer_casing:
            lower(scratch.original, scratch.phrase)
        else:
            scratch.copy_original_to_phrase()
        scratch.hits.clear()
        var completed = self._search(
            med, verbosity, ignore_token, transfer_casing, scratch
        )
        return self._finish(
            phrase, med, include_unknown, transfer_casing, completed, scratch
        )

    def _lookup_top(
        self,
        text: ImmSpan[UInt32, _],
        med: Int,
        ignore_token: Optional[TokenPredicate],
        mut scratch: LookupScratch,
    ) raises -> Bool:
        """`lookup(TOP)` on codepoints, without building `Suggestion`s.

        For `word_segmentation`, which makes many small lookups. Leaves the
        result (at most one hit with TOP) in `scratch.hits`. The caller checks
        `med` against the dictionary's maximum first.
        """
        scratch.set_phrase(text)
        scratch.hits.clear()
        _ = self._search(med, Verbosity.TOP, ignore_token, False, scratch)
        return len(scratch.hits) > 0

    def _search(
        self,
        med: Int,
        verbosity: Verbosity,
        ignore_token: Optional[TokenPredicate],
        transfer_casing: Bool,
        mut scratch: LookupScratch,
    ) raises -> Bool:
        """Fills `scratch.hits`, following symspellpy's `lookup` loop.

        Returns False on an early exit. symspellpy then neither sorts the
        suggestions nor transfers casing.
        """
        var phrase_len = len(scratch.original)
        var p = self._header.prefix_length
        if phrase_len - med > self._header.max_length:
            return False
        # The first candidate is the phrase prefix. Start loading its bucket
        # now, so that this overlaps with the exact-match probe.
        scratch.reset_candidates()
        var phrase_prefix_len = phrase_len
        if phrase_prefix_len > p:
            phrase_prefix_len = p
            scratch.push_phrase_prefix(p)
        else:
            # The lowercased phrase may be longer than the original
            # (`transfer_casing`); symspellpy then uses all of it.
            scratch.push_phrase_prefix(len(scratch.phrase))
        if med > 0:
            self._prefetch_bucket(scratch.candidate_hash(0))
        var exact = self._find_term(scratch.phrase)
        if exact >= 0:
            var kind = Hit.ORIGINAL if transfer_casing else Hit.PHRASE
            scratch.hits.append(Hit(kind, exact, 0, self._count(exact)))
            if verbosity != Verbosity.ALL:
                return False
        if ignore_token and ignore_token.value()(to_string(scratch.phrase)):
            scratch.hits.append(Hit(Hit.PHRASE, -1, 0, 1))
            if verbosity != Verbosity.ALL:
                return False
        if med == 0:
            return False

        var med2 = med
        scratch.masks.set(scratch.phrase)
        # symspellpy always adds the deletes of the phrase prefix: its
        # len_diff is 0, and med2 stays >= 1 because every hit found here has
        # a distance >= 1. Adding them first lets their buckets load while
        # the first bucket is processed. The candidate order does not change.
        scratch.add_deletes_of(0)
        for c in range(1, scratch.candidate_count()):
            self._prefetch_bucket(scratch.candidate_hash(c))
        var pointer = 0
        while pointer < scratch.candidate_count():
            # Valid until `add_deletes_of` below adds more candidates.
            var candidate = scratch.candidate(pointer)
            var candidate_hash = scratch.candidate_hash(pointer)
            var candidate_index = pointer
            pointer += 1
            var candidate_len = len(candidate)
            var len_diff = phrase_prefix_len - candidate_len
            if len_diff > med2:
                if verbosity == Verbosity.ALL:
                    continue
                break

            var bucket = self._bucket(candidate_hash)
            if pointer < scratch.candidate_count():
                # Start loading the next candidate's bucket (its table slot
                # was prefetched when it was added).
                var next = self._bucket(scratch.candidate_hash(pointer))
                prefetch(self._t.postings.unsafe_offset(next[0]))
                prefetch(self._t.posting_lengths.unsafe_offset(next[0]))
            # Pre-filter by the stored lengths, and start loading the records
            # of the survivors so the memory accesses overlap. med2 only
            # shrinks while the bucket is processed and `_consider` checks
            # again, so this filter never drops a term it should keep.
            scratch.survivors.clear()
            for k in range(bucket[0], bucket[1]):
                var length = Int(self._t.posting_lengths[unsafe_offset=k])
                if length != 255:  # 255 means "255 or more": checked later
                    if (
                        abs(length - phrase_len) > med2
                        or length < candidate_len
                    ):
                        continue
                    var prefix_len = min(length, p)
                    if (
                        prefix_len > phrase_prefix_len
                        and prefix_len - candidate_len > med2
                    ):
                        continue
                prefetch(
                    self._t.records.unsafe_offset(
                        Int(self._t.postings[unsafe_offset=k])
                    )
                )
                scratch.survivors.append(k)
            for s in range(len(scratch.survivors)):
                med2 = self._consider(
                    scratch.survivors.unsafe_ptr()[unsafe_offset=s],
                    candidate,
                    phrase_len,
                    phrase_prefix_len,
                    med,
                    med2,
                    verbosity,
                    scratch,
                )

            # Add the deletes of this candidate as new candidates (those of
            # the first candidate were added before the loop).
            if candidate_index > 0 and len_diff < med and candidate_len <= p:
                if verbosity != Verbosity.ALL and len_diff >= med2:
                    continue
                var first_new = scratch.candidate_count()
                scratch.add_deletes_of(candidate_index)
                for c in range(first_new, scratch.candidate_count()):
                    self._prefetch_bucket(scratch.candidate_hash(c))
        return True

    def _consider(
        self,
        posting: Int,
        candidate: ImmSpan[UInt32, ImmUntrackedOrigin],
        phrase_len: Int,
        phrase_prefix_len: Int,
        med: Int,
        med2_in: Int,
        verbosity: Verbosity,
        mut scratch: LookupScratch,
    ) raises -> Int:
        """Checks the term of one posting and records it as a hit.

        Returns the new `max_edit_distance_2` (med2). The checks before the
        first side effect only skip terms, so their order does not matter.
        """
        var med2 = med2_in
        var p = self._header.prefix_length
        var candidate_len = len(candidate)
        ref phrase = scratch.phrase
        var record = Int(self._t.postings[unsafe_offset=posting])
        # The real length, from the record (the stored posting length is
        # only a hint used by the pre-filter).
        var suggestion = self._record_cps(record)
        var suggestion_len = len(suggestion)
        if (
            abs(suggestion_len - phrase_len) > med2
            or suggestion_len < candidate_len
        ):
            return med2
        var suggestion_prefix_len = min(suggestion_len, p)
        if (
            suggestion_prefix_len > phrase_prefix_len
            and suggestion_prefix_len - candidate_len > med2
        ):
            return med2
        if suggestion_len == candidate_len and not _spans_equal(
            suggestion, candidate
        ):
            return med2
        var term_id = self._record_term_id(record)
        if not is_delete_of(
            candidate, suggestion, self._header.max_dictionary_edit_distance, p
        ):
            return med2  # in this bucket only because of a hash collision
        if _spans_equal(suggestion, phrase):
            return med2

        var distance: Int
        if candidate_len == 0:
            distance = max(phrase_len, suggestion_len)
            if distance > med2 or self._considered(term_id, scratch):
                return med2
        elif suggestion_len == 1:
            # symspellpy: `phrase.index(suggestion[0])` always succeeds here,
            # because the suggestion equals the candidate, a delete of the phrase.
            distance = phrase_len - 1
            if distance > med2 or self._considered(term_id, scratch):
                return med2
        else:
            var at_prefix_limit = p - med == candidate_len
            var min_distance = (
                min(phrase_len, suggestion_len) - p if at_prefix_limit else 0
            )
            # Python evaluates `A and (B and C) or (D and E and (F or G))`
            # left to right; indexing may raise, as it does in Python.
            var skip = (
                at_prefix_limit
                and min_distance > 1
                and not _py_tail_equal(
                    phrase,
                    phrase_len + 1 - min_distance,
                    suggestion,
                    suggestion_len + 1 - min_distance,
                )
            )
            if not skip and min_distance > 0:
                var pc = _py_char(phrase, phrase_len - min_distance)
                var sc = _py_char(suggestion, suggestion_len - min_distance)
                if pc != sc:
                    skip = _py_char(
                        phrase, phrase_len - min_distance - 1
                    ) != sc or pc != _py_char(
                        suggestion, suggestion_len - min_distance - 1
                    )
            if skip:
                return med2
            if not scratch.considered_terms.insert_if_absent(UInt64(term_id)):
                return med2
            var levenshtein = (
                self._header.distance_algorithm
                == DistanceAlgorithm.LEVENSHTEIN.value
            )
            if scratch.masks.length > 0:  # phrase of 1 to 64 codepoints
                if levenshtein:
                    distance = levenshtein_distance(
                        scratch.masks, suggestion, med2
                    )
                else:
                    distance = osa_distance(scratch.masks, suggestion, med2)
            elif levenshtein:
                distance = scratch.levenshtein.distance(
                    phrase, suggestion, med2
                )
            else:
                distance = scratch.osa.distance(phrase, suggestion, med2)
            if distance < 0:
                return med2

        if distance <= med2:
            var count = self._count(term_id)
            var hit = Hit(Hit.TERM, term_id, distance, count)
            if len(scratch.hits) > 0:
                if verbosity == Verbosity.CLOSEST:
                    if distance < med2:
                        scratch.hits.clear()
                elif verbosity == Verbosity.TOP:
                    if distance < med2 or count > scratch.hits[0].count:
                        scratch.hits[0] = hit
                        return distance
                    return med2
            if verbosity != Verbosity.ALL:
                med2 = distance
            scratch.hits.append(hit)
        return med2

    def _considered(self, term_id: Int, scratch: LookupScratch) -> Bool:
        """Membership test only (symspellpy does not add these terms)."""
        var key = UInt64(term_id)
        ref terms = scratch.considered_terms
        var i = terms.start(key)
        while terms.occupied(i):
            if terms.key_at(i) == key:
                return True
            i = terms.next(i)
        return False

    def _finish(
        self,
        phrase: StringSlice,
        med: Int,
        include_unknown: Bool,
        transfer_casing: Bool,
        completed: Bool,
        mut scratch: LookupScratch,
    ) raises -> List[Suggestion]:
        """Turns hits into suggestions, with sorting, casing and unknown handling.

        Sorting and casing only apply when the search was `completed`.
        """
        if completed and len(scratch.hits) > 1:
            sort_hits(scratch.hits, scratch.sort_buffer)
        var suggestions = List[Suggestion](capacity=len(scratch.hits))
        for hit in scratch.hits:
            var term: String
            if hit.kind == Hit.ORIGINAL:
                term = String(phrase)
            elif hit.kind == Hit.PHRASE:
                term = to_string(scratch.phrase) if transfer_casing else String(
                    phrase
                )
            else:
                term = String(self.term(hit.term_id))
            suggestions.append(Suggestion(term^, hit.distance, hit.count))
        if completed and transfer_casing:
            for ref s in suggestions:
                s.term = case_transfer_similar(phrase, s.term)
        if include_unknown and len(suggestions) == 0:
            var unknown = to_string(
                scratch.phrase
            ) if transfer_casing else String(phrase)
            suggestions.append(Suggestion(unknown^, med + 1, 0))
        return suggestions^

    # --- Multi-word ---

    def lookup_compound(
        self,
        phrase: StringSlice,
        max_edit_distance: Int,
        ignore_non_words: Bool = False,
        transfer_casing: Bool = False,
        split_by_space: Bool = False,
        ignore_term_with_digits: Bool = False,
    ) raises -> List[Suggestion]:
        """Corrects a multi-word text, also splitting and merging words.

        Returns one suggestion: the corrected text, its edit distance to
        `phrase`, and an estimated count. With `ignore_non_words`, numbers and
        acronyms are kept; with `ignore_term_with_digits` as well, so is any
        term containing a digit. See docs/BEHAVIOR.md, section 8.
        """
        var replaced_words = Dict[String, Suggestion]()
        return self.lookup_compound(
            phrase,
            max_edit_distance,
            ignore_non_words,
            transfer_casing,
            split_by_space,
            ignore_term_with_digits,
            replaced_words=replaced_words,
        )

    def lookup_compound(
        self,
        phrase: StringSlice,
        max_edit_distance: Int,
        ignore_non_words: Bool = False,
        transfer_casing: Bool = False,
        split_by_space: Bool = False,
        ignore_term_with_digits: Bool = False,
        *,
        mut replaced_words: Dict[String, Suggestion],
    ) raises -> List[Suggestion]:
        """Like `lookup_compound`, also recording each replaced input term.

        `replaced_words` maps an input term to its replacement, like
        symspellpy's `replaced_words` attribute. Entries accumulate over calls
        that share the same dict.
        """
        return compound_impl(
            self,
            phrase,
            max_edit_distance,
            ignore_non_words,
            transfer_casing,
            split_by_space,
            ignore_term_with_digits,
            replaced_words,
        )

    def word_segmentation(
        self,
        phrase: StringSlice,
        max_edit_distance: Optional[Int] = None,
        max_segmentation_word_length: Optional[Int] = None,
        ignore_token: Optional[TokenPredicate] = None,
    ) raises -> Composition:
        """Splits text without spaces into words and corrects their spelling.

        Existing spaces are kept and considered. Runs in time linear in the
        text length. Unlike symspellpy, the text is not NFKC-normalized.
        See docs/BEHAVIOR.md, section 9.
        """
        return segmentation_impl(
            self,
            phrase,
            max_edit_distance,
            max_segmentation_word_length,
            ignore_token,
        )

    def lookup_batch(
        self,
        phrases: ImmSpan[String, _],
        verbosity: Verbosity,
        max_edit_distance: Optional[Int] = None,
        include_unknown: Bool = False,
        ignore_token: Optional[TokenPredicate] = None,
        transfer_casing: Bool = False,
        threads: Int = 0,
    ) raises -> List[List[Suggestion]]:
        """Looks up many words in parallel; `result[i]` is `lookup(phrases[i])`.

        `threads=0` uses one thread per logical CPU. Results are identical to
        calling `lookup` on each phrase in order. If a lookup raises, the
        first error is raised after all threads finish.
        """
        return batch_impl(
            self,
            phrases,
            verbosity,
            max_edit_distance,
            include_unknown,
            ignore_token,
            transfer_casing,
            threads,
        )
