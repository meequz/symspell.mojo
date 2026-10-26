"""`lookup_compound`: spelling correction of multi-word text.

Handles three cases: a space inserted into a word, a space missing between two
words, and independent misspelled words. A port of symspellpy's
`SymSpell.lookup_compound` (docs/BEHAVIOR.md, section 8), including its float
arithmetic.
"""

from symspell.casing import case_transfer_similar
from symspell.config import DistanceAlgorithm
from symspell.distance import DamerauOsa, DistanceComparer, Levenshtein
from symspell.index import SymSpell
from symspell.io import py_index, rstrip_whitespace
from symspell.scratch import LookupScratch
from symspell.suggestion import Suggestion, suggestion_with_probability
from symspell.text import to_codepoints
from symspell.tokenize import is_acronym, parse_words, try_parse_int64
from symspell.verbosity import Verbosity

comptime N = 1024908267229
"""Words in the corpus behind the English dictionary; probabilities are count / N."""
comptime MAXSIZE = 9223372036854775807
comptime _TWO_POW_63 = 9223372036854775808.0


def int_gt_float(i: Int, f: Float64) -> Bool:
    """Python `i > f` for an int and a float: exact, without rounding `i`."""
    if f != f:
        return False
    if f >= _TWO_POW_63:
        return False
    if f < -_TWO_POW_63:
        return True
    var truncated = Int(f)  # toward zero, so exact for |f| < 2**63
    if Float64(truncated) == f or f > 0:
        return i > truncated
    return i > truncated - 1


def float_to_int(f: Float64) raises -> Int:
    """Python `int(f)`, saturated to 64 bits (docs/DECISIONS.md, D2)."""
    if f != f:
        raise Error("ValueError: cannot convert float NaN to integer")
    if f - f != 0.0:  # only infinities give NaN here
        raise Error("OverflowError: cannot convert float infinity to integer")
    if f >= _TWO_POW_63:
        return MAXSIZE
    if f < -_TWO_POW_63:
        return -MAXSIZE - 1
    return Int(f)


def _saturating_add(a: Int, b: Int) -> Int:
    if a > MAXSIZE - b:
        return MAXSIZE
    return a + b


def _distance(
    index: SymSpell,
    a: StringSlice,
    b: StringSlice,
    max_distance: Int,
    mut scratch: LookupScratch,
) -> Int:
    var x = to_codepoints(a)
    var y = to_codepoints(b)
    if index.config().distance_algorithm == DistanceAlgorithm.LEVENSHTEIN:
        return scratch.levenshtein.distance(x, y, max_distance)
    return scratch.osa.distance(x, y, max_distance)


def lookup_compound(
    index: SymSpell,
    phrase: StringSlice,
    max_edit_distance: Int,
    ignore_non_words: Bool,
    transfer_casing: Bool,
    split_by_space: Bool,
    ignore_term_with_digits: Bool,
    mut replaced_words: Dict[String, Suggestion],
) raises -> List[Suggestion]:
    """See `SymSpell.lookup_compound`."""
    var med = max_edit_distance
    var scratch = LookupScratch()
    var terms_1 = parse_words(phrase, split_by_space=split_by_space)
    var terms_2 = List[String]()
    if ignore_non_words:
        terms_2 = parse_words(
            phrase, preserve_case=True, split_by_space=split_by_space
        )
    var parts = List[Suggestion]()
    var is_last_combi = False

    for i in range(len(terms_1)):
        ref term = terms_1[i]
        if ignore_non_words:
            if try_parse_int64(term):
                parts.append(Suggestion(term, 0, N))
                continue
            ref cased = terms_2[py_index(len(terms_2), i)]
            if is_acronym(cased, ignore_term_with_digits):
                parts.append(Suggestion(cased, 0, N))
                continue
        var suggestions = index.lookup(
            term, Verbosity.TOP, med, scratch=scratch
        )

        # Combination check, always before the split.
        if i > 0 and not is_last_combi:
            var combi = index.lookup(
                String(terms_1[i - 1], term),
                Verbosity.TOP,
                med,
                scratch=scratch,
            )
            if combi:
                ref best_1 = parts[len(parts) - 1]
                var best_2 = suggestions[
                    0
                ].copy() if suggestions else suggestion_with_probability(
                    term, med + 1
                )
                var distance_1 = best_1.distance + best_2.distance
                var product = (
                    Float64(best_1.count) / Float64(N) * Float64(best_2.count)
                )
                if distance_1 >= 0 and (
                    combi[0].distance + 1 < distance_1
                    or (
                        combi[0].distance + 1 == distance_1
                        and int_gt_float(combi[0].count, product)
                    )
                ):
                    combi[0].distance += 1
                    parts[len(parts) - 1] = combi[0].copy()
                    replaced_words[terms_1[i - 1]] = combi[0].copy()
                    is_last_combi = True
                    continue
        is_last_combi = False

        # Never split terms with a perfect suggestion, or single characters.
        var length = term.count_codepoints()
        if suggestions and (suggestions[0].distance == 0 or length == 1):
            parts.append(suggestions[0].copy())
            continue
        var best = Optional[Suggestion](
            suggestions[0].copy()
        ) if suggestions else None
        if length > 1:
            var cps = to_codepoints(term)
            for j in range(1, length):
                var part_1 = String()
                var part_2 = String()
                for k in range(len(cps)):
                    if k < j:
                        part_1.append(
                            Codepoint(unsafe_unchecked_codepoint=cps[k])
                        )
                    else:
                        part_2.append(
                            Codepoint(unsafe_unchecked_codepoint=cps[k])
                        )
                var s1 = index.lookup(
                    part_1, Verbosity.TOP, med, scratch=scratch
                )
                if not s1:
                    continue
                var s2 = index.lookup(
                    part_2, Verbosity.TOP, med, scratch=scratch
                )
                if not s2:
                    continue
                var tmp_term = String(s1[0].term, " ", s2[0].term)
                var tmp_distance = _distance(
                    index, term, tmp_term, med, scratch
                )
                if tmp_distance < 0:
                    tmp_distance = med + 1
                if best:
                    if tmp_distance > best.value().distance:
                        continue
                    if tmp_distance < best.value().distance:
                        best = None
                var tmp_count: Int
                var bigram = index.bigram_count(tmp_term)
                if bigram:
                    tmp_count = bigram.value()
                    var joined = String(s1[0].term, s2[0].term)
                    if suggestions:
                        # Make the split beat the single-term correction it contains.
                        ref best_si = suggestions[0]
                        if joined == term:
                            tmp_count = max(
                                tmp_count, _saturating_add(best_si.count, 2)
                            )
                        elif (
                            best_si.term == s1[0].term
                            or best_si.term == s2[0].term
                        ):
                            tmp_count = max(
                                tmp_count, _saturating_add(best_si.count, 1)
                            )
                    elif joined == term:
                        tmp_count = max(
                            tmp_count,
                            _saturating_add(max(s1[0].count, s2[0].count), 2),
                        )
                else:
                    # Naive Bayes: P(AB) = P(A) * P(B), as an estimated count.
                    var estimate = (
                        Float64(s1[0].count) / Float64(N) * Float64(s2[0].count)
                    )
                    tmp_count = min(
                        index.bigram_count_min(), float_to_int(estimate)
                    )
                if not best or tmp_count > best.value().count:
                    best = Suggestion(tmp_term, tmp_distance, tmp_count)
            if best:
                parts.append(best.value().copy())
                replaced_words[term] = best.value().copy()
                continue
        var item = suggestion_with_probability(term, med + 1)
        parts.append(item.copy())
        replaced_words[term] = item^

    var joined_term = String()
    var joined_count = Float64(N)
    for item in parts:
        joined_term += item.term
        joined_term += " "
        joined_count *= Float64(item.count) / Float64(N)
    joined_term = String(rstrip_whitespace(joined_term))
    if transfer_casing:
        joined_term = case_transfer_similar(phrase, joined_term)
    var distance = _distance(index, phrase, joined_term, 2**31 - 1, scratch)
    var result = List[Suggestion]()
    result.append(Suggestion(joined_term, distance, float_to_int(joined_count)))
    return result^
