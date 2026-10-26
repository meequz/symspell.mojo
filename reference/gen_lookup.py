"""Lookup fixtures: thousands of queries over several dictionary configs.

Each file starts with a config record:
    C  dictionary  max_dictionary_edit_distance  prefix_length  count_threshold
       distance_algorithm
followed by summary records:
    S  word_count  entry_count  max_length
and query records:
    Q  phrase  verbosity  max_edit_distance  include_unknown  transfer_casing
       n  term_1  distance_1  count_1  ...
A query that raises in symspellpy has n = "E" and the error message as term_1.
"""

import random

from symspellpy import SymSpell, Verbosity
from symspellpy.editdistance import DistanceAlgorithm, EditDistance

from _common import (
    EN_DICT,
    INTL_DICT,
    SEED,
    FixtureWriter,
    alphabet_of,
    bool_field,
    log,
    random_casing,
    random_string,
    read_dictionary_terms,
    suggestion_fields,
    typo,
)

VERBOSITIES = [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]

# name, dictionary, d, p, t, number of plain queries, number of flag queries.
# Names ending in "_lev" use the Levenshtein distance instead of OSA.
CONFIGS = [
    ("en_d2_p7_t1", EN_DICT, 2, 7, 1, 3000, 800),
    ("en_d3_p7_t1", EN_DICT, 3, 7, 1, 700, 150),
    ("en_d1_p3_t1", EN_DICT, 1, 3, 1, 1000, 200),
    ("en_d2_p4_t1", EN_DICT, 2, 4, 1, 1000, 200),
    ("en_d2_p10_t1", EN_DICT, 2, 10, 1, 600, 100),
    ("en_d2_p7_t50000", EN_DICT, 2, 7, 50000, 1000, 200),
    ("intl_d2_p7_t1", INTL_DICT, 2, 7, 1, 2500, 800),
    ("intl_d3_p5_t1", INTL_DICT, 3, 5, 1, 800, 200),
    ("intl_d2_p7_t3000", INTL_DICT, 2, 7, 3000, 800, 200),
    ("en_d2_p7_t1_lev", EN_DICT, 2, 7, 1, 1500, 300),
    ("intl_d3_p7_t1_lev", INTL_DICT, 3, 7, 1, 800, 200),
]


def make_queries(rng: random.Random, terms: list[tuple[str, int]], n: int) -> list[str]:
    words = [w for w, _ in terms]
    alphabet = alphabet_of(words[:5000])
    common = words[:20000]
    queries = ["", " ", "a", "  a  ", "\t"]
    while len(queries) < n:
        r = rng.random()
        word = rng.choice(common if rng.random() < 0.8 else words)
        if r < 0.15:
            queries.append(word)
        elif r < 0.40:
            queries.append(typo(rng, word, 1, alphabet))
        elif r < 0.65:
            queries.append(typo(rng, word, 2, alphabet))
        elif r < 0.78:
            queries.append(typo(rng, word, 3, alphabet))
        elif r < 0.86:
            queries.append(random_string(rng, alphabet, 1, 10))
        elif r < 0.91:
            queries.append(random_string(rng, list("абвгдеёжзійўąłńß😀漢é"), 1, 10))
        elif r < 0.95:
            queries.append(word[: rng.randint(1, max(1, len(word)))])
        elif r < 0.98:
            queries.append(random_string(rng, alphabet, 25, 120))
        else:
            queries.append(word + " " + rng.choice(common))
    return queries


def make_flag_queries(rng: random.Random, queries: list[str], n: int) -> list[str]:
    picked = rng.sample(queries, min(n, len(queries)))
    return [random_casing(rng, q) for q in picked] + ["İstanbul", "ΟΔΟΣ", "Straße", "STRASSE", "ÄRGER", "I"]


def write_query(out, sym, phrase, verbosity, med, include_unknown, transfer_casing):
    try:
        result = sym.lookup(
            phrase,
            verbosity,
            med,
            include_unknown=include_unknown,
            transfer_casing=transfer_casing,
        )
        fields = suggestion_fields(result)
    except Exception as exc:  # noqa: BLE001 - recorded as expected behavior
        fields = ["E", f"{type(exc).__name__}: {exc}"]
    out.write(
        "Q",
        phrase,
        verbosity.value,
        med,
        bool_field(include_unknown),
        bool_field(transfer_casing),
        *fields,
    )


def main() -> None:
    for name, dictionary, d, p, t, n_plain, n_flags in CONFIGS:
        log(f"lookup {name}")
        rng = random.Random(f"{SEED}-{name}")
        levenshtein = name.endswith("_lev")
        algorithm = DistanceAlgorithm.LEVENSHTEIN if levenshtein else DistanceAlgorithm.DAMERAU_OSA
        sym = SymSpell(d, p, t, distance_comparer=EditDistance(algorithm))
        sym.load_dictionary(dictionary, 0, 1)
        terms = read_dictionary_terms(dictionary)
        queries = make_queries(rng, terms, n_plain)

        out = FixtureWriter(f"lookup_{name}.tsv", __doc__)
        out.write("C", dictionary.name, d, p, t, "levenshtein" if levenshtein else "osa")
        out.write("S", sym.word_count, sym.entry_count, sym._max_length)
        for phrase in queries:
            for verbosity in VERBOSITIES:
                for med in range(0, d + 1):
                    write_query(out, sym, phrase, verbosity, med, False, False)
        # med above the dictionary setting must raise; negative is accepted.
        for phrase in queries[:20]:
            write_query(out, sym, phrase, Verbosity.TOP, d + 1, False, False)
            write_query(out, sym, phrase, Verbosity.ALL, -1, True, False)
        for phrase in make_flag_queries(rng, queries, n_flags):
            for verbosity in VERBOSITIES:
                for med in sorted({1, d}):
                    for include_unknown, transfer_casing in [(True, False), (False, True), (True, True)]:
                        write_query(out, sym, phrase, verbosity, med, include_unknown, transfer_casing)
        out.close()


if __name__ == "__main__":
    main()
