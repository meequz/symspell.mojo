"""Builder and dictionary loading tests.

Ports symspellpy's tests/test_symspellpy.py and checks the load.tsv fixture.
symspellpy's stream variants (StringIO, DictIO) are ported by writing the same
lines to a temporary file, because this library loads from paths only.
"""

from std.os import makedirs
from std.os.path import exists
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from _fixtures import FIXTURES, read_records, show, to_int
from symspell import (
    DistanceAlgorithm,
    SymSpellBuilder,
    SymSpellConfig,
    Verbosity,
)

comptime MAXSIZE = 9223372036854775807
comptime DICTIONARY = "data/frequency_dictionary_en_82_765.txt"
comptime FORTESTS = "tests/fixtures/symspellpy/"
comptime TMP = "build/tmp/"


def _temp_file(name: StringSlice, content: StringSlice) raises -> String:
    if not exists(TMP):
        makedirs(TMP)
    var path = String(TMP, name)
    with open(path, "w") as f:
        f.write(content)
    return path^


def _short(threshold: Int = 1) raises -> SymSpellBuilder:
    """symspellpy's `symspell_short` fixture: SymSpell(1, 3, threshold)."""
    return SymSpellBuilder(SymSpellConfig(1, 3, threshold))


def _dict_io_lines(separator: StringSlice) -> String:
    """The lines symspellpy's DictIO produces for `get_dictionary_stream`."""
    var out = String()
    var entries: List[Tuple[String, String]] = [
        ("the", "23135851162"),
        ("of", "13151942776"),
        ("abcs of", "10956800"),
        ("aaron and", "10721728"),
        ("and", "12997637966"),
        ("large count", "92233720368547758081"),
    ]
    for entry in entries:
        out += String(entry[0], separator, entry[1], "\n")
    return out^


# --- Configuration ---


def test_negative_max_dictionary_edit_distance() raises:
    with assert_raises(
        contains="max_dictionary_edit_distance cannot be negative"
    ):
        _ = SymSpellBuilder(SymSpellConfig(-1, 3))


def test_invalid_prefix_length() raises:
    with assert_raises(contains="prefix_length cannot be less than 1"):
        _ = SymSpellBuilder(SymSpellConfig(1, 0))
    with assert_raises(contains="prefix_length cannot be less than 1"):
        _ = SymSpellBuilder(SymSpellConfig(1, -1))
    with assert_raises(
        contains=(
            "prefix_length must be greater than max_dictionary_edit_distance"
        )
    ):
        _ = SymSpellBuilder(SymSpellConfig(2, 2))


def test_negative_count_threshold() raises:
    with assert_raises(contains="count_threshold cannot be negative"):
        _ = SymSpellBuilder(SymSpellConfig(1, 3, -1))


def test_set_distance_comparer() raises:
    # symspellpy accepts any comparer object; here the algorithm is part of the config.
    var config = SymSpellConfig(
        distance_algorithm=DistanceAlgorithm.LEVENSHTEIN
    )
    var index = SymSpellBuilder(config).build()
    assert_true(
        index.config().distance_algorithm == DistanceAlgorithm.LEVENSHTEIN
    )


# --- Entries ---


def test_create_dictionary_entry_negative_count() raises:
    for threshold in [1, 0]:
        var builder = _short(threshold)
        assert_equal(builder.create_dictionary_entry("pipe", 0), threshold == 0)
        assert_false(builder.create_dictionary_entry("pipe", -1))


def test_create_dictionary_entry_below_threshold() raises:
    var builder = _short(10)
    _ = builder.create_dictionary_entry("pipe", 4)
    assert_equal(builder.below_threshold_size(), 1)
    assert_equal(builder.below_threshold_count("pipe").value(), 4)
    _ = builder.create_dictionary_entry("pipe", 4)
    assert_equal(builder.below_threshold_size(), 1)
    assert_equal(builder.below_threshold_count("pipe").value(), 8)
    _ = builder.create_dictionary_entry("pipe", 4)
    assert_equal(builder.below_threshold_size(), 0)


def test_add_additional_counts_should_not_add_word_again() raises:
    var builder = SymSpellBuilder()
    for count in [11, 3]:
        _ = builder.create_dictionary_entry("hello", count)
        assert_equal(builder.word_count(), 1)


def test_add_additional_counts_should_increase_count() raises:
    var builder = SymSpellBuilder()
    var expected = 0
    for count in [11, 3]:
        expected += count
        _ = builder.create_dictionary_entry("hello", count)
        var result = builder.snapshot().lookup("hello", Verbosity.TOP)
        assert_equal(result[0].count, expected)


def test_add_additional_counts_should_not_overflow() raises:
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("hello", MAXSIZE - 1)
    assert_equal(
        builder.snapshot().lookup("hello", Verbosity.TOP)[0].count, MAXSIZE - 1
    )
    _ = builder.create_dictionary_entry("hello", 3)
    assert_equal(
        builder.snapshot().lookup("hello", Verbosity.TOP)[0].count, MAXSIZE
    )


# --- Loading ---


def test_load_bigram_dictionary_invalid_path() raises:
    with assert_raises(
        contains=(
            "Bigram dictionary file not found at invalid/dictionary/path.txt."
        )
    ):
        var builder = SymSpellBuilder()
        builder.load_bigram_dictionary("invalid/dictionary/path.txt", 0, 2)


def test_load_dictionary_invalid_path() raises:
    with assert_raises(
        contains="Dictionary file not found at invalid/dictionary/path.txt."
    ):
        var builder = SymSpellBuilder()
        builder.load_dictionary("invalid/dictionary/path.txt", 0, 1)


def test_create_dictionary_invalid_path() raises:
    with assert_raises(
        contains="Corpus not found at invalid/dictionary/path.txt."
    ):
        var builder = SymSpellBuilder()
        builder.create_dictionary("invalid/dictionary/path.txt")


def test_load_bigram_dictionary_bad_dict() raises:
    var builder = SymSpellBuilder()
    builder.load_bigram_dictionary(String(FORTESTS, "bad_dict.txt"), 0, 2)
    assert_equal(builder.bigram_size(), 2)
    assert_equal(builder.bigram_count("rtyu tyui").value(), 12)
    assert_equal(builder.bigram_count("yuio uiop").value(), 13)


def test_load_bigram_dictionary_separator() raises:
    var builder = SymSpellBuilder()
    builder.load_bigram_dictionary(
        String(FORTESTS, "separator_dict.txt"), 0, 1, String("$")
    )
    assert_equal(builder.bigram_size(), 5)
    assert_equal(builder.bigram_count("the").value(), 23135851162)
    assert_equal(builder.bigram_count("of").value(), 13151942776)
    assert_equal(builder.bigram_count("abcs of").value(), 10956800)
    assert_equal(builder.bigram_count("aaron and").value(), 10721728)
    assert_equal(builder.bigram_count("and").value(), 12997637966)


def test_load_bigram_dictionary_stream() raises:
    var path = _temp_file("bigram_stream.txt", _dict_io_lines(" "))
    var builder = SymSpellBuilder()
    builder.load_bigram_dictionary(path, 0, 2)
    assert_equal(builder.bigram_size(), 2)
    assert_equal(builder.bigram_count("abcs of").value(), 10956800)
    assert_equal(builder.bigram_count("aaron and").value(), 10721728)
    assert_false(builder.bigram_count("large count"))


def test_load_bigram_dictionary_stream_separator() raises:
    var path = _temp_file("bigram_stream_sep.txt", _dict_io_lines("$"))
    var builder = SymSpellBuilder()
    builder.load_bigram_dictionary(path, 0, 1, String("$"))
    assert_equal(builder.bigram_size(), 5)
    assert_equal(builder.bigram_count("the").value(), 23135851162)
    assert_equal(builder.bigram_count("of").value(), 13151942776)
    assert_equal(builder.bigram_count("abcs of").value(), 10956800)
    assert_equal(builder.bigram_count("aaron and").value(), 10721728)
    assert_equal(builder.bigram_count("and").value(), 12997637966)


def test_load_dictionary_bad_dictionary() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary(String(FORTESTS, "bad_dict.txt"), 0, 1)
    assert_equal(builder.word_count(), 2)
    assert_equal(builder.count("asdf").value(), 10)
    assert_equal(builder.count("sdfg").value(), 12)


def test_load_dictionary_count() raises:
    # Also covers symspellpy's StringIO and TextIOWrapper variants.
    var builder = SymSpellBuilder()
    builder.load_dictionary(DICTIONARY, 0, 1)
    var index = builder^.build()
    assert_equal(index.word_count(), 82834)
    assert_equal(index.entry_count(), 676094)


def test_load_dictionary_below_threshold() raises:
    var builder = _short(10)
    builder.load_dictionary(String(FORTESTS, "below_threshold_dict.txt"), 0, 1)
    assert_equal(builder.below_threshold_size(), 1)
    assert_equal(builder.below_threshold_count("below").value(), 8)
    assert_equal(builder.word_count(), 2)


def test_load_dictionary_separator() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary(String(FORTESTS, "separator_dict.txt"), 0, 1, "$")
    assert_equal(builder.word_count(), 5)
    assert_equal(builder.count("the").value(), 23135851162)
    assert_equal(builder.count("of").value(), 13151942776)
    assert_equal(builder.count("abcs of").value(), 10956800)
    assert_equal(builder.count("aaron and").value(), 10721728)
    assert_equal(builder.count("and").value(), 12997637966)


def test_load_dictionary_stream() raises:
    # Keys with a space are not parsed with the default separator " ".
    var path = _temp_file("dictionary_stream.txt", _dict_io_lines(" "))
    var builder = SymSpellBuilder()
    builder.load_dictionary(path, 0, 1)
    assert_equal(builder.word_count(), 3)
    assert_equal(builder.count("the").value(), 23135851162)
    assert_equal(builder.count("of").value(), 13151942776)
    assert_equal(builder.count("and").value(), 12997637966)


def test_load_dictionary_stream_separator() raises:
    var path = _temp_file("dictionary_stream_sep.txt", _dict_io_lines("$"))
    var builder = SymSpellBuilder()
    builder.load_dictionary(path, 0, 1, "$")
    assert_equal(builder.word_count(), 5)
    assert_equal(builder.count("abcs of").value(), 10956800)
    assert_equal(builder.count("aaron and").value(), 10721728)


def test_load_dictionary_encoding() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary(String(FORTESTS, "non_en_dict.txt"), 0, 1)
    var result = builder^.build().lookup("АБ", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "АБИ")


def test_loading_dictionary_from_file() raises:
    var builder = SymSpellBuilder()
    builder.create_dictionary(String(FORTESTS, "big_words.txt"))


def test_create_dictionary() raises:
    var builder = SymSpellBuilder()
    builder.create_dictionary(String(FORTESTS, "big_modified.txt"))
    var lines = 0
    with open(String(FORTESTS, "big_words.txt"), "r") as f:
        for line in f.read().splitlines():
            var parts = line.split(" ")
            assert_equal(
                builder.count(parts[0]).value(), Int(parts[1]), String(parts[0])
            )
            lines += 1
    assert_equal(builder.word_count(), lines)


# --- Deleting ---


def _steam_entries() raises -> SymSpellBuilder:
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("stea", 1)
    _ = builder.create_dictionary_entry("steama", 2)
    _ = builder.create_dictionary_entry("steem", 3)
    return builder^


def test_delete_dictionary_entry() raises:
    var builder = _steam_entries()
    var result = builder.snapshot().lookup("steama", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steama")
    assert_equal(builder.max_length(), 6)

    assert_true(builder.delete_dictionary_entry("steama"))
    assert_false(builder.count("steama"))
    assert_equal(builder.max_length(), 5)
    result = builder.snapshot().lookup("steama", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steem")

    assert_true(builder.delete_dictionary_entry("stea"))
    assert_false(builder.count("stea"))
    assert_equal(builder.max_length(), 5)
    result = builder.snapshot().lookup("steama", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steem")


def test_delete_dictionary_entry_invalid_word() raises:
    var builder = _steam_entries()
    var result = builder.snapshot().lookup("steama", Verbosity.TOP, 2)
    assert_equal(result[0].term, "steama")
    assert_equal(builder.max_length(), 6)
    assert_false(builder.delete_dictionary_entry("steamab"))
    result = builder.snapshot().lookup("steama", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steama")
    assert_equal(builder.max_length(), 6)


def test_delete_last_word_raises_like_symspellpy() raises:
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("a", 1)
    with assert_raises(contains="max() iterable argument is empty"):
        _ = builder.delete_dictionary_entry("a")
    assert_equal(builder.word_count(), 0)


def test_deleted_words_keep_their_entries() raises:
    # symspellpy keeps delete keys whose lists became empty.
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("ab", 1)
    _ = builder.create_dictionary_entry("abc", 1)
    _ = builder.delete_dictionary_entry("abc")
    var index = builder^.build()
    assert_equal(index.word_count(), 1)
    assert_equal(index.entry_count(), 8)


# --- Differential test against load.tsv ---


def test_load_fixture() raises:
    var records = read_records("load.tsv")
    var i = 0
    var cases = 0
    while i < len(records):
        ref head = records[i]
        var label = String(head[0], " ", head[1])
        var builder: SymSpellBuilder
        var error = String()
        if head[0] == "U":
            builder = SymSpellBuilder(
                SymSpellConfig(
                    to_int(head[5]), to_int(head[6]), to_int(head[7])
                )
            )
            try:
                builder.load_dictionary(
                    String(FIXTURES, "load/", head[1]),
                    to_int(head[2]),
                    to_int(head[3]),
                    head[4],
                )
            except e:
                error = String(e)
        elif head[0] == "B":
            builder = SymSpellBuilder()
            var separator = Optional[String](None) if head[
                4
            ] == "<None>" else Optional[String](head[4])
            try:
                builder.load_bigram_dictionary(
                    String(FIXTURES, "load/", head[1]),
                    to_int(head[2]),
                    to_int(head[3]),
                    separator,
                )
            except e:
                error = String(e)
        else:
            builder = SymSpellBuilder(
                SymSpellConfig(
                    to_int(head[2]), to_int(head[3]), to_int(head[4])
                )
            )
            try:
                builder.create_dictionary(String(FIXTURES, "load/", head[1]))
            except e:
                error = String(e)
        i += 1
        cases += 1
        if records[i][0] == "E":
            assert_true(
                error.byte_length() > 0,
                String(label, ": expected an error: ", records[i][1]),
            )
            var expected_type = records[i][1].split(":")[0]
            assert_true(
                String(expected_type) in error,
                String(label, ": got ", error, ", expected ", records[i][1]),
            )
            i += 1
            continue
        assert_equal(error, "", label)
        ref state = records[i]
        var index = builder.snapshot()
        assert_equal(
            index.word_count(), to_int(state[1]), String(label, " word_count")
        )
        assert_equal(
            index.entry_count(), to_int(state[2]), String(label, " entry_count")
        )
        assert_equal(
            index.max_length(), to_int(state[3]), String(label, " max_length")
        )
        assert_equal(
            builder.below_threshold_size(),
            to_int(state[4]),
            String(label, " below"),
        )
        assert_equal(
            builder.bigram_count_min(),
            to_int(state[5]),
            String(label, " bigram min"),
        )
        assert_equal(
            index.bigram_count_min(),
            to_int(state[5]),
            String(label, " bigram min (index)"),
        )
        i += 1
        var bigrams = 0
        while i < len(records) and records[i][0] in ["w", "b", "g"]:
            ref r = records[i]
            var what = String(label, " ", r[0], " ", show(r[1]))
            if r[0] == "w":
                assert_equal(index.count(r[1]).value(), to_int(r[2]), what)
                assert_equal(builder.count(r[1]).value(), to_int(r[2]), what)
            elif r[0] == "b":
                assert_equal(
                    builder.below_threshold_count(r[1]).value(),
                    to_int(r[2]),
                    what,
                )
            else:
                assert_equal(
                    index.bigram_count(r[1]).value(), to_int(r[2]), what
                )
                bigrams += 1
            i += 1
        assert_equal(
            index.bigram_size(), bigrams, String(label, " bigram count")
        )
    assert_true(cases > 60)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
