# Benchmarks

symspell (this library, Mojo) against symspellpy 6.10.0 with editdistpy 0.4.0 (Python), on the
same machine, the same data and the same parameters. Higher "Mojo is" means better for Mojo.

## Setup

- Machine: Intel Core i5-4200H (2 cores, 4 threads, up to 3.4 GHz), 15 GB RAM.
- OS: Linux Mint 21, Linux 6.8, x86-64.
- Mojo 1.2.0; Python 3.13.17.
- symspellpy uses `DistanceAlgorithm.DAMERAU_OSA_FAST` (editdistpy), its fastest setting. Its
  default pure-Python comparer is slower still (for example 62 µs instead of 40 µs for `TOP`).
- Date: 2026-10-26. A desktop machine with other programs open (load average 1 to 3), so expect
  about ±10% noise between runs.

## Method

- Data (`bench/gen_data.py`, fixed seeds): symspellpy's English dictionary (82,834 words) and bigrams;
  10,000 queries (30% correct words, 40% one edit, 30% two edits); 200 noisy sentences; 100 phrases
  without spaces; a synthetic 1.2M-word dictionary of an inflected language (Belarusian-like Cyrillic
  stems with 24 endings, Zipf counts) and 5,000 queries for it.
- `lookup`: each query timed on its own; mean, median (p50) and 99th percentile (p99). `ALL` uses the
  first 3,000 queries (500 at distance 3), distance 3 uses 2,000.
- Every timing is the median of 3 full runs of both suites, alternating the two libraries so both
  see the same machine load (`BENCH_RUNS=3 pixi run bench`).
- Build and load: within a run, the median of 3 to 5 builds. A later build reuses memory the first
  one freed, so "first one in a new process" is shown too. "Cold cache" means the file was dropped from the OS page
  cache first (`posix_fadvise(DONTNEED)`).
- Memory: the increase of resident memory (RSS), each measured in a fresh process.
- Mojo: `lookup` runs with a reused `LookupScratch`; `lookup_batch` with 1, 2 and 4 threads.
  `build()` uses all 4 logical cores (its default); symspellpy builds on one.
  Python has no batch API, so its sequential rate is shown.

Reproduce with `pixi run bench`. It writes raw results to `bench/results/` and prints these tables.

## Results

### English dictionary (82,834 words, max edit distance 2, prefix length 7)

| Metric | symspellpy | symspell (Mojo) | Mojo is |
|---|---|---|---|
| Build from the text file | 1.87 s | 0.17 s | 10.8× |
| Build, first one in a new process | 1.88 s | 0.19 s | 9.7× |
| Load a saved index (Python: pickle; Mojo: `open`, cold cache) | 0.90 s | 0.05 s | 19.8× |
| Load a saved index, warm cache | – | 0.03 s | – |
| Saved index size | 5.3 MB | 24 MB | 0.2× |
| Memory after building (RSS increase) | 124 MB | 52 MB | 2.4× |
| Memory after loading a saved index and 10k lookups | 152 MB | 26 MB | 5.9× |
| `lookup` TOP, distance 1 (mean) | 16.6 µs | 1.6 µs | 10.5× |
| `lookup` CLOSEST, distance 1 (mean) | 17.1 µs | 1.8 µs | 9.3× |
| `lookup` ALL, distance 1 (mean) | 31.6 µs | 3.0 µs | 10.6× |
| `lookup` TOP, distance 2 (mean) | 40.4 µs | 3.8 µs | 10.5× |
| `lookup` CLOSEST, distance 2 (mean) | 41.4 µs | 4.2 µs | 9.8× |
| `lookup` ALL, distance 2 (mean) | 360 µs | 29.9 µs | 12.1× |
| `lookup` TOP, distance 3 (mean) | 59.7 µs | 4.8 µs | 12.5× |
| `lookup` CLOSEST, distance 3 (mean) | 58.8 µs | 5.2 µs | 11.3× |
| `lookup` ALL, distance 3 (mean) | 3769 µs | 322 µs | 11.7× |
| `lookup` TOP, distance 2, p50 | 20.8 µs | 2.3 µs | 9.0× |
| `lookup` TOP, distance 2, p99 | 293 µs | 26.6 µs | 11.0× |
| symspellpy's 1000 noisy queries, CLOSEST | 66.4 ms | 6.85 ms | 9.7× |
| `lookup_batch` TOP d2, 1 thread(s) (Python: sequential) | 25k/s | 274k/s | 11.1× |
| `lookup_batch` TOP d2, 2 thread(s) (Python: sequential) | 25k/s | 522k/s | 21.1× |
| `lookup_batch` TOP d2, 4 thread(s) (Python: sequential) | 25k/s | 662k/s | 26.7× |
| `lookup_compound`, per sentence | 3.34 ms | 0.30 ms | 11.1× |
| `word_segmentation`, distance 0, per phrase | 2.10 ms | 0.58 ms | 3.6× |
| `word_segmentation`, distance 2, per phrase | 54.4 ms | 4.71 ms | 11.6× |
| Build with max edit distance 3 | 3.79 s | 0.29 s | 12.9× |

### Large synthetic dictionary (1,200,000 words, distance 2)

| Metric | symspellpy | symspell (Mojo) | Mojo is |
|---|---|---|---|
| Build from the text file | 32.4 s | 3.48 s | 9.3× |
| Memory after building (RSS increase) | 1177 MB | 614 MB | 1.9× |
| Peak memory while building (Mojo) | – | 1005 MB | – |
| Saved index size | – | 329 MB | – |
| `open`, cold cache, validated | – | 748.1 ms | – |
| `open`, cold cache, `trusted=True` | – | 0.18 ms | – |
| `lookup` TOP, distance 2 (mean) | 84.4 µs | 8.0 µs | 10.5× |
| `lookup` CLOSEST, distance 2 (mean) | 82.9 µs | 8.9 µs | 9.3× |

## Targets

| Target | Result |
|---|---|
| `lookup` at least 10× faster | **Mostly met:** 10.5–12.5× for `TOP` and `ALL` at distances 1–3. **Just missed for `CLOSEST`** at distances 1 and 2 (9.3× and 9.8×), and for the median (p50) `TOP` lookup (9.0×). Batch: 11× on 1 thread, 21–27× on 2–4 threads. |
| Build at least 10× faster | **Met on 4 threads:** 10.8× (9.7× for the first build in a process). On 1 thread: 0.22 s, about 8.5×. |
| RAM at most ¼ of symspellpy | **Met for a loaded index** (26 MB against 152 MB, 17%). **Missed right after building** in the same process (52 MB against 124 MB, 42%). |
| `open()` of the English index under 50 ms | **Met:** 26 ms warm, 46 ms cold, with full validation and checksum; 20 ms and 37 ms without the checksum. |

## Notes

- **Noise.** The machine had other programs running, so single runs vary by about ±10%. The `CLOSEST`
  and p50 results sit within that noise of 10×.
- **Where lookup time goes.** A `TOP` lookup at distance 2 visits about 12 buckets and 22 term
  records. The English index (24 MB) is larger than the CPU cache: about half of a lookup is waiting
  for memory, which prefetching only partly hides. See docs/DECISIONS.md, D19 and D20.
- **Build** uses threads (D20). The result is byte-identical for any thread count. Most build stages
  are limited by memory speed, so 4 threads on this 2-core machine are only about 1.3× faster than 1.
- **Build is still a one-time cost.** The intended workflow is build once, `save()`, then `open()`:
  opening the saved English index is about 20× faster than symspellpy loading its pickle.
- **Index size.** The saved index (24 MB) is larger than symspellpy's pickle (5.3 MB, compressed),
  because it is laid out to be memory-mapped and used without parsing or decompression. The same
  layout is what keeps memory low after loading.
- **Memory right after building** includes memory that the allocator keeps after the builder and the
  build's temporary arrays free it. A long-running process should build once, save, and open the
  file; a loaded index uses 26 MB. For the large dictionary this number grew in phase 6b (490 to
  614 MB), because the faster build uses larger temporary arrays; peak memory stayed about 1 GB.
- **`word_segmentation` at distance 0** gains less (3.6×): it makes about 1,000 very small exact
  lookups per phrase, where fixed per-call costs dominate on both sides.
- **Large dictionary.** Opening the 329 MB index with full validation reads the whole file (750 ms
  cold, mostly disk). With `trusted=True` it takes 0.2 ms, because pages then load lazily on first use.
