"""Case transfer, matching symspellpy `helpers.case_transfer_*`.

`case_transfer_similar` depends on the exact opcodes of Python's
`difflib.SequenceMatcher`, so this module ports it (with `isjunk=None` and
`autojunk=True`, as symspellpy uses it). See docs/BEHAVIOR.md, section 6.
"""

from symspell.text import is_upper, lower, to_codepoints, to_string, upper

comptime OP_REPLACE = 0
comptime OP_DELETE = 1
comptime OP_INSERT = 2
comptime OP_EQUAL = 3


@fieldwise_init
struct Opcode(Equatable, ImplicitlyCopyable, Writable):
    """One `difflib` opcode: turn `a[i1:i2]` into `b[j1:j2]`."""

    var tag: Int
    var i1: Int
    var i2: Int
    var j1: Int
    var j2: Int


@fieldwise_init
struct _Block(ImplicitlyCopyable):
    var i: Int
    var j: Int
    var size: Int

    def precedes(self, other: Self) -> Bool:
        if self.i != other.i:
            return self.i < other.i
        if self.j != other.j:
            return self.j < other.j
        return self.size < other.size


@fieldwise_init
struct _Range(ImplicitlyCopyable):
    var alo: Int
    var ahi: Int
    var blo: Int
    var bhi: Int


struct _Matcher:
    """A port of `difflib.SequenceMatcher` for codepoint sequences."""

    var a: List[UInt32]
    var b: List[UInt32]
    var b2j: Dict[UInt32, List[Int]]

    def __init__(out self, var a: List[UInt32], var b: List[UInt32]):
        self.a = a^
        self.b = b^
        self.b2j = Dict[UInt32, List[Int]]()
        for j in range(len(self.b)):
            var cp = self.b[j]
            if cp not in self.b2j:
                self.b2j[cp] = List[Int]()
            try:
                self.b2j[cp].append(j)
            except:
                pass
        # autojunk: drop "popular" elements of long sequences. They are not
        # junk (isbjunk stays false), they just cannot start a match.
        var n = len(self.b)
        if n >= 200:
            var ntest = n // 100 + 1
            var popular = List[UInt32]()
            for entry in self.b2j.items():
                if len(entry.value) > ntest:
                    popular.append(entry.key)
            for cp in popular:
                try:
                    _ = self.b2j.pop(cp)
                except:
                    pass

    def longest_match(self, alo: Int, ahi: Int, blo: Int, bhi: Int) -> _Block:
        var best_i = alo
        var best_j = blo
        var best_size = 0
        # Matches ending at row i-1: j -> length, as two sorted lists.
        var prev_j = List[Int]()
        var prev_len = List[Int]()
        var next_j = List[Int]()
        var next_len = List[Int]()
        for i in range(alo, ahi):
            next_j.clear()
            next_len.clear()
            var indices = self.b2j.get(self.a[i])
            if indices:
                var p = 0
                for j in indices.value():
                    if j < blo:
                        continue
                    if j >= bhi:
                        break
                    while p < len(prev_j) and prev_j[p] < j - 1:
                        p += 1
                    var k = 1
                    if p < len(prev_j) and prev_j[p] == j - 1:
                        k = prev_len[p] + 1
                    next_j.append(j)
                    next_len.append(k)
                    if k > best_size:
                        best_i = i - k + 1
                        best_j = j - k + 1
                        best_size = k
            swap(prev_j, next_j)
            swap(prev_len, next_len)
        while (
            best_i > alo
            and best_j > blo
            and self.a[best_i - 1] == self.b[best_j - 1]
        ):
            best_i -= 1
            best_j -= 1
            best_size += 1
        while (
            best_i + best_size < ahi
            and best_j + best_size < bhi
            and self.a[best_i + best_size] == self.b[best_j + best_size]
        ):
            best_size += 1
        return _Block(best_i, best_j, best_size)

    def matching_blocks(self) -> List[_Block]:
        var queue: List[_Range] = [_Range(0, len(self.a), 0, len(self.b))]
        var blocks = List[_Block]()
        while queue:
            var r = queue.pop()
            var m = self.longest_match(r.alo, r.ahi, r.blo, r.bhi)
            if m.size == 0:
                continue
            blocks.append(m)
            if r.alo < m.i and r.blo < m.j:
                queue.append(_Range(r.alo, m.i, r.blo, m.j))
            if m.i + m.size < r.ahi and m.j + m.size < r.bhi:
                queue.append(_Range(m.i + m.size, r.ahi, m.j + m.size, r.bhi))
        # Insertion sort: block lists are short.
        for k in range(1, len(blocks)):
            var item = blocks[k]
            var pos = k
            while pos > 0 and item.precedes(blocks[pos - 1]):
                blocks[pos] = blocks[pos - 1]
                pos -= 1
            blocks[pos] = item
        # Merge adjacent blocks.
        var merged = List[_Block]()
        var i1 = 0
        var j1 = 0
        var k1 = 0
        for block in blocks:
            if i1 + k1 == block.i and j1 + k1 == block.j:
                k1 += block.size
            else:
                if k1:
                    merged.append(_Block(i1, j1, k1))
                i1 = block.i
                j1 = block.j
                k1 = block.size
        if k1:
            merged.append(_Block(i1, j1, k1))
        merged.append(_Block(len(self.a), len(self.b), 0))
        return merged^

    def opcodes(self) -> List[Opcode]:
        var answer = List[Opcode]()
        var i = 0
        var j = 0
        for block in self.matching_blocks():
            var tag = -1
            if i < block.i and j < block.j:
                tag = OP_REPLACE
            elif i < block.i:
                tag = OP_DELETE
            elif j < block.j:
                tag = OP_INSERT
            if tag >= 0:
                answer.append(Opcode(tag, i, block.i, j, block.j))
            i = block.i + block.size
            j = block.j + block.size
            if block.size:
                answer.append(Opcode(OP_EQUAL, block.i, i, block.j, j))
        return answer^


def get_opcodes(var a: List[UInt32], var b: List[UInt32]) -> List[Opcode]:
    """`difflib.SequenceMatcher(a=a, b=b).get_opcodes()` on codepoints."""
    return _Matcher(a^, b^).opcodes()


def _index_error() -> Error:
    return Error("IndexError: string index out of range")


def _append_cased(cp: UInt32, make_upper: Bool, mut out: List[UInt32]):
    """Appends `cp.upper()` or `cp.lower()` (of the one-codepoint string)."""
    var one = [cp]
    if make_upper:
        upper(one, out)
    else:
        lower(one, out)


def _clamped(
    text: ImmSpan[UInt32, _], start: Int, end: Int
) -> ImmSpan[UInt32, text.origin]:
    """Python slice `text[start:end]` for non-negative bounds."""
    var lo = min(start, len(text))
    var hi = min(max(end, lo), len(text))
    return text[lo:hi]


def case_transfer_matching(
    cased: StringSlice, uncased: StringSlice
) raises -> String:
    """Port of symspellpy `helpers.case_transfer_matching`.

    Raises if the texts have different lengths (in codepoints).
    """
    var cased_cps = to_codepoints(cased)
    var uncased_cps = to_codepoints(uncased)
    if len(cased_cps) != len(uncased_cps):
        raise Error(
            "'cased_text' and 'uncased_text' don't have the same length, use"
            " case_transfer_similar() instead"
        )
    var out = List[UInt32](capacity=len(uncased_cps))
    for i in range(len(cased_cps)):
        _append_cased(uncased_cps[i], is_upper(cased_cps[i]), out)
    return to_string(out)


def case_transfer_similar(
    cased: StringSlice, uncased: StringSlice
) raises -> String:
    """Port of symspellpy `helpers.case_transfer_similar`.

    Returns `uncased` with the casing of `cased`, using difflib opcodes to align
    the two texts. Raises if `cased` is empty and `uncased` is not.
    """
    if uncased.byte_length() == 0:
        return String(uncased)
    if cased.byte_length() == 0:
        raise Error("'cased_text' cannot be empty")
    var cased_cps = to_codepoints(cased)
    var uncased_cps = to_codepoints(uncased)
    var lowered = List[UInt32](capacity=len(cased_cps))
    lower(cased_cps, lowered)
    var out = List[UInt32](capacity=len(uncased_cps))
    for op in get_opcodes(lowered^, uncased_cps.copy()):
        if op.tag == OP_DELETE:
            continue
        if op.tag == OP_INSERT:
            # Take the casing of the previous codepoint, or of the next one
            # at the start or after a space. Indices come from the lowercased
            # text but index the original, as in Python.
            var ia_ref = op.i1
            if op.i1 != 0:
                if op.i1 - 1 >= len(cased_cps):
                    raise _index_error()
                if cased_cps[op.i1 - 1] != 0x20:
                    ia_ref = op.i1 - 1
            if ia_ref >= len(cased_cps):
                raise _index_error()
            var piece = uncased_cps[op.j1 : op.j2]
            if is_upper(cased_cps[ia_ref]):
                upper(piece, out)
            else:
                lower(piece, out)
        elif op.tag == OP_EQUAL:
            out.extend(_clamped(cased_cps, op.i1, op.i2))
        else:
            var cased_seq = _clamped(cased_cps, op.i1, op.i2)
            var uncased_seq = uncased_cps[op.j1 : op.j2]
            var pairs = min(len(cased_seq), len(uncased_seq))
            for k in range(pairs):
                _append_cased(uncased_seq[k], is_upper(cased_seq[k]), out)
            if len(cased_seq) < len(uncased_seq):
                if len(cased_seq) == 0:
                    raise _index_error()
                var make_upper = is_upper(cased_seq[len(cased_seq) - 1])
                for k in range(len(cased_seq), len(uncased_seq)):
                    _append_cased(uncased_seq[k], make_upper, out)
    return to_string(out)
