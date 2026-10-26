"""Read-only memory-mapped files through libc (Linux and macOS).

Mojo's stdlib has no `mmap` (docs/DECISIONS.md, D5). This module is the
only place that calls it.
"""

from std.ffi import c_int, external_call

comptime _O_RDONLY: c_int = 0
comptime _SEEK_END: c_int = 2
comptime _PROT_READ: c_int = 1
comptime _MAP_PRIVATE: c_int = 2  # the same value on Linux and macOS
comptime _MAP_FAILED = -1


def _open_read_only(path: String) raises -> c_int:
    var c_path = path
    var fd = external_call["open", c_int, num_fixed_args=2](
        c_path.as_c_string_span(), _O_RDONLY, c_int(0)
    )
    if fd < 0:
        raise Error(t"cannot open {path}")
    return fd


def _close(fd: c_int):
    _ = external_call["close", c_int](fd)


struct MappedFile(Movable):
    """A whole file mapped read-only into memory. Unmapped when destroyed."""

    var address: Int
    var length: Int

    def __init__(out self, path: String) raises:
        """Maps `path`. Raises if it cannot be opened, is empty or mmap fails.
        """
        var fd = _open_read_only(path)
        var size = Int(external_call["lseek", Int64](fd, Int64(0), _SEEK_END))
        if size <= 0:
            _close(fd)
            raise Error(t"{path} is empty or not a regular file")
        var address = external_call["mmap", Int](
            Int(0), size, _PROT_READ, _MAP_PRIVATE, fd, Int64(0)
        )
        _close(fd)  # the mapping stays valid after closing
        if address == _MAP_FAILED or address == 0:
            raise Error(t"mmap failed for {path}")
        self.address = address
        self.length = size

    def __deinit__(deinit self):
        _ = external_call["munmap", c_int](self.address, self.length)

    def bytes(self) -> ImmSpan[UInt8, ImmUntrackedOrigin]:
        """The mapped bytes. Valid while this object is alive."""
        return ImmSpan[UInt8, ImmUntrackedOrigin](
            unsafe_ptr=ImmPointer[UInt8, ImmUntrackedOrigin](
                unsafe_from_address=self.address
            ),
            length=self.length,
        )
