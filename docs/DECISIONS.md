# Design decisions

Each entry: what we chose, and why. Newest last.

## D1. pixi, Mojo pinned to 1.2.x

`pixi.toml` pins `mojo = "1.2.*"` from `conda.modular.com/max`.
A second environment `ref` holds Python 3.13 with `symspellpy==6.10.0` and `editdistpy` from PyPI.
conda-forge only has symspellpy 6.9.0, so we take it from PyPI.

## D2. Counts are `Int` (signed 64-bit) and saturate at `2**63 - 1`

symspellpy saturates word counts at `sys.maxsize = 2**63 - 1` (`helpers.increment_count`).
A `UInt64` would give no extra range that symspellpy can produce, and signed counts keep the
arithmetic in `lookup_compound` simple. Python ints are unbounded in `lookup_compound`
(e.g. `count + 2`, or the float product); we saturate at `2**63 - 1` there. This only differs for
counts within 2 of `2**63 - 1`, or for products above it.

## D3. Hashed deletes index with exact membership check

The deletes index maps a 64-bit hash of each delete string to a list of term ids, like the C# original.
Two different deletes can share a hash, and the bucket then holds terms of both.

symspellpy uses an exact `dict`, and the **order** in which suggestions are found is observable
(stable sort on ties; `TOP` keeps the first of equal counts). Extra terms from a collision could change
that order. So for every term in a bucket we check that the candidate really is one of its deletes:
the candidate must be a subsequence of `term[:prefix_length]` and at most `max_dictionary_edit_distance`
codepoints shorter (see BEHAVIOR.md 2.1). This is cheap, and it makes results identical to an exact dict
even with collisions. Inside a bucket, term ids stay in insertion order, as in symspellpy's lists.

## D4. No `parallelize` in `std`

In Mojo 1.2, `parallelize` lives in `max.algorithm`, which is part of the large `max` package.
We do not want that dependency. `lookup_batch` uses a small pthread helper in an isolated private module.

## D5. No `mmap` in `std`

We call libc `mmap`/`munmap` through `external_call` in an isolated private module.

## D6. Unicode tables generated from Python

Mojo's stdlib does not expose Unicode categories (`isalnum`, `isspace`, `isupper`, decimal digits).
Exact parity with symspellpy needs exactly Python's tables. A reference script generates compact
range tables and case mappings from Python 3.13's `unicodedata` (Unicode 15.1) into a Mojo source file.

## D7. No Unicode normalization

`word_segmentation` in symspellpy applies NFKC. Mojo's stdlib has no normalization, and a full NFKC
implementation is large. We do not normalize. Callers should normalize input first.
(Confirmed by the project owner.) symspellpy's `test_word_segmentation_ligature` is ported with
input that is already normalized, plus a test that documents that we leave ligatures unchanged.
For NFKC-stable input (all ASCII, and most real text), results are identical.

## D8. Text fixtures instead of JSON

Mojo's stdlib has no JSON parser. Reference fixtures use a simple tab-separated format with escapes
(`\\`, `\t`, `\n`, `\r`), one record per line. The parser is a few lines in each language.
symspellpy's own JSON fixtures are kept as-is and also converted to this format.

## D9. Large lookup fixtures are generated, not committed

The `tests/fixtures/lookup_*.tsv` files are about 32 MB. They are in `.gitignore`.
`pixi run test` depends on `pixi run fixtures`, which generates them with symspellpy if any is missing
(about 2 minutes). The generators use fixed seeds, and two runs give byte-identical files.
All other fixtures are small and committed.

## D10. `mojo precompile` instead of `mojo package`

In Mojo 1.2, `mojo package` is deprecated and requires a `.mojoc` output. `pixi run build` uses
`mojo precompile src/symspell -o build/symspell.mojoc`. Tests import it with `-I build`.

## D11. Distance comparers: a trait plus a faithful SoftWx port

`DistanceComparer` is a trait with one method, `distance(mut self, a, b, max_distance) -> Int`, on
codepoint spans. It is `mut` because each comparer keeps its DP buffers between calls, so a lookup
allocates nothing. One comparer per thread.

`DamerauOsa` and `Levenshtein` are line-by-line ports of symspellpy's bounded SoftWx algorithms,
with the same special cases (`max_distance <= 0`, clamping to `2**31 - 1`, affix trimming, banding).
Tests compare them with symspellpy (12,000 pairs) and with textbook DP oracles in `tests/_oracles.mojo`.
Faster variants (ASCII bytes, bit-parallel) are for phase 6, and only if benchmarks justify them.

## D12. Generated Unicode tables are not formatted

`mojo format` would put every number of `_unicode_data.mojo` on its own line (17,000 lines instead of
1,500). The generator wraps the tables in `# fmt: off` / `# fmt: on`.

## D13. `Suggestion.term` is an owned `String`

The task suggested a zero-copy `StringSlice` into the index arena. But some suggestion terms are not
in the arena: the phrase itself (`include_unknown`, exact matches with `transfer_casing`, `ignore_token`)
and every case-transferred term. A slice type would need a union of origins (index, scratch, caller's
phrase), which makes the API much harder to use. Mojo's `String` stores up to 23 bytes inline, so
a typical word costs no heap allocation. `SymSpell.term(id)` still gives zero-copy access to the arena.

## D14. `ignore_token` is a `def(String) thin -> Bool`

Mojo has no regex in its stdlib. `lookup` takes an optional predicate instead, with ready-made ones in
`symspell.tokenize`: `has_digits`, `is_punctuation`, `is_url_like`. The predicate receives the
(lowercased, with `transfer_casing`) phrase, as symspellpy's `re.match` does. It takes a `String`
rather than a `StringSlice` to avoid origin parameters in the function type.

## D15. The builder computes deletes once, in `build()`

symspellpy updates its deletes dict on every `create_dictionary_entry`. The builder only records
terms and counts; `build()` (consuming) or `snapshot()` (keeping the builder) generates all deletes in
two passes. This is faster and uses far less memory, but the incremental workflow (add words after
lookups) needs a new `snapshot()`, which costs a full build.

## D16. `entry_count` counts distinct 64-bit delete hashes

symspellpy's `entry_count` is the number of distinct delete strings. The index only stores their
64-bit hashes, so two different deletes with the same hash would count once. For the English
dictionary (676,094 deletes) the chance of any such collision is about 1 in 10^8, and the tests check
the exact symspellpy value for every fixture. Lookups are not affected by collisions (D3).

## D17. Binary index format, version 1

- One image: a 256-byte header (magic `SYMSPELL`, version, endianness marker, the scalar fields,
  a checksum, and a table of 14 sections), then the sections, each aligned to 64 bytes.
  The layout is documented in `src/symspell/_image.mojo`.
- `build()` produces exactly these bytes in memory, `save()` writes them, and `open()` memory-maps
  them. A saved file is used without parsing or copying.
- Offsets are `UInt32`, so an index is limited to 4 GiB. The 82k English index is 24 MB.
- `open()` always validates the structure: section sizes match the header counts, offsets rise and stay
  inside their arena, terms are valid UTF-8 with the stored lengths, ids are in range, and every hash
  table has an empty slot (so probing ends). After that, no read can leave the file, even for a crafted
  file. This costs one linear pass. The fuzz test found one missing check here (an offset past the
  arena before the "increasing" check), now fixed.
- The checksum (FNV-1a over 8-byte words) catches random corruption. It is not cryptographic.
  `verify_checksum=False` skips it. On the English index, `open()` takes about 15 ms with the
  checksum and about 9 ms without (warm page cache).
- If `mmap` fails, or with `use_mmap=False`, the file is read into memory instead.
- Only little-endian machines are supported (all current Mojo targets). A file with a different
  endianness marker is rejected.
