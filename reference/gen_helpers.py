"""Fixtures for text helpers: casing, word parsing, number parsing, case transfer.

Records:
    L  text  text.lower()  text.upper()  text.capitalize()
    P  text  split_by_space  preserve_case  n  word_1 ... word_n   (helpers.parse_words)
    D  text  n  word_1 ... word_n                                 (SymSpell._parse_words)
    A  word  is_acronym(word)  is_acronym(word, True)
    I  text  ok  value                                            (helpers.try_parse_int64)
    T  cased  uncased  result-or-"E"  error                        (case_transfer_similar)
    M  a  b  n  tag i1 i2 j1 j2 ...                                (SequenceMatcher opcodes)
"""

import random
from difflib import SequenceMatcher

from symspellpy import helpers
from symspellpy.symspellpy import SymSpell

from _common import SEED, FixtureWriter, random_casing, random_string, typo

PIECES = [
    "a", "B", "z", "Z", "0", "9", "_", " ", "  ", "\t", "\n", "'", "’", "-", ".", ",", "!", "?",
    "ä", "Ä", "ß", "ẞ", "ł", "Ł", "ў", "Ў", "я", "Я", "İ", "ı", "Σ", "σ", "ς", "Ω", "ǅ", "ǆ", "Ǆ",
    "ŉ", "ﬁ", "é", "̆", "😀", "🇧🇾", "漢", "٣", "²", "½", "Ⅻ", " ", " ",
    "　", "\x1c", "\x85", "ΟΔΟΣ", "ΑΣ", "Σ.", "AΣb", "word", "Word", "WORD", "123",
]
INT_CASES = [
    "0", "-0", "+5", " 42 ", "\t7\n", "1_000", "1__0", "_1", "1_", "٣٤", "²", "１２", "9223372036854775807",
    "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "92233720368547758081",
    "", " ", "+", "-", "1.0", "1e3", "0x10", "00012", " 12 ", "1 2", "١٢٣", "--1",
]


def main() -> None:
    rng = random.Random(f"{SEED}-helpers")
    texts = ["", " ", "ΟΔΟΣ ΟΣ", "İstanbul", "ǆa", "ŉ", "Straße", "don't stop", "it’s ok", "a'b'c", "''a", "a''", "_a_b_"]
    for _ in range(4000):
        texts.append("".join(rng.choice(PIECES) for _ in range(rng.randint(1, 8))))

    out = FixtureWriter("helpers.tsv", __doc__)
    for text in texts:
        out.write("L", text, text.lower(), text.upper(), text.capitalize())
    # Every codepoint once, so the generated Unicode tables are fully checked.
    for cp in range(0x110000):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        c = chr(cp)
        if c.lower() != c or c.upper() != c or c.capitalize() != c:
            out.write("L", c, c.lower(), c.upper(), c.capitalize())
    for text in texts:
        for split_by_space in (False, True):
            for preserve_case in (False, True):
                words = helpers.parse_words(text, preserve_case, split_by_space)
                out.write("P", text, int(split_by_space), int(preserve_case), len(words), *words)
        words = SymSpell._parse_words(text)
        out.write("D", text, len(words), *words)
    acronyms = ["ABCDE", "AB12E", "abcde", "ABCde", "abcDE", "abCDe", "abc12", "ab12e", "A", "AB", "AB_", "AB-c",
                "ÄB", "AB'S", "AB’S", "12", "1", "A1", "AB c", "²²", "ABä", "AB😀", " AB", "_AB"]
    acronyms += [t for t in texts[:800]]
    for word in acronyms:
        out.write("A", word, int(helpers.is_acronym(word)), int(helpers.is_acronym(word, True)))
    for text in INT_CASES + texts[:300]:
        value = helpers.try_parse_int64(text)
        out.write("I", text, 0 if value is None else 1, 0 if value is None else value)

    pairs = [
        ("Haaw is the weeather in New York?", "how is the weather in new york?"),
        ("Wethr in New Yoork", "weather in new york"),
        ("Efthr in New Yoork", "weather in new york"),
        ("efthr in New Yoork", "weather in new york"),
        ("eTr in New Yoork", "weather in new york"),
        ("hoW eqr", "Haaaw er"),
        ("hOW eqr", "Haaaw er"),
        ("", "abcd"),
        ("abc", ""),
        ("İstanbul", "istanbul"),
        ("ΟΔΟΣ", "οδος"),
    ]
    alphabet = list("abcde fghij")
    for _ in range(3000):
        base = random_string(rng, alphabet, 0, 40) if rng.random() < 0.9 else random_string(rng, alphabet, 190, 320)
        pairs.append((random_casing(rng, typo(rng, base, rng.randint(0, 5), alphabet)), base))
    for _ in range(300):
        base = "".join(rng.choice(PIECES) for _ in range(rng.randint(1, 6)))
        pairs.append((random_casing(rng, base), base.lower()))
    for cased, uncased in pairs:
        try:
            out.write("T", cased, uncased, helpers.case_transfer_similar(cased, uncased), "")
        except Exception as exc:  # noqa: BLE001
            out.write("T", cased, uncased, "E", f"{type(exc).__name__}: {exc}")
        a = cased.lower()
        ops = SequenceMatcher(a=a, b=uncased).get_opcodes()
        out.write("M", a, uncased, len(ops), *[x for op in ops for x in op])
    out.close()


if __name__ == "__main__":
    main()
