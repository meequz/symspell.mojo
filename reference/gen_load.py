"""Dictionary loading fixtures: odd files and the resulting dictionary state.

Input files are written to tests/fixtures/load/. Records:
    U  file  term_index  count_index  separator  d  p  t      (load_dictionary)
    B  file  term_index  count_index  separator-or-"<None>"   (load_bigram_dictionary)
    Y  file  d  p  t                                          (create_dictionary)
followed by the outcome:
    E  error message            (the call raised)
    G  word_count  entry_count  max_length  n_below  bigram_count_min
    w  term  count              (one per word, sorted by term)
    b  term  count              (one per below-threshold word, sorted)
    g  bigram  count            (one per bigram, sorted)
"""

import random
import warnings

from symspellpy import SymSpell

from _common import FIXTURES_DIR, SEED, FixtureWriter

LOAD_DIR = FIXTURES_DIR / "load"
MAXSIZE = 2**63 - 1

FILES = {
    "crlf.txt": b"apple 10\r\nbanana 20\r\ncherry 30\r\n",
    "lone_cr.txt": b"apple 10\rbanana 20\rcherry 30",
    "mixed_newlines.txt": b"one 1\ntwo 2\r\nthree 3\rfour 4\n\nfive five\n",
    "trailing_space.txt": b"alpha 5   \nbeta 6\t\ngamma 7\xc2\xa0\ndelta 8\xe2\x80\x83\n",
    "bad_lines.txt": b"\n \nonlyword\nword notanumber\nok 3\n 4\n\t5\nx  6\ndup 1\ndup 2\ndup 3\n",
    "counts.txt": (
        "neg -5\nzero 0\nplus +7\nunder 1_000\nbadunder 1__0\nwide １２\n"
        "arabic ٣٤\nsup ²\nhuge 92233720368547758081\n"
        f"max {MAXSIZE}\nmax 1\nnear {MAXSIZE - 1}\nnear 1\nnear 5\n"
        "small 1\n"
    ).encode("utf-8"),
    "unicode.txt": "сям'я 10\nλόγος 20\nStraße 30\n😀 40\né 50\n漢字 60\n".encode("utf-8"),
    "separator.txt": b"the$23135851162\nof$13151942776\nabcs of$10956800\n$5\nx$$6\n",
    "tabs.txt": b"a\t1\tz\nb\t2\tz\nlongword\t3\tz\n",
    "columns.txt": b"5 alpha\n6 beta\n7 gamma\n",
    "invalid_utf8.txt": b"good 1\nbad\xff\xfe 2\n",
    "bigrams.txt": (
        "the quick 10\nquick brown 3\nbad line\nx y notanumber\nthe quick 12\n"
        "a  b 4\nlonely 5 7\nc\td 8\n"
    ).encode("utf-8"),
    "bigrams_sep.txt": b"the quick$10\nquick brown$3\nonly\n$1\n",
    "corpus.txt": (
        "The quick brown fox. Don't stop! It’s 2026, isn't it? "
        "snake_case and CamelCase; сям'я λόγος "
        "'quoted' word''s a² ٣ fox fox FOX\n"
    ).encode("utf-8"),
}

UNIGRAM_CASES = [
    ("crlf.txt", 0, 1, " ", 2, 7, 1),
    ("lone_cr.txt", 0, 1, " ", 2, 7, 1),
    ("mixed_newlines.txt", 0, 1, " ", 2, 7, 1),
    ("trailing_space.txt", 0, 1, " ", 2, 7, 1),
    ("bad_lines.txt", 0, 1, " ", 2, 7, 1),
    ("bad_lines.txt", 0, 1, " ", 2, 7, 4),
    ("counts.txt", 0, 1, " ", 2, 7, 1),
    ("counts.txt", 0, 1, " ", 2, 7, 0),
    ("counts.txt", 0, 1, " ", 2, 7, 1000),
    ("unicode.txt", 0, 1, " ", 2, 7, 1),
    ("unicode.txt", 0, 1, " ", 1, 2, 1),
    ("separator.txt", 0, 1, "$", 2, 7, 1),
    ("tabs.txt", 0, 1, "\t", 2, 7, 1),
    ("tabs.txt", 0, 2, "\t", 2, 7, 1),
    ("columns.txt", 1, 0, " ", 2, 7, 1),
    ("invalid_utf8.txt", 0, 1, " ", 2, 7, 1),
    ("bigrams.txt", 0, 2, " ", 2, 7, 1),
]
BIGRAM_CASES = [
    ("bigrams.txt", 0, 2, None),
    ("bigrams_sep.txt", 0, 1, "$"),
    ("crlf.txt", 0, 1, " "),
    ("separator.txt", 0, 1, "$"),
    ("invalid_utf8.txt", 0, 1, " "),
]
CORPUS_CASES = [
    ("corpus.txt", 2, 7, 1),
    ("corpus.txt", 2, 7, 2),
    ("invalid_utf8.txt", 2, 7, 1),
]


def write_state(out, sym: SymSpell) -> None:
    out.write("G", sym.word_count, sym.entry_count, sym._max_length, len(sym.below_threshold_words), sym.bigram_count_min)
    for term, count in sorted(sym.words.items()):
        out.write("w", term, count)
    for term, count in sorted(sym.below_threshold_words.items()):
        out.write("b", term, count)
    for term, count in sorted(sym.bigrams.items()):
        out.write("g", term, count)


def write_random_files(rng: random.Random) -> None:
    alphabet = list("ab \t$\r\n5-_ я😀")
    for n in range(20):
        FILES[f"random_{n}.txt"] = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 300))).encode("utf-8")
        UNIGRAM_CASES.append((f"random_{n}.txt", 0, 1, " ", 2, 7, 1))
        UNIGRAM_CASES.append((f"random_{n}.txt", 0, 1, "$", 2, 7, 2))
        BIGRAM_CASES.append((f"random_{n}.txt", 0, 2, None))


def main() -> None:
    warnings.simplefilter("ignore")
    write_random_files(random.Random(f"{SEED}-load"))
    LOAD_DIR.mkdir(parents=True, exist_ok=True)
    for name, content in FILES.items():
        (LOAD_DIR / name).write_bytes(content)

    out = FixtureWriter("load.tsv", __doc__)
    for name, term_index, count_index, separator, d, p, t in UNIGRAM_CASES:
        out.write("U", name, term_index, count_index, separator, d, p, t)
        sym = SymSpell(d, p, t)
        try:
            sym.load_dictionary(LOAD_DIR / name, term_index, count_index, separator, encoding="utf-8")
            write_state(out, sym)
        except Exception as exc:  # noqa: BLE001
            out.write("E", f"{type(exc).__name__}: {exc}")
    for name, term_index, count_index, separator in BIGRAM_CASES:
        out.write("B", name, term_index, count_index, "<None>" if separator is None else separator)
        sym = SymSpell()
        try:
            sym.load_bigram_dictionary(LOAD_DIR / name, term_index, count_index, separator, encoding="utf-8")
            write_state(out, sym)
        except Exception as exc:  # noqa: BLE001
            out.write("E", f"{type(exc).__name__}: {exc}")
    for name, d, p, t in CORPUS_CASES:
        out.write("Y", name, d, p, t)
        sym = SymSpell(d, p, t)
        try:
            sym.create_dictionary(LOAD_DIR / name, encoding="utf-8")
            write_state(out, sym)
        except Exception as exc:  # noqa: BLE001
            out.write("E", f"{type(exc).__name__}: {exc}")
    out.close()


if __name__ == "__main__":
    main()
