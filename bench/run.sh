#!/usr/bin/env bash
# Runs all benchmarks and writes raw results to bench/results/.
# Usage: pixi run bench   (or: bash bench/run.sh [--skip-python])
# For stable numbers, close other programs first; see BENCHMARKS.md.
set -euo pipefail
cd "$(dirname "$0")/.."
PIXI="${PIXI_EXE:-pixi}"
mkdir -p bench/results build/tmp

if [[ ! -f bench/data/large_dict.txt ]]; then
    "$PIXI" run -e ref python bench/gen_data.py
fi
mojo build -I build bench/bench.mojo -o build/bench

echo "== Mojo timings"
./build/bench timings | tee bench/results/mojo_timings.jsonl

echo "== Mojo memory (one process per measurement)"
{
    ./build/bench rss-build data/frequency_dictionary_en_82_765.txt | sed 's/"rss_build_mb"/"rss_build_en_mb"/; s/"peak_mb"/"peak_build_en_mb"/'
    ./build/bench rss-build bench/data/large_dict.txt | sed 's/"rss_build_mb"/"rss_build_large_mb"/; s/"peak_mb"/"peak_build_large_mb"/'
    ./build/bench save data/frequency_dictionary_en_82_765.txt build/tmp/en.idx
    ./build/bench rss-open build/tmp/en.idx
    rm -f build/tmp/en.idx
} | tee bench/results/mojo_memory.jsonl

if [[ "${1:-}" != "--skip-python" ]]; then
    echo "== symspellpy"
    "$PIXI" run -e ref python bench/bench_symspellpy.py
fi
python3 bench/report.py
