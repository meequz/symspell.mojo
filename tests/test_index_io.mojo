"""Tests for the binary index format: save, open, round trips and bad files."""

from std.os import makedirs, remove
from std.os.path import exists
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from _fixtures import FIXTURES
from _oracles import Rng
from symspell import (
    LookupScratch,
    SymSpell,
    SymSpellBuilder,
    SymSpellConfig,
    Verbosity,
)
from symspell._image import checksum
from symspell.text import to_codepoints

comptime TMP = "build/tmp/"


def _tmp(name: StringSlice) raises -> String:
    if not exists(TMP):
        makedirs(TMP)
    return String(TMP, name)


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _write(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


def _intl_index() raises -> SymSpell:
    var builder = SymSpellBuilder(SymSpellConfig(2, 7))
    builder.load_dictionary(String(FIXTURES, "dict_intl.txt"))
    builder.load_bigram_dictionary(String(FIXTURES, "bigrams_intl.txt"))
    return builder^.build()


def _english_index() raises -> SymSpell:
    var builder = SymSpellBuilder()
    builder.load_dictionary("data/frequency_dictionary_en_82_765.txt")
    builder.load_bigram_dictionary(
        "data/frequency_bigramdictionary_en_243_342.txt"
    )
    return builder^.build()


def _queries(seed: UInt64, words: List[String], n: Int) -> List[String]:
    var rng = Rng(seed)
    var alphabet = to_codepoints(
        "abcdefghijklmnopqrstuvwxyzабвгдеёжзійўąłńüωéß"
    )
    var out = List[String]()
    for _ in range(n):
        var text = String()
        for cp in rng.mutate(
            to_codepoints(words[rng.below(len(words))]),
            alphabet,
            rng.between(0, 3),
        ):
            text.append(Codepoint(unsafe_unchecked_codepoint=cp))
        out.append(text^)
    return out^


def _assert_same(
    a: SymSpell, b: SymSpell, queries: List[String], label: String
) raises:
    assert_equal(a.word_count(), b.word_count(), label)
    assert_equal(a.entry_count(), b.entry_count(), label)
    assert_equal(a.max_length(), b.max_length(), label)
    assert_equal(a.bigram_size(), b.bigram_size(), label)
    assert_equal(a.bigram_count_min(), b.bigram_count_min(), label)
    assert_true(a.config() == b.config(), label)
    var sa = LookupScratch()
    var sb = LookupScratch()
    for q in queries:
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            var ra = a.lookup(q, v, 2, scratch=sa)
            var rb = b.lookup(q, v, 2, scratch=sb)
            assert_equal(len(ra), len(rb), String(label, ": ", q))
            for i in range(len(ra)):
                assert_equal(ra[i].term, rb[i].term, String(label, ": ", q))
                assert_equal(
                    ra[i].distance, rb[i].distance, String(label, ": ", q)
                )
                assert_equal(ra[i].count, rb[i].count, String(label, ": ", q))


def test_round_trip() raises:
    var words = List[String]()
    with open(String(FIXTURES, "dict_intl.txt"), "r") as f:
        for line in f.read().splitlines():
            words.append(String(line.split(" ")[0]))
    var queries = _queries(3, words, 600)
    var index = _intl_index()
    var path = _tmp("intl.idx")
    index.save(path)
    var mapped = SymSpell.open(path)
    assert_true(mapped.is_memory_mapped())
    _assert_same(index, mapped, queries, "mmap")
    _assert_same(
        index,
        SymSpell.open(path, verify_checksum=False),
        queries,
        "no checksum",
    )
    _assert_same(index, SymSpell.open(path, trusted=True), queries, "trusted")
    _assert_same(
        index,
        SymSpell.open(path, use_mmap=False, trusted=True),
        queries,
        "trusted read",
    )
    var read = SymSpell.open(path, use_mmap=False)
    assert_false(read.is_memory_mapped())
    _assert_same(index, read, queries, "read")
    # Bigrams and exact lookups survive too.
    assert_equal(
        mapped.bigram_count("сям'я λόγος").or_else(-1),
        index.bigram_count("сям'я λόγος").or_else(-1),
    )
    for w in words[:200]:
        assert_equal(mapped.count(w).value(), index.count(w).value(), w)
    # A re-saved mapped index is byte-identical.
    var again = _tmp("intl_again.idx")
    mapped.save(again)
    assert_true(_read(path) == _read(again))
    remove(path)
    remove(again)


def test_english_round_trip_with_bigrams() raises:
    var index = _english_index()
    var path = _tmp("en.idx")
    index.save(path)
    var mapped = SymSpell.open(path)
    var words: List[String] = [
        "the",
        "quick",
        "brown",
        "fox",
        "memebers",
        "acommodation",
        "helo",
        "kniht",
    ]
    _assert_same(index, mapped, words, "english")
    assert_equal(
        mapped.bigram_count("where is").value(),
        index.bigram_count("where is").value(),
    )
    assert_equal(mapped.word_count(), 82834)
    remove(path)


def test_builds_are_deterministic() raises:
    var a = _tmp("a.idx")
    var b = _tmp("b.idx")
    _intl_index().save(a)
    _intl_index().save(b)
    assert_true(_read(a) == _read(b))
    remove(a)
    remove(b)


def test_empty_dictionary_round_trip() raises:
    var path = _tmp("empty.idx")
    SymSpellBuilder().build().save(path)
    var index = SymSpell.open(path)
    assert_equal(index.word_count(), 0)
    assert_equal(len(index.lookup("abc", Verbosity.ALL)), 0)
    assert_equal(
        index.lookup("abc", Verbosity.TOP, include_unknown=True)[0].term, "abc"
    )
    remove(path)


# --- Bad files ---


def _corrupt_and_expect(
    image: List[UInt8],
    name: String,
    message: String,
    verify_checksum: Bool = True,
) raises:
    var path = _tmp(name)
    _write(path, image)
    with assert_raises(contains=message):
        _ = SymSpell.open(path, verify_checksum=verify_checksum)
    with assert_raises(contains=message):
        _ = SymSpell.open(path, verify_checksum=verify_checksum, use_mmap=False)
    remove(path)


def _store_u32(mut image: List[UInt8], offset: Int, value: UInt32):
    for i in range(4):
        image[offset + i] = UInt8((value >> UInt32(8 * i)) & 0xFF)


def _reseal(mut image: List[UInt8]):
    """Recomputes the checksum, so only the structural checks can catch a change.
    """
    var value = checksum(Span(image)[256:])
    for i in range(8):
        image[120 + i] = UInt8((value >> UInt64(8 * i)) & 0xFF)


def test_missing_and_empty_files() raises:
    with assert_raises():
        _ = SymSpell.open("build/tmp/does-not-exist.idx")
    _corrupt_and_expect(List[UInt8](), "empty.idx", "")
    _corrupt_and_expect(
        List[UInt8](length=100, fill=0), "short.idx", "too short"
    )


def test_rejects_bad_headers() raises:
    var path = _tmp("good.idx")
    _intl_index().save(path)
    var good = _read(path)
    remove(path)

    var bad = good.copy()
    bad[0] = UInt8(ord("X"))
    _corrupt_and_expect(bad, "magic.idx", "bad magic")

    bad = good.copy()
    _store_u32(bad, 8, 99)
    _corrupt_and_expect(
        bad, "version.idx", "unsupported index format version 99"
    )

    bad = good.copy()
    _store_u32(bad, 12, 0x04030201)
    _corrupt_and_expect(bad, "endian.idx", "byte order")

    bad = good.copy()
    bad[len(bad) - 70] ^= 0x40
    _corrupt_and_expect(bad, "checksum.idx", "checksum mismatch")

    var truncated = List[UInt8](good[: len(good) // 2])
    _corrupt_and_expect(truncated, "truncated.idx", "out of bounds")


def test_structural_checks_without_checksum() raises:
    var path = _tmp("good.idx")
    _intl_index().save(path)
    var good = _read(path)
    remove(path)

    # Word count no longer matches the section sizes.
    var bad = good.copy()
    _store_u32(bad, 24 + 8 * 4, 7)
    _reseal(bad)
    _corrupt_and_expect(bad, "word_count.idx", "corrupted index")

    # A posting that points past the last term (POSTINGS is section 7).
    bad = good.copy()
    var postings_offset = (
        Int(bad[128 + 8 * 7])
        | (Int(bad[129 + 8 * 7]) << 8)
        | (Int(bad[130 + 8 * 7]) << 16)
        | (Int(bad[131 + 8 * 7]) << 24)
    )
    _store_u32(bad, postings_offset, 0xFFFFFFF0)
    _reseal(bad)
    _corrupt_and_expect(bad, "posting.idx", "points past the last term")

    # Invalid UTF-8 in the term arena.
    bad = good.copy()
    var arena_offset = (
        Int(bad[128 + 8 * 1])
        | (Int(bad[129 + 8 * 1]) << 8)
        | (Int(bad[130 + 8 * 1]) << 16)
        | (Int(bad[131 + 8 * 1]) << 24)
    )
    bad[arena_offset] = 0xFF
    _reseal(bad)
    _corrupt_and_expect(bad, "utf8.idx", "not valid UTF-8")

    # An invalid configuration.
    bad = good.copy()
    _store_u32(bad, 24 + 8 * 1, 1)  # prefix_length 1 <= max distance 2
    _reseal(bad)
    _corrupt_and_expect(bad, "config.idx", "prefix_length must be greater")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
