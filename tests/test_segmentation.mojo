"""Tests for word_segmentation.

Ports symspellpy's tests/test_symspellpy_word_segmentation.py and checks the
segmentation_*.tsv fixtures generated from symspellpy.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from _fixtures import FIXTURES, read_records, show, to_int
from symspell import SymSpell, SymSpellBuilder, SymSpellConfig
from symspell.text import capitalize_string, decimal_value, to_codepoints

comptime DICTIONARY = "data/frequency_dictionary_en_82_765.txt"


def _english(max_distance: Int) raises -> SymSpell:
    var builder = SymSpellBuilder(SymSpellConfig(max_distance))
    builder.load_dictionary(DICTIONARY, 0, 1)
    return builder^.build()


def _two_digits_then_word(token: String) -> Bool:
    """Same as `re.match(r"\\d{2}\\w*\\b", token)`: two leading decimal digits.
    """
    var cps = to_codepoints(token)
    return (
        len(cps) >= 2
        and decimal_value(cps[0]) >= 0
        and decimal_value(cps[1]) >= 0
    )


def _close(a: Float64, b: Float64) -> Bool:
    return abs(a - b) <= 1e-9 * max(1.0, abs(b))


# --- Ports of tests/test_symspellpy_word_segmentation.py ---


def test_word_segmentation_ignore_token() raises:
    var typo = "24th december"
    var result = _english(2).word_segmentation(
        typo, ignore_token=_two_digits_then_word
    )
    assert_equal(result.corrected_string, typo)


def test_word_segmentation() raises:
    var index = _english(0)
    var records = read_records("symspellpy/word_segmentation_data.tsv")
    assert_equal(len(records), 3)
    for with_arguments in [False, True]:
        for capitalize in [False, True]:
            if with_arguments and capitalize:
                continue  # symspellpy does not test this combination
            for record in records:
                var typo = capitalize_string(
                    record[1]
                ) if capitalize else record[1]
                var correction = capitalize_string(
                    record[3]
                ) if capitalize else record[3]
                var result = index.word_segmentation(
                    typo, 0, 11
                ) if with_arguments else index.word_segmentation(typo)
                assert_equal(result.corrected_string, correction, typo)


def test_word_segmentation_apostrophe() raises:
    var result = _english(0).word_segmentation("There'resomewords")
    assert_equal(result.corrected_string, "There' re some words")


def test_word_segmentation_ligature() raises:
    # symspellpy NFKC-normalizes the input; this library does not
    # (docs/DECISIONS.md, D7). With normalized input the result is the same.
    var index = _english(0)
    var normalized = index.word_segmentation("Therearesomescientificwords")
    assert_equal(normalized.corrected_string, "There are some scientific words")
    # Unnormalized input keeps the ligature, so it is not corrected the same way.
    var ligature = index.word_segmentation("Therearesomescientiﬁcwords")
    assert_true("ﬁ" in ligature.corrected_string)
    assert_false(ligature.corrected_string == normalized.corrected_string)


# --- Differential tests against segmentation_*.tsv ---


def _check_fixture(name: String) raises -> Int:
    var records = read_records(String("segmentation_", name, ".tsv"))
    ref c = records[0]
    var dictionary = String("data/", c[1]) if c[1].startswith(
        "frequency"
    ) else String(FIXTURES, c[1])
    var builder = SymSpellBuilder(
        SymSpellConfig(to_int(c[2]), to_int(c[3]), to_int(c[4]))
    )
    builder.load_dictionary(dictionary, 0, 1)
    var index = builder^.build()
    var checked = 0
    for k in range(1, len(records)):
        ref r = records[k]
        var med = to_int(r[2])
        var max_len = Optional[Int](None) if r[3] == "-" else Optional[Int](
            to_int(r[3])
        )
        var label = String(
            name, ": ", show(r[1]), " med=", med, " max_len=", r[3]
        )
        if r[4] == "E":
            var raised = False
            try:
                _ = index.word_segmentation(r[1], med, max_len)
            except e:
                raised = True
                var expected_type = r[5].split(":")[0]
                assert_true(
                    String(expected_type) in String(e),
                    String(label, ": wrong error ", e),
                )
            assert_true(raised, String(label, ": expected ", r[5]))
        else:
            var result = index.word_segmentation(r[1], med, max_len)
            assert_equal(result.segmented_string, r[4], label)
            assert_equal(result.corrected_string, r[5], label)
            assert_equal(result.distance_sum, to_int(r[6]), label)
            var expected = Float64(r[7])
            assert_true(
                _close(result.log_prob_sum, expected),
                String(
                    label,
                    ": log_prob_sum ",
                    result.log_prob_sum,
                    " vs ",
                    expected,
                ),
            )
        checked += 1
    return checked


def test_segmentation_matches_symspellpy() raises:
    var total = 0
    for name in ["en_d2", "intl_d2"]:
        total += _check_fixture(name)
    print("    checked", total, "word_segmentation calls against symspellpy")
    assert_equal(total, 2256)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
