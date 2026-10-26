"""Build once, save the index, and open it quickly later.

Opening a saved index memory-maps the file: it takes milliseconds and the
index uses little memory. Run from the repository root: `pixi run examples`.
"""

from std.os import makedirs, remove
from std.os.path import exists

from symspell import SymSpell, SymSpellBuilder, Verbosity


def main() raises:
    if not exists("build/tmp"):
        makedirs("build/tmp")
    var path = "build/tmp/example_en.idx"

    var builder = SymSpellBuilder()
    builder.load_dictionary("data/frequency_dictionary_en_82_765.txt")
    builder^.build().save(path)

    var index = SymSpell.open(path)
    print("words:", index.word_count())
    print("contains 'members':", index.contains("members"))
    print("count of 'the':", index.count("the").value())
    print(index.lookup("acommodation", Verbosity.TOP)[0].term)
    remove(path)
