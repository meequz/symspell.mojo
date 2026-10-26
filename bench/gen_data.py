"""Generates benchmark data into bench/data/ (fixed seeds, reproducible).

- queries_10k.txt: 10,000 queries from the English dictionary, a fixed mix of
  correct words (30%), one-edit (40%) and two-edit (30%) typos.
- sentences.txt: 200 noisy sentences for lookup_compound.
- segmentation.txt: 100 phrases without spaces for word_segmentation.
- large_dict.txt: a synthetic 1.2M-term dictionary of an inflected language
  (Belarusian-like Cyrillic stems x 24 endings), with Zipf-like counts.
- large_queries.txt: 5,000 queries for the large dictionary.

Run: pixi run -e ref python bench/gen_data.py
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "reference"))
from _common import EN_DICT, alphabet_of, read_dictionary_terms, typo  # noqa: E402

OUT = Path(__file__).resolve().parent / "data"
SEED = 6061

CONSONANTS = "бвгджзйклмнпрстўфхцчш"
VOWELS = "аеёіоуыэюя"
ENDINGS = [
    "", "а", "у", "ы", "ам", "аў", "амі", "ах", "е", "ем", "ой", "ою",
    "ага", "аму", "ым", "ых", "ымі", "ая", "ую", "ое", "ыя", "ці", "ць", "ла",
]


def write(name: str, lines: list[str]) -> None:
    path = OUT / name
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  {path.relative_to(OUT.parent.parent)}: {len(lines)} lines", file=sys.stderr)


def english_queries(rng: random.Random, words: list[str], alphabet: list[str], n: int) -> list[str]:
    queries = []
    for i in range(n):
        word = rng.choice(words)
        r = i % 10
        edits = 0 if r < 3 else (1 if r < 7 else 2)
        queries.append(typo(rng, word, edits, alphabet) if edits else word)
    rng.shuffle(queries)
    return [q for q in queries if q.strip()] or ["a"]


def sentences(rng: random.Random, words: list[str], alphabet: list[str], n: int) -> list[str]:
    out = []
    for _ in range(n):
        tokens = []
        for word in (rng.choice(words) for _ in range(rng.randint(4, 10))):
            r = rng.random()
            if r < 0.3:
                tokens.append(typo(rng, word, rng.randint(1, 2), alphabet))
            elif r < 0.4 and len(word) > 3:
                cut = rng.randint(1, len(word) - 1)
                tokens.append(word[:cut] + " " + word[cut:])
            else:
                tokens.append(word)
        # Merge one pair of neighbors to test the combination logic.
        if len(tokens) > 2:
            k = rng.randrange(len(tokens) - 1)
            tokens[k : k + 2] = [tokens[k] + tokens[k + 1]]
        out.append(" ".join(tokens))
    return out


def large_dictionary(rng: random.Random) -> list[str]:
    stems = set()
    while len(stems) < 50_000:
        stem = "".join(rng.choice(CONSONANTS) + rng.choice(VOWELS) for _ in range(rng.randint(1, 4)))
        stem += rng.choice(CONSONANTS)
        stems.add(stem)
    terms = [stem + ending for stem in sorted(stems) for ending in ENDINGS]
    rng.shuffle(terms)
    lines = []
    for rank, term in enumerate(terms, start=1):
        lines.append(f"{term} {int(1e9 / rank ** 0.9 * rng.uniform(0.5, 1.5)) + 1}")
    return lines


def main() -> None:
    OUT.mkdir(exist_ok=True)
    rng = random.Random(SEED)
    terms = read_dictionary_terms(EN_DICT)
    words = [w for w, _ in terms[:30000]]
    alphabet = alphabet_of(words[:5000])
    write("queries_10k.txt", english_queries(rng, words, alphabet, 10_000))
    sents = sentences(rng, words[:10000], alphabet, 200)
    write("sentences.txt", sents)
    write("segmentation.txt", [s.replace(" ", "") for s in sents[:100]])
    large = large_dictionary(rng)
    write("large_dict.txt", large)
    large_words = [line.split(" ")[0] for line in large[:200_000]]
    cyrillic = sorted(set(CONSONANTS + VOWELS))
    write("large_queries.txt", english_queries(rng, large_words, cyrillic, 5_000))


if __name__ == "__main__":
    main()
