"""Differential and property tests for `lookup`.

1. Every query in tests/fixtures/lookup_*.tsv must give exactly symspellpy's
   result: same terms, distances, counts and order.
2. A brute-force oracle (distance to every word) checks that `Verbosity.ALL`
   finds every word within the distance, independently of Python.
3. Properties: self lookup, distance bound, sort order, insertion order.
"""

from std.testing import TestSuite, assert_equal, assert_true

from _fixtures import FIXTURES, read_records, show, to_bool, to_int
from _oracles import Rng, osa_reference
from symspell import (
    LookupScratch,
    Suggestion,
    SymSpell,
    SymSpellBuilder,
    SymSpellConfig,
    Verbosity,
)
from symspell.config import DistanceAlgorithm
from symspell.text import to_codepoints

comptime CONFIGS: List[String] = [
    "en_d2_p7_t1",
    "en_d3_p7_t1",
    "en_d1_p3_t1",
    "en_d2_p4_t1",
    "en_d2_p10_t1",
    "en_d2_p7_t50000",
    "intl_d2_p7_t1",
    "intl_d3_p5_t1",
    "intl_d2_p7_t3000",
    "en_d2_p7_t1_lev",
    "intl_d3_p7_t1_lev",
]


def _dictionary_path(name: String) -> String:
    if name.startswith("frequency_dictionary"):
        return String("data/", name)
    return String(FIXTURES, name)


def _load(path: String, config: SymSpellConfig) raises -> SymSpell:
    var builder = SymSpellBuilder(config)
    builder.load_dictionary(path, 0, 1)
    return builder^.build()


def _check_fixture(name: String) raises -> Int:
    var records = read_records(String("lookup_", name, ".tsv"))
    ref c = records[0]
    assert_equal(c[0], "C")
    var index = _load(
        _dictionary_path(c[1]),
        SymSpellConfig(
            to_int(c[2]),
            to_int(c[3]),
            to_int(c[4]),
            DistanceAlgorithm.LEVENSHTEIN if c[5]
            == "levenshtein" else DistanceAlgorithm.DAMERAU_OSA,
        ),
    )
    ref s = records[1]
    assert_equal(index.word_count(), to_int(s[1]), String(name, " word_count"))
    assert_equal(
        index.entry_count(), to_int(s[2]), String(name, " entry_count")
    )
    assert_equal(index.max_length(), to_int(s[3]), String(name, " max_length"))
    var scratch = LookupScratch()
    var queries = 0
    for k in range(2, len(records)):
        ref q = records[k]
        var verbosity = Verbosity(to_int(q[2]))
        var med = to_int(q[3])
        var label = String(
            name,
            ": ",
            show(q[1]),
            " ",
            verbosity,
            " med=",
            med,
            " unknown=",
            q[4],
            " casing=",
            q[5],
        )
        if q[6] == "E":
            var raised = False
            try:
                _ = index.lookup(
                    q[1],
                    verbosity,
                    med,
                    to_bool(q[4]),
                    transfer_casing=to_bool(q[5]),
                    scratch=scratch,
                )
            except e:
                raised = True
                assert_true(
                    String(e) in q[7], String(label, ": wrong error ", e)
                )
            assert_true(raised, String(label, ": expected error ", q[7]))
        else:
            var result = index.lookup(
                q[1],
                verbosity,
                med,
                to_bool(q[4]),
                transfer_casing=to_bool(q[5]),
                scratch=scratch,
            )
            var expected = to_int(q[6])
            assert_equal(len(result), expected, String(label, ": result count"))
            for i in range(expected):
                var at = String(label, ": item ", i)
                assert_equal(result[i].term, q[7 + 3 * i], at)
                assert_equal(result[i].distance, to_int(q[8 + 3 * i]), at)
                assert_equal(result[i].count, to_int(q[9 + 3 * i]), at)
        queries += 1
    return queries


def test_lookup_matches_symspellpy() raises:
    var total = 0
    for name in materialize[CONFIGS]():
        total += _check_fixture(name)
    print("    checked", total, "lookups against symspellpy")
    assert_true(total > 100000)


# --- Brute-force oracle ---


def _brute_force(
    phrase: List[UInt32], words: List[List[UInt32]], max_distance: Int
) -> List[Int]:
    """Indices of all words within `max_distance` (OSA) of `phrase`."""
    var out = List[Int]()
    for i in range(len(words)):
        if osa_reference(phrase, words[i]) <= max_distance:
            out.append(i)
    return out^


def _check_all_is_complete(
    dictionary: String, config: SymSpellConfig, word_limit: Int, queries: Int
) raises:
    var builder = SymSpellBuilder(config)
    var words = List[String]()
    var codepoints = List[List[UInt32]]()
    with open(dictionary, "r") as f:
        for line in f.read().splitlines():
            var parts = line.split(" ")
            if len(parts) < 2:
                continue
            if builder.create_dictionary_entry(parts[0], Int(parts[1])):
                words.append(String(parts[0]))
                codepoints.append(to_codepoints(parts[0]))
            if len(words) == word_limit:
                break
    var index = builder^.build()
    var rng = Rng(42)
    var alphabet = List[UInt32]()
    for w in codepoints[: min(200, len(codepoints))]:
        for cp in w:
            if cp not in alphabet:
                alphabet.append(cp)
    var scratch = LookupScratch()
    for _ in range(queries):
        ref base = codepoints[rng.below(len(codepoints))]
        var phrase = rng.mutate(base, alphabet, rng.between(0, 3))
        var text = String()
        for cp in phrase:
            text.append(Codepoint(unsafe_unchecked_codepoint=cp))
        var med = rng.between(1, config.max_dictionary_edit_distance)
        var expected = _brute_force(phrase, codepoints, med)
        var result = index.lookup(text, Verbosity.ALL, med, scratch=scratch)
        var label = String(show(text), " med=", med)
        # symspellpy can return a short term twice, the second time with a
        # larger distance (docs/BEHAVIOR.md, 11). Compare distinct terms and
        # their smallest distance.
        var distinct = 0
        for k in range(len(result)):
            var first = True
            for j in range(k):
                if result[j].term == result[k].term:
                    first = False
            if first:
                distinct += 1
        assert_equal(
            distinct, len(expected), String(label, ": distinct result count")
        )
        for i in expected:
            var best = -1
            for s in result:
                if s.term == words[i] and (best < 0 or s.distance < best):
                    best = s.distance
            assert_true(best >= 0, String(label, ": missing ", words[i]))
            assert_equal(
                best,
                osa_reference(phrase, codepoints[i]),
                String(label, ": distance of ", words[i]),
            )


def test_all_is_complete_english() raises:
    _check_all_is_complete(
        "data/frequency_dictionary_en_82_765.txt",
        SymSpellConfig(2, 7),
        3000,
        400,
    )
    _check_all_is_complete(
        "data/frequency_dictionary_en_82_765.txt",
        SymSpellConfig(3, 5),
        1500,
        200,
    )


def test_all_is_complete_intl() raises:
    _check_all_is_complete(
        String(FIXTURES, "dict_intl.txt"), SymSpellConfig(2, 7), 2000, 300
    )
    _check_all_is_complete(
        String(FIXTURES, "dict_intl.txt"), SymSpellConfig(3, 4), 1000, 150
    )


# --- Properties ---


def _check_sorted_and_bounded(
    result: List[Suggestion], med: Int, label: String
) raises:
    for i in range(len(result)):
        assert_true(
            result[i].distance <= med, String(label, ": distance above max")
        )
        if i > 0:
            assert_true(
                not result[i].precedes(result[i - 1]),
                String(label, ": not sorted"),
            )


def test_properties() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary(String(FIXTURES, "dict_intl.txt"), 0, 1)
    var index = builder.snapshot()
    var scratch = LookupScratch()
    var words = List[String]()
    with open(String(FIXTURES, "dict_intl.txt"), "r") as f:
        for line in f.read().splitlines():
            words.append(String(line.split(" ")[0]))
    # Every word finds itself at distance 0 with its count.
    for word in words:
        var result = index.lookup(word, Verbosity.TOP, 0, scratch=scratch)
        assert_equal(len(result), 1, word)
        assert_equal(result[0].term, word)
        assert_equal(result[0].distance, 0)
        assert_equal(result[0].count, index.count(word).value())
    # Results are bounded and sorted.
    var rng = Rng(5)
    var alphabet = to_codepoints("абвгдеёжзійўąłńüωéß")
    for _ in range(2000):
        var phrase = String()
        for cp in rng.mutate(
            to_codepoints(words[rng.below(len(words))]),
            alphabet,
            rng.between(0, 3),
        ):
            phrase.append(Codepoint(unsafe_unchecked_codepoint=cp))
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            var med = rng.between(0, 2)
            _check_sorted_and_bounded(
                index.lookup(phrase, v, med, scratch=scratch), med, phrase
            )


def test_insertion_order_does_not_change_results() raises:
    # Reversed insertion changes the order of ties (equal distance and count)
    # but not the set of results or their distances and counts.
    var lines = List[Tuple[String, Int]]()
    with open(String(FIXTURES, "dict_intl.txt"), "r") as f:
        for line in f.read().splitlines():
            var parts = line.split(" ")
            lines.append((String(parts[0]), Int(parts[1])))
    var forward = SymSpellBuilder()
    var backward = SymSpellBuilder()
    for i in range(len(lines)):
        _ = forward.create_dictionary_entry(lines[i][0], lines[i][1])
        ref back = lines[len(lines) - 1 - i]
        _ = backward.create_dictionary_entry(back[0], back[1])
    var a = forward^.build()
    var b = backward^.build()
    var rng = Rng(9)
    var alphabet = to_codepoints("абвгдеёжзійўąłńüωéß")
    for _ in range(1500):
        var phrase = String()
        for cp in rng.mutate(
            to_codepoints(lines[rng.below(len(lines))][0]),
            alphabet,
            rng.between(0, 3),
        ):
            phrase.append(Codepoint(unsafe_unchecked_codepoint=cp))
        for v in [Verbosity.CLOSEST, Verbosity.ALL]:
            var ra = a.lookup(phrase, v, 2)
            var rb = b.lookup(phrase, v, 2)
            assert_equal(len(ra), len(rb), phrase)
            for s in ra:
                var found = False
                for t in rb:
                    if (
                        t.term == s.term
                        and t.distance == s.distance
                        and t.count == s.count
                    ):
                        found = True
                assert_true(found, String(phrase, ": ", s.term))
        var ta = a.lookup(phrase, Verbosity.TOP, 2)
        var tb = b.lookup(phrase, Verbosity.TOP, 2)
        assert_equal(len(ta), len(tb), phrase)
        if len(ta) == 1:
            assert_equal(ta[0].distance, tb[0].distance, phrase)
            assert_equal(ta[0].count, tb[0].count, phrase)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
