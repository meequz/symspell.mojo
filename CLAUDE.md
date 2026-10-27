# CLAUDE.md

SymSpell spelling correction in pure Mojo 1.2. A port of symspellpy 6.10.0 that must give exactly
the same results. Read README.md first, then docs/BEHAVIOR.md (what to match) and
docs/DECISIONS.md (why things are the way they are).

## Priorities

Correct > Fast > Small > Clean.

- Results must match symspellpy exactly: terms, distances, counts and order. Floats within a tight
  tolerance. If symspellpy looks wrong, keep its behavior and document it in BEHAVIOR.md section 11.
- Never weaken, skip or delete a test to make it pass.
- Keep a speed change only if a benchmark shows a gain. Record dropped attempts in DECISIONS.md too.
- Non-obvious choices get a new `D<n>` entry in docs/DECISIONS.md. Newest last.

## Commands

`pixi` may not be on PATH: use `~/.pixi/bin/pixi`. `mojo` only works inside pixi (`pixi run mojo ...`).

- `pixi run test`: builds `build/symspell.mojoc`, then runs every `tests/test_*.mojo`.
  `pixi run bash tests/run_all.sh <name>` runs a subset (needs a prior `pixi run build`).
- `pixi run test-debug`: the same with `-D ASSERT=all`. Run it after touching unsafe pointer code.
- `pixi run examples`: examples plus a CLI output check. `pixi run cli` builds `build/bin/symspell`.
- `pixi run bench` (`BENCH_RUNS=3` for medians), `pixi run bench-smoke` (30 s, Mojo only).
  Faster loop for lookup work: `pixi run mojo build -I build bench/bench.mojo -o build/bench && ./build/bench lookups`.
- `pixi run ref`: regenerates reference fixtures with symspellpy (env `ref`, Python 3.13).
- `pixi run fmt`: `mojo format`. `_unicode_data.mojo` is generated and stays unformatted (D12).

The large `tests/fixtures/lookup_*.tsv` files are generated, not committed (D9). `pixi run test`
creates them when missing. A new config in `reference/gen_lookup.py` needs `pixi run -e ref ref lookup`.

## Layout

- `src/symspell/`: the library. `__init__.mojo` only re-exports. Modules starting with `_` are private.
  Hot paths: `index.mojo` (`_search`, `_consider`), `scratch.mojo`, `_bitparallel.mojo`, `delete_index.mojo` (build).
- `src/symspell/_image.mojo` documents the binary index layout (format version 1, D17).
  Changing the layout needs a version bump and updates to `validate_image` and the corruption tests.
- `tests/`: `_oracles.mojo` holds the simple reference implementations. Fixtures live in `tests/fixtures/`.
- `reference/`: Python scripts that run symspellpy to make fixtures.
- `bench/`: benchmarks; results go into BENCHMARKS.md by hand.

## Mojo notes

Mojo changes fast. Use the `mojo-syntax` skill and compile small probes instead of guessing APIs.
Things learned in this codebase:

- Objects reached only through a raw address (thread jobs, buffers) can be destroyed early (ASAP
  destruction). Keep them alive with `_ = len(x)` after the last use.
- You cannot move a field out of a list element. Use `pop()` or a `deinit self` method.
- Hot loops use `p[unsafe_offset=i]` on raw pointers. Default `List` indexing is bounds-checked and
  was 2× slower. Each such loop must only use indices that the surrounding code or `open()`
  validation keeps in range.
- Threads use our own pthread helper (`_threads.mojo`, C-ABI workers), not `parallelize` (D4).
- No `perf` here. Profile with callgrind:
  `~/.pixi/bin/pixi exec --spec valgrind -- bash -c 'valgrind --tool=callgrind ...'`.

## Platform

Linux and macOS, little-endian only. Only Linux x86-64 can be tested locally. CI also covers
Linux arm64 and macOS arm64 (`.github/workflows/ci.yml`). Use only POSIX calls that macOS has, or
guard them with `comptime if CompilationTarget.is_linux()`.
