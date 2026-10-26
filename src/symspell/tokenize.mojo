"""Word parsing and number parsing, matching symspellpy's regexes and Python `int()`.

See docs/BEHAVIOR.md, sections 2.4, 2.6 and 7.
"""

from symspell.text import (
    decimal_value,
    is_alnum,
    is_digit,
    is_space,
    is_word_char,
    lower,
    to_codepoints,
    to_string,
)

comptime _APOSTROPHE: UInt32 = 0x27
comptime _RIGHT_QUOTE: UInt32 = 0x2019
comptime _INT64_MAX: UInt64 = 0x7FFFFFFFFFFFFFFF


def _is_apostrophe(cp: UInt32) -> Bool:
    return cp == _APOSTROPHE or cp == _RIGHT_QUOTE


def _lowered(text: StringSlice) -> List[UInt32]:
    var cps = to_codepoints(text)
    var out = List[UInt32](capacity=len(cps))
    lower(cps, out)
    return out^


def split_whitespace(text: ImmSpan[UInt32, _]) -> List[String]:
    """Python `str.split()`: splits on runs of Unicode whitespace."""
    var words = List[String]()
    var start = -1
    for i in range(len(text)):
        if is_space(text[i]):
            if start >= 0:
                words.append(to_string(text[start:i]))
                start = -1
        elif start < 0:
            start = i
    if start >= 0:
        words.append(to_string(text[start:]))
    return words^


def parse_words(
    phrase: StringSlice,
    preserve_case: Bool = False,
    split_by_space: Bool = False,
) -> List[String]:
    """Port of symspellpy `helpers.parse_words`.

    Without `split_by_space` this is `re.findall(r"([^\\W_]+['’]*[^\\W_]*)", ...)`:
    a run of alphanumerics, then apostrophes, then alphanumerics again.
    Lowercases first unless `preserve_case`.
    """
    var text = to_codepoints(phrase) if preserve_case else _lowered(phrase)
    if split_by_space:
        return split_whitespace(text)
    var words = List[String]()
    var i = 0
    var n = len(text)
    while i < n:
        if not is_alnum(text[i]):
            i += 1
            continue
        var start = i
        while i < n and is_alnum(text[i]):
            i += 1
        while i < n and _is_apostrophe(text[i]):
            i += 1
        while i < n and is_alnum(text[i]):
            i += 1
        words.append(to_string(text[start:i]))
    return words^


def parse_corpus_words(text: StringSlice) -> List[String]:
    """Port of symspellpy `SymSpell._parse_words`, used by `create_dictionary`.

    `re.findall(r"(([^\\W_]|['’])+)", text.lower())`: maximal runs of
    alphanumerics and apostrophes.
    """
    var cps = _lowered(text)
    var words = List[String]()
    var start = -1
    for i in range(len(cps)):
        var in_word = is_alnum(cps[i]) or _is_apostrophe(cps[i])
        if in_word and start < 0:
            start = i
        elif not in_word and start >= 0:
            words.append(to_string(cps[start:i]))
            start = -1
    if start >= 0:
        words.append(to_string(cps[start:]))
    return words^


def is_acronym(word: StringSlice, contain_digits: Bool = False) -> Bool:
    """Port of symspellpy `helpers.is_acronym`.

    `re.match(r"\\b[A-Z0-9]{2,}\\b", word)`: the leading run of ASCII capitals
    and digits has length >= 2 and ends at a word boundary. Or, if
    `contain_digits`, any codepoint is a digit (`str.isdigit`).
    """
    var cps = to_codepoints(word)
    var run = 0
    while run < len(cps) and (
        (cps[run] >= 0x41 and cps[run] <= 0x5A)
        or (cps[run] >= 0x30 and cps[run] <= 0x39)
    ):
        run += 1
    if run >= 2 and (run == len(cps) or not is_word_char(cps[run])):
        return True
    if contain_digits:
        for cp in cps:
            if is_digit(cp):
                return True
    return False


def try_parse_int64(text: StringSlice) -> Optional[Int]:
    """Port of symspellpy `helpers.try_parse_int64`: Python `int(text)` limited to 64 bits.

    Accepts surrounding Unicode whitespace, an optional sign, Unicode decimal
    digits and single underscores between digits. Returns None otherwise.
    """
    var cps = to_codepoints(text)
    var start = 0
    var end = len(cps)
    while start < end and is_space(cps[start]):
        start += 1
    while end > start and is_space(cps[end - 1]):
        end -= 1
    var negative = False
    if start < end and (cps[start] == 0x2B or cps[start] == 0x2D):
        negative = cps[start] == 0x2D
        start += 1
    if start == end:
        return None
    # The magnitude may reach 2**63 for a negative number.
    var limit = _INT64_MAX + 1 if negative else _INT64_MAX
    var value: UInt64 = 0
    var previous_digit = False
    for i in range(start, end):
        if cps[i] == 0x5F:
            if not previous_digit or i + 1 == end:
                return None
            previous_digit = False
            continue
        var digit = decimal_value(cps[i])
        if digit < 0:
            return None
        if value > (limit - UInt64(digit)) // 10:
            return None
        value = value * 10 + UInt64(digit)
        previous_digit = True
    if negative and value > 0:
        return -Int(value - 1) - 1
    return Int(value)
