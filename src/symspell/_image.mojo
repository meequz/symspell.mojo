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
comptime TERM_LENGTHS = 2
"""UInt32[word_count]: term lengths in codepoints."""
comptime COUNTS = 3
"""Int64[word_count]: term counts."""
comptime TERM_SLOT_HASHES = 4
"""UInt64[term_slots]: open-addressing table of term hashes (0 = empty)."""
comptime TERM_SLOT_IDS = 5
"""UInt32[term_slots]: term id of each slot."""
comptime DELETE_SLOT_HASHES = 6
"""UInt64[delete_slots]: open-addressing table of delete hashes (0 = empty)."""
comptime DELETE_SLOT_STARTS = 7
"""UInt32[delete_slots + 1]: CSR offsets of each slot's postings."""
comptime POSTINGS = 8
"""UInt32: term ids, grouped by slot, in term id order within a slot."""
comptime BIGRAM_OFFSETS = 9
"""UInt32[bigram_count + 1]: byte offsets of each bigram in BIGRAM_ARENA."""
comptime BIGRAM_ARENA = 10
"""UInt8: all bigram keys ("w1 w2"), UTF-8, concatenated."""
comptime BIGRAM_COUNTS = 11
"""Int64[bigram_count]: bigram counts."""
comptime BIGRAM_SLOT_HASHES = 12
"""UInt64[bigram_slots]: open-addressing table of bigram hashes (0 = empty)."""
comptime BIGRAM_SLOT_IDS = 13
"""UInt32[bigram_slots]: bigram id of each slot."""
comptime SECTION_COUNT = 14


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

    def add[
        T: TrivialRegisterPassable
    ](mut self, section: Int, data: ImmSpan[T, _]):
        """Appends `data` as `section`, aligned to `ALIGNMENT` bytes."""
        var start = (len(self.bytes) + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
        var size = len(data) * size_of[T]()
        self.bytes.resize(start + size, 0)
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
    if verify_checksum:
        var expected = _load[UInt64](data, _CHECKSUM_OFFSET)
        if checksum(data[HEADER_SIZE:]) != expected:
            raise Error("corrupted index: checksum mismatch")
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
    return (Header.from_fields(fields), sections^)
