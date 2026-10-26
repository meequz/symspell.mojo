# Differences from symspellpy's API

symspell keeps symspellpy's names, parameters and results wherever it can. Lookups,
`lookup_compound` and `word_segmentation` return exactly what symspellpy 6.10.0 returns, except
where this page says otherwise. The design reasons are in [DECISIONS.md](DECISIONS.md).

## Overview

| symspellpy | symspell |
|---|---|
| `SymSpell(max_dictionary_edit_distance, prefix_length, count_threshold)` | `SymSpellBuilder(SymSpellConfig(...))`, then `build()` |
| `distance_comparer=EditDistance(...)` | `SymSpellConfig(distance_algorithm=DistanceAlgorithm.LEVENSHTEIN)` |
| `load_dictionary(...)` returns `False` on a missing file | raises |
| `load_bigram_dictionary(...)` returns `False` on a missing file | raises |
| `create_dictionary(corpus)` returns `False` on a missing file | raises |
| `create_dictionary_entry`, `delete_dictionary_entry` | on the builder; same `Bool` results |
| `sym_spell.bigrams[key] = count` | `builder.set_bigram(key, count)` |
| `lookup(...)` | same parameters, plus an optional `scratch=` keyword |
| `ignore_token=re.compile(...)` | `ignore_token=` a function `def(String) thin -> Bool` |
| `lookup_compound(...)` and the `replaced_words` attribute | `lookup_compound(..., replaced_words=my_dict)` |
| `word_segmentation(...)` | same, but without NFKC normalization |
| pickle: `save_pickle`, `load_pickle` | `index.save(path)`, `SymSpell.open(path)` |
| `words`, `deletes`, `bigrams` dicts | accessor methods, listed below |
| no batch API | `lookup_batch(words, ...)`, in parallel |
| `Verbosity.TOP` (an enum) | `Verbosity.TOP` (a constant) |

## Builder and frozen index

symspellpy has one mutable `SymSpell` object. symspell has two:

- `SymSpellBuilder` collects words, counts and bigrams. It does not compute deletes.
- `builder^.build()` consumes the builder and returns a read-only `SymSpell` index.
  `builder.snapshot()` does the same and keeps the builder.

The index never changes, so many threads can use one index without locks. Its memory is a single
block that can also be a memory-mapped file.

The cost: adding words after lookups needs a new `snapshot()`, which rebuilds the whole index
(0.2 s for the English dictionary). symspellpy updates its index word by word.

Both `build()` and `snapshot()` take `threads=0`, which means one thread per logical CPU. The index
is byte-identical for any thread count.

## Errors

- File loading raises if the file is missing or not valid UTF-8, where symspellpy returns `False`.
  Bad lines are skipped silently, as in symspellpy.
- Invalid configuration values raise with symspellpy's messages, when the builder is created.
- `lookup` with `max_edit_distance` above the index's limit raises "distance too large", as in
  symspellpy.
- `SymSpell.open` raises for a missing, truncated, corrupted or incompatible file.

## Lookups

- `Suggestion` has `term`, `distance` and `count`. Like symspellpy's `SuggestItem`, `==` compares
  only distance and count, and printing gives `"term, distance, count"`.
- `Suggestion.term` is an owned `String`, not a slice into the index. Short terms (up to 23 bytes)
  need no heap allocation. `SymSpell.term(id)` gives zero-copy access to the stored terms.
- `scratch=LookupScratch()`: pass one reused scratch to avoid allocating working buffers on every
  call. Use one scratch per thread. Without it, each call makes its own.
- `ignore_token`: Mojo has no regular expressions in its standard library. Pass a function instead.
  `symspell.tokenize` has `has_digits`, `is_punctuation` and `is_url_like`. The function receives
  the phrase that symspellpy's `re.match` would see.
- `lookup_batch(words, verbosity, ..., threads=0)` is new. `result[i]` equals
  `lookup(words[i], ...)`.

## lookup_compound

- symspellpy stores replaced words in the `replaced_words` attribute of the `SymSpell` object. The
  index is read-only, so here you pass your own `Dict[String, Suggestion]` as
  `replaced_words=`. Entries accumulate across calls that share the dict, as in symspellpy.
- Counts saturate at `2**63 - 1`. Python's integers are unbounded, so results differ only for counts
  within 2 of that limit.

## word_segmentation

symspellpy normalizes the input with Unicode NFKC first. Mojo's standard library has no
normalization, so symspell does not. For text that NFKC does not change, such as ASCII, the results
are identical. Normalize the input yourself if it may contain ligatures, full-width forms and similar
characters.

## Inspecting a dictionary

symspellpy exposes its internal dicts. symspell has methods instead.

| symspellpy | `SymSpell` (index) | `SymSpellBuilder` |
|---|---|---|
| `word_count` | `word_count()` | `word_count()` |
| `entry_count` | `entry_count()` | – |
| `_max_length` | `max_length()` | `max_length()` |
| `key in words` | `contains(key)` | `count(key)` is not None |
| `words[key]` | `count(key)` | `count(key)` |
| `bigrams[key]` | `bigram_count(key)` | `bigram_count(key)` |
| `len(bigrams)` | `bigram_size()` | `bigram_size()` |
| `_bigram_count_min` | `bigram_count_min()` | `bigram_count_min()` |
| `below_threshold_words[key]` | – | `below_threshold_count(key)` |
| `len(below_threshold_words)` | – | `below_threshold_size()` |
| `deletes` | – (internal) | – |

`entry_count()` counts distinct 64-bit hashes of deletes. symspellpy counts distinct delete strings.
The two match for every tested dictionary; see DECISIONS.md, D16.

## Saving and loading

symspellpy saves with pickle. symspell has its own binary format:

- `index.save(path)` writes the index.
- `SymSpell.open(path)` memory-maps it. The file is used without parsing, so the English index opens
  in about 30 ms with full validation.
- `open(path, verify_checksum=False)` skips the checksum. `open(path, trusted=True)` also skips the
  structure checks, for files you wrote yourself. `use_mmap=False` reads the file into memory.

Files are limited to 4 GiB and to little-endian machines.

## Text input

- Dictionary files must be UTF-8. symspellpy has an `encoding` parameter; symspell does not.
- Lengths, edit distances and prefixes count codepoints, as in Python.
