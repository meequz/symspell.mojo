# Plan: `symspell` in pure Mojo

## Context

The repo is empty. It has a MIT LICENSE, a one-line README, and a uv setup with Mojo 1.2.0.
Goal: a SymSpell spelling-correction library in pure Mojo.
It must give exactly the same results as `symspellpy` 6.10.0.
It must be much faster and use less memory.

Facts checked on this machine:
- Mojo 1.2.0 works. Unicode `upper()`/`lower()` match Python (`ß` -> `SS`).
- `std.hash` exists. FFI via `external_call` works.
- `parallelize` is no longer in `std`. It moved to the big `max` package.
- There is no `mmap` in `std`. I will call libc `mmap` through FFI.
- symspellpy source and tests are cloned to the scratchpad for reading.

## Decisions you made

- Use **pixi**. Install it into `~/.pixi`. Pin `mojo = "1.2.*"`. Remove `pyproject.toml`, `uv.lock`, `.python-version`, `.venv`.
- Batch lookups use **my own small pthread helper** in one isolated module (`_threads.mojo`).
- **Commits:** at the end of each phase I ask you to commit. You commit and tell me. Then I continue.
- **Check-ins:** I stop after each phase with a short report.

## Phases

Each phase ends with all tests green, a short report, and a request to commit.

### Phase 1. Behavior doc and reference fixtures
- Install pixi. Write `pixi.toml` with two environments:
  - default: Mojo 1.2.x. Tasks `build`, `test`, `bench`, `fmt`.
  - `ref`: Python + `symspellpy==6.10.0` + `editdistpy`. Task `ref` generates fixtures.
- Read all of symspellpy's code and tests.
- Write `docs/BEHAVIOR.md`. It describes exactly what we must reproduce:
  sort order, thresholds, count merging and saturation, `max_length`, prefix logic,
  `include_unknown`, `transfer_casing`, compound rules and formulas, segmentation scoring.
- Write `docs/PLAN.md` (a copy of this plan) and `docs/DECISIONS.md`.
- Write `reference/*.py`. These scripts run symspellpy and write JSON fixtures to `tests/fixtures/`:
  thousands of queries (typos, random, non-ASCII, empty, very long), all verbosities,
  distances 0..3, several prefix lengths and thresholds, flags on/off,
  compound and segmentation sentences, English dict and a synthetic non-ASCII dict.
  A fixed random seed makes them reproducible.
- Copy symspellpy's dictionaries and test fixtures into the repo (MIT, credited).

### Phase 2. Edit distance
- `text.mojo`: UTF-8 to codepoint arrays, casing helpers.
- `distance.mojo`: trait `DistanceComparer`, with `DamerauOsa` and `Levenshtein`.
  - Simple DP version. This is the test oracle.
  - Bounded version with early exit and common prefix/suffix trimming, like editdistpy.
  - Fast paths are added only in phase 6, and only if benchmarks show they help.
- Tests: known values, port of `test_editdistance.py`, random fast vs simple (ASCII and Unicode, length 0..200),
  bounded vs unbounded, symmetry, identity. Triangle inequality only for Levenshtein.

### Phase 3. Builder, frozen index, `lookup`
- `config.mojo`, `verbosity.mojo`, `suggestion.mojo`.
- `builder.mojo`: mutable `SymSpellBuilder`. Entries, counts, below-threshold words, bigrams, text loading.
- `arena.mojo`: all terms in one byte buffer plus `UInt32` offsets.
- `delete_index.mojo`: 64-bit hash of each delete -> list of term ids.
  Stored CSR-style (one flat id array plus offsets) in an open-addressing table. Built in two passes.
- `index.mojo`: frozen `SymSpell` with `lookup`, `contains`, `count`, `word_count`, `entry_count`.
  Uses a reusable `LookupScratch`, so a lookup does no heap allocations in steady state.
- `Suggestion.term` is a zero-copy slice into the arena. `term_owned()` gives a `String`.
- Tests: port of lookup tests and edge cases, differential tests against the JSON fixtures,
  brute-force oracle (linear scan) for `ALL`, property tests (self lookup, sorting, insert order).

### Phase 4. Binary index format and mmap
- `io.mojo`: `save(path)` and `SymSpell.open(path)`.
- Header: magic bytes, format version, endianness, config, section offsets and lengths, checksum.
- Sections are aligned so the file is used directly after `mmap`, without parsing.
  Fallback: read the file into memory.
- `_mmap.mojo`: the isolated libc FFI wrapper.
- Tests: save/open round trip gives identical lookups. Fuzzing: truncated and corrupted files must raise, never crash.

### Phase 5. `lookup_compound` and `word_segmentation`
- `compound.mojo`, `segmentation.mojo`, ported 1:1 from symspellpy logic.
- `ignore_token` regex becomes a predicate function. Ready-made predicates: has digits, is punctuation, is URL-like.
- Tests: port symspellpy's compound and segmentation tests and fixtures, plus differential fixtures. Floats within tight tolerance.

### Phase 6. Performance
- `bench/`: Mojo benchmark programs plus a Python script that measures symspellpy on the same data.
- Datasets: English 82k dict and bigrams, a 1M+ term dictionary (documented synthetic or a real list),
  10k noisy queries with fixed seed, symspellpy's noisy query file, noisy sentences.
- Metrics: build time, index size, `open()` time, RSS, lookup latency (mean, p50, p99) per verbosity
  and distance 1..3, batch throughput 1 and N threads, compound and segmentation time.
- `_threads.mojo`: pthread pool for `lookup_batch`. Each worker has its own scratch.
- Profile first. Try fast paths (ASCII bytes, bit-parallel OSA for <= 64 codepoints).
  Keep each one only if the benchmark shows a win.
- Write `BENCHMARKS.md` with honest numbers, including missed targets.

### Phase 7. Docs, packaging, CI
- `README.md`, `docs/API_DIFFERENCES.md`, final `docs/DECISIONS.md`.
- `examples/`: CLI (`symspell check file.txt`, `symspell build dict.txt -o dict.idx`) and small examples.
- `recipe.yaml` for modular-community.
- `.github/workflows/ci.yml`: Linux x86-64, Linux arm64, macOS arm64. Tests, differential suite, short bench smoke test.
  I write the file. I cannot run arm64 or macOS here, so CI is untested until you push.
- Python bindings are out of scope for now (optional later phase).

## Layout

As in the task: `src/symspell/*.mojo`, `tests/`, `reference/`, `bench/`, `examples/`, `docs/`.
Private modules start with `_`.

## Verification

- `pixi run test` runs all Mojo tests: unit, ported symspellpy, differential, brute-force, property, fuzz.
- `pixi run ref` regenerates fixtures from symspellpy. Output is byte-identical between runs.
  Large lookup fixtures are not committed; `pixi run test` generates them when missing (D9).
- `pixi run bench` runs benchmarks for both libraries.
- Debug assertions on (`-D ASSERT=all`) for a test run. Long-loop RSS check for leaks.
- No dev servers or background processes are left running.

## Known risks

- Mojo stdlib gaps may need small workarounds. Each one goes in an isolated module and in `DECISIONS.md`.
- Passing a Mojo function to `pthread_create` needs a C-ABI callback. I will probe this early in phase 6.
  If it fails, I fall back to sequential batch and report it.
