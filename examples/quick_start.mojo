"""Quick start: build an index from a dictionary file and correct some text.

Run from the repository root: `pixi run examples`.
"""

from symspell import SymSpellBuilder, SymSpellConfig, Verbosity


def main() raises:
    # Words up to 2 edits away can be found; the first 7 letters are indexed.
    var builder = SymSpellBuilder(
        SymSpellConfig(max_dictionary_edit_distance=2, prefix_length=7)
    )
    # "term count" lines; the bigrams ("word word count") help lookup_compound.
    builder.load_dictionary("data/frequency_dictionary_en_82_765.txt")
    builder.load_bigram_dictionary(
        "data/frequency_bigramdictionary_en_243_342.txt"
    )
    var index = builder^.build()

    # One word. CLOSEST returns every suggestion at the smallest distance.
    for suggestion in index.lookup("memebers", Verbosity.CLOSEST, 2):
        print(suggestion.term, suggestion.distance, suggestion.count)

    # Keep the input's capital letters in the suggestion.
    print(index.lookup("Helo", Verbosity.TOP, transfer_casing=True)[0].term)

    # A sentence with spelling mistakes, and wrongly split or joined words.
    var text = "whereis th elove hehad dated forImuch of thepast"
    print(index.lookup_compound(text, max_edit_distance=2)[0].term)

    # Text without spaces.
    var segmented = index.word_segmentation(
        "thequickbrownfoxjumpsoverthelazydog"
    )
    print(segmented.corrected_string)
