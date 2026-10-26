"""A small spell-checking command-line tool built on symspell.

Build it with `pixi run cli`, which writes `build/symspell`. Then:

    symspell build DICT -o INDEX [--bigrams FILE] [--max-distance N]
                                 [--prefix-length N] [--count-threshold N]
    symspell check FILE    [--index INDEX | --dict DICT] [--max-distance N]
    symspell lookup WORD.. [--index INDEX | --dict DICT] [--max-distance N]
    symspell correct TEXT  [--index INDEX | --dict DICT] [--max-distance N]
    symspell segment TEXT  [--index INDEX | --dict DICT] [--max-distance N]

`check` prints one line per unknown word, "file:line:column: word -> fix",
and exits with status 1 if it found any. Without `--index` or `--dict`, the
English dictionary in `data/` is used.
"""

from std.sys import argv, exit

from symspell import SymSpell, SymSpellBuilder, SymSpellConfig, Verbosity
from symspell.text import is_alnum, is_digit, lower_string, to_string

comptime DEFAULT_DICT = "data/frequency_dictionary_en_82_765.txt"
comptime DEFAULT_BIGRAMS = "data/frequency_bigramdictionary_en_243_342.txt"
comptime USAGE = """usage:
  symspell build DICT -o INDEX [--bigrams FILE] [--max-distance N]
                               [--prefix-length N] [--count-threshold N]
  symspell check FILE    [--index INDEX | --dict DICT] [--max-distance N]
  symspell lookup WORD.. [--index INDEX | --dict DICT] [--max-distance N]
  symspell correct TEXT  [--index INDEX | --dict DICT] [--max-distance N]
  symspell segment TEXT  [--index INDEX | --dict DICT] [--max-distance N]"""


struct Options(Movable):
    """The parsed command line."""

    var command: String
    var positional: List[String]
    var output: String
    var index: String
    var dictionary: String
    var bigrams: String
    var max_distance: Int
    var prefix_length: Int
    var count_threshold: Int

    def __init__(out self, args: List[String]) raises:
        if len(args) < 2:
            raise Error("missing command")
        self.command = args[1]
        self.positional = List[String]()
        self.output = String()
        self.index = String()
        self.dictionary = String()
        self.bigrams = String()
        self.max_distance = 2
        self.prefix_length = 7
        self.count_threshold = 1
        var i = 2
        while i < len(args):
            var arg = args[i]
            if not arg.startswith("-"):
                self.positional.append(arg)
                i += 1
                continue
            if i + 1 >= len(args):
                raise Error("missing value for ", arg)
            var value = args[i + 1]
            if arg == "-o" or arg == "--output":
                self.output = value
            elif arg == "--index":
                self.index = value
            elif arg == "--dict":
                self.dictionary = value
            elif arg == "--bigrams":
                self.bigrams = value
            elif arg == "--max-distance":
                self.max_distance = Int(value)
            elif arg == "--prefix-length":
                self.prefix_length = Int(value)
            elif arg == "--count-threshold":
                self.count_threshold = Int(value)
            else:
                raise Error("unknown option ", arg)
            i += 2

    def config(self) -> SymSpellConfig:
        return SymSpellConfig(
            self.max_distance, self.prefix_length, self.count_threshold
        )


def build_from_text(options: Options) raises -> SymSpell:
    """Builds an index from the dictionary text files named in `options`."""
    var builder = SymSpellBuilder(options.config())
    if options.dictionary:
        builder.load_dictionary(options.dictionary)
        if options.bigrams:
            builder.load_bigram_dictionary(options.bigrams)
    else:
        builder.load_dictionary(DEFAULT_DICT)
        builder.load_bigram_dictionary(DEFAULT_BIGRAMS)
    return builder^.build()


def load_index(options: Options) raises -> SymSpell:
    if options.index:
        return SymSpell.open(options.index)
    return build_from_text(options)


def run_build(options: Options) raises:
    if len(options.positional) != 1 or not options.output:
        raise Error("build needs one dictionary file and -o INDEX")
    var builder = SymSpellBuilder(options.config())
    builder.load_dictionary(options.positional[0])
    if options.bigrams:
        builder.load_bigram_dictionary(options.bigrams)
    var index = builder^.build()
    index.save(options.output)
    print(
        "wrote",
        options.output,
        "with",
        index.word_count(),
        "words and",
        index.bigram_size(),
        "bigrams",
    )


def is_word_part(cp: UInt32) -> Bool:
    return is_alnum(cp) or cp == 0x27 or cp == 0x2019  # ' and ’


def check_word(
    index: SymSpell,
    options: Options,
    path: String,
    line_number: Int,
    column: Int,
    word: List[UInt32],
) raises -> Bool:
    """Prints a report and returns True if `word` is misspelled."""
    var text = to_string(word)
    for cp in word:
        if is_digit(cp):
            return False  # numbers and codes are not checked
    if index.contains(lower_string(text)):
        return False
    var found = index.lookup(
        text,
        Verbosity.TOP,
        options.max_distance,
        transfer_casing=True,
    )
    var fix = found[0].term if found else String("?")
    print(String(path, ":", line_number, ":", column, ": ", text, " -> ", fix))
    return True


def run_check(options: Options) raises -> Bool:
    """Checks every word of each file. Returns True if all are known."""
    if not options.positional:
        raise Error("check needs at least one file")
    var index = load_index(options)
    var clean = True
    for path in options.positional:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var line_number = 0
        for line in text.splitlines():
            line_number += 1
            var word = List[UInt32]()
            var column = 0
            var start = 0
            for c in line.codepoints():
                column += 1
                if is_word_part(c.to_u32()):
                    if not word:
                        start = column
                    word.append(c.to_u32())
                elif word:
                    if check_word(
                        index, options, path, line_number, start, word
                    ):
                        clean = False
                    word.clear()
            if word:
                if check_word(index, options, path, line_number, start, word):
                    clean = False
    return clean


def run_lookup(options: Options) raises:
    var index = load_index(options)
    for word in options.positional:
        var found = index.lookup(
            word,
            Verbosity.CLOSEST,
            options.max_distance,
            include_unknown=True,
        )
        for suggestion in found:
            print(word, "->", suggestion)


def joined(words: List[String]) -> String:
    var text = String()
    for i in range(len(words)):
        if i > 0:
            text += " "
        text += words[i]
    return text^


def run_correct(options: Options) raises:
    var index = load_index(options)
    var result = index.lookup_compound(
        joined(options.positional), options.max_distance
    )
    print(result[0].term)


def run_segment(options: Options) raises:
    var index = load_index(options)
    var result = index.word_segmentation(
        joined(options.positional), options.max_distance
    )
    print(result.corrected_string)


def main():
    var args = List[String]()
    for arg in argv():
        args.append(String(arg))
    try:
        var options = Options(args)
        if options.command == "build":
            run_build(options)
        elif options.command == "check":
            if not run_check(options):
                exit(1)
        elif options.command == "lookup":
            run_lookup(options)
        elif options.command == "correct":
            run_correct(options)
        elif options.command == "segment":
            run_segment(options)
        elif options.command == "-h" or options.command == "--help":
            print(USAGE)
        else:
            raise Error("unknown command ", options.command)
    except e:
        print("error:", e)
        print(USAGE)
        exit(2)
