"""Edit distance fixtures: random string pairs and symspellpy's distances.

Record: a, b, max_distance, damerau_osa, levenshtein
"""

import random

from symspellpy.editdistance import DamerauOsa, Levenshtein

from _common import SEED, FixtureWriter, random_string, typo

ALPHABETS = [
    list("ab"),
    list("ab "),
    list("abcd"),
    list("abcdefghijklmnopqrstuvwxyz"),
    list("абвгдеёжзійклмнўэюя"),
    list("aąćęłńóśźżß😀"),
    list("é̆и漢字🇧🇾 "),
]
MAX_DISTANCES = [-1, 0, 1, 2, 3, 4, 5, 10, 2**31 - 1, 2**40]


def main() -> None:
    rng = random.Random(SEED + 1)
    osa = DamerauOsa()
    lev = Levenshtein()
    out = FixtureWriter(
        "distance.tsv",
        "a, b, max_distance, damerau_osa, levenshtein (symspellpy 6.10.0)",
    )
    for n in range(12000):
        alphabet = rng.choice(ALPHABETS)
        if n % 10 == 0:
            a = random_string(rng, alphabet, 30, 200)
        else:
            a = random_string(rng, alphabet, 0, 12)
        b = typo(rng, a, rng.randint(0, 6), alphabet) if rng.random() < 0.7 else random_string(rng, alphabet, 0, 12)
        k = rng.choice(MAX_DISTANCES)
        out.write(a, b, k, osa.distance(a, b, k), lev.distance(a, b, k))
    out.close()


if __name__ == "__main__":
    main()
