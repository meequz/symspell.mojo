"""How many suggestions a lookup returns."""


@fieldwise_init
struct Verbosity(Equatable, ImplicitlyCopyable, Writable):
    """Controls the closeness and quantity of returned suggestions."""

    var value: Int

    comptime TOP = Verbosity(0)
    """The suggestion with the highest count among those of smallest distance."""
    comptime CLOSEST = Verbosity(1)
    """All suggestions of the smallest distance, by count."""
    comptime ALL = Verbosity(2)
    """All suggestions within the maximum distance, by distance then count."""

    def write_to(self, mut writer: Some[Writer]):
        if self == Self.TOP:
            writer.write("TOP")
        elif self == Self.CLOSEST:
            writer.write("CLOSEST")
        else:
            writer.write("ALL")
