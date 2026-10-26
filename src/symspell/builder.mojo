"""The mutable dictionary builder.

`SymSpellBuilder` collects terms, counts and bigrams with symspellpy's exact
rules (docs/BEHAVIOR.md, section 2). `build()` turns it into a frozen,
read-only `SymSpell` index.

Unlike symspellpy, the builder does not maintain the deletes index while
words are added: it is computed once, in `build()`. Adding words after a
lookup (symspellpy's incremental workflow) therefore means building again;
`snapshot()` builds without consuming the builder. Each build costs about as
much as building the whole dictionary from scratch.
"""

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
    ImageWriter,
)
from symspell._hash import hash_codepoints
from symspell.config import SymSpellConfig
from symspell.delete_index import (
    build_delete_table,
    build_id_table,
    slot_count_for,
)
from symspell.index import SymSpell
from symspell.io import (
    read_lines,
    read_text,
    rstrip_whitespace,
    split_fields,
    py_index,
)
from symspell.text import to_codepoints
from symspell.tokenize import (
    parse_corpus_words,
    split_whitespace,
    try_parse_int64,
)

comptime MAXSIZE = 9223372036854775807
"""Python's `sys.maxsize`; counts saturate here."""


def increment_count(count: Int, count_previous: Int) -> Int:
    """Port of symspellpy `helpers.increment_count`: adds, saturating at `MAXSIZE`.
    """
    if MAXSIZE - count_previous > count:
        return count_previous + count
    return MAXSIZE


struct SymSpellBuilder(Copyable, Movable):
    """A mutable dictionary. Call `build()` to get a `SymSpell` index."""

    var config: SymSpellConfig
    # Words in the order they became correct spellings. A deleted word keeps
    # its slot with `_alive` false; adding it again appends a new slot.
    var _terms: List[String]
    var _counts: List[Int]
    var _lengths: List[Int]
    var _alive: List[Bool]
    var _slot_of: Dict[String, Int]
    var _word_count: Int
    var _below_threshold: Dict[String, Int]
    var _bigrams: Dict[String, Int]
    var _bigram_count_min: Int
    var _max_length: Int

    def __init__(out self, config: SymSpellConfig = SymSpellConfig()) raises:
        """Creates an empty dictionary. Raises if `config` is invalid."""
        config.validate()
        self.config = config
        self._terms = List[String]()
        self._counts = List[Int]()
        self._lengths = List[Int]()
        self._alive = List[Bool]()
        self._slot_of = Dict[String, Int]()
        self._word_count = 0
        self._below_threshold = Dict[String, Int]()
        self._bigrams = Dict[String, Int]()
        self._bigram_count_min = MAXSIZE
        self._max_length = 0

    # --- Entries ---

    def create_dictionary_entry(mut self, key: StringSlice, count: Int) -> Bool:
        """Adds `count` occurrences of `key`.

        Returns True only if `key` became a new correct spelling. Counts merge
        and saturate at 2**63 - 1. Words whose total stays below
        `count_threshold` are kept apart and do not appear in lookups.
        """
        var threshold = self.config.count_threshold
        var c = count
        if c <= 0:
            if threshold > 0:
                return False
            c = 0
        var term = String(key)
        var below = self._below_threshold.get(term) if threshold > 1 else None
        if below:
            c = increment_count(c, below.value())
            if c >= threshold:
                _ = self._below_threshold.pop(term, 0)
            else:
                self._below_threshold[term] = c
                return False
        else:
            var slot = self._slot_of.get(term)
            if slot:
                self._counts[slot.value()] = increment_count(
                    c, self._counts[slot.value()]
                )
                return False
            if c < threshold:
                self._below_threshold[term] = c
                return False
        var length = term.count_codepoints()
        self._slot_of[term] = len(self._terms)
        self._terms.append(term^)
        self._counts.append(c)
        self._lengths.append(length)
        self._alive.append(True)
        self._word_count += 1
        if length > self._max_length:
            self._max_length = length
        return True

    def delete_dictionary_entry(mut self, key: StringSlice) raises -> Bool:
        """Removes a correct spelling. Returns False if `key` is not one.

        Raises when the last word is deleted while it is the longest one,
        like symspellpy (the word is removed anyway).
        """
        var term = String(key)
        if term not in self._slot_of:
            return False
        var slot = self._slot_of.pop(term)
        self._alive[slot] = False
        self._word_count -= 1
        if self._lengths[slot] == self._max_length:
            if self._word_count == 0:
                raise Error("max() iterable argument is empty")
            var longest = 0
            for i in range(len(self._terms)):
                if self._alive[i] and self._lengths[i] > longest:
                    longest = self._lengths[i]
            self._max_length = longest
        return True

    def set_bigram(mut self, key: StringSlice, count: Int):
        """Sets a bigram count directly, like assigning to symspellpy's
        `bigrams` dict. Unlike `load_bigram_dictionary`, this does not update
        the minimum bigram count used by `lookup_compound`.
        """
        self._bigrams[String(key)] = count

    # --- Loading ---

    def load_dictionary(
        mut self,
        path: StringSlice,
        term_index: Int = 0,
        count_index: Int = 1,
        separator: StringSlice = " ",
    ) raises:
        """Loads "term count" lines from a UTF-8 text file.

        Lines with fewer than two fields, or whose count is not a 64-bit
        integer, are skipped. Raises if the file is missing or not UTF-8.
        """
        var text = read_text(path, "Dictionary file")
        for line in read_lines(text):
            var parts = split_fields(rstrip_whitespace(line), separator)
            if len(parts) < 2:
                continue
            var count = try_parse_int64(
                parts[py_index(len(parts), count_index)]
            )
            if not count:
                continue
            var key = parts[py_index(len(parts), term_index)]
            _ = self.create_dictionary_entry(key, count.value())

    def load_bigram_dictionary(
        mut self,
        path: StringSlice,
        term_index: Int = 0,
        count_index: Int = 2,
        separator: Optional[String] = None,
    ) raises:
        """Loads bigram lines from a UTF-8 text file.

        Without a separator, lines are split on whitespace and the bigram is
        the two fields at `term_index` and `term_index + 1`. With one, the
        bigram is the single field at `term_index`.
        """
        var text = read_text(path, "Bigram dictionary file")
        var min_parts = 3 if not separator else 2
        for line in read_lines(text):
            var stripped = rstrip_whitespace(line)
            var parts: List[String]
            if separator:
                parts = split_fields(stripped, separator.value())
            else:
                parts = split_whitespace(to_codepoints(stripped))
            if len(parts) < min_parts:
                continue
            var count = try_parse_int64(
                parts[py_index(len(parts), count_index)]
            )
            if not count:
                continue
            var key: String
            if separator:
                key = parts[py_index(len(parts), term_index)]
            else:
                key = String(
                    parts[py_index(len(parts), term_index)],
                    " ",
                    parts[py_index(len(parts), term_index + 1)],
                )
            self._bigrams[key] = count.value()
            if count.value() < self._bigram_count_min:
                self._bigram_count_min = count.value()

    def create_dictionary(mut self, corpus_path: StringSlice) raises:
        """Counts every word of a UTF-8 text file, one occurrence at a time."""
        var text = read_text(corpus_path, "Corpus")
        for word in parse_corpus_words(text):
            _ = self.create_dictionary_entry(word, 1)

    # --- Inspection ---

    def word_count(self) -> Int:
        """Number of correct spellings."""
        return self._word_count

    def max_length(self) -> Int:
        """Length in codepoints of the longest correct spelling."""
        return self._max_length

    def count(self, key: StringSlice) -> Optional[Int]:
        """The count of a correct spelling, or None."""
        var slot = self._slot_of.get(String(key))
        if not slot:
            return None
        return self._counts[slot.value()]

    def below_threshold_count(self, key: StringSlice) -> Optional[Int]:
        """The count of a word below `count_threshold`, or None."""
        return self._below_threshold.get(String(key))

    def below_threshold_size(self) -> Int:
        """Number of words below `count_threshold`."""
        return len(self._below_threshold)

    def bigram_count(self, key: StringSlice) -> Optional[Int]:
        """The count of a bigram, or None."""
        return self._bigrams.get(String(key))

    def bigram_size(self) -> Int:
        """Number of bigrams."""
        return len(self._bigrams)

    def bigram_count_min(self) -> Int:
        """The smallest loaded bigram count (2**63 - 1 if none was loaded)."""
        return self._bigram_count_min

    # --- Building ---

    def build(var self) raises -> SymSpell:
        """Builds the frozen index, consuming the builder."""
        return self.snapshot()

    def snapshot(self) raises -> SymSpell:
        """Builds the frozen index and keeps the builder for more changes."""
        var writer = ImageWriter()
        var term_count = self._add_terms(writer)
        var bigram_count = self._add_bigrams(writer)
        var header = Header(
            max_dictionary_edit_distance=self.config.max_dictionary_edit_distance,
            prefix_length=self.config.prefix_length,
            count_threshold=self.config.count_threshold,
            distance_algorithm=self.config.distance_algorithm.value,
            word_count=self._word_count,
            entry_count=term_count[0],
            max_length=self._max_length,
            bigram_count=bigram_count,
            bigram_count_min=self._bigram_count_min,
            term_slots=term_count[1],
            delete_slots=term_count[2],
            bigram_slots=slot_count_for(bigram_count),
        )
        return SymSpell(writer^.finish(header))

    def _add_terms(
        self, mut writer: ImageWriter
    ) raises -> Tuple[Int, Int, Int]:
        """Adds the term sections. Returns (entry_count, term_slots, delete_slots).
        """
        var arena = List[UInt8]()
        var offsets = List[UInt32](capacity=self._word_count + 1)
        var lengths = List[UInt32](capacity=self._word_count)
        var counts = List[Int64](capacity=self._word_count)
        var hashes = List[UInt64](capacity=self._word_count)
        var codepoints = List[List[UInt32]](capacity=self._word_count)
        var ghosts = List[List[UInt32]]()
        for slot in range(len(self._terms)):
            var cps = to_codepoints(self._terms[slot])
            if not self._alive[slot]:
                ghosts.append(cps^)
                continue
            offsets.append(UInt32(len(arena)))
            arena.extend(self._terms[slot].as_bytes())
            lengths.append(UInt32(len(cps)))
            counts.append(Int64(self._counts[slot]))
            hashes.append(hash_codepoints(cps))
            codepoints.append(cps^)
        offsets.append(UInt32(len(arena)))
        var terms = build_id_table(hashes)
        var deletes = build_delete_table(
            codepoints,
            ghosts,
            self.config.max_dictionary_edit_distance,
            self.config.prefix_length,
        )
        writer.add(TERM_OFFSETS, offsets)
        writer.add(TERM_ARENA, arena)
        writer.add(TERM_LENGTHS, lengths)
        writer.add(COUNTS, counts)
        writer.add(TERM_SLOT_HASHES, terms.hashes)
        writer.add(TERM_SLOT_IDS, terms.ids)
        writer.add(DELETE_SLOT_HASHES, deletes.slot_hashes)
        writer.add(DELETE_SLOT_STARTS, deletes.slot_starts)
        writer.add(POSTINGS, deletes.postings)
        return (
            deletes.entry_count,
            len(terms.hashes),
            len(deletes.slot_hashes),
        )

    def _add_bigrams(self, mut writer: ImageWriter) -> Int:
        """Adds the bigram sections. Returns the number of bigrams."""
        var arena = List[UInt8]()
        var offsets = List[UInt32](capacity=len(self._bigrams) + 1)
        var counts = List[Int64](capacity=len(self._bigrams))
        var hashes = List[UInt64](capacity=len(self._bigrams))
        for entry in self._bigrams.items():
            offsets.append(UInt32(len(arena)))
            arena.extend(entry.key.as_bytes())
            counts.append(Int64(entry.value))
            hashes.append(hash_codepoints(to_codepoints(entry.key)))
        offsets.append(UInt32(len(arena)))
        var table = build_id_table(hashes)
        writer.add(BIGRAM_OFFSETS, offsets)
        writer.add(BIGRAM_ARENA, arena)
        writer.add(BIGRAM_COUNTS, counts)
        writer.add(BIGRAM_SLOT_HASHES, table.hashes)
        writer.add(BIGRAM_SLOT_IDS, table.ids)
        return len(self._bigrams)
