"""Running work on OS threads through pthreads (Linux and macOS).

Mojo 1.2 moved `parallelize` out of the stdlib into the large `max` package
(docs/DECISIONS.md, D4). This module is the small replacement: it starts one
pthread per job and joins them all. Each worker is a C-ABI function that gets
the address of its job.
"""

from std.ffi import c_int, external_call

comptime WorkerFn = def(Int) abi("C") thin -> Int
"""A thread entry point: receives a job's address, returns 0."""


def run_threads(worker: WorkerFn, job_addresses: List[Int]) raises:
    """Runs `worker(address)` for every address on its own thread and waits.

    Raises if a thread cannot be started; threads already started are still
    joined first.
    """
    var handles = List[UInt64](length=len(job_addresses), fill=0)
    var started = 0
    var failed = False
    for i in range(len(job_addresses)):
        var rc = external_call["pthread_create", c_int](
            handles.unsafe_ptr().unsafe_offset(i),
            Int(0),
            worker,
            job_addresses[i],
        )
        if rc != 0:
            failed = True
            break
        started += 1
    for i in range(started):
        _ = external_call["pthread_join", c_int](handles[i], Int(0))
    if failed:
        raise Error("could not start a thread")
