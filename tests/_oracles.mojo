"""Simple reference implementations used as test oracles."""


def osa_reference(a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _]) -> Int:
    """Textbook optimal string alignment distance (full DP matrix)."""
    var n = len(a)
    var m = len(b)
    var d = List[List[Int]]()
    for i in range(n + 1):
        var row = List[Int](length=m + 1, fill=0)
        row[0] = i
        d.append(row^)
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            var cost = 0 if a[i - 1] == b[j - 1] else 1
            var best = min(
                d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost
            )
            if (
                i > 1
                and j > 1
                and a[i - 1] == b[j - 2]
                and a[i - 2] == b[j - 1]
            ):
                best = min(best, d[i - 2][j - 2] + 1)
            d[i][j] = best
    return d[n][m]


def levenshtein_reference(a: ImmSpan[UInt32, _], b: ImmSpan[UInt32, _]) -> Int:
    """Textbook Levenshtein distance (two-row DP)."""
    var prev = List[Int](capacity=len(b) + 1)
    for j in range(len(b) + 1):
        prev.append(j)
    for i in range(1, len(a) + 1):
        var cur = List[Int](capacity=len(b) + 1)
        cur.append(i)
        for j in range(1, len(b) + 1):
            var cost = 0 if a[i - 1] == b[j - 1] else 1
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost))
        prev = cur^
    return prev[len(b)]


def bounded(distance: Int, max_distance: Int) -> Int:
    """What a bounded comparer must return for an exact `distance`."""
    if max_distance <= 0:
        return 0 if distance == 0 else -1
    return distance if distance <= max_distance else -1


struct Rng:
    """Small deterministic xorshift64* generator for property tests."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed * 0x9E3779B97F4A7C15 + 1

    def next(mut self) -> UInt64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        return self.state * 0x2545F4914F6CDD1D

    def below(mut self, n: Int) -> Int:
        """Returns a value in [0, n)."""
        return Int(self.next() % UInt64(n))

    def between(mut self, lo: Int, hi: Int) -> Int:
        """Returns a value in [lo, hi]."""
        return lo + self.below(hi - lo + 1)

    def codepoints(
        mut self, alphabet: ImmSpan[UInt32, _], lo: Int, hi: Int
    ) -> List[UInt32]:
        var n = self.between(lo, hi)
        var out = List[UInt32](capacity=n)
        for _ in range(n):
            out.append(alphabet[self.below(len(alphabet))])
        return out^

    def mutate(
        mut self,
        text: ImmSpan[UInt32, _],
        alphabet: ImmSpan[UInt32, _],
        edits: Int,
    ) -> List[UInt32]:
        """Applies random insertions, deletions, substitutions and transpositions.
        """
        var out = List[UInt32](text)
        for _ in range(edits):
            var op = self.below(4)
            if len(out) == 0 or op == 0:
                out.insert(
                    self.below(len(out) + 1),
                    alphabet[self.below(len(alphabet))],
                )
            elif op == 1:
                _ = out.pop(self.below(len(out)))
            elif op == 2:
                out[self.below(len(out))] = alphabet[self.below(len(alphabet))]
            elif len(out) >= 2:
                var i = self.below(len(out) - 1)
                out.swap_elements(i, i + 1)
        return out^
