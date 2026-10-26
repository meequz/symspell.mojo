"""Codepoint helpers that match Python `str` semantics exactly.

Mojo strings are UTF-8 bytes, but symspellpy works on Python codepoints.
All lengths, slices and edits in this package are per codepoint, so text is
decoded to `List[UInt32]` first. Unicode properties and case mappings come
from tables generated from Python's `unicodedata` (docs/DECISIONS.md, D6).
"""

from std.builtin.globals import global_constant

from symspell._unicode_data import (
    CASE_MULTI,
    FLAG_ALNUM,
    FLAG_CASE_IGNORABLE,
    FLAG_CASED,
    FLAG_DECIMAL,
    FLAG_DIGIT,
    FLAG_SPACE,
    FLAG_UPPER,
    LOWER_KEYS,
    LOWER_VALUES,
    MULTI_BIT,
    PROP_FLAGS,
    PROP_STARTS,
    TITLE_KEYS,
    TITLE_VALUES,
    UPPER_KEYS,
    UPPER_VALUES,
)

comptime _SIGMA: UInt32 = 0x3A3
comptime _SMALL_SIGMA: UInt32 = 0x3C3
comptime _FINAL_SIGMA: UInt32 = 0x3C2
comptime _UNDERSCORE: UInt32 = 0x5F
comptime SPACE: UInt32 = 0x20
"""The ASCII space codepoint."""


# ===----------------------------------------------------------------------=== #
# Properties
# ===----------------------------------------------------------------------=== #


def _flags(cp: UInt32) -> UInt16:
    """Returns the property flags of a codepoint (binary search over runs)."""
    ref starts = global_constant[PROP_STARTS]()
    var lo = 0
    var hi = len(starts)
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if starts[mid] <= cp:
            lo = mid
        else:
            hi = mid
    return global_constant[PROP_FLAGS]()[lo]


def is_alnum(cp: UInt32) -> Bool:
    """Python `str.isalnum()` for one codepoint."""
    if cp < 128:
        return (
            (cp >= 0x30 and cp <= 0x39)
            or (cp >= 0x41 and cp <= 0x5A)
            or (cp >= 0x61 and cp <= 0x7A)
        )
    return (_flags(cp) & FLAG_ALNUM) != 0


def is_word_char(cp: UInt32) -> Bool:
    """Python regex `\\w` for one codepoint: alphanumeric or underscore."""
    return cp == _UNDERSCORE or is_alnum(cp)


def is_space(cp: UInt32) -> Bool:
    """Python `str.isspace()` for one codepoint."""
    if cp < 128:
        return (
            cp == SPACE
            or (cp >= 0x09 and cp <= 0x0D)
            or (cp >= 0x1C and cp <= 0x1F)
        )
    return (_flags(cp) & FLAG_SPACE) != 0


def is_upper(cp: UInt32) -> Bool:
    """Python `str.isupper()` for one codepoint."""
    if cp < 128:
        return cp >= 0x41 and cp <= 0x5A
    return (_flags(cp) & FLAG_UPPER) != 0


def is_digit(cp: UInt32) -> Bool:
    """Python `str.isdigit()` for one codepoint."""
    if cp < 128:
        return cp >= 0x30 and cp <= 0x39
    return (_flags(cp) & FLAG_DIGIT) != 0


def decimal_value(cp: UInt32) -> Int:
    """Returns the decimal digit value (Unicode category Nd), or -1."""
    if cp < 128:
        return Int(cp) - 0x30 if cp >= 0x30 and cp <= 0x39 else -1
    var flags = _flags(cp)
    if (flags & FLAG_DECIMAL) == 0:
        return -1
    return Int(flags >> 8) & 0xF


def _is_cased(cp: UInt32) -> Bool:
    return (_flags(cp) & FLAG_CASED) != 0


def _is_case_ignorable(cp: UInt32) -> Bool:
    return (_flags(cp) & FLAG_CASE_IGNORABLE) != 0


# ===----------------------------------------------------------------------=== #
# Conversion
# ===----------------------------------------------------------------------=== #


def decode(text: StringSlice, mut out: List[UInt32]):
    """Replaces the contents of `out` with the codepoints of `text`."""
    out.clear()
    for c in text.codepoints():
        out.append(c.to_u32())


def to_codepoints(text: StringSlice) -> List[UInt32]:
    """Returns the codepoints of `text`."""
    var out = List[UInt32](capacity=text.byte_length())
    decode(text, out)
    return out^


def encode(codepoints: ImmSpan[UInt32, _], mut out: String):
    """Appends the UTF-8 encoding of `codepoints` to `out`."""
    for cp in codepoints:
        out.append(Codepoint(unsafe_unchecked_codepoint=cp))


def to_string(codepoints: ImmSpan[UInt32, _]) -> String:
    """Returns the codepoints as a UTF-8 string."""
    var out = String()
    out.reserve_bytes(len(codepoints))
    encode(codepoints, out)
    return out^


# ===----------------------------------------------------------------------=== #
# Case mapping
# ===----------------------------------------------------------------------=== #


def _append_mapped(
    cp: UInt32,
    keys: Span[UInt32, ImmStaticOrigin],
    values: Span[UInt32, ImmStaticOrigin],
    mut out: List[UInt32],
):
    """Appends the mapping of `cp` from a key/value case table to `out`."""
    var lo = 0
    var hi = len(keys)
    while lo < hi:
        var mid = (lo + hi) // 2
        if keys[mid] < cp:
            lo = mid + 1
        else:
            hi = mid
    if lo == len(keys) or keys[lo] != cp:
        out.append(cp)
        return
    var value = values[lo]
    if (value & MULTI_BIT) == 0:
        out.append(value)
        return
    ref multi = global_constant[CASE_MULTI]()
    var offset = Int((value & ~MULTI_BIT) >> 8)
    for i in range(Int(value & 0xFF)):
        out.append(multi[offset + i])


def _append_lower(cp: UInt32, mut out: List[UInt32]):
    if cp < 128:
        out.append(cp + 32 if cp >= 0x41 and cp <= 0x5A else cp)
        return
    _append_mapped(
        cp,
        Span(global_constant[LOWER_KEYS]()),
        Span(global_constant[LOWER_VALUES]()),
        out,
    )


def _append_upper(cp: UInt32, mut out: List[UInt32]):
    if cp < 128:
        out.append(cp - 32 if cp >= 0x61 and cp <= 0x7A else cp)
        return
    _append_mapped(
        cp,
        Span(global_constant[UPPER_KEYS]()),
        Span(global_constant[UPPER_VALUES]()),
        out,
    )


def _append_title(cp: UInt32, mut out: List[UInt32]):
    if cp < 128:
        _append_upper(cp, out)
        return
    _append_mapped(
        cp,
        Span(global_constant[TITLE_KEYS]()),
        Span(global_constant[TITLE_VALUES]()),
        out,
    )


def _lower_sigma(text: ImmSpan[UInt32, _], i: Int) -> UInt32:
    """Lowercases the capital sigma at `text[i]` with Python's final sigma rule.

    It becomes final sigma when preceded by a cased codepoint and not followed
    by one, ignoring case-ignorable codepoints in both directions
    (CPython `handle_capital_sigma`).
    """
    var j = i - 1
    while j >= 0 and _is_case_ignorable(text[j]):
        j -= 1
    var final_sigma = j >= 0 and _is_cased(text[j])
    if final_sigma and i + 1 < len(text):
        j = i + 1
        while j < len(text) and _is_case_ignorable(text[j]):
            j += 1
        final_sigma = j == len(text) or not _is_cased(text[j])
    return _FINAL_SIGMA if final_sigma else _SMALL_SIGMA


def _append_lower_at(text: ImmSpan[UInt32, _], i: Int, mut out: List[UInt32]):
    if text[i] == _SIGMA:
        out.append(_lower_sigma(text, i))
    else:
        _append_lower(text[i], out)


def lower(text: ImmSpan[UInt32, _], mut out: List[UInt32]):
    """Appends Python `str.lower()` of `text` to `out`."""
    for i in range(len(text)):
        _append_lower_at(text, i, out)


def upper(text: ImmSpan[UInt32, _], mut out: List[UInt32]):
    """Appends Python `str.upper()` of `text` to `out`."""
    for cp in text:
        _append_upper(cp, out)


def capitalize(text: ImmSpan[UInt32, _], mut out: List[UInt32]):
    """Appends Python `str.capitalize()` of `text` to `out`.

    The first codepoint is title-cased, the rest are lowercased.
    """
    if len(text) == 0:
        return
    _append_title(text[0], out)
    for i in range(1, len(text)):
        _append_lower_at(text, i, out)


def lower_string(text: StringSlice) -> String:
    """Returns Python `str.lower()` of `text`."""
    var cps = to_codepoints(text)
    var out = List[UInt32](capacity=len(cps))
    lower(cps, out)
    return to_string(out)


def upper_string(text: StringSlice) -> String:
    """Returns Python `str.upper()` of `text`."""
    var cps = to_codepoints(text)
    var out = List[UInt32](capacity=len(cps))
    upper(cps, out)
    return to_string(out)


def capitalize_string(text: StringSlice) -> String:
    """Returns Python `str.capitalize()` of `text`."""
    var cps = to_codepoints(text)
    var out = List[UInt32](capacity=len(cps))
    capitalize(cps, out)
    return to_string(out)


def utf8_codepoint_count(data: ImmSpan[UInt8, _]) -> Int:
    """Returns the number of codepoints, or -1 if `data` is not valid UTF-8.

    Rejects overlong forms, surrogates and values above U+10FFFF, like
    Python's UTF-8 decoder.
    """
    var n = len(data)
    var i = 0
    var count = 0
    while i < n:
        var b0 = data[i]
        var extra: Int
        var lo: UInt8 = 0x80
        var hi: UInt8 = 0xBF
        if b0 < 0x80:
            extra = 0
        elif b0 >= 0xC2 and b0 <= 0xDF:
            extra = 1
        elif b0 >= 0xE0 and b0 <= 0xEF:
            extra = 2
            if b0 == 0xE0:
                lo = 0xA0  # overlong
            elif b0 == 0xED:
                hi = 0x9F  # surrogates
        elif b0 >= 0xF0 and b0 <= 0xF4:
            extra = 3
            if b0 == 0xF0:
                lo = 0x90  # overlong
            elif b0 == 0xF4:
                hi = 0x8F  # above U+10FFFF
        else:
            return -1
        if i + extra >= n and extra > 0:
            return -1
        for k in range(1, extra + 1):
            var b = data[i + k]
            if k == 1:
                if b < lo or b > hi:
                    return -1
            elif b < 0x80 or b > 0xBF:
                return -1
        i += extra + 1
        count += 1
    return count
