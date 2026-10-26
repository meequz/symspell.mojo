"""Turns bench/results/*.json* into the Markdown tables of BENCHMARKS.md.

Run: python3 bench/report.py   (after bench/run.sh)
"""

import json
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"


def load_jsonl(name: str) -> dict:
    out: dict = {}
    path = RESULTS / name
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith("{"):
                out.update(json.loads(line))
    return out


def fmt(value: float | None, unit: str) -> str:
    if value is None:
        return "–"
    if unit == "us":
        return f"{value:.1f} µs" if value < 100 else f"{value:.0f} µs"
    if unit == "ms":
        return f"{value:.2f} ms" if value < 10 else f"{value:.1f} ms"
    if unit == "s":
        return f"{value:.2f} s" if value < 10 else f"{value:.1f} s"
    if unit == "MB":
        return f"{value:.0f} MB" if value >= 10 else f"{value:.1f} MB"
    if unit == "/s":
        return f"{value / 1000:.0f}k/s"
    return f"{value}"


def ratio(python: float | None, mojo: float | None, higher_is_better: bool = False) -> str:
    if not python or not mojo:
        return "–"
    r = mojo / python if higher_is_better else python / mojo
    return f"{r:.1f}×"


def row(name: str, python, mojo, unit: str, higher_is_better: bool = False, label: str = "") -> str:
    return f"| {name} | {fmt(python, unit)} | {fmt(mojo, unit)} | {label or ratio(python, mojo, higher_is_better)} |"


def main() -> None:
    m = load_jsonl("mojo_timings.jsonl") | load_jsonl("mojo_memory.jsonl")
    py_doc = json.loads((RESULTS / "symspellpy.json").read_text()) if (RESULTS / "symspellpy.json").exists() else {"results": {}}
    p = py_doc["results"]

    def mean(src: dict, key: str):
        v = src.get(key)
        return v["mean_us"] if isinstance(v, dict) else v

    def pct(src: dict, key: str, which: str):
        v = src.get(key)
        return v[which] if isinstance(v, dict) else None

    print("### English dictionary (82,834 words, max edit distance 2, prefix length 7)\n")
    print("| Metric | symspellpy | symspell (Mojo) | Mojo is |")
    print("|---|---|---|---|")
    print(row("Build from the text file", p.get("build_en_s"), m.get("build_en_s"), "s"))
    print(row("Load a saved index (Python: pickle; Mojo: `open`, cold cache)", p.get("load_pickle_en_s"), m.get("open_cold_ms", 0) / 1000 if m.get("open_cold_ms") else None, "s"))
    print(row("Load a saved index, warm cache", None, m.get("open_warm_ms", 0) / 1000 if m.get("open_warm_ms") else None, "s", label="–"))
    print(row("Saved index size", p.get("pickle_en_mb"), m.get("index_en_mb"), "MB"))
    print(row("Memory after building (RSS increase)", p.get("rss_en_mb"), m.get("rss_build_en_mb"), "MB"))
    print(row("Memory after loading a saved index and 10k lookups", p.get("rss_pickle_en_mb"), m.get("rss_open_after_lookups_mb"), "MB"))
    for d in (1, 2, 3):
        for v in ("TOP", "CLOSEST", "ALL"):
            key = f"lookup_{v}_d{d}"
            print(row(f"`lookup` {v}, distance {d} (mean)", mean(p, key), mean(m, key), "us"))
    print(row("`lookup` TOP, distance 2, p50", pct(p, "lookup_TOP_d2", "p50_us"), pct(m, "lookup_TOP_d2", "p50_us"), "us"))
    print(row("`lookup` TOP, distance 2, p99", pct(p, "lookup_TOP_d2", "p99_us"), pct(m, "lookup_TOP_d2", "p99_us"), "us"))
    print(row("symspellpy's 1000 noisy queries, CLOSEST", p.get("noisy_1000_closest_ms"), m.get("noisy_1000_closest_ms"), "ms"))
    py_rate = 1e6 / mean(p, "lookup_TOP_d2") if mean(p, "lookup_TOP_d2") else None
    for threads in (1, 2, 4):
        print(row(f"`lookup_batch` TOP d2, {threads} thread(s) (Python: sequential)", py_rate, m.get(f"batch_TOP_d2_threads_{threads}_per_s"), "/s", higher_is_better=True))
    print(row("`lookup_compound`, per sentence", p.get("compound_ms"), m.get("compound_ms"), "ms"))
    print(row("`word_segmentation`, distance 0, per phrase", p.get("segmentation_d0_ms"), m.get("segmentation_d0_ms"), "ms"))
    print(row("`word_segmentation`, distance 2, per phrase", p.get("segmentation_d2_ms"), m.get("segmentation_d2_ms"), "ms"))
    print(row("Build with max edit distance 3", p.get("build_en_d3_s"), m.get("build_en_d3_s"), "s"))

    print("\n### Large synthetic dictionary (1,200,000 words, distance 2)\n")
    print("| Metric | symspellpy | symspell (Mojo) | Mojo is |")
    print("|---|---|---|---|")
    print(row("Build from the text file", p.get("build_large_s"), m.get("build_large_s"), "s"))
    print(row("Memory after building (RSS increase)", p.get("rss_large_mb"), m.get("rss_build_large_mb"), "MB"))
    print(row("Peak memory while building (Mojo)", None, m.get("peak_build_large_mb"), "MB", label="–"))
    print(row("Saved index size", None, m.get("index_large_mb"), "MB", label="–"))
    print(row("`open`, cold cache, validated", None, m.get("open_cold_large_ms"), "ms", label="–"))
    print(row("`open`, cold cache, `trusted=True`", None, m.get("open_cold_large_trusted_ms"), "ms", label="–"))
    print(row("`lookup` TOP, distance 2 (mean)", mean(p, "lookup_large_TOP_d2"), mean(m, "lookup_large_TOP_d2"), "us"))
    print(row("`lookup` CLOSEST, distance 2 (mean)", mean(p, "lookup_large_CLOSEST_d2"), mean(m, "lookup_large_CLOSEST_d2"), "us"))


if __name__ == "__main__":
    main()
