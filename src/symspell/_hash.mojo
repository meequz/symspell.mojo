"""A fast 64-bit hash of codepoint sequences.

Used for the deletes index and the term table. Collisions are harmless:
every hit is verified against the actual codepoints (docs/DECISIONS.md, D3).
The hash is part of the on-disk format, so changing it needs a format version bump.

It is split into `hash_start`, `hash_step` and `hash_finish`, so code can hash
a sequence while it builds it. The length is mixed in at the end, so a
depth-first walk over deletes can share the work of common prefixes.
"""


def _mix(x: UInt64) -> UInt64:
    """The MurmurHash3 64-bit finalizer."""
    var h = x
    h ^= h >> 33
    h *= 0xFF51AFD7ED558CCD
    h ^= h >> 33
    h *= 0xC4CEB9FE1A85EC53
    h ^= h >> 33
    return h


comptime _SEED: UInt64 = 0x9E3779B97F4A7C15


@inline(.always)
def hash_start() -> UInt64:
    return _SEED


@inline(.always)
def hash_step(h: UInt64, cp: UInt32) -> UInt64:
    var x = (h ^ UInt64(cp)) * 0x100000001B3
    return (x << 23) | (x >> 41)


@inline(.always)
def hash_finish(h: UInt64, length: Int) -> UInt64:
    """Never returns 0, which marks an empty slot."""
    var m = _mix(h ^ (UInt64(length) * _SEED))
    return m if m != 0 else 1


def hash_codepoints(text: ImmSpan[UInt32, _]) -> UInt64:
    """Hashes a codepoint sequence."""
    var h = hash_start()
    var p = text.unsafe_ptr()
    for i in range(len(text)):
        h = hash_step(h, p[unsafe_offset=i])
    return hash_finish(h, len(text))
