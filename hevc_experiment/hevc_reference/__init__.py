"""Reference components for the FPGA-oriented HEVC experiment.

The package separates deterministic byte/integer logic from the external x265
quality oracle and image I/O. RTL tests should import these small modules.
"""

from .annexb import NalUnit, annexb_nals, build_annexb
from .radio import (
    PACKET_HEADER,
    PacketHeader,
    ParsedPacket,
    RadioPacket,
    build_packet,
    packetize,
    parse_packet,
    reassemble,
    simulate_loss,
)

__all__ = [
    "NalUnit", "PACKET_HEADER", "PacketHeader", "ParsedPacket",
    "RadioPacket", "annexb_nals",
    "build_annexb", "build_packet", "packetize", "parse_packet",
    "reassemble", "simulate_loss",
]
