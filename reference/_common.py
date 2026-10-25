"""Shared helpers for the reference fixture generators.

Fixture format (see docs/DECISIONS.md, D8): UTF-8 text, one record per line,
fields separated by TAB. Inside a field, backslash, TAB, LF and CR are escaped
as \\\\, \\t, \\n and \\r. Lines starting with '#' are comments.
"""

import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
FIXTURES_DIR = ROOT / "tests" / "fixtures"
EN_DICT = DATA_DIR / "frequency_dictionary_en_82_765.txt"
EN_BIGRAMS = DATA_DIR / "frequency_bigramdictionary_en_243_342.txt"
INTL_DICT = FIXTURES_DIR / "dict_intl.txt"
INTL_BIGRAMS = FIXTURES_DIR / "bigrams_intl.txt"

SEED = 20261025


def escape(value: object) -> str:
    text = str(value)
    return (
        text.replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )


def bool_field(value: bool) -> str:
    return "1" if value else "0"


def float_field(value: float) -> str:
    # repr() gives the shortest string that round-trips exactly.
    return repr(float(value))


class FixtureWriter:
    """Writes records to a fixture file and reports its size when closed."""

    def __init__(self, name: str, header: str) -> None:
        self.path = FIXTURES_DIR / name
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._file = open(self.path, "w", encoding="utf-8", newline="\n")
        for line in header.strip().splitlines():
            self._file.write(f"# {line}\n")
        self.records = 0

    def write(self, *fields: object) -> None:
        self._file.write("\t".join(escape(f) for f in fields) + "\n")
        self.records += 1

    def close(self) -> None:
        self._file.close()
        size_kb = self.path.stat().st_size / 1024
        log(f"  {self.path.relative_to(ROOT)}: {self.records} records, {size_kb:.0f} KB")


def suggestion_fields(suggestions) -> list[object]:
    """Flattens a list of SuggestItem into [n, term, distance, count, ...]."""
    fields: list[object] = [len(suggestions)]
    for s in suggestions:
        fields += [s.term, s.distance, s.count]
    return fields


def read_dictionary_terms(path: Path) -> list[tuple[str, int]]:
    terms = []
    with open(path, encoding="utf-8") as infile:
        for line in infile:
            parts = line.rstrip().split(" ")
            if len(parts) >= 2:
                terms.append((parts[0], int(parts[1])))
    return terms


def alphabet_of(words: list[str]) -> list[str]:
    return sorted({c for w in words for c in w})


def typo(rng: random.Random, word: str, edits: int, alphabet: list[str]) -> str:
    """Applies `edits` random edits (insert, delete, substitute, transpose)."""
    chars = list(word)
    for _ in range(edits):
        ops = ["insert", "substitute", "delete", "transpose"]
        if not chars:
            ops = ["insert"]
        elif len(chars) < 2:
            ops = ["insert", "substitute", "delete"]
        op = rng.choice(ops)
        if op == "insert":
            chars.insert(rng.randint(0, len(chars)), rng.choice(alphabet))
        elif op == "delete":
            del chars[rng.randrange(len(chars))]
        elif op == "substitute":
            chars[rng.randrange(len(chars))] = rng.choice(alphabet)
        else:
            i = rng.randrange(len(chars) - 1)
            chars[i], chars[i + 1] = chars[i + 1], chars[i]
    return "".join(chars)


def random_string(rng: random.Random, alphabet: list[str], lo: int, hi: int) -> str:
    return "".join(rng.choice(alphabet) for _ in range(rng.randint(lo, hi)))


def random_casing(rng: random.Random, text: str) -> str:
    style = rng.choice(["lower", "title", "upper", "mixed", "first"])
    if style == "lower":
        return text
    if style == "title":
        return text.title()
    if style == "upper":
        return text.upper()
    if style == "first":
        return text[:1].upper() + text[1:]
    return "".join(c.upper() if rng.random() < 0.3 else c for c in text)


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)
