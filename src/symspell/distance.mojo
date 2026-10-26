"""Edit distance algorithms on codepoint sequences.

Both algorithms are bounded: they return the exact distance when it is at most
`max_distance`, and -1 otherwise. They trim the common prefix and suffix and,
when `max_distance` is small, only fill a diagonal band of the DP matrix.
This follows symspellpy's `editdistance.py` (from SoftWx.Match), including its
special cases (docs/BEHAVIOR.md, section 3).

A comparer keeps its work buffers between calls, so use one per thread.
"""

comptime _MAX_INT32 = 2**31 - 1


trait DistanceComparer(Copyable, Defaultable, Deinitable, Movable):
    """Computes a bounded edit distance between two codepoint sequences."""

    def distance(
        mut self,
        a: ImmSpan[UInt32, _],
        b: ImmSpan[UInt32, _],
        max_distance: Int,
    ) -> Int:
        """Returns the distance if it is <= `max_distance`, otherwise -1."""
        ...


@fieldwise_init
struct _Trimmed(ImplicitlyCopyable):
    """Lengths and start of two sequences after removing common affixes."""

    var len_1: Int
    var len_2: Int
    var start: Int


def _prefix_suffix_prep(
    a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _]
) -> _Trimmed:
    """symspellpy `helpers.prefix_suffix_prep`. Expects `len(a) <= len(b)`."""
    var len_1 = len(a)
    var len_2 = len(b)
    while len_1 != 0 and a[len_1 - 1] == b[len_2 - 1]:
        len_1 -= 1
        len_2 -= 1
    var start = 0
    while start != len_1 and a[start] == b[start]:
        start += 1
    return _Trimmed(len_1 - start, len_2 - start, start)


def _equal(a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _grow(mut buffer: List[Int], size: Int):
    if len(buffer) < size:
        buffer.resize(size, 0)


struct DamerauOsa(DistanceComparer):
    """Damerau-Levenshtein distance, optimal string alignment variant.

    Insertions, deletions, substitutions and transpositions of two adjacent
    codepoints cost 1; no substring is edited twice. This is symspellpy's
    default algorithm.
    """

    var _costs: List[Int]
    var _prev_costs: List[Int]

    def __init__(out self):
        self._costs = List[Int]()
        self._prev_costs = List[Int]()

    def distance(
        mut self,
        a: ImmSpan[UInt32, _],
        b: ImmSpan[UInt32, _],
        max_distance: Int,
    ) -> Int:
        if max_distance <= 0:
            return 0 if _equal(a, b) else -1
        var max_d = min(max_distance, _MAX_INT32)
        if len(a) > len(b):
            return self._run(b, a, max_d)
        return self._run(a, b, max_d)

    def _run(
        mut self, a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _], max_d: Int
    ) -> Int:
        if len(b) - len(a) > max_d:
            return -1
        var t = _prefix_suffix_prep(a, b)
        if t.len_1 == 0:
            return t.len_2 if t.len_2 <= max_d else -1
        _grow(self._costs, t.len_2)
        _grow(self._prev_costs, t.len_2)
        var s1 = a[t.start : t.start + t.len_1]
        var s2 = b[t.start : t.start + t.len_2]
        if max_d < t.len_2:
            return self._distance_max(s1, s2, max_d)
        return self._distance(s1, s2)

    def _distance(
        mut self, s1: ImmSpan[UInt32, _], s2: ImmSpan[UInt32, _]
    ) -> Int:
        var len_1 = len(s1)
        var len_2 = len(s2)
        var costs = Span(self._costs)
        var prev_costs = Span(self._prev_costs)
        for j in range(len_2):
            costs[j] = j + 1
        var char_1: UInt32 = 0x20
        var current_cost = 0
        for i in range(len_1):
            var prev_char_1 = char_1
            char_1 = s1[i]
            var char_2: UInt32 = 0x20
            var left_cost = i
            var above_cost = i
            var next_trans_cost = 0
            for j in range(len_2):
                var this_trans_cost = next_trans_cost
                next_trans_cost = prev_costs[j]
                current_cost = left_cost
                prev_costs[j] = current_cost
                left_cost = costs[j]
                var prev_char_2 = char_2
                char_2 = s2[j]
                if char_1 != char_2:
                    if above_cost < current_cost:
                        current_cost = above_cost
                    if left_cost < current_cost:
                        current_cost = left_cost
                    current_cost += 1
                    if (
                        i != 0
                        and j != 0
                        and char_1 == prev_char_2
                        and prev_char_1 == char_2
                        and this_trans_cost + 1 < current_cost
                    ):
                        current_cost = this_trans_cost + 1
                costs[j] = current_cost
                above_cost = current_cost
        return current_cost

    def _distance_max(
        mut self, s1: ImmSpan[UInt32, _], s2: ImmSpan[UInt32, _], max_d: Int
    ) -> Int:
        var len_1 = len(s1)
        var len_2 = len(s2)
        var costs = Span(self._costs)
        var prev_costs = Span(self._prev_costs)
        for j in range(len_2):
            costs[j] = j + 1 if j < max_d else max_d + 1
        var len_diff = len_2 - len_1
        var j_start_offset = max_d - len_diff
        var j_start = 0
        var j_end = max_d
        var char_1: UInt32 = 0x20
        var current_cost = 0
        for i in range(len_1):
            var prev_char_1 = char_1
            char_1 = s1[i]
            var char_2: UInt32 = 0x20
            var left_cost = i
            var above_cost = i
            var next_trans_cost = 0
            if i > j_start_offset:
                j_start += 1
            if j_end < len_2:
                j_end += 1
            for j in range(j_start, j_end):
                var this_trans_cost = next_trans_cost
                next_trans_cost = prev_costs[j]
                current_cost = left_cost
                prev_costs[j] = current_cost
                left_cost = costs[j]
                var prev_char_2 = char_2
                char_2 = s2[j]
                if char_1 != char_2:
                    if above_cost < current_cost:
                        current_cost = above_cost
                    if left_cost < current_cost:
                        current_cost = left_cost
                    current_cost += 1
                    if (
                        i != 0
                        and j != 0
                        and char_1 == prev_char_2
                        and prev_char_1 == char_2
                        and this_trans_cost + 1 < current_cost
                    ):
                        current_cost = this_trans_cost + 1
                costs[j] = current_cost
                above_cost = current_cost
            if costs[i + len_diff] > max_d:
                return -1
        return current_cost if current_cost <= max_d else -1


struct Levenshtein(DistanceComparer):
    """Levenshtein distance: insertions, deletions and substitutions cost 1."""

    var _costs: List[Int]

    def __init__(out self):
        self._costs = List[Int]()

    def distance(
        mut self,
        a: ImmSpan[UInt32, _],
        b: ImmSpan[UInt32, _],
        max_distance: Int,
    ) -> Int:
        if max_distance <= 0:
            return 0 if _equal(a, b) else -1
        var max_d = min(max_distance, _MAX_INT32)
        if len(a) > len(b):
            return self._run(b, a, max_d)
        return self._run(a, b, max_d)

    def _run(
        mut self, a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _], max_d: Int
    ) -> Int:
        if len(b) - len(a) > max_d:
            return -1
        var t = _prefix_suffix_prep(a, b)
        if t.len_1 == 0:
            return t.len_2 if t.len_2 <= max_d else -1
        _grow(self._costs, t.len_2)
        var s1 = a[t.start : t.start + t.len_1]
        var s2 = b[t.start : t.start + t.len_2]
        if max_d < t.len_2:
            return self._distance_max(s1, s2, max_d)
        return self._distance(s1, s2)

    def _distance(
        mut self, s1: ImmSpan[UInt32, _], s2: ImmSpan[UInt32, _]
    ) -> Int:
        var len_2 = len(s2)
        var costs = Span(self._costs)
        for j in range(len_2):
            costs[j] = j + 1
        var current_cost = 0
        for i in range(len(s1)):
            var left_cost = i
            var above_cost = i
            var char_1 = s1[i]
            for j in range(len_2):
                current_cost = left_cost
                left_cost = costs[j]
                if s2[j] != char_1:
                    if above_cost < current_cost:
                        current_cost = above_cost
                    if left_cost < current_cost:
                        current_cost = left_cost
                    current_cost += 1
                costs[j] = current_cost
                above_cost = current_cost
        return current_cost

    def _distance_max(
        mut self, s1: ImmSpan[UInt32, _], s2: ImmSpan[UInt32, _], max_d: Int
    ) -> Int:
        var len_1 = len(s1)
        var len_2 = len(s2)
        var costs = Span(self._costs)
        for j in range(len_2):
            costs[j] = j + 1 if j < max_d else max_d + 1
        var len_diff = len_2 - len_1
        var j_start_offset = max_d - len_diff
        var j_start = 0
        var j_end = max_d
        var current_cost = 0
        for i in range(len_1):
            var char_1 = s1[i]
            var prev_cost = i
            var above_cost = i
            if i > j_start_offset:
                j_start += 1
            if j_end < len_2:
                j_end += 1
            for j in range(j_start, j_end):
                current_cost = prev_cost
                prev_cost = costs[j]
                if s2[j] != char_1:
                    if above_cost < current_cost:
                        current_cost = above_cost
                    if prev_cost < current_cost:
                        current_cost = prev_cost
                    current_cost += 1
                costs[j] = current_cost
                above_cost = current_cost
            if costs[i + len_diff] > max_d:
                return -1
        return current_cost if current_cost <= max_d else -1
