"""Merges several benchmark runs into one result, taking each metric's median.

Run by bench/run.sh when BENCH_RUNS > 1. Reads bench/results/mojo_timings_run*.jsonl and
bench/results/symspellpy_run*.json, writes mojo_timings.jsonl and symspellpy.json.
"""

import json
import statistics
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"


def median_of(values: list):
    """Median of numbers, or field by field for latency stats."""
    if isinstance(values[0], dict):
        return {key: statistics.median(v[key] for v in values) for key in values[0]}
    return statistics.median(values)


def merge(runs: list[dict]) -> dict:
    return {key: median_of([run[key] for run in runs if key in run]) for key in runs[0]}


def main() -> None:
    mojo_runs = []
    for path in sorted(RESULTS.glob("mojo_timings_run*.jsonl")):
        run: dict = {}
        for line in path.read_text().splitlines():
            if line.startswith("{"):
                run.update(json.loads(line))
        mojo_runs.append(run)
    if mojo_runs:
        merged = merge(mojo_runs)
        lines = [json.dumps({key: value}) for key, value in merged.items()]
        (RESULTS / "mojo_timings.jsonl").write_text("\n".join(lines) + "\n")
    python_runs = [json.loads(p.read_text()) for p in sorted(RESULTS.glob("symspellpy_run*.json"))]
    if python_runs:
        doc = python_runs[0]
        doc["results"] = merge([run["results"] for run in python_runs])
        doc["runs"] = len(python_runs)
        (RESULTS / "symspellpy.json").write_text(json.dumps(doc, indent=2) + "\n")
    print(f"median of {len(mojo_runs)} Mojo and {len(python_runs)} symspellpy runs")


if __name__ == "__main__":
    main()
