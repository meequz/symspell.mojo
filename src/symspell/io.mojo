"""Reading dictionary text files the way Python's text mode does.

Python opens symspellpy's files in text mode: `\\n`, `\\r\\n` and a lone `\\r`
all end a line, and invalid UTF-8 is an error. Lines are then cleaned with
`str.rstrip()` and split with `str.split(sep)` (docs/BEHAVIOR.md, 2.4).
"""

from std.os.path import exists

from symspell.text import is_space


def read_text(path: StringSlice, what: StringSlice) raises -> String:
    """Reads a whole UTF-8 file. `what` names the file in error messages."""
    if not exists(path):
        raise Error(t"{what} not found at {path}.")
    var data: List[UInt8]
    with open(path, "r") as f:
        data = f.read_bytes()
    try:
        return String(from_utf8=data)
    except:
        raise Error(t"UnicodeDecodeError: {path} is not valid UTF-8")


def _slice(text: StringSlice, start: Int, end: Int) -> StringSlice[text.origin]:
    """Byte slice of `text`; `start` and `end` must be codepoint boundaries."""
    return StringSlice(unsafe_from_utf8=text.as_bytes()[start:end])


def read_lines(text: StringSlice) -> List[StringSlice[text.origin]]:
    """Splits text into lines with Python's universal newlines.

    A final line break does not start an extra empty line.
    """
    var lines = List[StringSlice[text.origin]]()
    var bytes = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(bytes):
        var b = bytes[i]
        if b == 0x0A or b == 0x0D:
            lines.append(_slice(text, start, i))
            if b == 0x0D and i + 1 < len(bytes) and bytes[i + 1] == 0x0A:
                i += 1
            start = i + 1
        i += 1
    if start < len(bytes):
        lines.append(_slice(text, start, len(bytes)))
    return lines^


def rstrip_whitespace(text: StringSlice) -> StringSlice[text.origin]:
    """Python `str.rstrip()`: removes trailing Unicode whitespace."""
    var end = text.byte_length()
    for c in text.codepoint_slices_reversed():
        if not is_space(Codepoint.ord(c).to_u32()):
            break
        end -= c.byte_length()
    return _slice(text, 0, end)


def split_fields(
    text: StringSlice, separator: StringSlice
) raises -> List[StringSlice[text.origin]]:
    """Python `str.split(separator)`: keeps empty fields."""
    if separator.byte_length() == 0:
        raise Error("ValueError: empty separator")
    var parts = List[StringSlice[text.origin]]()
    var start = 0
    while True:
        var found = text.find(separator, start)
        if found < 0:
            break
        parts.append(_slice(text, start, found))
        start = found + separator.byte_length()
    parts.append(_slice(text, start, text.byte_length()))
    return parts^


def py_index(length: Int, index: Int) raises -> Int:
    """Python list indexing: negative indices count from the end."""
    var i = index + length if index < 0 else index
    if i < 0 or i >= length:
        raise Error("IndexError: list index out of range")
    return i
