"""Edit distance tests.

Ports symspellpy's tests/test_editdistance.py, checks the distance.tsv
fixture from symspellpy, and compares against textbook DP oracles.
"""

from std.testing import TestSuite, assert_equal, assert_true

from _fixtures import read_records, show, to_int
from _oracles import Rng, bounded, levenshtein_reference, osa_reference
from symspell.distance import DamerauOsa, DistanceComparer, Levenshtein
from symspell.text import to_codepoints

comptime MAXSIZE = 9223372036854775807


def _all_strings() -> List[List[UInt32]]:
    """symspellpy's `get_strings`: "" and all permutations of subsets of "abcd".
    """
    var strings = List[List[UInt32]]()
    strings.append(List[UInt32]())
    var alphabet: List[UInt32] = [0x61, 0x62, 0x63, 0x64]
    # Every non-empty sequence of distinct letters, built by depth-first search.
    var stack = List[List[UInt32]]()
    stack.append(List[UInt32]())
    while stack:
        var current = stack.pop()
        for c in alphabet:
            if c in current:
                continue
            var longer = current.copy()
            longer.append(c)
            strings.append(longer.copy())
            stack.append(longer^)
    return strings^


def _check_against_reference[C: DistanceComparer](osa: Bool) raises:
    var comparer = C()
    var strings = _all_strings()
    assert_equal(len(strings), 65)
    var maxes: List[Int] = [0, 1, 3, MAXSIZE]
    for max_distance in maxes:
        for s1 in strings:
            for s2 in strings:
                var exact = osa_reference(
                    s1, s2
                ) if osa else levenshtein_reference(s1, s2)
                var expected = exact if exact <= max_distance else -1
                assert_equal(comparer.distance(s1, s2, max_distance), expected)


# --- Ports of symspellpy tests/test_editdistance.py ---


def test_damerau_osa_match_ref() raises:
    _check_against_reference[DamerauOsa](osa=True)


def test_levenshtein_match_ref() raises:
    _check_against_reference[Levenshtein](osa=False)


def _check_zero_and_long[C: DistanceComparer]() raises:
    var comparer = C()
    var short = to_codepoints("string")
    var very_long = to_codepoints("very_long_string")
    # `test_comparer_negative_max_distance` for the non-null pairs.
    assert_equal(comparer.distance(short, short, 0), 0)
    assert_equal(comparer.distance(short, short, -1), 0)
    assert_equal(comparer.distance(short, very_long, 0), -1)
    assert_equal(comparer.distance(short, very_long, -1), -1)
    # `test_comparer_very_long_string`.
    assert_equal(comparer.distance(short, very_long, 5), -1)


def test_zero_negative_and_very_long() raises:
    _check_zero_and_long[DamerauOsa]()
    _check_zero_and_long[Levenshtein]()


# --- Differential test against symspellpy (distance.tsv) ---


def test_match_symspellpy() raises:
    var osa = DamerauOsa()
    var lev = Levenshtein()
    var checked = 0
    for record in read_records("distance.tsv"):
        var a = to_codepoints(record[0])
        var b = to_codepoints(record[1])
        var max_distance = to_int(record[2])
        var label = String(
            t"{show(record[0])} {show(record[1])} max={max_distance}"
        )
        assert_equal(
            osa.distance(a, b, max_distance),
            to_int(record[3]),
            String(t"osa {label}"),
        )
        assert_equal(
            lev.distance(a, b, max_distance),
            to_int(record[4]),
            String(t"lev {label}"),
        )
        checked += 1
    assert_equal(checked, 12000)


# --- Properties against the DP oracles ---


def _alphabets() -> List[List[UInt32]]:
    var alphabets = List[List[UInt32]]()
    alphabets.append(to_codepoints("ab"))
    alphabets.append(to_codepoints("abc "))
    alphabets.append(to_codepoints("abcdefghijklmnopqrstuvwxyz"))
    alphabets.append(to_codepoints("абвгдеёжзійўэюя"))
    alphabets.append(to_codepoints("aąćęłńóśźżß😀漢é"))
    return alphabets^


def test_random_pairs_match_oracles() raises:
    var rng = Rng(7)
    var alphabets = _alphabets()
    var osa = DamerauOsa()
    var lev = Levenshtein()
    var maxes: List[Int] = [-1, 0, 1, 2, 3, 5, 8, 1000]
    for n in range(6000):
        ref alphabet = alphabets[rng.below(len(alphabets))]
        var long = n % 20 == 0
        var a = rng.codepoints(alphabet, 0, 200 if long else 14)
        var b = rng.mutate(a, alphabet, rng.between(0, 12 if long else 5))
        var exact_osa = osa_reference(a, b)
        var exact_lev = levenshtein_reference(a, b)
        for max_distance in maxes:
            # Bounded results agree with the unbounded oracle.
            assert_equal(
                osa.distance(a, b, max_distance),
                bounded(exact_osa, max_distance),
            )
            assert_equal(
                lev.distance(a, b, max_distance),
                bounded(exact_lev, max_distance),
            )
        # Symmetry.
        assert_equal(osa.distance(b, a, 1000), exact_osa)
        assert_equal(lev.distance(b, a, 1000), exact_lev)
        # Identity.
        assert_equal(osa.distance(a, a, 3), 0)
        assert_equal(lev.distance(a, a, 3), 0)
        # OSA never exceeds Levenshtein, and transposition is one edit.
        assert_true(exact_osa <= exact_lev)


def test_levenshtein_triangle_inequality() raises:
    # OSA does not satisfy the triangle inequality, so only Levenshtein is tested.
    var rng = Rng(11)
    var alphabet = to_codepoints("abcd")
    var lev = Levenshtein()
    for _ in range(3000):
        var a = rng.codepoints(alphabet, 0, 10)
        var b = rng.mutate(a, alphabet, rng.between(0, 4))
        var c = rng.mutate(b, alphabet, rng.between(0, 4))
        var ab = lev.distance(a, b, 1000)
        var bc = lev.distance(b, c, 1000)
        var ac = lev.distance(a, c, 1000)
        assert_true(ac <= ab + bc)


def test_known_values() raises:
    var osa = DamerauOsa()
    var lev = Levenshtein()
    # Expected values computed with symspellpy 6.10.0.
    var cases: List[Tuple[String, String, Int, Int]] = [
        ("", "", 0, 0),
        ("abc", "", 3, 3),
        ("ab", "ba", 1, 2),
        (
            "ca",
            "abc",
            3,
            3,
        ),  # true Damerau gives 2; OSA cannot edit a transposed pair again
        ("kitten", "sitting", 3, 3),
        ("bank", "knab", 3, 4),
        ("bank", "bink", 1, 1),
        ("Беларусь", "Белраусь", 1, 2),
        ("😀😃", "😃😀", 1, 2),
        ("é", "e", 1, 1),
    ]
    for item in cases:
        var a = to_codepoints(item[0])
        var b = to_codepoints(item[1])
        assert_equal(
            osa.distance(a, b, 100), item[2], String(t"osa {item[0]} {item[1]}")
        )
        assert_equal(
            lev.distance(a, b, 100), item[3], String(t"lev {item[0]} {item[1]}")
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
