#!/usr/bin/env bash
# Generates the large lookup fixtures if any is missing.
# They are not committed to git (docs/DECISIONS.md, D9).
set -euo pipefail
cd "$(dirname "$0")/.."

configs=$(grep -oE '^    \("[a-z0-9_]+"' reference/gen_lookup.py | grep -oE '[a-z0-9_]+')
for name in $configs; do
    if [[ ! -s "tests/fixtures/lookup_${name}.tsv" ]]; then
        echo "Missing lookup fixtures, generating them with symspellpy (about 2 minutes)..."
        "${PIXI_EXE:-pixi}" run -e ref ref lookup
        exit 0
    fi
done
