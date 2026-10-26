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
