"""Generates a synthetic non-ASCII dictionary and bigram list.

Words are built from syllables of several alphabets (Belarusian, Russian,
Polish, German, Greek), plus words with combining marks, apostrophes, CJK
and emoji. Counts follow a Zipf-like curve. Some lines repeat a word, to test
count merging, and a few counts are near 2**63 - 1, to test saturation.
"""

import random

from _common import INTL_BIGRAMS, INTL_DICT, SEED, log

LANGUAGES = {
    "be": ("бвгджзйклмнпрстўфхцчш", "аеёіоуыэюя"),
    "ru": ("бвгджзйклмнпрстфхцчшщ", "аеёиоуыэюя"),
    "pl": ("bcćdfghjklłmnńprsśtwzźż", "aąeęioóuy"),
    "de": ("bcdfghjklmnpqrstvwxzß", "aeiouäöü"),
    "el": ("βγδζθκλμνξπρστφχψ", "αεηιουωάέήίόύώ"),
}
WORDS_PER_LANGUAGE = 900
MAXSIZE = 2**63 - 1


def make_word(rng: random.Random, consonants: str, vowels: str) -> str:
    syllables = rng.choice([1, 2, 2, 3, 3, 3, 4, 5])
    word = ""
    for _ in range(syllables):
        if rng.random() < 0.8:
            word += rng.choice(consonants)
        word += rng.choice(vowels)
        if rng.random() < 0.25:
            word += rng.choice(consonants)
    return word


def special_words(rng: random.Random) -> list[str]:
    words = [
        # Belarusian apostrophes (both forms) and Greek final sigma.
        "сям'я", "сям’я", "вераб'і", "λόγος", "κόσμος", "ζωής",
        # Combining marks: decomposed й, ё and é.
        "йна", "мӧд", "café", "été",
        # Turkish dotted capital I lowercases to two codepoints.
        "i̇stanbul", "istanbul",
        # CJK and emoji.
        "漢字", "中文", "日本語", "😀", "😀😃", "a😀b", "🇧🇾",
        # Uppercase entries and digits.
        "ÄRGER", "Straße", "BY2026", "12", "x1",
        # Very short words, including one-codepoint words.
        "ў", "ł", "ß", "ä", "я", "ω",
    ]
    for _ in range(30):
        words.append("".join(rng.choice("абвгдежзß😀ąłńüωçé") for _ in range(rng.randint(15, 30))))
    return words


def main() -> None:
    rng = random.Random(SEED)
    words: list[str] = []
    seen: set[str] = set()
    for consonants, vowels in LANGUAGES.values():
        added = 0
        while added < WORDS_PER_LANGUAGE:
            word = make_word(rng, consonants, vowels)
            if word not in seen:
                seen.add(word)
                words.append(word)
                added += 1
    for word in special_words(rng):
        if word not in seen:
            seen.add(word)
            words.append(word)
    rng.shuffle(words)

    lines = []
    for rank, word in enumerate(words, start=1):
        count = int(5e8 / rank**1.07 * rng.uniform(0.5, 1.5)) + 1
        lines.append(f"{word} {count}")
    # Duplicates merge counts; saturation at 2**63 - 1.
    for word in rng.sample(words, 60):
        lines.append(f"{word} {rng.randint(1, 1000)}")
    lines.append(f"{words[0]} {MAXSIZE - 5}")
    lines.append(f"{words[0]} {MAXSIZE - 5}")
    lines.append(f"{words[1]} {MAXSIZE}")
    rng.shuffle(lines)
    INTL_DICT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    log(f"  {INTL_DICT.name}: {len(lines)} lines, {len(words)} words")

    bigrams = set()
    top = words[:1500]
    while len(bigrams) < 3000:
        bigrams.add((rng.choice(top), rng.choice(top)))
    bigram_lines = [f"{a} {b} {rng.randint(10, 100000)}" for a, b in sorted(bigrams)]
    INTL_BIGRAMS.write_text("\n".join(bigram_lines) + "\n", encoding="utf-8")
    log(f"  {INTL_BIGRAMS.name}: {len(bigram_lines)} lines")


if __name__ == "__main__":
    main()
