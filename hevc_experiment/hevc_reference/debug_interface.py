"""Reference contract for the FPGA-to-ESP32 debug interface.

This module does not emulate SPI timing. It defines the byte/nibble ordering,
register addresses and portable snapshot image shared by Python, RTL and the
ESP32 firmware. All multi-byte register values are little-endian.
"""

from __future__ import annotations

from dataclasses import dataclass, fields
import struct


DEBUG_ID = int.from_bytes(b"HEVC", "little")
DEBUG_ABI_VERSION = 1
SNAPSHOT_MAGIC = b"HDBG"
SNAPSHOT_STRUCT = struct.Struct("<4sHH14I")

# 32-bit SPI register map. Reads are from the live bank unless SNAPSHOT_SELECT
# is set, in which case the frozen shadow bank is exposed atomically.
REG_DEBUG_ID = 0x0000
REG_ABI_VERSION = 0x0004
REG_CONTROL = 0x0008
REG_STATUS = 0x000C
REG_HOST_PACKET_COUNT = 0x0010
REG_SNAPSHOT_SEQUENCE = 0x0014
REG_FRAME_ID = 0x0020
REG_PACKET_COUNT = 0x0024
REG_OUTPUT_BYTES = 0x0028
REG_NAL_COUNT = 0x002C
REG_SLICE_INDEX = 0x0030
REG_CTU_X = 0x0034
REG_CTU_Y = 0x0038
REG_INPUT_PIXELS = 0x003C
REG_FIFO_LEVEL = 0x0040
REG_FIFO_HIGH_WATER = 0x0044
REG_ERROR_FLAGS = 0x0048
REG_ASSERT_CODE = 0x004C
REG_TRACE_WRITE_POINTER = 0x0050
REG_TRACE_DROPPED = 0x0054
REG_MEMORY_WINDOW_SELECT = 0x0060
REG_MEMORY_WINDOW_ADDRESS = 0x0064
REG_MEMORY_WINDOW_DATA = 0x0068

CONTROL_SOFT_RESET = 1 << 0
CONTROL_CAPTURE_SNAPSHOT = 1 << 1
CONTROL_SNAPSHOT_SELECT = 1 << 2
CONTROL_TRACE_ENABLE = 1 << 3
CONTROL_CLEAR_ERRORS = 1 << 4

STATUS_BUSY = 1 << 0
STATUS_FRAME_DONE = 1 << 1
STATUS_PACKET_DONE = 1 << 2
STATUS_SNAPSHOT_READY = 1 << 3
STATUS_FIFO_OVERFLOW = 1 << 4
STATUS_ASSERT_FAILED = 1 << 5


def bytes_to_nibbles(data: bytes) -> list[int]:
    """Convert bytes to the 4-bit bus order: high nibble, then low nibble."""

    return [nibble for value in data for nibble in (value >> 4, value & 0x0F)]


def nibbles_to_bytes(nibbles: list[int]) -> bytes:
    """Inverse of :func:`bytes_to_nibbles`, rejecting truncated transfers."""

    if len(nibbles) & 1:
        raise ValueError("4-bit stream ended after only half a byte")
    if any(not 0 <= value <= 0x0F for value in nibbles):
        raise ValueError("4-bit bus value is outside [0, 15]")
    return bytes((nibbles[i] << 4) | nibbles[i + 1] for i in range(0, len(nibbles), 2))


@dataclass(frozen=True)
class DebugSnapshot:
    """Atomic state captured after a programmable number of output packets."""

    snapshot_sequence: int = 0
    frame_id: int = 0
    packet_count: int = 0
    output_bytes: int = 0
    nal_count: int = 0
    slice_index: int = 0
    ctu_x: int = 0
    ctu_y: int = 0
    input_pixels: int = 0
    fifo_level: int = 0
    fifo_high_water: int = 0
    error_flags: int = 0
    assert_code: int = 0
    trace_write_pointer: int = 0

    def to_bytes(self) -> bytes:
        values = [getattr(self, item.name) for item in fields(self)]
        if any(not 0 <= value <= 0xFFFFFFFF for value in values):
            raise ValueError("debug counters must fit unsigned 32-bit registers")
        return SNAPSHOT_STRUCT.pack(
            SNAPSHOT_MAGIC, DEBUG_ABI_VERSION, SNAPSHOT_STRUCT.size, *values
        )

    @classmethod
    def from_bytes(cls, data: bytes) -> "DebugSnapshot":
        if len(data) != SNAPSHOT_STRUCT.size:
            raise ValueError("invalid debug snapshot byte count")
        magic, version, size, *values = SNAPSHOT_STRUCT.unpack(data)
        if magic != SNAPSHOT_MAGIC or version != DEBUG_ABI_VERSION:
            raise ValueError("unsupported debug snapshot format")
        if size != SNAPSHOT_STRUCT.size:
            raise ValueError("debug snapshot size field is inconsistent")
        return cls(*values)
