"""Tests for word parsing, number parsing and case transfer.

Ports symspellpy's tests/test_helpers.py and checks every record of the
helpers.tsv fixture generated from symspellpy.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from _fixtures import read_records, show, to_bool, to_int
from symspell.casing import (
    OP_DELETE,
    OP_EQUAL,
    OP_INSERT,
    OP_REPLACE,
    case_transfer_matching,
    case_transfer_similar,
    get_opcodes,
)
from symspell.text import to_codepoints
from symspell.tokenize import (
    is_acronym,
    parse_corpus_words,
    parse_words,
    try_parse_int64,
)


def _check_words(
    got: List[String], record: List[String], first: Int, label: String
) raises:
    var expected_count = to_int(record[first])
    assert_equal(len(got), expected_count, String(t"{label}: word count"))
    for i in range(expected_count):
        assert_equal(
            got[i], record[first + 1 + i], String(t"{label}: word {i}")
        )


# --- Ports of symspellpy tests/test_helpers.py ---


def test_is_acronym() raises:
    # (word, default, with digits)
    var cases: List[Tuple[String, Bool, Bool]] = [
        ("ABCDE", True, True),
        ("AB12E", True, True),
        ("abcde", False, False),
        ("ABCde", False, False),
        ("abcDE", False, False),
        ("abCDe", False, False),
        ("abc12", False, True),
        ("ab12e", False, True),
    ]
    for item in cases:
        assert_equal(is_acronym(item[0]), item[1], item[0])
        assert_equal(is_acronym(item[0], True), item[2], item[0])


def test_case_transfer_matching_diff_lengths() raises:
    with assert_raises(
        contains=(
            "'cased_text' and 'uncased_text' don't have the same length, use"
            " case_transfer_similar() instead"
        )
    ):
        _ = case_transfer_matching("abc", "abcd")


def test_case_transfer_matching() raises:
    assert_equal(
        case_transfer_matching(
            "Haw is the eeather in New York?", "how is the weather in new york?"
        ),
        "How is the weather in New York?",
    )


def test_case_transfer_similar_empty_wo_casing() raises:
    assert_equal(
        case_transfer_similar("Haw is the eeather in New York?", ""), ""
    )


def test_case_transfer_similar_empty_w_casing() raises:
    with assert_raises(contains="'cased_text' cannot be empty"):
        _ = case_transfer_similar("", "abcd")


def test_case_transfer_similar() raises:
    var cases: List[Tuple[String, String, String]] = [
        (
            "Haaw is the weeather in New York?",
            "how is the weather in new york?",
            "How is the weather in New York?",
        ),
        ("Wethr in New Yoork", "weather in new york", "Weather in New York"),
        ("Efthr in New Yoork", "weather in new york", "WEather in New York"),
        ("efthr in New Yoork", "weather in new york", "weather in New York"),
        ("eTr in New Yoork", "weather in new york", "weaTHEr in New York"),
        ("hoW eqr", "Haaaw er", "haaaW er"),
        ("hOW eqr", "Haaaw er", "hAAAW er"),
    ]
    for item in cases:
        assert_equal(case_transfer_similar(item[0], item[1]), item[2])


# --- Differential tests against helpers.tsv ---


def test_parse_words_match_python() raises:
    var checked = 0
    for record in read_records("helpers.tsv"):
        if record[0] == "P":
            var words = parse_words(
                record[1],
                preserve_case=to_bool(record[3]),
                split_by_space=to_bool(record[2]),
            )
            _check_words(
                words,
                record,
                4,
                String(t"parse_words {show(record[1])} {record[2]}{record[3]}"),
            )
            checked += 1
        elif record[0] == "D":
            _check_words(
                parse_corpus_words(record[1]),
                record,
                2,
                String(t"corpus words {show(record[1])}"),
            )
            checked += 1
    assert_true(checked > 15000)


def test_is_acronym_match_python() raises:
    for record in read_records("helpers.tsv"):
        if record[0] == "A":
            assert_equal(
                is_acronym(record[1]),
                to_bool(record[2]),
                String(t"is_acronym {show(record[1])}"),
            )
            assert_equal(
                is_acronym(record[1], True),
                to_bool(record[3]),
                String(t"is_acronym digits {show(record[1])}"),
            )


def test_try_parse_int64_match_python() raises:
    for record in read_records("helpers.tsv"):
        if record[0] == "I":
            var got = try_parse_int64(record[1])
            var label = String(t"try_parse_int64 {show(record[1])}")
            assert_equal(Bool(got), to_bool(record[2]), label)
            if got:
                assert_equal(got.value(), to_int(record[3]), label)


def test_try_parse_int64_limits() raises:
    assert_equal(
        try_parse_int64("9223372036854775807").value(), 9223372036854775807
    )
    assert_equal(
        try_parse_int64("-9223372036854775808").value(),
        -9223372036854775807 - 1,
    )
    assert_false(try_parse_int64("9223372036854775808"))
    assert_false(try_parse_int64("-9223372036854775809"))
    assert_equal(try_parse_int64("-0").value(), 0)
    assert_equal(try_parse_int64(" 1_000 ").value(), 1000)


def _tag_name(tag: Int) -> String:
    if tag == OP_REPLACE:
        return "replace"
    if tag == OP_DELETE:
        return "delete"
    if tag == OP_INSERT:
        return "insert"
    return "equal"


def test_sequence_matcher_opcodes_match_python() raises:
    var checked = 0
    for record in read_records("helpers.tsv"):
        if record[0] != "M":
            continue
        var ops = get_opcodes(
            to_codepoints(record[1]), to_codepoints(record[2])
        )
        var label = String(t"opcodes {show(record[1])} vs {show(record[2])}")
        assert_equal(len(ops), to_int(record[3]), label)
        for k in range(len(ops)):
            var base = 4 + k * 5
            assert_equal(_tag_name(ops[k].tag), record[base], label)
            assert_equal(ops[k].i1, to_int(record[base + 1]), label)
            assert_equal(ops[k].i2, to_int(record[base + 2]), label)
            assert_equal(ops[k].j1, to_int(record[base + 3]), label)
            assert_equal(ops[k].j2, to_int(record[base + 4]), label)
        checked += 1
    assert_true(checked > 3000)


def test_case_transfer_similar_match_python() raises:
    for record in read_records("helpers.tsv"):
        if record[0] != "T":
            continue
        var label = String(
            t"case_transfer_similar {show(record[1])} {show(record[2])}"
        )
        if record[3] == "E" and record[4] != "":
            var raised = False
            try:
                _ = case_transfer_similar(record[1], record[2])
            except e:
                raised = True
                assert_true(String(e) in record[4], label)
            assert_true(raised, label)
        else:
            assert_equal(
                case_transfer_similar(record[1], record[2]), record[3], label
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
