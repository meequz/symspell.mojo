"""Converts symspellpy's JSON test fixtures to the TSV fixture format.

This is a plain format conversion; the values are symspellpy's own.

lookup_compound*.tsv records:
    F  typo  dictionary("bigram"/"unigram")  num_results  term  distance  count
    r  key  term                       (replacement, only in replaced_words data)
word_segmentation.tsv records:
    F  typo  edit_distance  term
"""

import json

from _common import FIXTURES_DIR, FixtureWriter

SRC = FIXTURES_DIR / "symspellpy"


def convert_compound(name: str) -> None:
    with open(SRC / f"{name}.json", encoding="utf-8") as infile:
        data = json.load(infile)["data"]
    out = FixtureWriter(f"symspellpy/{name}.tsv", __doc__)
    for entry in data:
        for dictionary in ("bigram", "unigram"):
            expected = entry[dictionary]
            out.write(
                "F",
                entry["typo"],
                dictionary,
                expected.get("num_results", ""),
                expected["term"],
                expected.get("distance", ""),
                expected.get("count", ""),
            )
            for key, value in expected.get("replacement", {}).items():
                out.write("r", key, value)
    out.close()


def convert_segmentation() -> None:
    with open(SRC / "word_segmentation_data.json", encoding="utf-8") as infile:
        data = json.load(infile)["data"]
    out = FixtureWriter("symspellpy/word_segmentation_data.tsv", __doc__)
    for entry in data:
        for key, value in entry.items():
            if key != "typo":
                out.write("F", entry["typo"], key, value["term"])
    out.close()


def main() -> None:
    for name in [
        "lookup_compound_data",
        "lookup_compound_ignore_non_words_data",
        "lookup_compound_replaced_words_data",
        "lookup_compound_transfer_casing_data",
        "lookup_compound_transfer_casing_ignore_nonwords_data",
    ]:
        convert_compound(name)
    convert_segmentation()


if __name__ == "__main__":
    main()
