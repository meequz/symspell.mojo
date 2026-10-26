"""Result types."""


@fieldwise_init
struct Suggestion(Copyable, Equatable, Movable, Writable):
    """A spelling suggestion: a term, its edit distance and its count.

    `count` is the term's frequency, or an estimate for combined terms in
    `lookup_compound`. Equality compares only `distance` and `count`, like
    symspellpy's `SuggestItem`.
    """

    var term: String
    var distance: Int
    var count: Int

    def __eq__(self, other: Self) -> Bool:
        return self.distance == other.distance and self.count == other.count

    def precedes(self, other: Self) -> Bool:
        """Sort order: distance ascending, then count descending."""
        if self.distance == other.distance:
            return self.count > other.count
        return self.distance < other.distance

    def write_to(self, mut writer: Some[Writer]):
        """Writes "term, distance, count", like symspellpy's `str()`."""
        writer.write(self.term, ", ", self.distance, ", ", self.count)


def sort_suggestions(mut suggestions: List[Suggestion]):
    """Stable sort by distance, then by descending count (Python `list.sort`).
    """
    for i in range(1, len(suggestions)):
        var j = i
        while j > 0 and suggestions[j].precedes(suggestions[j - 1]):
            suggestions.swap_elements(j, j - 1)
            j -= 1
