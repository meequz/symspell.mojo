"""A fast 64-bit hash of codepoint sequences.

Used for the deletes index and the term table. Collisions are harmless:
every hit is verified against the actual codepoints (docs/DECISIONS.md, D3).
The hash is part of the on-disk format, so changing it needs a format version bump.
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


def hash_codepoints(text: ImmSpan[UInt32, _]) -> UInt64:
    """Hashes a codepoint sequence. Never returns 0, which marks an empty slot.
    """
    var h: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(len(text))
    for cp in text:
        h = (h ^ UInt64(cp)) * 0x100000001B3
        h = (h << 23) | (h >> 41)
    h = _mix(h)
    return h if h != 0 else 1
