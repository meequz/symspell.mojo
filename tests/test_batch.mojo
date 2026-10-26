"""Tests for lookup_batch: results must equal sequential lookups."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from _fixtures import FIXTURES
from _oracles import Rng
from symspell import LookupScratch, SymSpellBuilder, SymSpellConfig, Verbosity
from symspell.text import to_codepoints


def _queries(n: Int) raises -> List[String]:
    var words = List[String]()
    with open(String(FIXTURES, "dict_intl.txt"), "r") as f:
        for line in f.read().splitlines():
            words.append(String(line.split(" ")[0]))
    var rng = Rng(12)
    var alphabet = to_codepoints("абвгдеёжзійўąłńüωéßABC")
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
    out.append("")
    return out^


def test_batch_equals_sequential() raises:
    var builder = SymSpellBuilder(SymSpellConfig(2, 7))
    builder.load_dictionary(String(FIXTURES, "dict_intl.txt"))
    var index = builder^.build()
    var queries = _queries(3000)
    var scratch = LookupScratch()
    for threads in [1, 2, 3, 4, 8, 0]:
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            var batch = index.lookup_batch(
                queries, v, 2, include_unknown=True, threads=threads
            )
            assert_equal(len(batch), len(queries))
            for i in range(len(queries)):
                var single = index.lookup(
                    queries[i], v, 2, True, scratch=scratch
                )
                assert_equal(len(batch[i]), len(single), queries[i])
                for k in range(len(single)):
                    assert_equal(batch[i][k].term, single[k].term, queries[i])
                    assert_equal(
                        batch[i][k].distance, single[k].distance, queries[i]
                    )
                    assert_equal(batch[i][k].count, single[k].count, queries[i])


def test_batch_edge_cases() raises:
    var builder = SymSpellBuilder()
    _ = builder.create_dictionary_entry("hello", 3)
    _ = builder.create_dictionary_entry(
        "a", 1
    )  # "" finds it, then casing raises
    var index = builder^.build()
    var empty = List[String]()
    assert_equal(len(index.lookup_batch(empty, Verbosity.TOP)), 0)
    var one: List[String] = ["helo"]
    assert_equal(
        index.lookup_batch(one, Verbosity.TOP, threads=16)[0][0].term, "hello"
    )
    with assert_raises(contains="distance too large"):
        _ = index.lookup_batch(one, Verbosity.TOP, 3)
    # An error inside a worker is raised after all threads finish.
    var with_empty: List[String] = ["helo", "", "Helo", "helo"]
    with assert_raises(contains="cased_text"):
        _ = index.lookup_batch(
            with_empty, Verbosity.TOP, transfer_casing=True, threads=4
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
