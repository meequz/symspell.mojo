"""Lookup tests: ports of symspellpy's tests/test_symspellpy_lookup.py and the
lookup parts of tests/test_symspellpy_edge_cases.py.
"""

from std.os.path import exists
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from symspell import (
    LookupScratch,
    SymSpell,
    SymSpellBuilder,
    SymSpellConfig,
    Verbosity,
)
from symspell.text import decimal_value, to_codepoints

comptime DICTIONARY = "data/frequency_dictionary_en_82_765.txt"
comptime QUERIES = "tests/fixtures/symspellpy/noisy_query_en_1000.txt"


def _index(
    entries: List[Tuple[String, Int]], config: SymSpellConfig = SymSpellConfig()
) raises -> SymSpell:
    var builder = SymSpellBuilder(config)
    for entry in entries:
        _ = builder.create_dictionary_entry(entry[0], entry[1])
    return builder^.build()


def _steam_abc() raises -> SymSpell:
    return _index([("steama", 4), ("steamb", 6), ("steamc", 2)])


def _high_threshold_flame() raises -> SymSpell:
    """symspellpy's `symspell_high_thres_flame`: SymSpell(2, 7, 10)."""
    return _index([("flame", 20), ("flam", 1)], SymSpellConfig(2, 7, 10))


def test_deletes() raises:
    var index = _steam_abc()
    var result = index.lookup("stream", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steamb")
    assert_equal(result[0].count, 6)
    assert_true(index.entry_count() > 0)


def test_words_with_shared_prefix_should_retain_counts() raises:
    var index = _index([("pipe", 5), ("pips", 10)], SymSpellConfig(1, 3))
    var result = index.lookup("pipe", Verbosity.ALL, 1)
    assert_equal(len(result), 2)
    assert_equal(result[0].term, "pipe")
    assert_equal(result[0].count, 5)
    assert_equal(result[1].term, "pips")
    assert_equal(result[1].count, 10)

    result = index.lookup("pips", Verbosity.ALL, 1)
    assert_equal(len(result), 2)
    assert_equal(result[0].term, "pips")
    assert_equal(result[0].count, 10)
    assert_equal(result[1].term, "pipe")
    assert_equal(result[1].count, 5)

    result = index.lookup("pip", Verbosity.ALL, 1)
    assert_equal(len(result), 2)
    assert_equal(result[0].term, "pips")
    assert_equal(result[0].count, 10)
    assert_equal(result[1].term, "pipe")
    assert_equal(result[1].count, 5)


def test_verbosity_should_control_lookup_results() raises:
    var index = _index([("steam", 1), ("steams", 2), ("steem", 3)])
    assert_equal(len(index.lookup("steems", Verbosity.TOP, 2)), 1)
    assert_equal(len(index.lookup("steems", Verbosity.CLOSEST, 2)), 2)
    assert_equal(len(index.lookup("steems", Verbosity.ALL, 2)), 3)


def test_should_return_most_frequent() raises:
    var result = _steam_abc().lookup("stream", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steamb")
    assert_equal(result[0].count, 6)


def test_should_find_exact_match() raises:
    var result = _steam_abc().lookup("streama", Verbosity.TOP, 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "steama")


def test_should_not_return_non_word_delete() raises:
    var index = _index([("pawn", 10)], SymSpellConfig(2, 7, 10))
    assert_equal(len(index.lookup("paw", Verbosity.TOP, 0)), 0)
    assert_equal(len(index.lookup("awn", Verbosity.TOP, 0)), 0)


def test_should_not_return_low_count_word() raises:
    var index = _index([("pawn", 1)], SymSpellConfig(2, 7, 10))
    assert_equal(len(index.lookup("pawn", Verbosity.TOP, 0)), 0)


def test_should_not_return_low_count_word_that_are_also_delete_word() raises:
    assert_equal(
        len(_high_threshold_flame().lookup("flam", Verbosity.TOP, 0)), 0
    )


def test_max_edit_distance_too_large() raises:
    with assert_raises(contains="distance too large"):
        _ = _high_threshold_flame().lookup("flam", Verbosity.TOP, 3)


def test_include_unknown() raises:
    var result = _high_threshold_flame().lookup("flam", Verbosity.TOP, 0, True)
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "flam")


def _two_digits_then_word(token: String) -> Bool:
    """Same as `re.match(r"\\d{2}\\w*\\b", token)`: two leading decimal digits.
    """
    var cps = to_codepoints(token)
    return (
        len(cps) >= 2
        and decimal_value(cps[0]) >= 0
        and decimal_value(cps[1]) >= 0
    )


def test_avoid_exact_match_early_exit() raises:
    var result = _high_threshold_flame().lookup(
        "24th", Verbosity.ALL, 2, ignore_token=_two_digits_then_word
    )
    assert_equal(len(result), 1)
    assert_equal(result[0].term, "24th")


def test_should_replicate_noisy_results() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary(DICTIONARY, 0, 1)
    var index = builder^.build()
    var scratch = LookupScratch()
    var total = 0
    with open(QUERIES, "r") as f:
        for line in f.read().splitlines():
            var parts = line.strip().split()
            if len(parts) >= 2:
                total += len(
                    index.lookup(
                        parts[0], Verbosity.CLOSEST, 2, scratch=scratch
                    )
                )
    assert_equal(total, 4955)


def test_transfer_casing() raises:
    var cases: List[Tuple[String, String, String]] = [
        ("steam", "Stream", "Steam"),
        ("steam", "StreaM", "SteaM"),
        ("steam", "STREAM", "STEAM"),
        ("i", "I", "I"),
    ]
    for item in cases:
        var index = _index([(item[0], 4)])
        var result = index.lookup(
            item[1], Verbosity.TOP, 2, transfer_casing=True
        )
        assert_equal(result[0].term, item[2])


def _resident_pages() raises -> Int:
    """Resident memory in pages (Linux), or -1 where /proc is not available."""
    if not exists("/proc/self/statm"):
        return -1
    with open("/proc/self/statm", "r") as f:
        return Int(f.read().split(" ")[1])


def test_no_memory_growth_in_long_loops() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary(DICTIONARY, 0, 1)
    var index = builder^.build()
    var scratch = LookupScratch()
    var queries: List[String] = [
        "helo",
        "memebers",
        "xyzzy",
        "Beutiful",
        "a",
        "acommodation",
        "Беларусь",
    ]
    var before = 0
    for round in range(6):
        for _ in range(1000):
            for q in queries:
                _ = index.lookup(
                    q,
                    Verbosity.ALL,
                    2,
                    include_unknown=True,
                    transfer_casing=True,
                    scratch=scratch,
                )
        if round == 0:
            before = (
                _resident_pages()
            )  # after buffers reached their working size
    var after = _resident_pages()
    if before >= 0:
        # 35,000 lookups after warm-up; allow 256 pages (1 MiB at 4 KiB) of noise.
        assert_true(
            after - before < 256,
            String("resident pages grew from ", before, " to ", after),
        )


# --- tests/test_symspellpy_edge_cases.py ---


def test_empty_string_has_all_short_deletes() raises:
    var entries: List[String] = ["baked", "ax", "lake", "", "slaked"]
    var builder = SymSpellBuilder(SymSpellConfig(5))
    for entry in entries:
        _ = builder.create_dictionary_entry(entry, 2)
    var bucket = builder^.build()._bucket_terms("")
    assert_equal(len(bucket), 4)
    for i in range(4):
        assert_true(entries[i] in bucket)
    assert_false(String("abc") in bucket)


def test_no_common_char_with_phrase() raises:
    var builder = SymSpellBuilder(SymSpellConfig(5))
    _ = builder.create_dictionary_entry("bank", 2)
    _ = builder.create_dictionary_entry("bink", 2)
    var results = builder^.build().lookup("knab", Verbosity.ALL, 4)
    assert_equal(len(results), 2)
    assert_equal(results[0].term, "bank")
    assert_equal(results[0].distance, 3)
    assert_equal(results[1].term, "bink")
    assert_equal(results[1].distance, 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
