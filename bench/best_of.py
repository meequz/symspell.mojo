"""Runs a benchmark command several times and keeps the best value per metric.

On a busy machine, the fastest run is the least disturbed one. Usage:
    python3 bench/best_of.py 5 ./build/bench lookups
Prints one line per metric: the best over runs (the minimum, or the maximum for
"_per_s" throughput metrics; for latency stats, of the mean).
"""

import json
import subprocess
import sys


def main() -> None:
    runs = int(sys.argv[1])
    command = sys.argv[2:]
    best: dict[str, float] = {}
    for _ in range(runs):
        output = subprocess.run(command, capture_output=True, text=True, check=True).stdout
        for line in output.splitlines():
            if not line.startswith("{"):
                continue
            for key, value in json.loads(line).items():
                number = value["mean_us"] if isinstance(value, dict) else value
                pick = max if key.endswith("_per_s") else min  # throughput: higher is better
                best[key] = pick(best.get(key, number), number)
    for key, value in best.items():
        print(f"{key:32s} {value:12.3f}")


if __name__ == "__main__":
    main()
