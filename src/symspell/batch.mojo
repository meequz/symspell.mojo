"""`lookup_batch`: many lookups spread over threads.

The index is read-only, so threads share it safely. Each thread gets a
contiguous slice of the phrases and its own `LookupScratch`, and writes only
its own result slots.
"""

from std.sys.info import num_logical_cores

from symspell._threads import run_threads
from symspell.index import SymSpell
from symspell.scratch import LookupScratch
from symspell.suggestion import Suggestion
from symspell.tokenize import TokenPredicate
from symspell.verbosity import Verbosity


struct _BatchJob(Movable):
    """What one thread needs. Addresses point into the caller's frame."""

    var index: Int
    var phrases: Int
    var results: Int
    var start: Int
    var end: Int
    var verbosity: Verbosity
    var max_edit_distance: Int
    var include_unknown: Bool
    var ignore_token: Optional[TokenPredicate]
    var transfer_casing: Bool
    var error: String

    def __init__(
        out self,
        index: Int,
        phrases: Int,
        results: Int,
        start: Int,
        end: Int,
        verbosity: Verbosity,
        max_edit_distance: Int,
        include_unknown: Bool,
        ignore_token: Optional[TokenPredicate],
        transfer_casing: Bool,
    ):
        self.index = index
        self.phrases = phrases
        self.results = results
        self.start = start
        self.end = end
        self.verbosity = verbosity
        self.max_edit_distance = max_edit_distance
        self.include_unknown = include_unknown
        self.ignore_token = ignore_token
        self.transfer_casing = transfer_casing
        self.error = String()


def _run_job(mut job: _BatchJob):
    ref index = ImmPointer[SymSpell, ImmUntrackedOrigin](
        unsafe_from_address=job.index
    )[]
    var phrases = ImmPointer[String, ImmUntrackedOrigin](
        unsafe_from_address=job.phrases
    )
    var results = MutPointer[List[Suggestion], MutUntrackedOrigin](
        unsafe_from_address=job.results
    )
    var scratch = LookupScratch()
    for i in range(job.start, job.end):
        try:
            results[unsafe_offset=i] = index.lookup(
                phrases[unsafe_offset=i],
                job.verbosity,
                job.max_edit_distance,
                job.include_unknown,
                job.ignore_token,
                job.transfer_casing,
                scratch=scratch,
            )
        except e:
            # Errors cannot cross the thread boundary; report the first one.
            if job.error.byte_length() == 0:
                job.error = String(e)


def _worker(address: Int) abi("C") -> Int:
    _run_job(
        MutPointer[_BatchJob, MutUntrackedOrigin](unsafe_from_address=address)[]
    )
    return 0


def lookup_batch(
    index: SymSpell,
    phrases: ImmSpan[String, _],
    verbosity: Verbosity,
    max_edit_distance: Optional[Int],
    include_unknown: Bool,
    ignore_token: Optional[TokenPredicate],
    transfer_casing: Bool,
    threads: Int,
) raises -> List[List[Suggestion]]:
    """See `SymSpell.lookup_batch`."""
    var med = max_edit_distance.or_else(
        index.config().max_dictionary_edit_distance
    )
    if med > index.config().max_dictionary_edit_distance:
        raise Error("distance too large")
    var n = len(phrases)
    var results = List[List[Suggestion]](capacity=n)
    for _ in range(n):
        results.append(List[Suggestion]())
    if n == 0:
        return results^
    var count = threads if threads > 0 else num_logical_cores()
    count = max(1, min(count, n))
    var jobs = List[_BatchJob](capacity=count)
    for t in range(count):
        jobs.append(
            _BatchJob(
                Int(Pointer(to=index)),
                Int(phrases.unsafe_ptr()),
                Int(results.unsafe_ptr()),
                t * n // count,
                (t + 1) * n // count,
                verbosity,
                med,
                include_unknown,
                ignore_token,
                transfer_casing,
            )
        )
    if count == 1:
        _run_job(jobs[0])
    else:
        var addresses = List[Int](capacity=count)
        for t in range(count):
            addresses.append(Int(jobs.unsafe_ptr().unsafe_offset(t)))
        run_threads(_worker, addresses)
    for t in range(count):
        if jobs[t].error.byte_length() > 0:
            raise Error(jobs[t].error)
    return results^
