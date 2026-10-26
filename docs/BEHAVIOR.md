# Observable behavior of symspellpy 6.10.0

This file lists what `symspell` must reproduce.
The reference is `symspellpy` 6.10.0 (`symspellpy.py`, `helpers.py`, `editdistance.py`,
`suggest_item.py`, `composition.py`, `verbosity.py`).
Line numbers below refer to `symspellpy/symspellpy.py` of that version.

All lengths, indices, slices and deletes are **per Unicode codepoint**, because Python `str` is
a sequence of codepoints. In Mojo, strings are UTF-8 bytes, so we decode to codepoints first.

Notation: `d` = `max_dictionary_edit_distance`, `p` = `prefix_length`, `t` = `count_threshold`,
`N` = `1024908267229`, `MAXSIZE` = `sys.maxsize` = `2**63 - 1`.

## 1. Configuration

Validation in `SymSpell.__init__`, checked in this order, each raising `ValueError`:

1. `d < 0` -> "max_dictionary_edit_distance cannot be negative"
2. `p < 1` -> "prefix_length cannot be less than 1"
3. `p <= d` -> "prefix_length must be greater than max_dictionary_edit_distance"
4. `t < 0` -> "count_threshold cannot be negative"

Defaults: `d = 2`, `p = 7`, `t = 1`, distance = Damerau-OSA.

## 2. Dictionary state

- `words`: term -> count. Only terms with count `>= t`.
- `below_threshold_words`: term -> count, for terms seen with a total count `< t`.
- `deletes`: delete string -> list of terms, in insertion order.
- `bigrams`: "w1 w2" -> count.
- `max_length`: longest term length (codepoints) among `words`.
- `word_count` = `len(words)`.
- `entry_count` = `len(deletes)`, i.e. the number of distinct delete strings.
  `delete_dictionary_entry` removes terms from the lists but **keeps the keys**,
  even when a list becomes empty. So `entry_count` never decreases.

### 2.1 Deletes of a term (`_edits_prefix`)

For a term `key`:
1. If `len(key) <= d`, add `""`.
2. Truncate: `key = key[:p]`.
3. Add `key` itself.
4. Add every string obtained by deleting 1..d codepoints from the truncated key.

Equivalently: the set of all subsequences `s` of `key[:p]` with `len(key[:p]) - len(s) <= d`,
plus `""` when `len(key) <= d`.
(The second rule is already covered by the first when `len(key) <= d`, because then `key[:p] = key`.)

The term is appended to the list of each delete in the set. The set is unordered, but each list
is ordered by term insertion time, which is what lookups observe.

### 2.2 `create_dictionary_entry(key, count) -> bool`

In this order:

1. If `count <= 0`: if `t > 0`, return `False`. Otherwise set `count = 0` and continue.
2. If `t > 1` and `key` is in `below_threshold_words`:
   `count = increment_count(count, previous)`.
   If `count >= t`: remove it from `below_threshold_words` and fall through to step 5.
   Otherwise store the new count and return `False`.
3. Else if `key` is in `words`: `words[key] = increment_count(count, previous)`, return `False`.
4. Else if `count < t`: `below_threshold_words[key] = count` (overwrites), return `False`.
5. New word: `words[key] = count`. Update `max_length`. Add deletes (2.1). Return `True`.

`increment_count(count, previous)` = `previous + count` if `MAXSIZE - previous > count`, else `MAXSIZE`.
So counts saturate at `2**63 - 1`. Counts are never negative.

Notes:
- With `t == 0`, a word with count `0` (or a negative count, turned into `0`) is added.
- With `t == 1`, nothing is ever below threshold.
- The empty string `""` is a valid term.

### 2.3 `delete_dictionary_entry(key) -> bool`

- Returns `False` if `key` is not in `words`. Below-threshold words are not touched.
- Removes the term from `words` and from each delete list (keys stay, see above).
- If `len(key) == max_length`, recompute `max_length` as the longest remaining word.
  If no words remain, Python raises `ValueError` ("max() iterable argument is empty").
  The word is already removed from `words` at that point, but the deletes are not yet updated.

### 2.4 `load_dictionary(path, term_index, count_index, separator=" ")`

- Missing file: logs an error and returns `False`.
- The file is read in text mode. Line endings `\n`, `\r\n` and lone `\r` all end a line.
  Invalid UTF-8 raises `UnicodeDecodeError`.
- For each line: `parts = line.rstrip().split(separator)`.
  `rstrip()` removes trailing Unicode whitespace (`str.isspace`).
  `split(" ")` splits on the exact separator string; empty fields are kept.
- If `len(parts) < 2`: skip the line.
- `count = try_parse_int64(parts[count_index])`. If `None`: warn and skip.
  An index past the end raises `IndexError` (this can happen when `count_index >= 2`).
- `create_dictionary_entry(parts[term_index], count)`.

`try_parse_int64(s)` follows Python `int(s)`:
leading/trailing Unicode whitespace allowed, optional `+`/`-`, digits are any Unicode decimal
digits (category Nd), single underscores allowed between digits.
Result must be in `[-2**63, 2**63 - 1]`, otherwise `None`.

### 2.5 `load_bigram_dictionary(path, term_index, count_index, separator=None)`

- Same file reading as 2.4.
- `parts = line.rstrip().split(separator)`. With `separator=None`, Python splits on runs of
  Unicode whitespace and drops empty fields.
- `min_parts = 3` if `separator is None` else `2`. Skip lines with fewer parts.
- `count = try_parse_int64(parts[count_index])`; skip on `None`.
- Key: `parts[term_index] + " " + parts[term_index + 1]` if `separator is None`, else `parts[term_index]`.
- `bigrams[key] = count` (overwrites, no merging, no threshold).
- `bigram_count_min = min(bigram_count_min, count)`. Its initial value is `MAXSIZE`.
  Setting `bigrams[k]` directly (as one symspellpy test does) does **not** update it.

### 2.6 `create_dictionary(corpus)`

- Reads the whole file (text mode). Missing file: log error, return `False`.
- Words: `re.findall(r"(([^\W_]|['’])+)", text.lower())`, taking the outer group.
  `[^\W_]` is a codepoint that is alphanumeric (`str.isalnum`), so a word is a maximal run of
  alphanumeric codepoints and the apostrophes `'` and `’`.
- Each word: `create_dictionary_entry(word, 1)`.

## 3. Edit distance

`DamerauOsa().distance(s1, s2, max_distance)` (the default) and `Levenshtein`:

- `max_distance <= 0`: return `0` if `s1 == s2` else `-1`.
- `max_distance = min(max_distance, 2**31 - 1)`.
- Otherwise return the exact distance if it is `<= max_distance`, else `-1`.

I checked that the SoftWx banded implementation always equals a textbook DP (300,000 random pairs,
small alphabets with spaces, both the shared instance and fresh instances, and editdistpy too).
So a textbook DP is a valid oracle. OSA here means "optimal string alignment":
a transposition of adjacent codepoints costs 1, and a substring is not edited twice.

## 4. `lookup(phrase, verbosity, max_edit_distance=None, include_unknown=False, ignore_token=None, transfer_casing=False)`

Let `med = max_edit_distance` (default `d`). Steps, in order (line 358):

1. If `med > d`: raise `ValueError("distance too large")`. Negative `med` is accepted.
2. `phrase_len = len(phrase)` **of the original phrase**.
   If `transfer_casing`: `phrase = phrase.lower()` (Python full lowercase mapping; its length
   can differ from `phrase_len`, e.g. `"İ".lower()` is 2 codepoints).
3. "early exit" means: if `include_unknown` and there are no suggestions,
   append `(phrase, med + 1, 0)`; then return suggestions.
   Note: `phrase` here is the lowercased phrase if `transfer_casing`.
4. If `phrase_len - med > max_length`: early exit.
   (So `lookup("hello", ALL, -1, include_unknown=True)` returns `("hello", 0, 0)`.)
5. If `phrase` is in `words`: append `(original_phrase if transfer_casing else phrase, 0, count)`.
   If `verbosity != ALL`: early exit.
6. If `ignore_token` matches the start of `phrase`: append `(phrase, 0, 1)`.
   If `verbosity != ALL`: early exit.
7. If `med == 0`: early exit.
8. Candidate search (below).
9. If more than one suggestion: stable sort by `(distance asc, count desc)`.
   Ties keep discovery order. This makes discovery order observable.
10. If `transfer_casing`: each term becomes `case_transfer_similar(original_phrase, term)`.
11. Early exit (adds the unknown item if still empty).

### 4.1 Candidate search

```
considered_deletes = {}
considered_suggestions = {phrase}
med2 = med
phrase_prefix_len = min(phrase_len, p)
candidates = [phrase[:p] if phrase_len > p else phrase]
```

Note: `phrase_len` is the original length, while `phrase` may be lowercased (step 2).

For each candidate, in list order (the list grows while we iterate):

- `candidate_len = len(candidate)`, `len_diff = phrase_prefix_len - candidate_len`.
- If `len_diff > med2`: if `ALL`, continue (never happens); else **stop the whole loop**.
- If `candidate` is a key of `deletes`, for each `suggestion` in its list, in order:
  - Skip if `suggestion == phrase`.
  - `suggestion_len = len(suggestion)`. Skip if
    `abs(suggestion_len - phrase_len) > med2`, or `suggestion_len < candidate_len`,
    or (`suggestion_len == candidate_len` and `suggestion != candidate`).
  - `suggestion_prefix_len = min(suggestion_len, p)`.
    Skip if `suggestion_prefix_len > phrase_prefix_len` and `suggestion_prefix_len - candidate_len > med2`.
  - Distance:
    - If `candidate_len == 0`: `distance = max(phrase_len, suggestion_len)`.
      Skip if `distance > med2` or `suggestion` is in `considered_suggestions`.
      **Not** added to `considered_suggestions`.
    - Elif `suggestion_len == 1`: `distance = phrase_len - 1` (Python computes
      `phrase.index(suggestion[0])`, which always succeeds here because the suggestion equals the
      candidate). Skip if `distance > med2` or already considered. Not added to considered.
    - Else:
      - If `p - med == candidate_len`: `min_distance = min(phrase_len, suggestion_len) - p`, else `0`.
      - Skip if
        (`p - med == candidate_len` and `min_distance > 1` and
        `phrase[phrase_len + 1 - min_distance:] != suggestion[suggestion_len + 1 - min_distance:]`)
        or
        (`min_distance > 0` and `phrase[phrase_len - min_distance] != suggestion[suggestion_len - min_distance]`
        and (`phrase[phrase_len - min_distance - 1] != suggestion[suggestion_len - min_distance]`
        or `phrase[phrase_len - min_distance] != suggestion[suggestion_len - min_distance - 1]`)).
        Python indexing uses the possibly lowercased `phrase` with the original `phrase_len`;
        negative indices wrap around and out-of-range indices raise `IndexError`.
        (This only matters with `transfer_casing` and length-changing lowercase.)
      - Skip if already considered; then add to `considered_suggestions`.
      - `distance = compare(phrase, suggestion, med2)`. Skip if `< 0`.
  - If `distance <= med2` (always true here):
    - `item = (suggestion, distance, words[suggestion])`.
    - If suggestions is not empty:
      - `CLOSEST`: if `distance < med2`, clear suggestions.
      - `TOP`: if `distance < med2` or `count > suggestions[0].count`:
        set `med2 = distance` and `suggestions[0] = item`. Then **continue** (do not append).
        Ties in count keep the first found.
    - If not `ALL`: `med2 = distance`.
    - Append `item`.
- Generate new candidates if `len_diff < med` and `candidate_len <= p`:
  - If not `ALL` and `len_diff >= med2`: skip generation.
  - For `i` in `0..candidate_len-1`: `delete = candidate` without codepoint `i`.
    If not in `considered_deletes`: add it and append to `candidates`.

The `ALL` verbosity never shrinks `med2`.

### 4.2 Verbosity

`TOP = 0`, `CLOSEST = 1`, `ALL = 2`.

## 5. Suggestions

- `SuggestItem(term, distance, count)`.
- Equality (`==`) compares only `distance` and `count`.
- `<` is `(distance asc, then count desc)`.
- `str()` gives `"term, distance, count"`.
- `create_with_probability(term, distance)`: count = `10 // 10 ** len(term)`, that is
  `10` for an empty term, `1` for one codepoint, `0` otherwise.

## 6. Casing helpers

### 6.1 `case_transfer_matching(cased, uncased)`

Raises `ValueError` if lengths differ. Otherwise per codepoint:
`y.upper() if x.isupper() else y.lower()`. Note `upper()`/`lower()` may produce several codepoints.

### 6.2 `case_transfer_similar(cased, uncased)`

- If `uncased` is empty: return it.
- If `cased` is empty: raise `ValueError("'cased_text' cannot be empty")`.
- Opcodes from `difflib.SequenceMatcher(a=cased.lower(), b=uncased).get_opcodes()`.
  This needs an exact port of difflib: `isjunk=None`, `autojunk=True`
  (if `len(b) >= 200`, codepoints occurring more than `len(b) // 100 + 1` times are "popular"
  and ignored), `find_longest_match`, `get_matching_blocks`, `get_opcodes`.
- Indices `i1, i2` index into **both** `cased.lower()` (in the matcher) and `cased` (when copying).
  If lowercasing changes the length, Python mixes the two index spaces. We reproduce this.
- `delete`: nothing.
- `insert`: `ia_ref = i1 if i1 == 0 or cased[i1 - 1] == " " else i1 - 1`;
  append `uncased[j1:j2]` upper-cased if `cased[ia_ref].isupper()`, else lower-cased.
  (`cased[ia_ref]` can be out of range at the end: Python raises `IndexError`.)
- `equal`: append `cased[i1:i2]`.
- `replace`: if the two slices have equal length, `case_transfer_matching`; else per pair
  `upper if cased.isupper() else lower`, then the rest of `uncased_seq` takes the case of the
  last codepoint of `cased_seq`.

## 7. Word parsing (`helpers.parse_words`)

- `split_by_space=True`: `phrase.split()` (Unicode whitespace runs), lowercased first unless
  `preserve_case`.
- Otherwise `re.findall(r"([^\W_]+['’]*[^\W_]*)", phrase)` on `phrase.lower()` unless `preserve_case`.
  A token = run of alphanumerics, then any number of `'`/`’`, then a possibly empty run of alphanumerics.
  The regex scans left to right, non-overlapping.

`is_acronym(word, contain_digits)`: `re.match(r"\b[A-Z0-9]{2,}\b", word)` (ASCII uppercase letters
and ASCII digits only; `\b` is a word boundary using Unicode `\w` = alphanumeric or `_`),
or (`contain_digits` and any codepoint has `isdigit()`).
Equivalent: the maximal leading run of `[A-Z0-9]` has length >= 2 and is followed by the end of
the string or by a non-`\w` codepoint. (A first codepoint that is not a word char makes `\b` fail.)

## 8. `lookup_compound(phrase, max_edit_distance, ignore_non_words=False, transfer_casing=False, split_by_space=False, ignore_term_with_digits=False)`

Line 639. Let `med = max_edit_distance`.

- `terms_1 = parse_words(phrase, split_by_space=...)` (lowercase).
- If `ignore_non_words`: `terms_2 = parse_words(phrase, preserve_case=True, ...)`.
  The two lists can differ in length if lowercasing changes tokenization; Python then
  indexes `terms_2[i]` and may raise `IndexError` or misalign. We reproduce it.
- `suggestion_parts = []`, `is_last_combi = False`.
- For each `i`:
  - If `ignore_non_words`:
    - If `try_parse_int64(terms_1[i])` is not `None`: append `(terms_1[i], 0, N)`; continue.
    - If `is_acronym(terms_2[i], ignore_term_with_digits)`: append `(terms_2[i], 0, N)`; continue.
    - Note: `is_last_combi` is **not** reset on these `continue`s.
  - `suggestions = lookup(terms_1[i], TOP, med)`.
  - Combination check if `i > 0` and not `is_last_combi`:
    - `combi = lookup(terms_1[i-1] + terms_1[i], TOP, med)`.
    - If not empty: `best_1 = suggestion_parts[-1]`;
      `best_2 = suggestions[0]` if any, else `create_with_probability(terms_1[i], med + 1)`.
    - `distance_1 = best_1.distance + best_2.distance`.
    - If `distance_1 >= 0` and (`combi[0].distance + 1 < distance_1` or
      (`combi[0].distance + 1 == distance_1` and `combi[0].count > best_1.count / N * best_2.count`)):
      `combi[0].distance += 1`; replace `suggestion_parts[-1]` with it;
      `replaced_words[terms_1[i-1]] = it`; `is_last_combi = True`; continue.
      The float expression is evaluated left to right in IEEE double: `(best_1.count / N) * best_2.count`,
      compared with the integer `combi[0].count` exactly (Python compares int and float exactly).
  - `is_last_combi = False`.
  - If suggestions exist and (`suggestions[0].distance == 0` or `len(terms_1[i]) == 1`): append `suggestions[0]`.
  - Else, split search:
    - `best = suggestions[0]` if any else `None`.
    - If `len(terms_1[i]) > 1`: for `j` in `1..len-1`:
      - `part_1 = term[:j]`, `part_2 = term[j:]`.
      - `s1 = lookup(part_1, TOP, med)`; skip if empty. `s2 = lookup(part_2, TOP, med)`; skip if empty.
      - `tmp_term = s1[0].term + " " + s2[0].term`.
      - `tmp_distance = compare(term, tmp_term, med)`; if `< 0`, `tmp_distance = med + 1`.
      - If `best` is not `None`: skip if `tmp_distance > best.distance`;
        if `tmp_distance < best.distance`, set `best = None`.
      - If `tmp_term` is in `bigrams`: `tmp_count = bigrams[tmp_term]`, then
        - if `suggestions` exist: if `s1.term + s2.term == term`: `tmp_count = max(tmp_count, suggestions[0].count + 2)`;
          elif `suggestions[0].term` is `s1.term` or `s2.term`: `tmp_count = max(tmp_count, suggestions[0].count + 1)`.
        - elif `s1.term + s2.term == term`: `tmp_count = max(tmp_count, max(s1.count, s2.count) + 2)`.
        Python ints do not overflow here, so `MAXSIZE + 2` is possible.
      - Else: `tmp_count = min(bigram_count_min, int(s1.count / N * s2.count))` (float, truncation toward zero).
      - If `best is None` or `tmp_count > best.count`: `best = (tmp_term, tmp_distance, tmp_count)`.
    - If `best` is not `None`: append it; `replaced_words[term] = best`.
    - Else (also for a 1-codepoint term with no suggestion): append
      `create_with_probability(term, med + 1)` and record it in `replaced_words`.
- Join: `joined_term = " ".join(part.term)`;
  `joined_count = N` (float), then for each part `joined_count *= part.count / N`, left to right.
- If `transfer_casing`: `joined_term = case_transfer_similar(phrase, joined_term)`.
- Result: a list with one item:
  `(joined_term, compare(phrase, joined_term, 2**31 - 1), int(joined_count))`.
  The distance is computed against the **original** phrase (with its case and punctuation).
- `replaced_words` is instance state that accumulates across calls and is never cleared.

## 9. `word_segmentation(phrase, max_edit_distance=None, max_segmentation_word_length=None, ignore_token=None)`

Line 867.

- `phrase = unicodedata.normalize("NFKC", phrase).replace("-", "")`.
  **Mojo has no Unicode normalization.** We remove `-` but do not normalize. See API_DIFFERENCES.md.
- `med` defaults to `d`. `max_seg_len` defaults to `max_length`. No check of `med > d` here,
  but the inner `lookup` raises `ValueError("distance too large")`.
- `array_size = min(max_seg_len, len(phrase))`; `compositions = [empty] * array_size`.
- `idx = -1`; `circular_index` cycles `0, 1, ..., array_size - 1`.
- For `j` in `0..len(phrase)-1`, for `i` in `1..min(len(phrase) - j, max_seg_len)`:
  - `part = phrase[j:j+i]`, `separator_len = 0`, `top_ed = 0`.
  - If `part[0].isspace()`: `part = part[1:]`; else `separator_len = 1`.
  - `top_ed += len(part)`; `part = part.replace(" ", "")`; `top_ed -= len(part)`.
    (Only U+0020 is removed here, not other whitespace.)
  - `results = lookup(part.lower(), TOP, med, ignore_token=...)`.
  - If results: `top_result = results[0].term`; if `len(part) > 0 and part[0].isupper()`,
    `top_result = top_result.capitalize()` (first codepoint title-cased, the rest lower-cased);
    `top_ed += results[0].distance`; `top_log_prob = log10(count / N)`.
    A count of `0` makes `log10(0)` raise `ValueError` ("math domain error").
  - Else: `top_result = part`; `top_ed += len(part)`;
    `top_log_prob = log10(10.0 / N / 10.0 ** len(part))`.
    `10.0 ** len(part)` raises `OverflowError` when `len(part) >= 309`;
    a tiny value can also make `log10(0.0)` raise.
  - `dest = (i + idx) % array_size`.
  - If `j == 0`: `compositions[dest] = (part, top_result, top_ed, top_log_prob)`.
  - Elif `i == max_seg_len`
    or (`compositions[dest].distance_sum` is `compositions[idx].distance_sum + top_ed` or
    `compositions[idx].distance_sum + separator_len + top_ed`,
    and `compositions[dest].log_prob_sum < compositions[idx].log_prob_sum + top_log_prob`)
    or `compositions[idx].distance_sum + separator_len + top_ed < compositions[dest].distance_sum`:
    - If (`len(top_result) == 1` and it is in `string.punctuation`) or
      (`len(top_result) == 2` and it starts with `'`):
      append `part`, `top_result`, `top_ed`, `top_log_prob` with no space.
    - Else append `" " + part`, `" " + top_result`, `separator_len + top_ed`, `top_log_prob`.
    (`idx` is `-1` only when `j == 0`, so Python's negative index never occurs in this branch.)
  - After the inner loop: `idx = next(circular_index)`.
- Return `compositions[idx]`.
- Errors when `array_size <= 0`:
  - Empty phrase: Python raises `IndexError`.
  - Non-empty phrase and `max_seg_len <= 0`: Python raises `StopIteration` (from the empty `cycle`).
  We raise an `Error` in both cases.

`Composition` fields: `segmented_string`, `corrected_string`, `distance_sum`, `log_prob_sum`.

## 10. Unicode details we must match

These Python `str` functions are used and must be reproduced exactly (Python 3.13, Unicode 15.1):

| Python | Used in |
|---|---|
| `isalnum` (regex `\w` minus `_`) | `parse_words`, `create_dictionary`, `is_acronym` |
| `isspace` | `rstrip`, `split()`, `word_segmentation` |
| `isupper` | casing transfer, segmentation capitalization |
| `isdigit` | `is_acronym(contain_digits=True)` |
| Nd digits | `try_parse_int64` |
| `lower()` (full mapping, final sigma rule) | lookup with `transfer_casing`, parse_words, segmentation |
| `upper()` (full mapping) | casing transfer |
| `capitalize()` (title case first, lower rest) | segmentation |

Python's `lower()` applies the "final sigma" rule: `Σ` becomes `ς` at the end of a word.
We generate these tables from Python's `unicodedata` so they match exactly.

## 11. Known quirks kept on purpose

- `lookup` with `transfer_casing` uses the original length with the lowercased phrase.
- Below-threshold words are not removed by `delete_dictionary_entry`.
- `entry_count` keeps counting deletes whose lists became empty.
- `lookup_compound` counts can exceed `2**63 - 1` in Python (unbounded ints). We saturate at
  `2**63 - 1` (see DECISIONS.md). This only happens with counts near `MAXSIZE`.
- The `include_unknown` item uses distance `med + 1` and count `0`.
- An early exit (steps 4 to 7 of section 4) returns before sorting and before casing transfer.
  So `lookup("Steam", TOP, transfer_casing=True)` with "steam" in the dictionary returns the
  phrase as typed, `"Steam"`, and `ALL` with `max_edit_distance=0` returns its (at most two)
  items unsorted.
- `ALL` can return the same term twice. One-codepoint terms (section 4.1, `suggestion_len == 1`)
  and terms found through the empty candidate (`candidate_len == 0`) are never added to
  `considered_suggestions`, so a later candidate can report them again, with a larger distance:
  in a dictionary {a, ma, am, m}, `lookup("ma", ALL, 2)` returns
  `ma 0, a 1, am 1, m 1, a 2, m 2`. The second distance is `max(phrase_len, suggestion_len)`,
  not the true distance.
