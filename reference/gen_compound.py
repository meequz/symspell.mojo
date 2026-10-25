"""lookup_compound and word_segmentation fixtures.

lookup_compound files:
    C  dictionary  bigrams-or-"-"  d  p  t
    K  phrase  med  ignore_non_words  transfer_casing  split_by_space  ignore_term_with_digits
       term  distance  count
    R  key  term  distance  count      (replaced_words after all K records of one flag set)
    X  (marks the start of a new flag set: the replaced_words map starts empty again)

word_segmentation files:
    C  dictionary  d  p  t
    W  phrase  med  max_segmentation_word_length-or-"-"
       segmented  corrected  distance_sum  log_prob_sum
A call that raises has "E" and the message in place of the result fields.
"""

import random
import unicodedata

from symspellpy import SymSpell

from _common import (
    EN_BIGRAMS,
    EN_DICT,
    FIXTURES_DIR,
    INTL_BIGRAMS,
    INTL_DICT,
    SEED,
    FixtureWriter,
    alphabet_of,
    bool_field,
    float_field,
    log,
    random_casing,
    read_dictionary_terms,
    typo,
)

FLAG_SETS = [
    (False, False, False, False),
    (True, False, False, False),
    (False, True, False, False),
    (True, True, False, False),
    (True, False, True, True),
    (False, False, True, False),
]
EXTRA_TOKENS = ["24", "1st", "AB12", "NASA", "24/7", "3.14", "U.S.", "don't", "it’s", "--", "!", "x2", "٣٤"]


def make_sentences(rng: random.Random, terms, n: int, intl: bool) -> list[str]:
    words = [w for w, _ in terms[:6000]]
    alphabet = alphabet_of(words[:3000])
    sentences = []
    for _ in range(n):
        tokens = [rng.choice(words) for _ in range(rng.randint(1, 9))]
        out = []
        i = 0
        while i < len(tokens):
            r = rng.random()
            word = tokens[i]
            if r < 0.25:
                out.append(typo(rng, word, rng.randint(1, 2), alphabet))
            elif r < 0.37 and i + 1 < len(tokens):
                out.append(word + tokens[i + 1])
                i += 1
            elif r < 0.47 and len(word) > 3:
                cut = rng.randint(1, len(word) - 1)
                out.append(word[:cut] + " " + word[cut:])
            elif r < 0.52 and not intl:
                out.append(rng.choice(EXTRA_TOKENS))
            else:
                out.append(word)
            i += 1
        sentence = " ".join(out)
        if rng.random() < 0.3:
            sentence = random_casing(rng, sentence)
        if rng.random() < 0.1:
            sentence += rng.choice([".", "?", "!", ","])
        sentences.append(sentence)
    return sentences


def symspellpy_typos() -> list[str]:
    import json

    typos = []
    for name in [
        "lookup_compound_data.json",
        "lookup_compound_ignore_non_words_data.json",
        "lookup_compound_replaced_words_data.json",
        "lookup_compound_transfer_casing_data.json",
        "lookup_compound_transfer_casing_ignore_nonwords_data.json",
    ]:
        with open(FIXTURES_DIR / "symspellpy" / name, encoding="utf-8") as infile:
            typos += [entry["typo"] for entry in json.load(infile)["data"]]
    return typos


def write_compound(name, dictionary, bigrams, sentences, meds) -> None:
    log(f"compound {name}")
    sym = SymSpell(2, 7, 1)
    sym.load_dictionary(dictionary, 0, 1)
    if bigrams is not None:
        sym.load_bigram_dictionary(bigrams, 0, 2)
    out = FixtureWriter(f"compound_{name}.tsv", __doc__)
    out.write("C", dictionary.name, bigrams.name if bigrams else "-", 2, 7, 1)
    for flags in FLAG_SETS:
        out.write("X")
        sym._replaced_words = {}
        for phrase in sentences:
            for med in meds:
                try:
                    r = sym.lookup_compound(phrase, med, *flags)[0]
                    result = [r.term, r.distance, r.count]
                except Exception as exc:  # noqa: BLE001
                    result = ["E", f"{type(exc).__name__}: {exc}", ""]
                out.write("K", phrase, med, *[bool_field(f) for f in flags], *result)
        for key, item in sorted(sym.replaced_words.items()):
            out.write("R", key, item.term, item.distance, item.count)
    out.close()


def write_segmentation(name, dictionary, phrases, d) -> None:
    log(f"segmentation {name}")
    sym = SymSpell(d, 7, 1)
    sym.load_dictionary(dictionary, 0, 1)
    out = FixtureWriter(f"segmentation_{name}.tsv", __doc__)
    out.write("C", dictionary.name, d, 7, 1)
    for phrase in phrases:
        for med in range(0, d + 1):
            for max_len in [None, 11]:
                try:
                    c = sym.word_segmentation(phrase, med, max_len)
                    result = [c.segmented_string, c.corrected_string, c.distance_sum, float_field(c.log_prob_sum)]
                except Exception as exc:  # noqa: BLE001
                    result = ["E", f"{type(exc).__name__}: {exc}", "", ""]
                out.write("W", phrase, med, "-" if max_len is None else max_len, *result)
    out.close()


def nfkc_stable(text: str) -> bool:
    return unicodedata.normalize("NFKC", text) == text


def main() -> None:
    rng = random.Random(f"{SEED}-compound")
    en_terms = read_dictionary_terms(EN_DICT)
    intl_terms = read_dictionary_terms(INTL_DICT)

    en_sentences = symspellpy_typos() + make_sentences(rng, en_terms, 250, intl=False)
    intl_sentences = make_sentences(rng, intl_terms, 200, intl=True)
    write_compound("en_bigram", EN_DICT, EN_BIGRAMS, en_sentences, [1, 2])
    write_compound("en_unigram", EN_DICT, None, en_sentences, [2])
    write_compound("intl_bigram", INTL_DICT, INTL_BIGRAMS, intl_sentences, [1, 2])

    # Segmentation input: sentences with most spaces removed. Mojo does not do
    # NFKC normalization (docs/DECISIONS.md, D7), so inputs must be NFKC-stable.
    def squash(sentences):
        phrases = []
        for s in sentences:
            s = "".join(c if c != " " or rng.random() < 0.15 else "" for c in s)
            if s and nfkc_stable(s):
                phrases.append(s)
        return phrases

    en_phrases = squash(en_sentences[:220]) + ["There'resomewords", "thequickbrownfoxjumpsoverthelazydog", "a", " ", "-", "a-b", ""]
    intl_phrases = squash(intl_sentences[:150])
    write_segmentation("en_d2", EN_DICT, en_phrases, 2)
    write_segmentation("intl_d2", INTL_DICT, intl_phrases, 2)


if __name__ == "__main__":
    main()
