"""Index configuration, validated like symspellpy's `SymSpell.__init__`."""


@fieldwise_init
struct DistanceAlgorithm(Equatable, ImplicitlyCopyable, Writable):
    """The edit distance used to verify candidates."""

    var value: Int

    comptime DAMERAU_OSA = DistanceAlgorithm(0)
    """Damerau-Levenshtein, optimal string alignment (symspellpy's default)."""
    comptime LEVENSHTEIN = DistanceAlgorithm(1)
    """Levenshtein: no transpositions."""

    def write_to(self, mut writer: Some[Writer]):
        if self == Self.DAMERAU_OSA:
            writer.write("DAMERAU_OSA")
        else:
            writer.write("LEVENSHTEIN")


struct SymSpellConfig(Equatable, ImplicitlyCopyable, Writable):
    """Parameters fixed when a dictionary is built.

    - `max_dictionary_edit_distance`: the largest edit distance a lookup may use.
    - `prefix_length`: only this many leading codepoints of each term are indexed.
    - `count_threshold`: terms with a smaller total count are not correct spellings.
    - `distance_algorithm`: how candidate distances are computed.
    """

    var max_dictionary_edit_distance: Int
    var prefix_length: Int
    var count_threshold: Int
    var distance_algorithm: DistanceAlgorithm

    def __init__(
        out self,
        max_dictionary_edit_distance: Int = 2,
        prefix_length: Int = 7,
        count_threshold: Int = 1,
        distance_algorithm: DistanceAlgorithm = DistanceAlgorithm.DAMERAU_OSA,
    ):
        self.max_dictionary_edit_distance = max_dictionary_edit_distance
        self.prefix_length = prefix_length
        self.count_threshold = count_threshold
        self.distance_algorithm = distance_algorithm

    def validate(self) raises:
        """Raises with symspellpy's message if a value is invalid."""
        if self.max_dictionary_edit_distance < 0:
            raise Error("max_dictionary_edit_distance cannot be negative")
        if self.prefix_length < 1:
            raise Error("prefix_length cannot be less than 1")
        if self.prefix_length <= self.max_dictionary_edit_distance:
            raise Error(
                "prefix_length must be greater than"
                " max_dictionary_edit_distance"
            )
        if self.count_threshold < 0:
            raise Error("count_threshold cannot be negative")
