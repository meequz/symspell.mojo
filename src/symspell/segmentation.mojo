"""`word_segmentation`: inserts missing spaces and corrects spelling.

A port of symspellpy's `SymSpell.word_segmentation` (docs/BEHAVIOR.md,
section 9). It finds the best composition in one pass over the text, keeping
only the last `max_segmentation_word_length` candidate compositions in a ring.

Unlike symspellpy, the input is not NFKC-normalized (docs/DECISIONS.md, D7);
normalize it first if it may contain ligatures or other compatibility forms.
"""

from std.math import log10

from symspell.index import SymSpell
from symspell.scratch import LookupScratch
from symspell.suggestion import Composition
from symspell.text import (
    capitalize_string,
    is_space,
    is_upper,
    lower,
    to_codepoints,
    to_string,
)
from symspell.tokenize import TokenPredicate
from symspell.verbosity import Verbosity

comptime N = 1024908267229
comptime _HYPHEN: UInt32 = 0x2D


def _checked_log10(x: Float64) raises -> Float64:
    """Python `math.log10`, which raises instead of returning -inf or NaN."""
    if not (x > 0.0):
        raise Error("ValueError: math domain error")
    return log10(x)


def _unknown_word_log_prob(length: Int) raises -> Float64:
    """log10(10 / N / 10.0**length), raising like Python when 10.0**length overflows.
    """
    var power = Float64(10.0) ** Float64(length)  # libm pow(), as in Python
    if power - power != 0.0:  # infinity
        raise Error("OverflowError: (34, 'Numerical result out of range')")
    return _checked_log10(10.0 / Float64(N) / power)


def _is_ascii_punctuation(text: List[UInt32]) -> Bool:
    if len(text) != 1:
        return False
    var c = text[0]
    return (
        (c >= 0x21 and c <= 0x2F)
        or (c >= 0x3A and c <= 0x40)
        or (c >= 0x5B and c <= 0x60)
        or (c >= 0x7B and c <= 0x7E)
    )


def word_segmentation(
    index: SymSpell,
    phrase: StringSlice,
    max_edit_distance: Optional[Int],
    max_segmentation_word_length: Optional[Int],
    ignore_token: Optional[TokenPredicate],
) raises -> Composition:
    """See `SymSpell.word_segmentation`."""
    var text = List[UInt32]()
    for cp in to_codepoints(phrase):
        if cp != _HYPHEN:
            text.append(cp)
    var med = max_edit_distance.or_else(
        index.config().max_dictionary_edit_distance
    )
    var max_len = max_segmentation_word_length.or_else(index.max_length())
    var n = len(text)
    var array_size = min(max_len, n)
    if array_size <= 0:
        if n == 0:
            raise Error("IndexError: list index out of range")
        raise Error(
            "StopIteration: max_segmentation_word_length must be positive"
        )
    var compositions = List[Composition]()
    for _ in range(array_size):
        compositions.append(Composition())
    var scratch = LookupScratch()
    var part = List[UInt32]()
    var lowered = List[UInt32]()
    var idx = -1
    var next_idx = 0  # the next value of Python's itertools.cycle

    for j in range(n):
        var imax = min(n - j, max_len)
        for i in range(1, imax + 1):
            part.clear()
            var separator_len = 0
            var start = j
            if is_space(text[j]):
                start = j + 1  # remove the space for the distance calculation
            else:
                separator_len = 1  # a space had to be inserted
            var top_ed = j + i - start
            for k in range(start, j + i):
                if text[k] != 0x20:
                    part.append(text[k])
            top_ed -= len(part)

            lowered.clear()
            lower(part, lowered)
            var results = index.lookup(
                to_string(lowered),
                Verbosity.TOP,
                med,
                ignore_token=ignore_token,
                scratch=scratch,
            )
            var top_result: String
            var top_log_prob: Float64
            if results:
                top_result = results[0].term
                if len(part) > 0 and is_upper(part[0]):
                    top_result = capitalize_string(top_result)
                top_ed += results[0].distance
                top_log_prob = _checked_log10(
                    Float64(results[0].count) / Float64(N)
                )
            else:
                top_result = to_string(part)
                top_ed += len(part)
                top_log_prob = _unknown_word_log_prob(len(part))

            var dest = (i + idx) % array_size
            if j == 0:
                compositions[dest] = Composition(
                    to_string(part), top_result, top_ed, top_log_prob
                )
                continue
            ref previous = compositions[idx]
            var candidate_sum = previous.distance_sum + top_ed
            var spaced_sum = previous.distance_sum + separator_len + top_ed
            var current_sum = compositions[dest].distance_sum
            if (
                i == max_len
                or (
                    (current_sum == candidate_sum or current_sum == spaced_sum)
                    and compositions[dest].log_prob_sum
                    < previous.log_prob_sum + top_log_prob
                )
                or spaced_sum < current_sum
            ):
                var result_cps = to_codepoints(top_result)
                if _is_ascii_punctuation(result_cps) or (
                    len(result_cps) == 2 and result_cps[0] == 0x27
                ):
                    compositions[dest] = previous.extended(
                        to_string(part), top_result, top_ed, top_log_prob
                    )
                else:
                    compositions[dest] = previous.extended(
                        String(" ", to_string(part)),
                        String(" ", top_result),
                        separator_len + top_ed,
                        top_log_prob,
                    )
        idx = next_idx
        next_idx = (next_idx + 1) % array_size
    return compositions[idx].copy()
