"""Fast paths for many lookups: a reused scratch, and parallel batches.

Run from the repository root: `pixi run examples`.
"""

from symspell import LookupScratch, SymSpellBuilder, Verbosity


def main() raises:
    var builder = SymSpellBuilder()
    builder.load_dictionary("data/frequency_dictionary_en_82_765.txt")
    var index = builder^.build()
    var words: List[String] = ["helo", "wrold", "speling", "corection"]

    # A LookupScratch holds the working buffers. Reusing it means a lookup
    # allocates nothing besides its result. Use one scratch per thread.
    var scratch = LookupScratch()
    for word in words:
        var found = index.lookup(word, Verbosity.TOP, scratch=scratch)
        print(word, "->", found[0].term)

    # lookup_batch spreads the words over all CPU cores. The results are
    # the same as calling lookup on each word in order.
    var results = index.lookup_batch(words, Verbosity.TOP)
    for i in range(len(words)):
        print(words[i], "->", results[i][0].term)
