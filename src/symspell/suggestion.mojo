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


def suggestion_with_probability(term: String, distance: Int) -> Suggestion:
    """Port of symspellpy `SuggestItem.create_with_probability`.

    The count estimates `10 // 10 ** len(term)`: 10 for an empty term, 1 for
    one codepoint, 0 otherwise.
    """
    var length = term.count_codepoints()
    var count = 10 if length == 0 else (1 if length == 1 else 0)
    return Suggestion(term, distance, count)


@fieldwise_init
struct Composition(Copyable, Movable, Writable):
    """A `word_segmentation` result.

    - `segmented_string`: the input with spaces inserted.
    - `corrected_string`: the segmented input with spelling corrected.
    - `distance_sum`: edit distance between the input and `corrected_string`.
    - `log_prob_sum`: sum of the words' log10 probabilities (higher is more likely).
    """

    var segmented_string: String
    var corrected_string: String
    var distance_sum: Int
    var log_prob_sum: Float64

    def __init__(out self):
        self.segmented_string = String()
        self.corrected_string = String()
        self.distance_sum = 0
        self.log_prob_sum = 0.0

    def extended(
        self,
        segmented: StringSlice,
        corrected: StringSlice,
        distance: Int,
        log_prob: Float64,
    ) -> Composition:
        """Port of symspellpy `Composition.create`: adds one part."""
        return Composition(
            String(self.segmented_string, segmented),
            String(self.corrected_string, corrected),
            self.distance_sum + distance,
            self.log_prob_sum + log_prob,
        )
