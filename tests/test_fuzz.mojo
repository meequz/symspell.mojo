"""Fuzz tests: corrupted index files, random dictionary files, random queries.

Each input must either raise an error or work; it must never crash. Run with
`pixi run test-debug` to also catch out-of-bounds reads.
"""

from std.os import makedirs, remove
from std.os.path import exists
from std.testing import TestSuite, assert_true

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


def _write(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


def _small_index() raises -> SymSpell:
    var builder = SymSpellBuilder(SymSpellConfig(2, 5))
    var count = 0
    with open(String(FIXTURES, "dict_intl.txt"), "r") as f:
        for line in f.read().splitlines():
            var parts = line.split(" ")
            _ = builder.create_dictionary_entry(parts[0], Int(parts[1]))
            count += 1
            if count == 300:
                break
    _ = builder.create_dictionary_entry("", 5)
    builder.set_bigram("сям'я λόγος", 10)
    builder.set_bigram("a b", 3)
    return builder^.build()


def _exercise(index: SymSpell, mut scratch: LookupScratch) raises:
    """Uses every read path of an index that opened successfully."""
    var queries: List[String] = [
        "",
        "a",
        "сям'я",
        "λόγος",
        "Straße",
        "😀😃",
        "zzzzzzzzzzzz",
    ]
    for q in queries:
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            try:
                _ = index.lookup(q, v, include_unknown=True, scratch=scratch)
                _ = index.lookup(q, v, 1, transfer_casing=True, scratch=scratch)
            except:
                pass  # a corrupted but valid-looking index may make Python-like errors
        _ = index.contains(q)
        _ = index.count(q)
    _ = index.bigram_count("a b")
    _ = index.bigram_count("сям'я λόγος")


def _store(mut image: List[UInt8], offset: Int, value: UInt64, size: Int):
    for i in range(size):
        if offset + i < len(image):
            image[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF)


def _mutate(mut rng: Rng, var image: List[UInt8]) -> List[UInt8]:
    var kind = rng.below(6)
    if kind == 0:  # flip a few bits anywhere
        for _ in range(rng.between(1, 8)):
            var i = rng.below(len(image))
            image[i] ^= UInt8(1 << rng.below(8))
    elif kind == 1:  # a header field or section table entry gets a nasty value
        var values: List[UInt64] = [
            0,
            1,
            7,
            8,
            63,
            64,
            0xFFFFFFFF,
            0x7FFFFFFFFFFFFFFF,
            UInt64(len(image)),
            UInt64(len(image) + 64),
        ]
        var offset = rng.between(8, 255)
        _store(
            image,
            offset,
            values[rng.below(len(values))],
            4 if offset >= 128 else 8,
        )
    elif kind == 2:  # truncate
        image.resize(rng.below(len(image)), 0)
    elif kind == 3:  # append garbage
        for _ in range(rng.between(1, 300)):
            image.append(UInt8(rng.below(256)))
    elif kind == 4:  # overwrite a run of bytes after the header
        var start = rng.between(256, len(image) - 1)
        for i in range(start, min(len(image), start + rng.between(1, 64))):
            image[i] = UInt8(rng.below(256))
    else:  # zero a run of bytes
        var start = rng.below(len(image))
        for i in range(start, min(len(image), start + rng.between(1, 512))):
            image[i] = 0
    return image^


def _reseal(mut image: List[UInt8]):
    if len(image) < 256:
        return
    var value = checksum(Span(image)[256:])
    _store(image, 120, value, 8)


def test_fuzz_index_loader() raises:
    var path = _tmp("fuzz_base.idx")
    _small_index().save(path)
    var good: List[UInt8]
    with open(path, "r") as f:
        good = f.read_bytes()
    var rng = Rng(2024)
    var scratch = LookupScratch()
    var opened = 0
    var rejected = 0
    var target = _tmp("fuzz.idx")
    for n in range(3000):
        var image = _mutate(rng, good.copy())
        if n % 2 == 0:
            _reseal(
                image
            )  # get past the checksum to reach the structural checks
        _write(target, image)
        for use_mmap in [True, False]:
            for verify in [True, False]:
                try:
                    var index = SymSpell.open(
                        target, verify_checksum=verify, use_mmap=use_mmap
                    )
                    _exercise(index, scratch)
                    opened += 1
                except:
                    rejected += 1
    print("    index fuzz: opened", opened, "rejected", rejected)
    assert_true(rejected > 1000)
    remove(path)
    remove(target)


def test_fuzz_dictionary_files() raises:
    var rng = Rng(77)
    var pieces: List[String] = [
        "word 12\n",
        "\r\n",
        "\r",
        " ",
        "\t",
        "$",
        "5",
        "-3",
        "1_0",
        "99999999999999999999",
        "Ā",
        "😀",
        " ",
        "a b 3\n",
        "\n",
        "é",
        "٣",
        "x$y$7\n",
    ]
    var path = _tmp("fuzz_dict.txt")
    var scratch = LookupScratch()
    for n in range(500):
        var data = List[UInt8]()
        for _ in range(rng.between(0, 60)):
            if rng.below(10) == 0:
                data.append(UInt8(rng.below(256)))  # may be invalid UTF-8
            else:
                data.extend(pieces[rng.below(len(pieces))].as_bytes())
        _write(path, data)
        var builder = SymSpellBuilder(SymSpellConfig(2, 7, rng.between(0, 3)))
        try:
            builder.load_dictionary(path, 0, 1, " " if n % 2 == 0 else "$")
        except:
            pass
        try:
            builder.load_bigram_dictionary(path, 0, 2)
        except:
            pass
        try:
            builder.create_dictionary(path)
        except:
            pass
        var index = builder^.build()
        for q in ["word", "a", "x", ""]:
            _ = index.lookup(q, Verbosity.ALL, scratch=scratch)
    remove(path)


def test_fuzz_queries() raises:
    var builder = SymSpellBuilder(SymSpellConfig(3, 6))
    builder.load_dictionary(String(FIXTURES, "dict_intl.txt"))
    _ = builder.create_dictionary_entry("", 1)
    var index = builder^.build()
    var rng = Rng(31337)
    var ranges: List[Tuple[Int, Int]] = [
        (0x20, 0x7E),
        (0x00, 0x1F),
        (0x80, 0x2FF),
        (0x300, 0x36F),
        (0x370, 0x3FF),
        (0x400, 0x4FF),
        (0x1E00, 0x1FFF),
        (0x2000, 0x206F),
        (0x4E00, 0x4E80),
        (0x1F300, 0x1F64F),
        (0xE000, 0xE010),
        (0x10FFF0, 0x10FFFF),
    ]
    var scratch = LookupScratch()
    for n in range(4000):
        var text = String()
        var length = rng.between(0, 12) if n % 10 != 0 else rng.between(20, 300)
        for _ in range(length):
            ref r = ranges[rng.below(len(ranges))]
            text.append(
                Codepoint(
                    unsafe_unchecked_codepoint=UInt32(rng.between(r[0], r[1]))
                )
            )
        var med = rng.between(-1, 3)
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            for transfer_casing in [False, True]:
                try:
                    var result = index.lookup(
                        text,
                        v,
                        med,
                        n % 3 == 0,
                        transfer_casing=transfer_casing,
                        scratch=scratch,
                    )
                    for s in result:
                        assert_true(s.distance <= max(med, 0) + 1, text)
                except e:
                    # The only errors symspellpy also raises here.
                    var message = String(e)
                    assert_true(
                        "cased_text" in message or "IndexError" in message,
                        String("unexpected error for ", text, ": ", message),
                    )


def test_fuzz_compound_and_segmentation() raises:
    var builder = SymSpellBuilder(SymSpellConfig(2, 7))
    builder.load_dictionary(String(FIXTURES, "dict_intl.txt"))
    builder.load_bigram_dictionary(String(FIXTURES, "bigrams_intl.txt"))
    _ = builder.create_dictionary_entry("a", 3)
    var index = builder^.build()
    var rng = Rng(4242)
    var pieces: List[String] = [
        " ",
        "  ",
        "a",
        "сям'я",
        "λόγος",
        "ΟΔΟΣ",
        "İ",
        "12",
        "AB12",
        "NASA",
        "-",
        "'",
        "’",
        ".",
        "😀",
        "e\u0301",
        "ß",
        "\t",
        "x",
        "Straße",
        "٣",
        "_",
    ]
    var allowed: List[String] = [
        "IndexError",
        "OverflowError",
        "ValueError",
        "cased_text",
        "StopIteration",
    ]
    for _ in range(600):
        var text = String()
        for _ in range(rng.between(0, 10)):
            text += pieces[rng.below(len(pieces))]
        var flags = rng.below(16)
        try:
            var r = index.lookup_compound(
                text,
                rng.between(0, 2),
                flags & 1 != 0,
                flags & 2 != 0,
                flags & 4 != 0,
                flags & 8 != 0,
            )
            assert_true(len(r) == 1, text)
        except e:
            var message = String(e)
            var ok = False
            for a in allowed:
                if a in message:
                    ok = True
            assert_true(ok, String("lookup_compound ", text, ": ", message))
        try:
            _ = index.word_segmentation(
                text,
                rng.between(0, 2),
                Optional[Int](rng.between(1, 12)) if rng.below(2)
                == 0 else None,
            )
        except e:
            var message = String(e)
            var ok = False
            for a in allowed:
                if a in message:
                    ok = True
            assert_true(ok, String("word_segmentation ", text, ": ", message))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
