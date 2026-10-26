"""The frozen, read-only SymSpell index and `lookup`.

All data lives in one byte image (see `_image.mojo`). The index never changes
after construction, so any number of threads can look up concurrently, each
with its own `LookupScratch`.
"""

from std.sys import size_of

from symspell._hash import hash_codepoints
from symspell._image import (
    BIGRAM_ARENA,
    BIGRAM_COUNTS,
    BIGRAM_OFFSETS,
    BIGRAM_SLOT_HASHES,
    BIGRAM_SLOT_IDS,
    COUNTS,
    DELETE_SLOT_HASHES,
    DELETE_SLOT_STARTS,
    POSTINGS,
    TERM_ARENA,
    TERM_LENGTHS,
    TERM_OFFSETS,
    TERM_SLOT_HASHES,
    TERM_SLOT_IDS,
    Header,
    Section,
    parse_image,
    validate_image,
)
from symspell._mmap import MappedFile
from symspell.casing import case_transfer_similar
from symspell.config import DistanceAlgorithm, SymSpellConfig
from symspell.delete_index import EMPTY, find_slot, is_delete_of, probe_start
from symspell.scratch import Hit, LookupScratch
from symspell.suggestion import Composition, Suggestion, sort_suggestions
from symspell.compound import lookup_compound as compound_impl
from symspell.segmentation import word_segmentation as segmentation_impl
from symspell.text import decode, lower, to_codepoints, to_string
from symspell.tokenize import TokenPredicate
from symspell.verbosity import Verbosity

comptime _Bytes = ImmSpan[UInt8, ImmUntrackedOrigin]


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
    for i in range(len(a)):
        if a[i] != b[i]:
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
    var _sections: List[Section]

    def __init__(out self, var image: List[UInt8]) raises:
        """Wraps a freshly built image. Use `SymSpellBuilder.build()` instead.
        """
        var parsed = parse_image(image, verify_checksum=False)
        self._header = parsed[0].copy()
        self._sections = parsed[1].copy()
        self._base = (
            image.unsafe_ptr().as_imm().unsafe_origin_cast[ImmUntrackedOrigin]()
        )
        self._size = len(image)
        self._storage = image^
        self._mapping = None

    def __init__(
        out self, var mapping: MappedFile, verify_checksum: Bool
    ) raises:
        """Wraps a mapped file after validating it. Use `SymSpell.open`."""
        var data = mapping.bytes()
        var parsed = parse_image(data, verify_checksum)
        validate_image(data, parsed[0], parsed[1])
        self._header = parsed[0].copy()
        self._sections = parsed[1].copy()
        self._base = data.unsafe_ptr()
        self._size = len(data)
        self._storage = List[UInt8]()
        self._mapping = mapping^

    @staticmethod
    def open(
        path: StringSlice, verify_checksum: Bool = True, use_mmap: Bool = True
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
        """
        var file = String(path)
        if use_mmap:
            var mapping: Optional[MappedFile] = None
            try:
                mapping = MappedFile(file)
            except:
                pass  # fall back to reading the file below
            if mapping:
                return SymSpell(mapping.take(), verify_checksum)
        var image: List[UInt8]
        with open(file, "r") as f:
            image = f.read_bytes()
        var parsed = parse_image(image, verify_checksum)
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

    # --- Typed views of the image ---

    def _view[
        T: TrivialRegisterPassable
    ](self, section: Int) -> ImmSpan[T, ImmUntrackedOrigin]:
        var s = self._sections[section]
        return ImmSpan[T, ImmUntrackedOrigin](
            unsafe_ptr=self._base.unsafe_offset(s.offset).unsafe_bitcast[T](),
            length=s.length // size_of[T](),
        )

    def _term_bytes(self, term_id: Int) -> _Bytes:
        var offsets = self._view[UInt32](TERM_OFFSETS)
        var start = Int(offsets[term_id])
        var end = Int(offsets[term_id + 1])
        return self._view[UInt8](TERM_ARENA)[start:end]

    def term(self, term_id: Int) -> StringSlice[ImmUntrackedOrigin]:
        """The UTF-8 text of a term."""
        return StringSlice(unsafe_from_utf8=self._term_bytes(term_id))

    def _term_length(self, term_id: Int) -> Int:
        return Int(self._view[UInt32](TERM_LENGTHS)[term_id])

    def _count(self, term_id: Int) -> Int:
        return Int(self._view[Int64](COUNTS)[term_id])

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

    def _find_term(
        self, text: ImmSpan[UInt32, _], mut buffer: List[UInt32]
    ) -> Int:
        """Term id of `text`, or -1. `buffer` is scratch space."""
        var hashes = self._view[UInt64](TERM_SLOT_HASHES)
        var ids = self._view[UInt32](TERM_SLOT_IDS)
        var h = hash_codepoints(text)
        var mask = len(hashes) - 1
        var i = probe_start(h, len(hashes))
        while hashes[i] != EMPTY:
            if hashes[i] == h:
                var term_id = Int(ids[i])
                decode(self.term(term_id), buffer)
                if _spans_equal(buffer, text):
                    return term_id
            i = (i + 1) & mask
        return -1

    def contains(self, term: StringSlice) -> Bool:
        """Whether `term` is a correctly spelled word."""
        var buffer = List[UInt32]()
        return self._find_term(to_codepoints(term), buffer) >= 0

    def count(self, term: StringSlice) -> Optional[Int]:
        """The count of a correctly spelled word, or None."""
        var buffer = List[UInt32]()
        var term_id = self._find_term(to_codepoints(term), buffer)
        if term_id < 0:
            return None
        return self._count(term_id)

    def bigram_count(self, bigram: StringSlice) -> Optional[Int]:
        """The count of a bigram ("word1 word2"), or None."""
        var hashes = self._view[UInt64](BIGRAM_SLOT_HASHES)
        var ids = self._view[UInt32](BIGRAM_SLOT_IDS)
        var offsets = self._view[UInt32](BIGRAM_OFFSETS)
        var arena = self._view[UInt8](BIGRAM_ARENA)
        var counts = self._view[Int64](BIGRAM_COUNTS)
        var h = hash_codepoints(to_codepoints(bigram))
        var mask = len(hashes) - 1
        var i = probe_start(h, len(hashes))
        while hashes[i] != EMPTY:
            if hashes[i] == h:
                var b = Int(ids[i])
                var key = StringSlice(
                    unsafe_from_utf8=arena[
                        Int(offsets[b]) : Int(offsets[b + 1])
                    ]
                )
                if key == bigram:
                    return Int(counts[b])
            i = (i + 1) & mask
        return None

    def _bucket_terms(self, delete: StringSlice) -> List[String]:
        """Terms that have `delete` among their deletes (a test hook)."""
        var out = List[String]()
        var cps = to_codepoints(delete)
        var slot = find_slot(
            self._view[UInt64](DELETE_SLOT_HASHES), hash_codepoints(cps)
        )
        if slot < 0:
            return out^
        var starts = self._view[UInt32](DELETE_SLOT_STARTS)
        var postings = self._view[UInt32](POSTINGS)
        var term = List[UInt32]()
        for k in range(Int(starts[slot]), Int(starts[slot + 1])):
            var term_id = Int(postings[k])
            decode(self.term(term_id), term)
            if is_delete_of(
                cps,
                term,
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
        var exact = self._find_term(scratch.phrase, scratch.term)
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
        scratch.reset_candidates()
        var phrase_prefix_len = phrase_len
        if phrase_prefix_len > p:
            phrase_prefix_len = p
            scratch.push_phrase_prefix(p)
        else:
            scratch.push_phrase_prefix(len(scratch.phrase))
        var hashes = self._view[UInt64](DELETE_SLOT_HASHES)
        var starts = self._view[UInt32](DELETE_SLOT_STARTS)
        var postings = self._view[UInt32](POSTINGS)
        var d = self._header.max_dictionary_edit_distance
        var pointer = 0
        while pointer < scratch.candidate_count():
            scratch.load_candidate(pointer)
            pointer += 1
            var candidate_len = len(scratch.current)
            var len_diff = phrase_prefix_len - candidate_len
            if len_diff > med2:
                if verbosity == Verbosity.ALL:
                    continue
                break

            var slot = find_slot(hashes, hash_codepoints(scratch.current))
            if slot >= 0:
                for k in range(Int(starts[slot]), Int(starts[slot + 1])):
                    var term_id = Int(postings[k])
                    decode(self.term(term_id), scratch.term)
                    if not is_delete_of(scratch.current, scratch.term, d, p):
                        continue  # hash collision
                    med2 = self._consider(
                        term_id,
                        candidate_len,
                        phrase_len,
                        phrase_prefix_len,
                        med,
                        med2,
                        verbosity,
                        scratch,
                    )

            # Add the deletes of this candidate as new candidates.
            if len_diff < med and candidate_len <= p:
                if verbosity != Verbosity.ALL and len_diff >= med2:
                    continue
                for i in range(candidate_len):
                    scratch.delete.clear()
                    for j in range(candidate_len):
                        if j != i:
                            scratch.delete.append(scratch.current[j])
                    _ = scratch.add_delete_if_new()
        return True

    def _consider(
        self,
        term_id: Int,
        candidate_len: Int,
        phrase_len: Int,
        phrase_prefix_len: Int,
        med: Int,
        med2_in: Int,
        verbosity: Verbosity,
        mut scratch: LookupScratch,
    ) raises -> Int:
        """Checks one suggestion (`scratch.term`) and records it as a hit.

        Returns the new `max_edit_distance_2` (med2).
        """
        var med2 = med2_in
        var p = self._header.prefix_length
        ref phrase = scratch.phrase
        ref suggestion = scratch.term
        if _spans_equal(suggestion, phrase):
            return med2
        var suggestion_len = self._term_length(term_id)
        if (
            abs(suggestion_len - phrase_len) > med2
            or suggestion_len < candidate_len
            or (
                suggestion_len == candidate_len
                and not _spans_equal(suggestion, scratch.current)
            )
        ):
            return med2
        var suggestion_prefix_len = min(suggestion_len, p)
        if (
            suggestion_prefix_len > phrase_prefix_len
            and suggestion_prefix_len - candidate_len > med2
        ):
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
            if (
                self._header.distance_algorithm
                == DistanceAlgorithm.LEVENSHTEIN.value
            ):
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
            if terms.keys[i] == key:
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
        if completed and len(suggestions) > 1:
            sort_suggestions(suggestions)
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
