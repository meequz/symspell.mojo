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
We do not want that dependency. `lookup_batch` and `build()` (D20) use a small pthread helper in an
isolated private module.

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
  a checksum, and a table of 15 sections), then the sections, each aligned to 64 bytes.
  The layout is documented in `src/symspell/_image.mojo`. Phase 6 changed the layout for speed
  (D19); the format is unreleased, so the version stayed 1.
- `build()` produces exactly these bytes in memory, `save()` writes them, and `open()` memory-maps
  them. A saved file is used without parsing or copying.
- Offsets are `UInt32`, so an index is limited to 4 GiB. The 82k English index is about 24 MB.
- `open()` validates the structure: section sizes match the header counts, offsets rise and stay
  inside their arena, terms are valid UTF-8, each term record matches its UTF-8 text, every posting
  points at a record start, ids are in range, and every hash table has an empty slot (so probing
  ends). After that, no read can leave the file, even for a crafted file. This costs one linear pass.
  The fuzz test found one missing check here (an offset past the arena before the "increasing"
  check), now fixed.
- Posting lengths (D19) are not validated: they are only hints for filtering. Lookups read every
  length they use for memory access from the validated records. A wrong hint can only change
  results, and the checksum catches that kind of damage.
- The checksum (FNV-1a over 8-byte words) catches random corruption. It is not cryptographic.
  `verify_checksum=False` skips it.
- `trusted=True` skips the checksum and the structural checks (only the header and the section
  table are checked). Opening then costs almost nothing, because mmap loads pages lazily: a 329 MB
  index opens in under a millisecond. It is meant for files you wrote yourself; a damaged file can
  then crash the process. The default stays safe.
- If `mmap` fails, or with `use_mmap=False`, the file is read into memory instead.
- Only little-endian machines are supported (all current Mojo targets). A file with a different
  endianness marker is rejected.

## D18. `lookup_compound` and `word_segmentation`

- Both are line-by-line ports, in `compound.mojo` and `segmentation.mojo`. `SymSpell` has thin methods
  that call them (the modules import each other, which Mojo allows).
- symspellpy keeps `replaced_words` as instance state. The index is read-only, so
  `lookup_compound(..., replaced_words=my_dict)` takes the dict as a `mut` keyword argument. Entries
  accumulate across calls that share the dict, as in symspellpy.
- Float arithmetic follows Python's evaluation order in IEEE doubles. Python compares an `int` with a
  `float` exactly, so `int_gt_float` does the same without rounding the integer. `int(float)` raises on
  infinity and NaN, and `math.log10` raises for zero, as in Python.
- Python's `count / N` is a correctly rounded division of two integers. We compute
  `Float64(count) / Float64(N)`, which is identical for counts below 2**53 (about 9 * 10**15) and may
  differ in the last bit above that. Real counts are far smaller.
- `word_segmentation` removes `-` but does not NFKC-normalize (D7).

## D19. Performance work (phase 6)

Measured, not guessed: each change was kept only if `bench/bench.mojo lookups` (best of several runs,
because the development machine was busy) showed a win, and the differential tests still passed.
No sampling profiler was available (`perf` is not installed, `ptrace` is restricted), so work was
located with counters (candidates, postings and distance calls per lookup) and micro-benchmarks.

Findings and the changes they led to, for the English dictionary, `TOP`, distance 2:

1. **Bounds checks.** Mojo's default build checks every `List`/`Span` index; this alone doubled lookup
   time. Hot loops (distance, membership check, sets, image access) now index raw pointers. Each
   such loop only uses indices that the surrounding code (or `open()` validation) keeps in range,
   and the test suite also runs with all assertions on (`pixi run test-debug`).
2. **Decoding UTF-8 per posting.** The index stores each term's codepoints, so lookups never decode.
3. **Section table lookups.** Raw pointers to all sections are computed once, when the index is built
   or opened.
4. **Candidate handling.** Deletes of a candidate are written straight into the candidate buffer and
   hashed while copying (the hash takes its length at the end, so this is possible); duplicates are
   rolled back. No candidate is copied or hashed twice.
5. **Sorting.** `ALL` can return hundreds of suggestions. They are sorted as small `Hit` records with
   a stable merge sort (Python's `list.sort` is stable too) before any string is made.
6. **Cache misses.** With the index bigger than the CPU cache, each posting cost about 100 ns of
   waiting. Now:
   - a posting points straight at a **term record** (length, id, codepoints), one memory access;
   - a **posting length** byte array lets a pre-filter skip about half of the postings without
     touching their records;
   - the deletes table stores **(32-bit fingerprint, start) pairs**, so one probe reads one cache
     line (and the table shrank from 12 to 8 MB); buckets whose fingerprints collide merge, which is
     correct because every term is verified (D3); `entry_count` still counts exact 64-bit hashes;
   - the records of a bucket's surviving postings and the table slots of new candidates are
     **prefetched**, so their memory accesses overlap.
7. **Build.** Delete enumeration hashes each combination in one tight pass (a recursive walk was
   slower: about 10 million calls), duplicate deletes go through a tiny set instead of a sort, table
   slots are prefetched per term, and the image grows geometrically without zero-filling.

Tried and dropped: prefetching candidate slots a fixed distance ahead instead of at creation (no
measurable difference).

Not done in phase 6: ASCII and bit-parallel distance fast paths. The estimate behind this was
wrong: distance is a third of a lookup's compute time once the data is in cache. D20 adds them.

## D20. More performance work (phase 6b)

Phase 6 missed the 10× targets for lookups and build. A second round, with a real profiler this
time: callgrind (valgrind's instruction counter) through `pixi exec`, so the project does not
depend on it. Each change was kept only if a best-of-5 benchmark improved and the tests passed.

Lookups. With the data in cache, a `TOP` lookup at distance 2 took 2.6 µs of compute; cold, 4.9 µs.

1. **Bit-parallel distances** (`_bitparallel.mojo`): Myers' algorithm for Levenshtein and Hyyrö's
   (2003) for optimal string alignment. The phrase's character masks are built once per lookup,
   then each comparison costs a few word operations per codepoint of the term. They give the exact
   distance, so the results do not change. Phrases over 64 codepoints keep the SoftWx port (D11).
   Tested against the textbook DP oracles on random strings up to 64 codepoints, and by the
   differential suite, which now also covers Levenshtein lookups (two new fixture configs).
2. **The last bounds checks** on hot paths (the candidate sets, prefix trimming).
3. **Earlier prefetching.** The first candidate's bucket starts loading before the exact-match
   probe. The first candidate's deletes are added before its bucket is processed (symspellpy always
   adds them; the candidate order does not change). Each bucket's postings start loading while the
   previous bucket is processed.

Tried and dropped: storing the length hints inside each bucket, next to the record offsets (format
version 2). It saved one cache miss per bucket on paper, but the two loads already overlapped, and
lookups did not get faster. Format version 1 stays. Prefetching two buckets ahead was slower than one.

Build. It took 0.42 s; delete generation ran twice (once per pass) and was 45% of it.

4. **Deletes are generated once**, into one array of hashes in term order. Hashing starts from the
   stored hash of the part before the first removed position.
5. **No duplicate check per term.** It took 45 of 70 ms. A term whose deletes coincide (as in
   "letter") now gives repeated keys, which the sort below puts side by side, and the output step
   drops. This is also a little stricter than before: a term never appears twice in one bucket,
   even when two of its different deletes share a fingerprint.
6. **Counting is a set.** Bucket sizes are no longer counted: the output step finds each bucket's
   start as it writes. Only the distinct 64-bit hashes are collected, for `entry_count` (D16).
7. **Buckets are filled by a stable radix sort** of (slot, term) keys instead of random writes.
8. **Threads** (`build(threads=0)`, `snapshot(threads=0)`; 0 means one per logical core). Delete
   generation and slot lookup split the terms into ranges; the distinct-hash sets split the hashes
   into 8 fixed partitions by their top bits; each radix sort pass splits the keys into chunks. The
   pieces are always joined in the same order, so the index is byte-identical for any thread
   count (a test builds English with 1, 2, 3, 4 and 7 threads).
9. **Parsing** keeps fields as slices and reads plain ASCII counts directly.
10. **The image is allocated once**, at its final size.

Memory after a build did not improve: about 52 MB (51 before). The allocator (tcmalloc, inside the
Mojo runtime) keeps freed memory, so this number is the index (24 MB) plus what the builder and the
build's temporary arrays leave behind. Parsing alone leaves about 20 MB. The ¼-of-symspellpy target
(about 31 MB) would need a much smaller builder; it is not met. Memory after `open()` (26 MB) is.


## D21. Packaging, examples and CI (phase 7)

- **Package format.** `recipe.yaml` follows current modular-community recipes for Mojo 1.2: it
  precompiles `src/symspell` into `$PREFIX/lib/mojo/symspell.mojoc`, where `mojo` finds packages
  without `-I`. It depends on `mojo-compiler`, because a `.mojoc` only works with the compiler
  version that made it. Its test runs `examples/quick_start.mojo` against the installed package.
  It was built and tested locally with `rattler-build` from a local copy of the source. The `tag`
  source needs a pushed `v0.1.0` tag.
- **The command-line tool** is an example (`examples/cli.mojo`), not part of the library. It parses
  its arguments by hand, so it needs no dependency. `pixi run cli` writes `build/bin/symspell`.
  `pixi run examples` runs every example and checks the tool's output on a small file.
- **CI** runs on Linux x86-64, Linux arm64 and macOS arm64: all tests, all tests with debug
  assertions, the examples, and a short benchmark (`pixi run bench-smoke`, about 30 s). The large
  symspellpy fixtures (D9) are cached by the hash of `reference/` and `pixi.lock`. Only Linux
  x86-64 was tested before the workflow was written; the other two run for the first time on GitHub.
- **macOS.** The library uses only POSIX calls that macOS has (`mmap`, `pthread_create`, `open`,
  `lseek`). The benchmark's cold-cache step (`posix_fadvise`) exists only on Linux; elsewhere it
  does nothing, so "cold" timings there are warm. Memory benchmarks read `/proc` and are Linux only.
