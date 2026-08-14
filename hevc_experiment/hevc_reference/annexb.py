"""Deterministic HEVC Annex-B parsing and serialization."""

from __future__ import annotations

from dataclasses import dataclass

START_CODE = b"\x00\x00\x00\x01"
PARAMETER_SET_TYPES = frozenset({32, 33, 34})
VCL_TYPES = frozenset(range(32))


@dataclass(frozen=True)
class NalUnit:
    """NAL payload including its HEVC header but excluding the start code."""

    nal_type: int
    data: bytes

    def __post_init__(self) -> None:
        if not 0 <= self.nal_type <= 63:
            raise ValueError("HEVC NAL type must be in [0, 63]")
        if len(self.data) < 2:
            raise ValueError("HEVC NAL must contain its two-byte header")
        if ((self.data[0] >> 1) & 0x3F) != self.nal_type:
            raise ValueError("NAL type disagrees with the encoded NAL header")


def annexb_nals(bitstream: bytes) -> list[NalUnit]:
    """Parse three- or four-byte Annex-B start codes."""

    starts: list[tuple[int, int]] = []
    position = 0
    while position + 3 <= len(bitstream):
        if bitstream[position:position + 4] == START_CODE:
            starts.append((position, 4))
            position += 4
        elif bitstream[position:position + 3] == b"\x00\x00\x01":
            starts.append((position, 3))
            position += 3
        else:
            position += 1
    output: list[NalUnit] = []
    for index, (start, prefix_bytes) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(bitstream)
        data = bitstream[start + prefix_bytes:end]
        if len(data) >= 2:
            output.append(NalUnit((data[0] >> 1) & 0x3F, data))
    if not output:
        raise ValueError("no Annex-B NAL units found")
    return output


def rbsp_to_ebsp(rbsp: bytes) -> bytes:
    """Insert HEVC emulation-prevention bytes into an RBSP payload."""

    output = bytearray()
    zero_count = 0
    for value in rbsp:
        if zero_count == 2 and value <= 3:
            output.append(3)
            zero_count = 0
        output.append(value)
        zero_count = zero_count + 1 if value == 0 else 0
    return bytes(output)


def hevc_nal_header(nal_type: int, temporal_id_plus1: int = 1) -> bytes:
    """Build a two-byte layer-zero HEVC NAL header."""

    if not 0 <= nal_type <= 63:
        raise ValueError("HEVC NAL type must be in [0, 63]")
    if not 1 <= temporal_id_plus1 <= 7:
        raise ValueError("temporal_id_plus1 must be in [1, 7]")
    return bytes((nal_type << 1, temporal_id_plus1))


def build_annexb_nal(
    nal_type: int,
    rbsp: bytes,
    temporal_id_plus1: int = 1,
) -> bytes:
    """Wrap one RBSP in a four-byte-start-code layer-zero HEVC NAL."""

    return START_CODE + hevc_nal_header(nal_type, temporal_id_plus1) + rbsp_to_ebsp(rbsp)


def build_annexb(nals: list[NalUnit]) -> bytes:
    """Serialize NALs using one four-byte start code per NAL."""

    return b"".join(START_CODE + nal.data for nal in nals)
