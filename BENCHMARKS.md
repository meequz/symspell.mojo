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
- Build and load: the median of 3 to 5 runs. "Cold cache" means the file was dropped from the OS page
  cache first (`posix_fadvise(DONTNEED)`).
- Memory: the increase of resident memory (RSS), each measured in a fresh process.
- Mojo: `lookup` runs with a reused `LookupScratch`; `lookup_batch` with 1, 2 and 4 threads.
  Python has no batch API, so its sequential rate is shown.

Reproduce with `pixi run bench`. It writes raw results to `bench/results/` and prints these tables.

## Results

### English dictionary (82,834 words, max edit distance 2, prefix length 7)

| Metric | symspellpy | symspell (Mojo) | Mojo is |
|---|---|---|---|
| Build from the text file | 1.75 s | 0.42 s | 4.1× |
| Load a saved index (Python: pickle; Mojo: `open`, cold cache) | 0.86 s | 0.05 s | 17.8× |
| Load a saved index, warm cache | – | 0.03 s | – |
| Saved index size | 5.3 MB | 24 MB | 0.2× |
| Memory after building (RSS increase) | 124 MB | 51 MB | 2.4× |
| Memory after loading a saved index and 10k lookups | 151 MB | 26 MB | 5.8× |
| `lookup` TOP, distance 1 (mean) | 15.1 µs | 2.0 µs | 7.6× |
| `lookup` CLOSEST, distance 1 (mean) | 15.6 µs | 1.9 µs | 8.1× |
| `lookup` ALL, distance 1 (mean) | 28.9 µs | 3.5 µs | 8.4× |
| `lookup` TOP, distance 2 (mean) | 39.5 µs | 4.9 µs | 8.1× |
| `lookup` CLOSEST, distance 2 (mean) | 38.1 µs | 5.2 µs | 7.4× |
| `lookup` ALL, distance 2 (mean) | 328 µs | 41.1 µs | 8.0× |
| `lookup` TOP, distance 3 (mean) | 53.6 µs | 6.8 µs | 7.9× |
| `lookup` CLOSEST, distance 3 (mean) | 54.7 µs | 7.7 µs | 7.1× |
| `lookup` ALL, distance 3 (mean) | 3414 µs | 462 µs | 7.4× |
| `lookup` TOP, distance 2, p50 | 20.3 µs | 2.9 µs | 6.9× |
| `lookup` TOP, distance 2, p99 | 298 µs | 33.7 µs | 8.8× |
| symspellpy's 1000 noisy queries, CLOSEST | 54.9 ms | 8.95 ms | 6.1× |
| `lookup_batch` TOP d2, 1 thread(s) (Python: sequential) | 25k/s | 204k/s | 8.1× |
| `lookup_batch` TOP d2, 2 thread(s) (Python: sequential) | 25k/s | 398k/s | 15.7× |
| `lookup_batch` TOP d2, 4 thread(s) (Python: sequential) | 25k/s | 521k/s | 20.6× |
| `lookup_compound`, per sentence | 3.03 ms | 0.38 ms | 8.0× |
| `word_segmentation`, distance 0, per phrase | 1.83 ms | 0.50 ms | 3.6× |
| `word_segmentation`, distance 2, per phrase | 49.7 ms | 5.57 ms | 8.9× |
| Build with max edit distance 3 | 3.54 s | 0.78 s | 4.5× |

### Large synthetic dictionary (1,200,000 words, distance 2)

| Metric | symspellpy | symspell (Mojo) | Mojo is |
|---|---|---|---|
| Build from the text file | 30.9 s | 7.67 s | 4.0× |
| Memory after building (RSS increase) | 1178 MB | 490 MB | 2.4× |
| Peak memory while building (Mojo) | – | 908 MB | – |
| Saved index size | – | 329 MB | – |
| `open`, cold cache, validated | – | 774.0 ms | – |
| `open`, cold cache, `trusted=True` | – | 0.17 ms | – |
| `lookup` TOP, distance 2 (mean) | 82.8 µs | 11.8 µs | 7.0× |
| `lookup` CLOSEST, distance 2 (mean) | 83.6 µs | 11.9 µs | 7.0× |

## Targets

| Target | Result |
|---|---|
| `lookup` at least 10× faster | **Missed: 7–9×** (mean), 8× for batch on 1 thread, 16–21× on 2–4 threads. |
| Build at least 10× faster | **Missed: about 4×.** |
| RAM at most ¼ of symspellpy | **Met for a loaded index** (26 MB against 151 MB, 17%). **Missed right after building** in the same process (51 MB against 124 MB, 41%). |
| `open()` of the English index under 50 ms | **Met:** 25 ms warm, 48 ms cold (with full validation and checksum); 19 ms and 38 ms without the checksum. |

## Notes

- **Where lookup time goes.** A `TOP` lookup at distance 2 visits about 8 candidates and 41
  postings. The English index (24 MB) is larger than the CPU cache, so most of the remaining time is
  waiting for memory, which prefetching only partly hides. The same lookup on a dictionary that fits
  in the cache takes about 1.4 µs. See docs/DECISIONS.md, D19, for what was measured and changed.
- **Build** is a one-time cost. The intended workflow is build once, `save()`, then `open()`: opening
  the saved English index is about 18× faster than symspellpy loading its pickle, and 40–60× faster
  than building.
- **Index size.** The saved index (24 MB) is larger than symspellpy's pickle (5.3 MB, compressed),
  because it is laid out to be memory-mapped and used without parsing or decompression. The same
  layout is what keeps memory low after loading.
- **Memory right after building** includes the builder's freed memory that the allocator keeps for
  reuse (`malloc_trim` does not release it). A long-running process should build once, save, and
  open the file; a loaded index uses 26 MB.
- **`word_segmentation` at distance 0** gains less (3.6×): it makes about 1,000 very small exact
  lookups per phrase, where fixed per-call costs dominate on both sides.
- **4 threads** give about 2.5× over 1 thread on this machine, which has 2 physical cores.
- **Large dictionary.** Opening the 329 MB index with full validation reads the whole file (774 ms
  cold, mostly disk). With `trusted=True` it takes 0.2 ms, because pages then load lazily on first use.
