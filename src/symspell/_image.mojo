"""The frozen index as one byte image: a header plus aligned typed sections.

The same bytes are kept in memory after `build()`, written by `save()` and
memory-mapped by `open()`, so a saved index is used without parsing.
All numbers are little-endian. Sections start at multiples of 64 bytes.

Header (256 bytes):
    0   magic "SYMSPELL"
    8   format version (UInt32)
    12  endianness marker 0x01020304 (UInt32)
    16  header size (UInt32)
    20  section count (UInt32)
    24  12 Int64 fields, see `Header`
    120 checksum (UInt64) of all bytes after the header
    128 section table: (offset, length in bytes) as UInt32 pairs
"""

from std.memory import unsafe_memcpy
from std.sys import size_of

from symspell.config import DistanceAlgorithm, SymSpellConfig
from symspell.text import utf8_codepoint_count

comptime MAGIC = "SYMSPELL"
comptime FORMAT_VERSION: UInt32 = 1
comptime ENDIAN_MARKER: UInt32 = 0x01020304
comptime HEADER_SIZE = 256
comptime ALIGNMENT = 64
comptime _FIELDS_OFFSET = 24
comptime _CHECKSUM_OFFSET = 120
comptime _TABLE_OFFSET = 128

# Section ids.
comptime TERM_OFFSETS = 0
"""UInt32[word_count + 1]: byte offsets of each term in TERM_ARENA."""
comptime TERM_ARENA = 1
"""UInt8: all terms, UTF-8, concatenated in term id order."""
comptime TERM_RECORD_OFFSETS = 2
"""UInt32[word_count]: offset of each term's record in TERM_RECORDS."""
comptime COUNTS = 3
"""Int64[word_count]: term counts."""
comptime TERM_SLOT_HASHES = 4
"""UInt64[term_slots]: open-addressing table of term hashes (0 = empty)."""
comptime TERM_SLOT_IDS = 5
"""UInt32[term_slots]: term id of each slot."""
comptime DELETE_SLOTS = 6
"""UInt32[2 * (delete_slots + 1)]: the deletes table, as (fingerprint, start) pairs.

A fingerprint is the upper half of a delete hash (never 0; 0 = empty slot).
A slot's postings are `POSTINGS[start : next slot's start]`; one final pair
`(0, total)` closes the last slot. Fingerprint and range sit side by side, so
a probe reads one cache line.
"""
comptime POSTINGS = 7
"""UInt32: term record offsets, grouped by slot, in term id order within a slot."""
comptime BIGRAM_OFFSETS = 8
"""UInt32[bigram_count + 1]: byte offsets of each bigram in BIGRAM_ARENA."""
comptime BIGRAM_ARENA = 9
"""UInt8: all bigram keys ("w1 w2"), UTF-8, concatenated."""
comptime BIGRAM_COUNTS = 10
"""Int64[bigram_count]: bigram counts."""
comptime BIGRAM_SLOT_HASHES = 11
"""UInt64[bigram_slots]: open-addressing table of bigram hashes (0 = empty)."""
comptime BIGRAM_SLOT_IDS = 12
"""UInt32[bigram_slots]: bigram id of each slot."""
comptime TERM_RECORDS = 13
"""UInt32: one record per term, in term id order: length, term id, codepoints.

A posting points straight at a record, so a lookup reads a term with one
memory access and never decodes UTF-8.
"""
comptime POSTING_LENGTHS = 14
"""UInt8[len(POSTINGS)]: min(term length, 255) of each posting.

Lets lookups apply length filters without touching the term records.
"""
comptime SECTION_COUNT = 15
comptime RECORD_HEADER = 2
"""Codepoints of a record start this many values after its offset."""


@fieldwise_init
struct Header(Copyable, Equatable, Movable, Writable):
    """The scalar fields of an index image."""

    var max_dictionary_edit_distance: Int
    var prefix_length: Int
    var count_threshold: Int
    var distance_algorithm: Int
    var word_count: Int
    var entry_count: Int
    var max_length: Int
    var bigram_count: Int
    var bigram_count_min: Int
    var term_slots: Int
    var delete_slots: Int
    var bigram_slots: Int

    def fields(self) -> List[Int]:
        return [
            self.max_dictionary_edit_distance,
            self.prefix_length,
            self.count_threshold,
            self.distance_algorithm,
            self.word_count,
            self.entry_count,
            self.max_length,
            self.bigram_count,
            self.bigram_count_min,
            self.term_slots,
            self.delete_slots,
            self.bigram_slots,
        ]

    @staticmethod
    def from_fields(f: List[Int]) -> Header:
        return Header(
            f[0],
            f[1],
            f[2],
            f[3],
            f[4],
            f[5],
            f[6],
            f[7],
            f[8],
            f[9],
            f[10],
            f[11],
        )


comptime _FIELD_COUNT = 12


def checksum(data: ImmSpan[UInt8, _]) -> UInt64:
    """A fast 64-bit checksum (FNV-1a over 8-byte words, then the tail)."""
    var h: UInt64 = 0xCBF29CE484222325
    var words = len(data) // 8
    var ptr = data.unsafe_ptr()
    var wide = ptr.unsafe_bitcast[UInt64]()
    for i in range(words):
        h = (h ^ wide.unsafe_offset(i).unsafe_load()) * 0x100000001B3
        h ^= h >> 29
    for i in range(words * 8, len(data)):
        h = (h ^ UInt64(data[i])) * 0x100000001B3
    return h


def _store[
    T: TrivialRegisterPassable
](mut bytes: List[UInt8], offset: Int, value: T):
    bytes.unsafe_ptr().unsafe_offset(offset).unsafe_bitcast[T]()[] = value


def _load[
    T: TrivialRegisterPassable
](bytes: ImmSpan[UInt8, _], offset: Int) -> T:
    return bytes.unsafe_ptr().unsafe_offset(offset).unsafe_bitcast[T]()[]


struct ImageWriter(Movable):
    """Builds an image: add sections in any order, then `finish`."""

    var bytes: List[UInt8]
    var offsets: List[Int]
    var lengths: List[Int]

    def __init__(out self):
        self.bytes = List[UInt8](length=HEADER_SIZE, fill=0)
        self.offsets = List[Int](length=SECTION_COUNT, fill=0)
        self.lengths = List[Int](length=SECTION_COUNT, fill=0)

    @staticmethod
    def space[T: TrivialRegisterPassable](count: Int) -> Int:
        """Bytes that a section of `count` values of `T` takes, with padding."""
        return (count * size_of[T]() + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT

    def reserve(mut self, section_bytes: Int):
        """Makes room for sections taking `section_bytes` (see `space`), so
        that adding them never moves the image."""
        self.bytes.reserve(len(self.bytes) + ALIGNMENT + section_bytes)

    def add[
        T: TrivialRegisterPassable
    ](mut self, section: Int, data: ImmSpan[T, _]):
        """Appends `data` as `section`, aligned to `ALIGNMENT` bytes."""
        var start = (len(self.bytes) + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
        var size = len(data) * size_of[T]()
        if start + size > self.bytes.capacity():
            # Grow geometrically: exact growth would copy the image each time.
            self.bytes.reserve(max(2 * self.bytes.capacity(), start + size))
        self.bytes.resize(start, 0)  # zero padding, for deterministic files
        self.bytes.resize(unsafe_uninit_length=start + size)  # memcpy fills it
        if size > 0:
            unsafe_memcpy(
                dest=self.bytes.unsafe_ptr().unsafe_offset(start),
                src=data.unsafe_ptr().unsafe_bitcast[UInt8](),
                count=size,
            )
        self.offsets[section] = start
        self.lengths[section] = size

    def finish(deinit self, header: Header) raises -> List[UInt8]:
        """Writes the header and checksum, and returns the image bytes."""
        var end = (len(self.bytes) + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
        self.bytes.resize(end, 0)
        if end > Int(UInt32.MAX):
            raise Error("index is too large for format version 1 (over 4 GiB)")
        for i in range(MAGIC.byte_length()):
            self.bytes[i] = MAGIC.as_bytes()[i]
        _store(self.bytes, 8, FORMAT_VERSION)
        _store(self.bytes, 12, ENDIAN_MARKER)
        _store(self.bytes, 16, UInt32(HEADER_SIZE))
        _store(self.bytes, 20, UInt32(SECTION_COUNT))
        var fields = header.fields()
        for i in range(len(fields)):
            _store(self.bytes, _FIELDS_OFFSET + 8 * i, Int64(fields[i]))
        for s in range(SECTION_COUNT):
            _store(self.bytes, _TABLE_OFFSET + 8 * s, UInt32(self.offsets[s]))
            _store(
                self.bytes, _TABLE_OFFSET + 8 * s + 4, UInt32(self.lengths[s])
            )
        var body = Span(self.bytes)[HEADER_SIZE:]
        _store(self.bytes, _CHECKSUM_OFFSET, checksum(body))
        return self.bytes^


@fieldwise_init
struct Section(ImplicitlyCopyable):
    var offset: Int
    var length: Int


def parse_image(
    data: ImmSpan[UInt8, _], verify_checksum: Bool
) raises -> Tuple[Header, List[Section]]:
    """Validates an image and returns its header and section table.

    Raises a clear error for anything that is not a valid, compatible image.
    Every section must lie inside the data, be aligned and have a whole number
    of elements, so later typed reads cannot go out of bounds.
    """
    if len(data) < HEADER_SIZE:
        raise Error("not a symspell index: file is too short")
    for i in range(MAGIC.byte_length()):
        if data[i] != MAGIC.as_bytes()[i]:
            raise Error("not a symspell index: bad magic bytes")
    var version = _load[UInt32](data, 8)
    if version != FORMAT_VERSION:
        raise Error(
            t"unsupported index format version {version} (expected"
            t" {FORMAT_VERSION})"
        )
    if _load[UInt32](data, 12) != ENDIAN_MARKER:
        raise Error("index was written on a machine with different byte order")
    if (
        _load[UInt32](data, 16) != HEADER_SIZE
        or _load[UInt32](data, 20) != SECTION_COUNT
    ):
        raise Error("corrupted index: bad header size or section count")
    var fields = List[Int]()
    for i in range(_FIELD_COUNT):
        fields.append(Int(_load[Int64](data, _FIELDS_OFFSET + 8 * i)))
    var sections = List[Section]()
    for s in range(SECTION_COUNT):
        var offset = Int(_load[UInt32](data, _TABLE_OFFSET + 8 * s))
        var length = Int(_load[UInt32](data, _TABLE_OFFSET + 8 * s + 4))
        if (
            offset < HEADER_SIZE
            or offset % ALIGNMENT != 0
            or offset + length > len(data)
        ):
            raise Error(t"corrupted index: section {s} is out of bounds")
        sections.append(Section(offset, length))
    # After the bounds check, so a truncated file is reported as such.
    if verify_checksum:
        var expected = _load[UInt64](data, _CHECKSUM_OFFSET)
        if checksum(data[HEADER_SIZE:]) != expected:
            raise Error("corrupted index: checksum mismatch")
    return (Header.from_fields(fields), sections^)


# ===----------------------------------------------------------------------=== #
# Structural validation
# ===----------------------------------------------------------------------=== #


def _corrupted(what: String) -> Error:
    return Error("corrupted index: ", what)


def _typed[
    T: TrivialRegisterPassable
](data: ImmSpan[UInt8, _], section: Section) -> ImmSpan[T, data.origin]:
    return ImmSpan[T, data.origin](
        unsafe_ptr=data.unsafe_ptr()
        .unsafe_offset(section.offset)
        .unsafe_bitcast[T](),
        length=section.length // size_of[T](),
    )


def _expect_length(sections: List[Section], section: Int, length: Int) raises:
    if sections[section].length != length:
        raise _corrupted(
            String(
                t"section {section} has {sections[section].length} bytes,"
                t" expected {length}"
            )
        )


def fingerprint(h: UInt64) -> UInt32:
    """The deletes-table key of a delete hash: its upper half, never 0."""
    var f = UInt32(h >> 32)
    return f if f != 0 else 1


def _check_slots(slots: Int, what: StringSlice) raises:
    if slots < 8 or (slots & (slots - 1)) != 0:
        raise _corrupted(
            String(t"{what} table size {slots} is not a power of two >= 8")
        )


def _check_offsets(
    offsets: ImmSpan[UInt32, _], arena_length: Int, what: StringSlice
) raises:
    """Offsets must rise from 0 to `arena_length`."""
    if offsets[0] != 0 or Int(offsets[len(offsets) - 1]) != arena_length:
        raise _corrupted(String(t"{what} offsets do not cover the arena"))
    for i in range(len(offsets) - 1):
        if offsets[i + 1] < offsets[i]:
            raise _corrupted(String(t"{what} offsets are not increasing"))


def _check_strings(
    data: ImmSpan[UInt8, _],
    sections: List[Section],
    offsets_section: Int,
    arena_section: Int,
    what: StringSlice,
) raises:
    """Each string must be valid UTF-8 inside its arena."""
    var offsets = _typed[UInt32](data, sections[offsets_section])
    var arena = _typed[UInt8](data, sections[arena_section])
    _check_offsets(offsets, len(arena), what)
    for i in range(len(offsets) - 1):
        var count = utf8_codepoint_count(
            arena[Int(offsets[i]) : Int(offsets[i + 1])]
        )
        if count < 0:
            raise _corrupted(String(t"{what} {i} is not valid UTF-8"))


def _check_records(
    data: ImmSpan[UInt8, _], sections: List[Section], word_count: Int
) raises:
    """Term records must be contiguous, in id order, and match the UTF-8 terms.
    """
    var offsets = _typed[UInt32](data, sections[TERM_OFFSETS])
    var arena = _typed[UInt8](data, sections[TERM_ARENA])
    var record_offsets = _typed[UInt32](data, sections[TERM_RECORD_OFFSETS])
    var records = _typed[UInt32](data, sections[TERM_RECORDS])
    var position = 0
    for term_id in range(word_count):
        if Int(
            record_offsets[term_id]
        ) != position or position + RECORD_HEADER > len(records):
            raise _corrupted(String(t"term record {term_id} is misplaced"))
        var length = Int(records[position])
        if Int(
            records[position + 1]
        ) != term_id or position + RECORD_HEADER + length > len(records):
            raise _corrupted(String(t"term record {term_id} is malformed"))
        var text = StringSlice(
            unsafe_from_utf8=arena[
                Int(offsets[term_id]) : Int(offsets[term_id + 1])
            ]
        )
        var k = position + RECORD_HEADER
        for c in text.codepoints():
            if (
                k == position + RECORD_HEADER + length
                or records[k] != c.to_u32()
            ):
                raise _corrupted(
                    String(t"term record {term_id} does not match its text")
                )
            k += 1
        if k != position + RECORD_HEADER + length:
            raise _corrupted(
                String(t"term record {term_id} does not match its text")
            )
        position = k
    if position != len(records):
        raise _corrupted("term records have trailing data")


def _check_table(
    data: ImmSpan[UInt8, _],
    sections: List[Section],
    hashes_section: Int,
    ids_section: Int,
    id_limit: Int,
    what: StringSlice,
) raises:
    """Ids must be in range and at least one slot must be empty (probing stops).
    """
    var hashes = _typed[UInt64](data, sections[hashes_section])
    var empty = 0
    for h in hashes:
        if h == 0:
            empty += 1
    if empty == 0:
        raise _corrupted(String(t"{what} table has no empty slot"))
    if ids_section >= 0:
        var ids = _typed[UInt32](data, sections[ids_section])
        for i in range(len(ids)):
            if hashes[i] != 0 and Int(ids[i]) >= id_limit:
                raise _corrupted(String(t"{what} table points past the end"))


def validate_image(
    data: ImmSpan[UInt8, _], header: Header, sections: List[Section]
) raises:
    """Checks every invariant that lookups rely on to stay in bounds.

    After this succeeds, no read of the index can go outside `data`, even for
    a deliberately crafted file. Takes time linear in the file size.
    """
    var config = SymSpellConfig(
        header.max_dictionary_edit_distance,
        header.prefix_length,
        header.count_threshold,
        DistanceAlgorithm(header.distance_algorithm),
    )
    try:
        config.validate()
    except e:
        raise _corrupted(String(e))
    if header.distance_algorithm != 0 and header.distance_algorithm != 1:
        raise _corrupted("unknown distance algorithm")
    var limit = len(data)
    for value in [
        header.word_count,
        header.entry_count,
        header.max_length,
        header.bigram_count,
        header.term_slots,
        header.delete_slots,
        header.bigram_slots,
    ]:
        if value < 0 or value > limit:
            raise _corrupted("a header count is out of range")
    var wc = header.word_count
    var bc = header.bigram_count
    _check_slots(header.term_slots, "term")
    _check_slots(header.delete_slots, "delete")
    _check_slots(header.bigram_slots, "bigram")
    _expect_length(sections, TERM_OFFSETS, 4 * (wc + 1))
    _expect_length(sections, TERM_RECORD_OFFSETS, 4 * wc)
    if sections[TERM_RECORDS].length % 4 != 0:
        raise _corrupted("term records size is not a multiple of 4")
    _expect_length(sections, COUNTS, 8 * wc)
    _expect_length(sections, TERM_SLOT_HASHES, 8 * header.term_slots)
    _expect_length(sections, TERM_SLOT_IDS, 4 * header.term_slots)
    _expect_length(sections, DELETE_SLOTS, 8 * (header.delete_slots + 1))
    _expect_length(sections, BIGRAM_OFFSETS, 4 * (bc + 1))
    _expect_length(sections, BIGRAM_COUNTS, 8 * bc)
    _expect_length(sections, BIGRAM_SLOT_HASHES, 8 * header.bigram_slots)
    _expect_length(sections, BIGRAM_SLOT_IDS, 4 * header.bigram_slots)
    if sections[POSTINGS].length % 4 != 0:
        raise _corrupted("postings size is not a multiple of 4")
    _expect_length(sections, POSTING_LENGTHS, sections[POSTINGS].length // 4)

    _check_strings(data, sections, TERM_OFFSETS, TERM_ARENA, "term")
    _check_strings(data, sections, BIGRAM_OFFSETS, BIGRAM_ARENA, "bigram")
    _check_records(data, sections, wc)
    _check_table(data, sections, TERM_SLOT_HASHES, TERM_SLOT_IDS, wc, "term")
    _check_table(
        data, sections, BIGRAM_SLOT_HASHES, BIGRAM_SLOT_IDS, bc, "bigram"
    )
    var slots = _typed[UInt32](data, sections[DELETE_SLOTS])
    var postings = _typed[UInt32](data, sections[POSTINGS])
    var empty = 0
    for i in range(header.delete_slots):
        if slots[2 * i] == 0:
            empty += 1
        if slots[2 * i + 3] < slots[2 * i + 1]:
            raise _corrupted("delete buckets are not increasing")
    if empty == 0:
        raise _corrupted("delete table has no empty slot")
    if slots[1] != 0 or Int(slots[len(slots) - 1]) != len(postings):
        raise _corrupted("delete buckets do not cover the postings")
    # Every posting must be the offset of a record start. A bitmap of the
    # record starts is small enough to stay in the CPU cache, so this pass
    # reads the postings sequentially. Posting lengths are only hints for
    # filtering, and lookups never trust them for memory access, so they are
    # left to the checksum.
    var records_length = sections[TERM_RECORDS].length // 4
    var record_offsets = _typed[UInt32](data, sections[TERM_RECORD_OFFSETS])
    var is_start = List[UInt64](length=records_length // 64 + 1, fill=0)
    for term_id in range(wc):
        var offset = Int(record_offsets[term_id])
        is_start[offset >> 6] |= UInt64(1) << UInt64(offset & 63)
    for k in range(len(postings)):
        var offset = Int(postings[k])
        if offset >= records_length:
            raise _corrupted("a posting points past the last term")
        if (is_start[offset >> 6] >> UInt64(offset & 63)) & 1 == 0:
            raise _corrupted("a posting does not point at a term record")
