#!/usr/bin/env bash
# Runs every tests/test_*.mojo file against the built package.
# Usage: tests/run_all.sh [name-filter]
# Extra compiler flags go in MOJO_FLAGS, e.g. MOJO_FLAGS="-D ASSERT=all".
set -euo pipefail
cd "$(dirname "$0")/.."

filter="${1:-}"
failed=()
count=0
for test_file in tests/test_*.mojo; do
    [[ -e "$test_file" ]] || continue
    [[ -z "$filter" || "$test_file" == *"$filter"* ]] || continue
    count=$((count + 1))
    echo "=== $test_file"
    # shellcheck disable=SC2086
    if ! mojo run ${MOJO_FLAGS:-} -I build "$test_file"; then
        failed+=("$test_file")
    fi
done

echo
if [[ $count -eq 0 ]]; then
    echo "No test files found."
    exit 1
fi
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FAILED (${#failed[@]} of $count files):"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
echo "All $count test files passed."
