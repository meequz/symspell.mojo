#!/usr/bin/env bash
# Runs every example, then checks the CLI on a small file with known mistakes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tmp

for example in examples/quick_start.mojo examples/save_and_open.mojo examples/many_lookups.mojo; do
    echo "=== $example"
    mojo run -I build "$example"
done

echo "=== CLI"
cli=build/bin/symspell
"$cli" build data/frequency_dictionary_en_82_765.txt -o build/tmp/cli.idx
printf 'Ths is a tset.\nNumbers like 42 are skiped.\n' > build/tmp/cli.txt
expected='build/tmp/cli.txt:1:1: Ths -> The
build/tmp/cli.txt:1:10: tset -> set
build/tmp/cli.txt:2:21: skiped -> skipped'
status=0
actual=$("$cli" check build/tmp/cli.txt --index build/tmp/cli.idx) || status=$?
rm -f build/tmp/cli.idx build/tmp/cli.txt
if [[ "$actual" != "$expected" || $status -ne 1 ]]; then
    echo "unexpected CLI output (status $status):"
    echo "$actual"
    exit 1
fi
echo "$actual"
echo "All examples passed."
