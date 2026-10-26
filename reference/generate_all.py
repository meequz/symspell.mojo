"""Regenerates every reference fixture from symspellpy (run: pixi run ref).

All generators use fixed seeds, so the output is reproducible.
Pass generator names to run only some of them, e.g. `pixi run ref distance helpers`.
"""

import sys
import time
from importlib.metadata import version

import gen_compound
import gen_distance
import gen_helpers
import gen_intl_dict
import gen_load
import gen_lookup
import gen_symspellpy_fixtures
import gen_unicode
from _common import log

GENERATORS = {
    "unicode": gen_unicode,
    "intl_dict": gen_intl_dict,
    "symspellpy": gen_symspellpy_fixtures,
    "distance": gen_distance,
    "helpers": gen_helpers,
    "load": gen_load,
    "lookup": gen_lookup,
    "compound": gen_compound,
}
EXPECTED_SYMSPELLPY = "6.10.0"


def main() -> None:
    found = version("symspellpy")
    if found != EXPECTED_SYMSPELLPY:
        sys.exit(f"symspellpy {EXPECTED_SYMSPELLPY} required, found {found}")
    names = sys.argv[1:] or list(GENERATORS)
    for name in names:
        start = time.perf_counter()
        log(f"[{name}]")
        GENERATORS[name].main()
        log(f"[{name}] done in {time.perf_counter() - start:.1f} s")


if __name__ == "__main__":
    main()
