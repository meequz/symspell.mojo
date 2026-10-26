"""Bit-parallel edit distances against a fixed pattern of up to 64 codepoints.

A lookup compares one phrase with many terms. Here the phrase is the pattern:
its character masks are built once (`PatternMasks.set`), and each comparison
then costs a few word operations per codepoint of the term.

- Levenshtein: Myers (1999), in Hyyrö's formulation.
- Optimal string alignment: Hyyrö (2003), which adds a transposition term.

Both give the exact distance, which is then compared with the limit, so the
results equal the bounded comparers in `distance.mojo` (docs/DECISIONS.md, D20).
"""

comptime MAX_PATTERN = 64
"""The longest pattern these functions accept, in codepoints."""

comptime _ASCII = 128


struct PatternMasks(Movable):
    """For each codepoint of the pattern: a bit mask of where it occurs."""

    var _ascii: List[UInt64]
    var _ascii_used: List[UInt32]
    var _other_cps: List[UInt32]
    var _other_masks: List[UInt64]
    var length: Int
    """Pattern length, or -1 when no usable pattern is set."""

    def __init__(out self):
        self._ascii = List[UInt64](length=_ASCII, fill=0)
        self._ascii_used = List[UInt32]()
        self._other_cps = List[UInt32]()
        self._other_masks = List[UInt64]()
        self.length = -1

    def set(mut self, pattern: ImmSpan[UInt32, _]):
        """Uses `pattern`. Leaves `length` at -1 if it is empty or too long."""
        var ascii = self._ascii.unsafe_ptr()
        for cp in self._ascii_used:
            ascii[unsafe_offset=Int(cp)] = 0
        self._ascii_used.clear()
        self._other_cps.clear()
        self._other_masks.clear()
        self.length = -1
        var n = len(pattern)
        if n == 0 or n > MAX_PATTERN:
            return
        for i in range(n):
            var cp = pattern[i]
            var bit = UInt64(1) << UInt64(i)
            if cp < _ASCII:
                if ascii[unsafe_offset=Int(cp)] == 0:
                    self._ascii_used.append(cp)
                ascii[unsafe_offset=Int(cp)] |= bit
                continue
            var found = False
            for k in range(len(self._other_cps)):
                if self._other_cps[k] == cp:
                    self._other_masks[k] |= bit
                    found = True
                    break
            if not found:
                self._other_cps.append(cp)
                self._other_masks.append(bit)
        self.length = n

    @inline(.always)
    def mask(self, cp: UInt32) -> UInt64:
        if cp < _ASCII:
            return self._ascii.unsafe_ptr()[unsafe_offset=Int(cp)]
        for k in range(len(self._other_cps)):
            if self._other_cps.unsafe_ptr()[unsafe_offset=k] == cp:
                return self._other_masks.unsafe_ptr()[unsafe_offset=k]
        return 0


def _distance[
    transpositions: Bool
](masks: PatternMasks, text: ImmSpan[UInt32, _], max_distance_in: Int) -> Int:
    var m = masks.length
    var n = len(text)
    var max_distance = max(max_distance_in, 0)  # <= 0 means "equal or not"
    if abs(m - n) > max_distance:
        return -1
    var last = UInt64(1) << UInt64(m - 1)
    var vp = ~UInt64(0)
    var vn = UInt64(0)
    var d0 = UInt64(0)
    var pm_old = UInt64(0)
    var current = m
    var p = text.unsafe_ptr()
    for j in range(n):
        var pm = masks.mask(p[unsafe_offset=j])
        comptime if transpositions:
            var tr = (((~d0) & pm) << 1) & pm_old  # uses the previous column
            d0 = (((pm & vp) + vp) ^ vp) | pm | vn | tr
            pm_old = pm
        else:
            d0 = (((pm & vp) + vp) ^ vp) | pm | vn
        var hp = vn | ~(d0 | vp)
        var hn = d0 & vp
        if hp & last:
            current += 1
        elif hn & last:
            current -= 1
        # Each remaining codepoint lowers the distance by at most one.
        if current - (n - 1 - j) > max_distance:
            return -1
        hp = (hp << 1) | 1
        vp = (hn << 1) | ~(d0 | hp)
        vn = hp & d0
    return current if current <= max_distance else -1


def osa_distance(
    masks: PatternMasks, text: ImmSpan[UInt32, _], max_distance: Int
) -> Int:
    """Optimal string alignment distance from the pattern to `text`.

    Returns the distance if it is <= `max_distance`, otherwise -1. Needs a
    pattern set (`masks.length >= 1`).
    """
    return _distance[True](masks, text, max_distance)


def levenshtein_distance(
    masks: PatternMasks, text: ImmSpan[UInt32, _], max_distance: Int
) -> Int:
    """Levenshtein distance from the pattern to `text`; see `osa_distance`."""
    return _distance[False](masks, text, max_distance)
