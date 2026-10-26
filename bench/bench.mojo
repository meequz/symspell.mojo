"""Benchmarks symspell on the same data as bench/bench_symspellpy.py.

Usage (see bench/run.sh, which drives all modes):
    bench timings [--quick]      lookup, build, open, compound, segmentation timings
    bench rss-build <dict>       resident memory after loading and building
    bench rss-open <index>       resident memory after opening a saved index
    bench save <dict> <index>    builds a dictionary (distance 2) and saves it
    bench lookups                only the English lookup timings
Prints one JSON object per line on stdout.
"""

from std.ffi import c_int, external_call
from std.math import ceil
from std.os import makedirs, remove
from std.os.path import exists, getsize
from std.sys import argv
from std.time import perf_counter_ns

from symspell import (
    LookupScratch,
    SymSpell,
    SymSpellBuilder,
    SymSpellConfig,
    Verbosity,
)

comptime DATA = "bench/data/"
comptime EN_DICT = "data/frequency_dictionary_en_82_765.txt"
comptime EN_BIGRAMS = "data/frequency_bigramdictionary_en_243_342.txt"
comptime NOISY_1000 = "tests/fixtures/symspellpy/noisy_query_en_1000.txt"
comptime TMP = "build/tmp/"


def now() -> Int:
    return Int(perf_counter_ns())


def read_lines(path: String) raises -> List[String]:
    var out = List[String]()
    with open(path, "r") as f:
        for line in f.read().split("\n"):
            if line.byte_length() > 0:
                out.append(String(line))
    return out^


def resident_mb() raises -> Float64:
    with open("/proc/self/statm", "r") as f:
        return Float64(Int(f.read().split(" ")[1])) * 4096.0 / 1048576.0


def peak_mb() raises -> Float64:
    with open("/proc/self/status", "r") as f:
        for line in f.read().split("\n"):
            if line.startswith("VmHWM:"):
                var parts = line.split()
                return Float64(Int(parts[1])) / 1024.0
    return -1.0


def drop_from_page_cache(path: String) raises:
    """Asks the kernel to evict a file's pages (POSIX_FADV_DONTNEED), for cold opens.
    """
    var c_path = path
    var fd = external_call["open", c_int, num_fixed_args=2](
        c_path.as_c_string_span(), c_int(0), c_int(0)
    )
    if fd < 0:
        raise Error("cannot open ", path)
    _ = external_call["fdatasync", c_int](fd)
    _ = external_call["posix_fadvise", c_int](fd, Int64(0), Int64(0), c_int(4))
    _ = external_call["close", c_int](fd)


def emit(key: String, value: Float64):
    print('{"', key, '": ', value, "}", sep="")


def emit_stats(key: String, var samples: List[Int]):
    sort(samples)
    var total = 0
    for s in samples:
        total += s
    var n = len(samples)
    var p99 = min(n - 1, Int(ceil(Float64(n) * 0.99)) - 1)
    print(
        '{"',
        key,
        '": {"mean_us": ',
        Float64(total) / Float64(n) / 1000.0,
        ', "p50_us": ',
        Float64(samples[n // 2]) / 1000.0,
        ', "p99_us": ',
        Float64(samples[p99]) / 1000.0,
        ', "n": ',
        n,
        "}}",
        sep="",
    )


def load(path: String, max_distance: Int) raises -> SymSpell:
    var builder = SymSpellBuilder(SymSpellConfig(max_distance))
    builder.load_dictionary(path)
    return builder^.build()


def time_lookups(
    index: SymSpell, queries: List[String], verbosity: Verbosity, med: Int
) raises -> List[Int]:
    var scratch = LookupScratch()
    var samples = List[Int](capacity=len(queries))
    for q in queries:
        var start = now()
        _ = index.lookup(q, verbosity, med, scratch=scratch)
        samples.append(now() - start)
    return samples^


def timings(quick: Bool) raises:
    if not exists(TMP):
        makedirs(TMP)
    var queries = read_lines(String(DATA, "queries_10k.txt"))
    if quick:
        queries.resize(300, String())

    # Build: parse + build, median of 3 (5 for build alone).
    var parse_times = List[Int]()
    var build_times = List[Int]()
    for _ in range(1 if quick else 5):
        var t0 = now()
        var builder = SymSpellBuilder()
        builder.load_dictionary(EN_DICT)
        var t1 = now()
        var index = builder^.build()
        var t2 = now()
        parse_times.append(t1 - t0)
        build_times.append(t2 - t1)
        _ = index.word_count()
    sort(parse_times)
    sort(build_times)
    emit("parse_en_s", Float64(parse_times[len(parse_times) // 2]) / 1e9)
    emit(
        "build_en_s",
        Float64(
            build_times[len(build_times) // 2]
            + parse_times[len(parse_times) // 2]
        )
        / 1e9,
    )

    var index = load(EN_DICT, 2)
    var path = String(TMP, "bench_en.idx")
    var t0 = now()
    index.save(path)
    emit("save_en_s", Float64(now() - t0) / 1e9)
    emit("index_en_mb", Float64(getsize(path)) / 1048576.0)
    for verify in [True, False]:
        var suffix = "" if verify else "_no_checksum"
        var warm = List[Int]()
        var cold = List[Int]()
        for _ in range(1 if quick else 5):
            drop_from_page_cache(path)
            var start = now()
            var a = SymSpell.open(path, verify_checksum=verify)
            cold.append(now() - start)
            _ = a.word_count()
            start = now()
            var b = SymSpell.open(path, verify_checksum=verify)
            warm.append(now() - start)
            _ = b.word_count()
        sort(cold)
        sort(warm)
        emit(
            String("open_cold", suffix, "_ms"),
            Float64(cold[len(cold) // 2]) / 1e6,
        )
        emit(
            String("open_warm", suffix, "_ms"),
            Float64(warm[len(warm) // 2]) / 1e6,
        )

    for med in [1, 2]:
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            var subset = queries.copy() if v != Verbosity.ALL else List[String](
                queries[: min(3000, len(queries))]
            )
            emit_stats(
                String("lookup_", v, "_d", med),
                time_lookups(index, subset, v, med),
            )

    emit_batch(index, queries)

    var noisy = List[String]()
    for line in read_lines(NOISY_1000):
        var parts = line.split()
        if len(parts) >= 2:
            noisy.append(String(parts[0]))
    var scratch = LookupScratch()
    var start = now()
    var total = 0
    for q in noisy:
        total += len(index.lookup(q, Verbosity.CLOSEST, 2, scratch=scratch))
    emit("noisy_1000_closest_ms", Float64(now() - start) / 1e6)
    emit("noisy_1000_results", Float64(total))

    var builder = SymSpellBuilder()
    builder.load_dictionary(EN_DICT)
    builder.load_bigram_dictionary(EN_BIGRAMS)
    var full = builder^.build()
    var sentences = read_lines(String(DATA, "sentences.txt"))
    sentences.resize(20 if quick else 200, String())
    var samples = List[Int]()
    for s in sentences:
        start = now()
        _ = full.lookup_compound(s, 2)
        samples.append(now() - start)
    var sum = 0
    for x in samples:
        sum += x
    emit("compound_ms", Float64(sum) / Float64(len(samples)) / 1e6)
    var phrases = read_lines(String(DATA, "segmentation.txt"))
    phrases.resize(5 if quick else 50, String())
    for med in [0, 2]:
        sum = 0
        for p in phrases:
            start = now()
            _ = full.word_segmentation(p, med)
            sum += now() - start
        emit(
            String("segmentation_d", med, "_ms"),
            Float64(sum) / Float64(len(phrases)) / 1e6,
        )

    start = now()
    var index3 = load(EN_DICT, 3)
    emit("build_en_d3_s", Float64(now() - start) / 1e9)
    for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
        var subset = List[String](
            queries[: min(2000 if v != Verbosity.ALL else 500, len(queries))]
        )
        emit_stats(
            String("lookup_", v, "_d3"), time_lookups(index3, subset, v, 3)
        )

    if not quick:
        start = now()
        var large = load(String(DATA, "large_dict.txt"), 2)
        emit("build_large_s", Float64(now() - start) / 1e9)
        var large_path = String(TMP, "bench_large.idx")
        large.save(large_path)
        emit("index_large_mb", Float64(getsize(large_path)) / 1048576.0)
        drop_from_page_cache(large_path)
        start = now()
        var trusted = SymSpell.open(large_path, trusted=True)
        emit("open_cold_large_trusted_ms", Float64(now() - start) / 1e6)
        _ = trusted.word_count()
        drop_from_page_cache(large_path)
        start = now()
        var opened = SymSpell.open(large_path)
        emit("open_cold_large_ms", Float64(now() - start) / 1e6)
        var large_queries = read_lines(String(DATA, "large_queries.txt"))
        emit_stats(
            "lookup_large_TOP_d2",
            time_lookups(opened, large_queries, Verbosity.TOP, 2),
        )
        emit_stats(
            "lookup_large_CLOSEST_d2",
            time_lookups(opened, large_queries, Verbosity.CLOSEST, 2),
        )
        remove(large_path)
    remove(path)


def emit_batch(index: SymSpell, queries: List[String]) raises:
    """Batch throughput (lookups per second) for 1, 2 and all logical CPUs."""
    for threads in [1, 2, 4]:
        var best = 0.0
        for _ in range(3):
            var start = now()
            _ = index.lookup_batch(queries, Verbosity.TOP, 2, threads=threads)
            best = max(
                best, Float64(len(queries)) / (Float64(now() - start) / 1e9)
            )
        emit(String("batch_TOP_d2_threads_", threads, "_per_s"), best)


def lookups() raises:
    """Only the English lookup timings, for quick before/after comparisons."""
    var queries = read_lines(String(DATA, "queries_10k.txt"))
    var index = load(EN_DICT, 2)
    for med in [1, 2]:
        for v in [Verbosity.TOP, Verbosity.CLOSEST, Verbosity.ALL]:
            var subset = queries.copy() if v != Verbosity.ALL else List[String](
                queries[:3000]
            )
            emit_stats(
                String("lookup_", v, "_d", med),
                time_lookups(index, subset, v, med),
            )
    emit_batch(index, queries)
    var start = now()
    var builds = 3
    for _ in range(builds):
        _ = load(EN_DICT, 2).word_count()
    emit("load_and_build_en_s", Float64(now() - start) / 1e9 / Float64(builds))


def rss_build(path: String) raises:
    var before = resident_mb()
    var index = load(path, 2)
    emit("rss_build_mb", resident_mb() - before)
    emit("peak_mb", peak_mb())
    _ = index.word_count()


def rss_open(path: String) raises:
    var before = resident_mb()
    var index = SymSpell.open(path)
    var after_open = resident_mb()
    # Touch the pages a typical workload uses.
    var scratch = LookupScratch()
    for q in read_lines(String(DATA, "queries_10k.txt")):
        _ = index.lookup(q, Verbosity.CLOSEST, 2, scratch=scratch)
    emit("rss_open_mb", after_open - before)
    emit("rss_open_after_lookups_mb", resident_mb() - before)
    _ = index.word_count()  # keep the index alive until here


def main() raises:
    var args = argv()
    var mode = String(args[1]) if len(args) > 1 else String("timings")
    if mode == "timings":
        timings(len(args) > 2 and args[2] == "--quick")
    elif mode == "lookups":
        lookups()
    elif mode == "save":
        load(String(args[2]), 2).save(String(args[3]))
    elif mode == "rss-build":
        rss_build(String(args[2]))
    elif mode == "rss-open":
        rss_open(String(args[2]))
    else:
        raise Error("unknown mode ", mode)
