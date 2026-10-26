"""Reader for the TSV reference fixtures (docs/DECISIONS.md, D8).

One record per line, fields separated by TAB. Backslash, TAB, LF and CR are
escaped as \\\\, \\t, \\n and \\r. Lines starting with '#' are comments.
"""

comptime FIXTURES = "tests/fixtures/"


def unescape(field: StringSlice) -> String:
    """Undoes the fixture escaping of one field."""
    if "\\" not in field:
        return String(field)
    var out = String()
    var escaped = False
    for c in field.codepoint_slices():
        if escaped:
            if c == "t":
                out += "\t"
            elif c == "n":
                out += "\n"
            elif c == "r":
                out += "\r"
            else:
                out += c
            escaped = False
        elif c == "\\":
            escaped = True
        else:
            out += c
    return out^


def read_records(name: StringSlice) raises -> List[List[String]]:
    """Reads all records of a fixture file under tests/fixtures/."""
    var path = String(FIXTURES, name)
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except e:
        raise Error(
            t"cannot read fixture {path} ({e}). Run `pixi run fixtures` first."
        )
    var records = List[List[String]]()
    for line in text.split("\n"):
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var fields = List[String]()
        for field in line.split("\t"):
            fields.append(unescape(field))
        records.append(fields^)
    return records^


def to_int(field: String) raises -> Int:
    return Int(field)


def to_bool(field: String) raises -> Bool:
    return field == "1"


def show(text: StringSlice) -> String:
    """Returns `text` with escapes, for readable failure messages."""
    var out = String("'")
    for c in text.codepoint_slices():
        if c == "\t":
            out += "\\t"
        elif c == "\n":
            out += "\\n"
        elif c == "\r":
            out += "\\r"
        else:
            out += c
    out += "'"
    return out^
