"""Deterministic radio framing, loss simulation and NAL reassembly.

Packet building/parsing/reassembly use integer and byte operations only. The
floating-point probability calculation is confined to the channel simulator
and is not part of the FPGA datapath.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import random
import struct
import zlib

from .annexb import NalUnit, PARAMETER_SET_TYPES, START_CODE, VCL_TYPES

PACKET_MAGIC = b"HR"
PACKET_VERSION = 2
PACKET_HEADER_NO_CRC = struct.Struct(">2sBBHHHHHIBB")
PACKET_HEADER = struct.Struct(">2sBBHHHHHIBBI")

@dataclass(frozen=True)
class RadioPacket:
    raw: bytes
    nal_index: int
    fragment_index: int
    fragment_count: int
    nal_type: int
    parity: bool


@dataclass(frozen=True)
class PacketHeader:
    """Decoded 24-byte big-endian radio header without its CRC field."""

    flags: int
    frame_id: int
    nal_index: int
    fragment_index: int
    fragment_count: int
    payload_bytes: int
    nal_bytes: int
    nal_type: int
    xor_groups: int

    @property
    def parity(self) -> bool:
        return bool(self.flags & 2)


@dataclass(frozen=True)
class ParsedPacket:
    header: PacketHeader
    payload: bytes


def build_packet(
    frame_id: int,
    nal_index: int,
    fragment_index: int,
    fragment_count: int,
    nal_type: int,
    nal_bytes: int,
    payload: bytes,
    parity: bool = False,
    xor_groups: int = 0,
) -> bytes:
    flags = int(nal_type in PARAMETER_SET_TYPES) | (int(parity) << 1)
    header = PACKET_HEADER_NO_CRC.pack(
        PACKET_MAGIC, PACKET_VERSION, flags, frame_id, nal_index,
        fragment_index, fragment_count, len(payload), nal_bytes, nal_type,
        xor_groups,
    )
    checksum = zlib.crc32(header + payload) & 0xFFFFFFFF
    return header + struct.pack(">I", checksum) + payload


def packetize(
    nals: list[NalUnit],
    maximum_packet_bytes: int,
    frame_id: int,
    cached_parameter_sets: bool,
    copies: int,
    xor_groups: int,
    packet_order: str,
) -> tuple[list[RadioPacket], list[NalUnit]]:
    payload_capacity = maximum_packet_bytes - PACKET_HEADER.size
    if payload_capacity < 1:
        raise ValueError("packet maximum cannot hold the radio header")
    packets: list[RadioPacket] = []
    cached: list[NalUnit] = []
    for nal_index, nal in enumerate(nals):
        if cached_parameter_sets and nal.nal_type in PARAMETER_SET_TYPES:
            cached.append(nal)
            continue
        fragment_count = max(1, math.ceil(len(nal.data) / payload_capacity))
        for fragment_index in range(fragment_count):
            start = fragment_index * payload_capacity
            payload = nal.data[start:start + payload_capacity]
            raw = build_packet(
                frame_id, nal_index, fragment_index, fragment_count,
                nal.nal_type, len(nal.data), payload, False, xor_groups,
            )
            packets.append(RadioPacket(
                raw, nal_index, fragment_index, fragment_count, nal.nal_type,
                False,
            ))
        if xor_groups and fragment_count > 1:
            parity_payloads = [bytearray(payload_capacity) for _ in range(xor_groups)]
            used_groups: set[int] = set()
            for fragment_index in range(fragment_count):
                group = fragment_index % xor_groups
                used_groups.add(group)
                start = fragment_index * payload_capacity
                fragment = nal.data[start:start + payload_capacity]
                for index, value in enumerate(fragment):
                    parity_payloads[group][index] ^= value
            for group in sorted(used_groups):
                parity_index = fragment_count + group
                raw = build_packet(
                    frame_id, nal_index, parity_index, fragment_count,
                    nal.nal_type, len(nal.data), bytes(parity_payloads[group]),
                    True, xor_groups,
                )
                packets.append(RadioPacket(
                    raw, nal_index, parity_index, fragment_count, nal.nal_type,
                    True,
                ))
    if packet_order == "round-robin":
        # Spread consecutive fragments of one NAL across other slices. A radio
        # burst then tends to remove one fragment from several repair groups,
        # rather than several fragments from one slice.
        packets.sort(key=lambda packet: (
            packet.fragment_index,
            int(packet.parity),
            packet.nal_index,
        ))
    elif packet_order != "nal":
        raise ValueError("packet order must be nal or round-robin")

    # Whole passes are concatenated instead of adjacent copies, so a short
    # burst is less likely to erase every copy of the same fragment.
    return packets * copies, cached


def parse_packet(raw: bytes, maximum_packet_bytes: int) -> ParsedPacket:
    if not PACKET_HEADER.size <= len(raw) <= maximum_packet_bytes:
        raise ValueError("invalid radio packet length")
    fields = PACKET_HEADER.unpack(raw[:PACKET_HEADER.size])
    magic, version = fields[:2]
    payload_bytes = fields[7]
    expected_crc = fields[-1]
    payload = raw[PACKET_HEADER.size:]
    if magic != PACKET_MAGIC or version != PACKET_VERSION:
        raise ValueError("invalid radio packet format")
    if payload_bytes != len(payload):
        raise ValueError("radio payload length mismatch")
    actual_crc = zlib.crc32(raw[:PACKET_HEADER_NO_CRC.size] + payload) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise ValueError("radio packet CRC mismatch")
    return ParsedPacket(PacketHeader(*fields[2:-1]), payload)


def simulate_loss(
    packets: list[RadioPacket],
    maximum_packet_bytes: int,
    reference_drop_rate: float,
    reference_packet_bytes: int,
    seed: int,
    loss_model: str,
    burst_min_packets: int,
    burst_max_packets: int,
) -> tuple[list[RadioPacket], int, float]:
    rng = random.Random(seed)
    received: list[RadioPacket] = []
    if loss_model == "burst":
        target_drops = min(len(packets), round(reference_drop_rate * len(packets)))
        drop_mask = [False] * len(packets)
        dropped_count = 0
        attempts = 0
        while dropped_count < target_drops and attempts < len(packets) * 100:
            attempts += 1
            start = rng.randrange(len(packets))
            length = rng.randint(burst_min_packets, burst_max_packets)
            for offset in range(length):
                index = start + offset
                if index >= len(packets) or dropped_count >= target_drops:
                    break
                if not drop_mask[index]:
                    drop_mask[index] = True
                    dropped_count += 1
        # Extremely dense masks can exhaust random uncovered starts.
        if dropped_count < target_drops:
            for index in range(len(packets)):
                if not drop_mask[index]:
                    drop_mask[index] = True
                    dropped_count += 1
                    if dropped_count == target_drops:
                        break
        for packet, dropped in zip(packets, drop_mask):
            if not dropped:
                parse_packet(packet.raw, maximum_packet_bytes)
                received.append(packet)
        effective = target_drops / len(packets) if packets else 0.0
        return received, target_drops, effective

    if loss_model not in ("airtime", "fixed"):
        raise ValueError("loss model must be airtime, fixed or burst")
    probabilities: list[float] = []
    for packet in packets:
        probability = reference_drop_rate if loss_model == "fixed" else (
            1.0 - (1.0 - reference_drop_rate) **
            (len(packet.raw) / reference_packet_bytes)
        )
        probabilities.append(probability)
        if rng.random() >= probability:
            # Parsing here models CRC rejection before reassembly.
            parse_packet(packet.raw, maximum_packet_bytes)
            received.append(packet)
    effective = sum(probabilities) / len(probabilities) if probabilities else 0.0
    return received, len(packets) - len(received), effective


def reassemble(
    received: list[RadioPacket],
    cached: list[NalUnit],
    expected_nals: list[NalUnit],
    maximum_packet_bytes: int,
    concealment_nals: list[NalUnit | None] | None = None,
) -> tuple[bytes, int, int, int, int]:
    fragments: dict[int, dict[int, bytes]] = {}
    parity_fragments: dict[int, dict[int, bytes]] = {}
    metadata: dict[int, tuple[int, int, int, int]] = {}
    for packet in received:
        parsed = parse_packet(packet.raw, maximum_packet_bytes)
        header, payload = parsed.header, parsed.payload
        nal_index = header.nal_index
        if header.parity:
            group = header.fragment_index - header.fragment_count
            parity_fragments.setdefault(nal_index, {})[group] = payload
        else:
            fragments.setdefault(nal_index, {})[header.fragment_index] = payload
        metadata[nal_index] = (
            header.nal_type, header.fragment_count, header.nal_bytes,
            header.xor_groups,
        )

    completed: list[tuple[int, NalUnit]] = []
    incomplete_vcl = 0
    complete_vcl = 0
    repaired_vcl = 0
    concealed_vcl = 0
    cached_data = {item.data for item in cached}
    for nal_index, expected in enumerate(expected_nals):
        if expected.nal_type in PARAMETER_SET_TYPES and expected.data in cached_data:
            continue
        if nal_index not in metadata:
            if expected.nal_type in VCL_TYPES:
                incomplete_vcl += 1
                if concealment_nals and concealment_nals[nal_index] is not None:
                    completed.append((nal_index, concealment_nals[nal_index]))
                    concealed_vcl += 1
            continue
        nal_type, fragment_count, nal_bytes, xor_groups = metadata[nal_index]
        parts = fragments.get(nal_index, {})
        parity_by_group = parity_fragments.get(nal_index, {})
        for group, parity_payload in parity_by_group.items():
            members = [
                index for index in range(fragment_count)
                if xor_groups and index % xor_groups == group
            ]
            missing = [index for index in members if index not in parts]
            if len(missing) != 1:
                continue
            recovered = bytearray(parity_payload)
            for member in members:
                if member not in parts:
                    continue
                for index, value in enumerate(parts[member]):
                    recovered[index] ^= value
            missing_index = missing[0]
            recovered_bytes = min(
                len(recovered), nal_bytes - missing_index * len(recovered)
            )
            parts[missing_index] = bytes(recovered[:recovered_bytes])
            if nal_type in VCL_TYPES:
                repaired_vcl += 1
        if len(parts) != fragment_count or any(i not in parts for i in range(fragment_count)):
            if nal_type in VCL_TYPES:
                incomplete_vcl += 1
                if concealment_nals and concealment_nals[nal_index] is not None:
                    completed.append((nal_index, concealment_nals[nal_index]))
                    concealed_vcl += 1
            continue
        nal = NalUnit(nal_type, b"".join(parts[i] for i in range(fragment_count)))
        completed.append((nal_index, nal))
        if nal_type in VCL_TYPES:
            complete_vcl += 1

    # Cached VPS/SPS/PPS are prepended, as they would be by a persistent
    # receiver session or an hvcC/extradata configuration record.
    output = bytearray()
    for nal in cached:
        output += START_CODE + nal.data
    for _, nal in completed:
        output += START_CODE + nal.data
    return (
        bytes(output), complete_vcl, incomplete_vcl, repaired_vcl, concealed_vcl
    )
