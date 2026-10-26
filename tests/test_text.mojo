"""Tests for symspell.text against Python `str` (fixture helpers.tsv)."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from _fixtures import read_records, show
from symspell.text import (
    capitalize_string,
    decimal_value,
    decode,
    is_alnum,
    is_digit,
    is_space,
    is_upper,
    is_word_char,
    lower_string,
    to_codepoints,
    to_string,
    upper_string,
)


def test_case_mappings_match_python() raises:
    var checked = 0
    for record in read_records("helpers.tsv"):
        if record[0] != "L":
            continue
        ref text = record[1]
        assert_equal(
            lower_string(text), record[2], String(t"lower {show(text)}")
        )
        assert_equal(
            upper_string(text), record[3], String(t"upper {show(text)}")
        )
        assert_equal(
            capitalize_string(text),
            record[4],
            String(t"capitalize {show(text)}"),
        )
        checked += 1
    assert_true(checked > 4000)


def test_final_sigma() raises:
    assert_equal(lower_string("ΟΔΟΣ ΟΣ"), "οδος ος")
    assert_equal(lower_string("Σ"), "σ")
    assert_equal(lower_string("AΣb"), "aσb")
    assert_equal(lower_string("Σ."), "σ.")
    assert_equal(lower_string("ΑΣ."), "ας.")


def test_length_changing_mappings() raises:
    assert_equal(lower_string("İ"), "i̇")
    assert_equal(upper_string("ß"), "SS")
    assert_equal(upper_string("ŉ"), "ʼN")
    assert_equal(capitalize_string("ǆa"), "ǅa")
    assert_equal(capitalize_string("ßa"), "Ssa")


def test_ascii_properties() raises:
    for cp in range(128):
        var c = UInt32(cp)
        var is_letter = (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122)
        var digit = cp >= 48 and cp <= 57
        assert_equal(is_alnum(c), is_letter or digit)
        assert_equal(is_digit(c), digit)
        assert_equal(is_upper(c), cp >= 65 and cp <= 90)
        assert_equal(is_word_char(c), is_letter or digit or cp == 95)
        assert_equal(decimal_value(c), cp - 48 if digit else -1)
    assert_true(is_space(0x20))
    assert_true(is_space(0x1C))
    assert_false(is_space(0x00))


def test_unicode_properties() raises:
    assert_true(is_alnum(0x0451))  # ё
    assert_true(is_alnum(0x00B2))  # ² is numeric
    assert_false(is_alnum(0x0301))  # combining acute accent
    assert_false(is_alnum(0x1F600))  # emoji
    assert_true(is_space(0x00A0))
    assert_true(is_space(0x2028))
    assert_true(is_space(0x0085))
    assert_false(is_space(0x200B))  # zero width space is not whitespace
    assert_true(is_upper(0x0130))  # İ
    assert_false(is_upper(0x01C5))  # ǅ is title case
    assert_true(is_digit(0x00B2))
    assert_equal(decimal_value(0x00B2), -1)  # ² is a digit but not decimal
    assert_equal(decimal_value(0x0663), 3)  # Arabic-Indic three
    assert_equal(decimal_value(0xFF19), 9)  # fullwidth nine


def test_codepoint_round_trip() raises:
    var text = "Беларусь ß 😀 é 🇧🇾"
    var cps = to_codepoints(text)
    assert_equal(len(cps), text.count_codepoints())
    assert_equal(to_string(cps), text)
    var reused = List[UInt32]()
    decode("ab", reused)
    decode("я", reused)
    assert_equal(len(reused), 1)
    assert_equal(reused[0], 0x044F)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
