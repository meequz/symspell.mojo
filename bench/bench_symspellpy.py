"""Benchmarks symspellpy on the same data as bench/bench.mojo.

Writes bench/results/symspellpy.json. Run: pixi run -e ref python bench/bench_symspellpy.py
Pass --quick for a short smoke run.
"""

import gc
import json
import math
import os
import platform
import statistics
import sys
import time
from importlib.metadata import version
from pathlib import Path

from symspellpy import SymSpell, Verbosity
from symspellpy.editdistance import DistanceAlgorithm, EditDistance

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "bench" / "data"
RESULTS = ROOT / "bench" / "results"
EN_DICT = ROOT / "data" / "frequency_dictionary_en_82_765.txt"
EN_BIGRAMS = ROOT / "data" / "frequency_bigramdictionary_en_243_342.txt"
NOISY_1000 = ROOT / "tests" / "fixtures" / "symspellpy" / "noisy_query_en_1000.txt"
QUICK = "--quick" in sys.argv
PAGE = os.sysconf("SC_PAGE_SIZE")


def rss_mb() -> float:
    with open("/proc/self/statm") as f:
        return int(f.read().split()[1]) * PAGE / 2**20


def lines(path: Path) -> list[str]:
    return [line for line in path.read_text(encoding="utf-8").split("\n") if line]


def stats_us(samples_ns: list[int]) -> dict:
    s = sorted(samples_ns)
    return {
        "mean_us": statistics.fmean(s) / 1000,
        "p50_us": s[len(s) // 2] / 1000,
        "p99_us": s[min(len(s) - 1, math.ceil(len(s) * 0.99) - 1)] / 1000,
        "n": len(s),
    }


def make(d: int, fast: bool) -> SymSpell:
    comparer = EditDistance(DistanceAlgorithm.DAMERAU_OSA_FAST if fast else DistanceAlgorithm.DAMERAU_OSA)
    return SymSpell(d, 7, distance_comparer=comparer)


def timed_load(d: int, fast: bool, path: Path = EN_DICT) -> tuple[SymSpell, float, float]:
    gc.collect()
    before = rss_mb()
    start = time.perf_counter()
    sym = make(d, fast)
    sym.load_dictionary(path, 0, 1)
    seconds = time.perf_counter() - start
    gc.collect()
    return sym, seconds, rss_mb() - before


def time_lookups(sym: SymSpell, queries: list[str], verbosity: Verbosity, med: int) -> dict:
    samples = []
    for q in queries:
        start = time.perf_counter_ns()
        sym.lookup(q, verbosity, med)
        samples.append(time.perf_counter_ns() - start)
    return stats_us(samples)


def main() -> None:
    RESULTS.mkdir(exist_ok=True)
    queries = lines(DATA / "queries_10k.txt")
    if QUICK:
        queries = queries[:300]
    out: dict = {
        "library": f"symspellpy {version('symspellpy')} + editdistpy {version('editdistpy')}",
        "python": platform.python_version(),
        "machine": platform.processor() or platform.machine(),
        "results": {},
    }
    r = out["results"]

    # Build: median of 3 loads of the English dictionary.
    loads = []
    for _ in range(1 if QUICK else 3):
        sym, seconds, delta = timed_load(2, fast=True)
        loads.append((seconds, delta))
        del sym
    r["build_en_s"] = statistics.median(x[0] for x in loads)
    r["rss_en_mb"] = statistics.median(x[1] for x in loads)
    print(f"build en: {r['build_en_s']:.2f} s, +{r['rss_en_mb']:.0f} MB", file=sys.stderr)

    sym, _, _ = timed_load(2, fast=True)
    # Python users reload a built dictionary with pickle; time that too.
    pickle_path = RESULTS / "symspellpy_en.pickle"
    sym.save_pickle(pickle_path)
    r["pickle_en_mb"] = pickle_path.stat().st_size / 2**20
    pickle_loads = []
    for _ in range(1 if QUICK else 3):
        gc.collect()
        before = rss_mb()
        start = time.perf_counter()
        loaded = make(2, fast=True)
        loaded.load_pickle(pickle_path)
        pickle_loads.append((time.perf_counter() - start, rss_mb() - before))
        del loaded
    r["load_pickle_en_s"] = statistics.median(x[0] for x in pickle_loads)
    r["rss_pickle_en_mb"] = statistics.median(x[1] for x in pickle_loads)
    pickle_path.unlink()
    print(f"load_pickle en: {r['load_pickle_en_s']:.2f} s, +{r['rss_pickle_en_mb']:.0f} MB", file=sys.stderr)
    slow, _, _ = timed_load(2, fast=False)
    for med in (1, 2):
        for v in (Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL):
            key = f"lookup_{v.name}_d{med}"
            r[key] = time_lookups(sym, queries if v != Verbosity.ALL else queries[:3000], v, med)
            print(f"{key}: {r[key]['mean_us']:.1f} us", file=sys.stderr)
    for v in (Verbosity.TOP, Verbosity.CLOSEST):
        key = f"lookup_{v.name}_d2_pure_python"
        r[key] = time_lookups(slow, queries[:3000], v, 2)
        print(f"{key}: {r[key]['mean_us']:.1f} us", file=sys.stderr)
    del slow

    noisy = [line.split()[0] for line in lines(NOISY_1000) if len(line.split()) >= 2]
    start = time.perf_counter()
    total = sum(len(sym.lookup(q, Verbosity.CLOSEST, 2)) for q in noisy)
    r["noisy_1000_closest_ms"] = (time.perf_counter() - start) * 1000
    r["noisy_1000_results"] = total

    sym.load_bigram_dictionary(EN_BIGRAMS, 0, 2)
    sentences = lines(DATA / "sentences.txt")[: 20 if QUICK else 200]
    samples = []
    for s in sentences:
        start = time.perf_counter_ns()
        sym.lookup_compound(s, 2)
        samples.append(time.perf_counter_ns() - start)
    r["compound_ms"] = statistics.fmean(samples) / 1e6
    phrases = lines(DATA / "segmentation.txt")[: 5 if QUICK else 50]
    for med in (0, 2):
        samples = []
        for p in phrases:
            start = time.perf_counter_ns()
            sym.word_segmentation(p, med)
            samples.append(time.perf_counter_ns() - start)
        r[f"segmentation_d{med}_ms"] = statistics.fmean(samples) / 1e6
    print(f"compound: {r['compound_ms']:.1f} ms, segmentation: {r['segmentation_d0_ms']:.1f} / {r['segmentation_d2_ms']:.1f} ms", file=sys.stderr)
    del sym

    # Distance 3 needs a dictionary built for it.
    sym3, seconds, delta = timed_load(3, fast=True)
    r["build_en_d3_s"] = seconds
    r["rss_en_d3_mb"] = delta
    for v in (Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL):
        key = f"lookup_{v.name}_d3"
        r[key] = time_lookups(sym3, queries[:2000] if v != Verbosity.ALL else queries[:500], v, 3)
        print(f"{key}: {r[key]['mean_us']:.1f} us", file=sys.stderr)
    del sym3

    if not QUICK:
        gc.collect()
        large, seconds, delta = timed_load(2, fast=True, path=DATA / "large_dict.txt")
        r["build_large_s"] = seconds
        r["rss_large_mb"] = delta
        print(f"build large: {seconds:.1f} s, +{delta:.0f} MB", file=sys.stderr)
        large_queries = lines(DATA / "large_queries.txt")
        r["lookup_large_TOP_d2"] = time_lookups(large, large_queries, Verbosity.TOP, 2)
        r["lookup_large_CLOSEST_d2"] = time_lookups(large, large_queries, Verbosity.CLOSEST, 2)

    name = "symspellpy_quick.json" if QUICK else "symspellpy.json"
    (RESULTS / name).write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote bench/results/{name}", file=sys.stderr)


if __name__ == "__main__":
    main()
