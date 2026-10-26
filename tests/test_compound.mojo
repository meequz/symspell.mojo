"""Tests for lookup_compound.

Ports symspellpy's tests/test_symspellpy_lookup_compound.py and the compound
edge case, and checks the compound_*.tsv fixtures generated from symspellpy.
"""

from std.testing import TestSuite, assert_equal, assert_true

from _fixtures import FIXTURES, read_records, show, to_bool, to_int
from symspell import Suggestion, SymSpell, SymSpellBuilder, SymSpellConfig

comptime DICTIONARY = "data/frequency_dictionary_en_82_765.txt"
comptime BIGRAMS = "data/frequency_bigramdictionary_en_243_342.txt"
comptime MAXSIZE = 9223372036854775807


def _english(with_bigrams: Bool) raises -> SymSpell:
    var builder = SymSpellBuilder()
    builder.load_dictionary(DICTIONARY, 0, 1)
    if with_bigrams:
        builder.load_bigram_dictionary(BIGRAMS, 0, 2)
    return builder^.build()


def _expected_count(field: String) -> Int:
    """Python counts can exceed 64 bits here; we saturate (DECISIONS.md, D2)."""
    try:
        return Int(field)
    except:
        return MAXSIZE


# --- Ports of tests/test_symspellpy_lookup_compound.py ---


def _check_symspellpy_data(
    name: String, ignore_non_words: Bool, transfer_casing: Bool
) raises:
    for dictionary in ["bigram", "unigram"]:
        var index = _english(dictionary == "bigram")
        for record in read_records(String("symspellpy/", name, ".tsv")):
            if record[0] != "F" or record[2] != dictionary:
                continue
            var results = index.lookup_compound(
                record[1], 2, ignore_non_words, transfer_casing
            )
            var label = String(name, " ", dictionary, ": ", record[1])
            if record[3] != "":
                assert_equal(len(results), to_int(record[3]), label)
            assert_equal(results[0].term, record[4], label)
            if record[5] != "":
                assert_equal(results[0].distance, to_int(record[5]), label)
            if record[6] != "":
                assert_equal(results[0].count, to_int(record[6]), label)


def test_lookup_compound() raises:
    _check_symspellpy_data("lookup_compound_data", False, False)


def test_lookup_compound_only_combi() raises:
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("steam", 1)
    _ = builder.create_dictionary_entry("machine", 1)
    var results = builder^.build().lookup_compound("ste am machie", 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].term, "steam machine")


def test_lookup_compound_no_suggestion() raises:
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("steam", 1)
    _ = builder.create_dictionary_entry("machine", 1)
    var results = builder^.build().lookup_compound("qwer erty ytui a", 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].term, "qwer erty ytui a")


def test_lookup_compound_replaced_words() raises:
    for dictionary in ["bigram", "unigram"]:
        var index = _english(dictionary == "bigram")
        var replaced = Dict[String, Suggestion]()
        var expected_size = 0
        var records = read_records(
            "symspellpy/lookup_compound_replaced_words_data.tsv"
        )
        var i = 0
        while i < len(records):
            ref record = records[i]
            i += 1
            if record[0] != "F" or record[2] != dictionary:
                continue
            var results = index.lookup_compound(
                record[1], 2, replaced_words=replaced
            )
            assert_equal(results[0].term, record[4], record[1])
            while i < len(records) and records[i][0] == "r":
                expected_size += 1
                assert_equal(
                    replaced[records[i][1]].term,
                    records[i][2],
                    String(record[1], ": ", records[i][1]),
                )
                i += 1
            assert_equal(
                len(replaced), expected_size, String(dictionary, " ", record[1])
            )


def test_lookup_compound_ignore_non_words() raises:
    _check_symspellpy_data("lookup_compound_ignore_non_words_data", True, False)


def test_lookup_compound_ignore_non_words_ignore_digits() raises:
    for with_bigrams in [True, False]:
        var results = _english(with_bigrams).lookup_compound(
            "is the officeon 1st floor oepn 24/7",
            2,
            True,
            split_by_space=True,
            ignore_term_with_digits=True,
        )
        assert_equal(len(results), 1)
        assert_equal(results[0].term, "is the office on 1st floor open 24/7")
        assert_equal(results[0].distance, 2)
        assert_equal(results[0].count, 0)


def test_lookup_compound_transfer_casing() raises:
    _check_symspellpy_data("lookup_compound_transfer_casing_data", False, True)


def test_lookup_compound_transfer_casing_ignore_nonwords() raises:
    _check_symspellpy_data(
        "lookup_compound_transfer_casing_ignore_nonwords_data", True, True
    )


def test_split_correction_part_of_single_term_correction() raises:
    # From tests/test_symspellpy_edge_cases.py.
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("where", 2)
    _ = builder.create_dictionary_entry("is", 2)
    _ = builder.create_dictionary_entry("whereas", 2)
    builder.set_bigram("where is", 10)
    var suggestions = builder^.build().lookup_compound("whereiz", 2)
    assert_equal(suggestions[0].term, "where is")
    assert_equal(suggestions[0].distance, 2)
    assert_equal(suggestions[0].count, 10)


# --- Differential tests against compound_*.tsv ---


def _check_fixture(name: String) raises -> Int:
    var records = read_records(String("compound_", name, ".tsv"))
    ref c = records[0]
    var dictionary = String("data/", c[1]) if c[1].startswith(
        "frequency"
    ) else String(FIXTURES, c[1])
    var builder = SymSpellBuilder(
        SymSpellConfig(to_int(c[3]), to_int(c[4]), to_int(c[5]))
    )
    builder.load_dictionary(dictionary, 0, 1)
    if c[2] != "-":
        var bigrams = String("data/", c[2]) if c[2].startswith(
            "frequency"
        ) else String(FIXTURES, c[2])
        builder.load_bigram_dictionary(bigrams, 0, 2)
    var index = builder^.build()
    var replaced = Dict[String, Suggestion]()
    var expected_replaced = 0
    var checked = 0
    for k in range(1, len(records)):
        ref r = records[k]
        if r[0] == "X":
            if k > 1:
                assert_equal(
                    len(replaced),
                    expected_replaced,
                    String(name, ": replaced_words size"),
                )
            replaced = Dict[String, Suggestion]()
            expected_replaced = 0
        elif r[0] == "R":
            expected_replaced += 1
            var label = String(name, ": replaced ", show(r[1]))
            assert_true(r[1] in replaced, label)
            ref got = replaced[r[1]]
            assert_equal(got.term, r[2], label)
            assert_equal(got.distance, to_int(r[3]), label)
            assert_equal(got.count, _expected_count(r[4]), label)
        else:
            var label = String(
                name,
                ": ",
                show(r[1]),
                " med=",
                r[2],
                " flags=",
                r[3],
                r[4],
                r[5],
                r[6],
            )
            if r[7] == "E":
                var raised = False
                try:
                    _ = index.lookup_compound(
                        r[1],
                        to_int(r[2]),
                        to_bool(r[3]),
                        to_bool(r[4]),
                        to_bool(r[5]),
                        to_bool(r[6]),
                        replaced_words=replaced,
                    )
                except e:
                    raised = True
                    assert_true(
                        String(e) in r[8], String(label, ": wrong error ", e)
                    )
                assert_true(raised, String(label, ": expected ", r[8]))
            else:
                var result = index.lookup_compound(
                    r[1],
                    to_int(r[2]),
                    to_bool(r[3]),
                    to_bool(r[4]),
                    to_bool(r[5]),
                    to_bool(r[6]),
                    replaced_words=replaced,
                )
                assert_equal(len(result), 1, label)
                assert_equal(result[0].term, r[7], label)
                assert_equal(result[0].distance, to_int(r[8]), label)
                assert_equal(result[0].count, _expected_count(r[9]), label)
            checked += 1
    assert_equal(
        len(replaced), expected_replaced, String(name, ": replaced_words size")
    )
    return checked


def test_compound_matches_symspellpy() raises:
    var total = 0
    for name in ["en_bigram", "en_unigram", "intl_bigram"]:
        total += _check_fixture(name)
    print("    checked", total, "lookup_compound calls against symspellpy")
    assert_equal(total, 7224)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
