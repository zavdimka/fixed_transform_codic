#!/usr/bin/env python3
"""End-to-end radio packet simulation for fixed_transform_codec.py.

The codec path is:
    RGB -> YCbCr420 wrapper -> integer codec -> coefficient bytes
        -> radio packets -> packet loss/CRC -> coefficient decoder -> RGB

A 32x32 or 64x64 radio block groups independently compressed 16x16 codec
macroblocks. This changes loss geometry and transport granularity without
changing transform quality when no packets are lost.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import struct
import zlib

import numpy as np
from PIL import Image

import fixed_transform_codec as codec


PACKET_MAGIC = b"FP"
PACKET_VERSION = 1
# magic, version, flags, frame_id, sequence, radio_block_size, bytes_per_mb,
# first_unit, unit_count, payload_size, frame_width, frame_height, crc32
PACKET_HEADER_NO_CRC = struct.Struct(">2sBBHHBBIHHHH")
PACKET_HEADER = struct.Struct(">2sBBHHBBIHHHHI")


@dataclass(frozen=True)
class RadioConfig:
    bytes_per_mb: int
    packet_bytes: int
    radio_block_size: int
    transform: str
    dc_mode: str
    quality_scale: float
    luma_share: float
    chroma_quality_factor: float
    frame_id: int
    lf_backup_coefficients: int = 1

    @property
    def flags(self) -> int:
        transform_flag = 1 if self.transform == "hadamard" else 0
        dc_flag = 2 if self.dc_mode == "block" else 0
        lf_flags = (self.lf_backup_coefficients & 0x07) << 2
        return transform_flag | dc_flag | lf_flags


@dataclass(frozen=True)
class ParsedPacket:
    frame_id: int
    sequence: int
    flags: int
    radio_block_size: int
    bytes_per_mb: int
    first_unit: int
    unit_count: int
    frame_width: int
    frame_height: int
    payload: bytes


@dataclass
class RadioResult:
    rgb: np.ndarray
    psnr: float
    codec_payload_bytes: int
    wire_bytes: int
    packet_count: int
    dropped_packets: int
    dropped_radio_blocks: int
    low_frequency_recovered_blocks: int
    unrecovered_radio_blocks: int
    redundancy_bytes: int
    crc_failures: int
    min_packet_bytes: int
    max_packet_bytes: int
    average_packet_bytes: float
    units_per_full_packet: int
    arithmetic_saturations: int


def build_packet(
    config: RadioConfig,
    sequence: int,
    first_unit: int,
    unit_count: int,
    frame_width: int,
    frame_height: int,
    payload: bytes,
) -> bytes:
    if len(payload) > 0xFFFF:
        raise ValueError("packet payload exceeds 65535 bytes")
    header_no_crc = PACKET_HEADER_NO_CRC.pack(
        PACKET_MAGIC,
        PACKET_VERSION,
        config.flags,
        config.frame_id,
        sequence,
        config.radio_block_size,
        config.bytes_per_mb,
        first_unit,
        unit_count,
        len(payload),
        frame_width,
        frame_height,
    )
    checksum = zlib.crc32(header_no_crc + payload) & 0xFFFFFFFF
    return header_no_crc + struct.pack(">I", checksum) + payload


def parse_packet(raw: bytes) -> ParsedPacket:
    if len(raw) < PACKET_HEADER.size:
        raise ValueError("truncated radio packet header")
    fields = PACKET_HEADER.unpack(raw[:PACKET_HEADER.size])
    (
        magic,
        version,
        flags,
        frame_id,
        sequence,
        radio_block_size,
        bytes_per_mb,
        first_unit,
        unit_count,
        payload_size,
        frame_width,
        frame_height,
        expected_crc,
    ) = fields
    if magic != PACKET_MAGIC:
        raise ValueError("invalid radio packet magic")
    if version != PACKET_VERSION:
        raise ValueError(f"unsupported packet version {version}")
    if len(raw) != PACKET_HEADER.size + payload_size:
        raise ValueError("radio packet length does not match its header")
    payload = raw[PACKET_HEADER.size:]
    actual_crc = zlib.crc32(raw[:PACKET_HEADER_NO_CRC.size] + payload) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise ValueError("radio packet CRC mismatch")
    return ParsedPacket(
        frame_id=frame_id,
        sequence=sequence,
        flags=flags,
        radio_block_size=radio_block_size,
        bytes_per_mb=bytes_per_mb,
        first_unit=first_unit,
        unit_count=unit_count,
        frame_width=frame_width,
        frame_height=frame_height,
        payload=payload,
    )


def plane_payload_bytes(block_count: int, bits_per_block: int) -> int:
    return (block_count * bits_per_block + 7) // 8


def macroblock_payload_layout(
    bytes_per_mb: int,
    luma_share: float,
) -> tuple[codec.PlaneBudget, codec.PlaneBudget, int, int, int]:
    y_budget, c_budget = codec.make_budgets(bytes_per_mb, luma_share)
    y_bytes = plane_payload_bytes(16, y_budget.bits_per_block)
    c_bytes = plane_payload_bytes(4, c_budget.bits_per_block)
    return y_budget, c_budget, y_bytes, c_bytes, y_bytes + 2 * c_bytes



def hierarchical_dc_widths(
    budget: codec.PlaneBudget,
    block_count: int,
) -> list[int]:
    dc_total_bits = budget.coefficient_bits[0] * block_count
    return codec.allocate_bits(
        dc_total_bits,
        1,
        codec.COEFFICIENT_IMPORTANCE[:block_count],
    )[:block_count]


def low_frequency_bits_per_macroblock(
    config: RadioConfig,
    coefficient_count: int,
) -> int:
    if coefficient_count <= 0:
        return 0
    y_budget, c_budget, _, _, _ = macroblock_payload_layout(
        config.bytes_per_mb, config.luma_share
    )
    y_widths = hierarchical_dc_widths(y_budget, 16)
    c_widths = hierarchical_dc_widths(c_budget, 4)
    return (
        sum(y_widths[:coefficient_count])
        + 2 * sum(c_widths[:coefficient_count])
    )


def extract_low_frequency_backup(
    units: list[bytes],
    config: RadioConfig,
    coefficient_count: int,
) -> bytes:
    """Pack selected hierarchical DC codes from a group of future units."""
    if coefficient_count <= 0 or not units:
        return b""
    y_budget, c_budget, y_bytes, c_bytes, macroblock_bytes = macroblock_payload_layout(
        config.bytes_per_mb, config.luma_share
    )
    plane_layout = (
        (0, y_bytes, hierarchical_dc_widths(y_budget, 16)),
        (y_bytes, c_bytes, hierarchical_dc_widths(c_budget, 4)),
        (y_bytes + c_bytes, c_bytes, hierarchical_dc_widths(c_budget, 4)),
    )
    writer = codec.BitWriter()
    macroblocks_per_unit = (config.radio_block_size // 16) ** 2

    for unit in units:
        if len(unit) != macroblocks_per_unit * macroblock_bytes:
            raise ValueError("invalid unit length while extracting LF backup")
        for macroblock_index in range(macroblocks_per_unit):
            base = macroblock_index * macroblock_bytes
            for offset, length, widths in plane_layout:
                reader = codec.BitReader(unit[base + offset:base + offset + length])
                for bits in widths[:coefficient_count]:
                    writer.write_bits(reader.read_bits(bits), bits)
    return writer.flush()


def build_low_frequency_plane_payload(
    backup_reader: codec.BitReader,
    budget: codec.PlaneBudget,
    block_count: int,
    coefficient_count: int,
) -> bytes:
    """Expand compact LF backup into a normal plane payload with zero AC."""
    dc_widths = hierarchical_dc_widths(budget, block_count)
    ac_bits = budget.coefficient_bits.copy()
    ac_bits[0] = 0
    writer = codec.BitWriter()

    for rank, bits in enumerate(dc_widths):
        raw = backup_reader.read_bits(bits) if rank < coefficient_count else 0
        writer.write_bits(raw, bits)
    for _ in range(block_count):
        for bits in ac_bits:
            if bits > 0:
                writer.write_bits(0, bits)
    return writer.flush()


def expand_low_frequency_backup(
    payload: bytes,
    unit_count: int,
    config: RadioConfig,
    coefficient_count: int,
) -> list[bytes]:
    """Create decodable low-detail unit payloads from compact backup bits."""
    if coefficient_count <= 0:
        return []
    y_budget, c_budget, _, _, _ = macroblock_payload_layout(
        config.bytes_per_mb, config.luma_share
    )
    reader = codec.BitReader(payload)
    macroblocks_per_unit = (config.radio_block_size // 16) ** 2
    expanded: list[bytes] = []

    for _ in range(unit_count):
        macroblocks: list[bytes] = []
        for _ in range(macroblocks_per_unit):
            y_payload = build_low_frequency_plane_payload(
                reader, y_budget, 16, coefficient_count
            )
            cb_payload = build_low_frequency_plane_payload(
                reader, c_budget, 4, coefficient_count
            )
            cr_payload = build_low_frequency_plane_payload(
                reader, c_budget, 4, coefficient_count
            )
            macroblocks.append(y_payload + cb_payload + cr_payload)
        expanded.append(b"".join(macroblocks))
    reader.assert_zero_padding()
    return expanded

def encode_macroblock(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    config: RadioConfig,
    stats: codec.FixedArithmeticStats,
) -> bytes:
    y_budget, c_budget, _, _, expected_bytes = macroblock_payload_layout(
        config.bytes_per_mb, config.luma_share
    )
    quality_q8 = int(round(config.quality_scale * 256.0))
    chroma_quality_q8 = int(
        round(config.quality_scale * config.chroma_quality_factor * 256.0)
    )

    if config.dc_mode == "hadamard":
        _, y_payload = codec.process_plane_fixed_hierarchical(
            y, config.transform, y_budget, quality_q8, 16, stats
        )
        _, cb_payload = codec.process_plane_fixed_hierarchical(
            cb, config.transform, c_budget, chroma_quality_q8, 8, stats
        )
        _, cr_payload = codec.process_plane_fixed_hierarchical(
            cr, config.transform, c_budget, chroma_quality_q8, 8, stats
        )
    else:
        _, y_payload = codec.process_plane_fixed_block(
            y, config.transform, y_budget.coefficient_bits, quality_q8, stats
        )
        _, cb_payload = codec.process_plane_fixed_block(
            cb, config.transform, c_budget.coefficient_bits, chroma_quality_q8, stats
        )
        _, cr_payload = codec.process_plane_fixed_block(
            cr, config.transform, c_budget.coefficient_bits, chroma_quality_q8, stats
        )

    payload = y_payload + cb_payload + cr_payload
    if len(payload) != expected_bytes:
        raise AssertionError("macroblock payload size mismatch")
    return payload


def decode_macroblock(
    payload: bytes,
    config: RadioConfig,
    stats: codec.FixedArithmeticStats,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    y_budget, c_budget, y_bytes, c_bytes, expected_bytes = macroblock_payload_layout(
        config.bytes_per_mb, config.luma_share
    )
    if len(payload) != expected_bytes:
        raise ValueError("invalid macroblock payload length")
    y_payload = payload[:y_bytes]
    cb_payload = payload[y_bytes:y_bytes + c_bytes]
    cr_payload = payload[y_bytes + c_bytes:]
    quality_q8 = int(round(config.quality_scale * 256.0))
    chroma_quality_q8 = int(
        round(config.quality_scale * config.chroma_quality_factor * 256.0)
    )

    if config.dc_mode == "hadamard":
        y = codec.decode_plane_fixed_hierarchical(
            y_payload, (16, 16), config.transform, y_budget, quality_q8, 16, stats
        )
        cb = codec.decode_plane_fixed_hierarchical(
            cb_payload, (8, 8), config.transform, c_budget, chroma_quality_q8, 8, stats
        )
        cr = codec.decode_plane_fixed_hierarchical(
            cr_payload, (8, 8), config.transform, c_budget, chroma_quality_q8, 8, stats
        )
    else:
        y = codec.decode_plane_fixed_block(
            y_payload, (16, 16), config.transform, y_budget.coefficient_bits,
            quality_q8, stats
        )
        cb = codec.decode_plane_fixed_block(
            cb_payload, (8, 8), config.transform, c_budget.coefficient_bits,
            chroma_quality_q8, stats
        )
        cr = codec.decode_plane_fixed_block(
            cr_payload, (8, 8), config.transform, c_budget.coefficient_bits,
            chroma_quality_q8, stats
        )
    return y, cb, cr


def prepare_planes(
    rgb: np.ndarray,
    radio_block_size: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, tuple[int, int]]:
    y, cb, cr = codec.rgb_to_ycbcr420(rgb)
    original_shape = y.shape
    h, w = original_shape
    padded_h = math.ceil(h / radio_block_size) * radio_block_size
    padded_w = math.ceil(w / radio_block_size) * radio_block_size
    y = np.pad(y, ((0, padded_h - h), (0, padded_w - w)), mode="edge")
    cb = np.pad(
        cb,
        ((0, padded_h // 2 - cb.shape[0]), (0, padded_w // 2 - cb.shape[1])),
        mode="edge",
    )
    cr = np.pad(
        cr,
        ((0, padded_h // 2 - cr.shape[0]), (0, padded_w // 2 - cr.shape[1])),
        mode="edge",
    )
    return (
        np.clip(np.rint(y), 0, 255).astype(np.int16),
        np.clip(np.rint(cb), 0, 255).astype(np.int16),
        np.clip(np.rint(cr), 0, 255).astype(np.int16),
        original_shape,
    )


def encode_radio_blocks(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    config: RadioConfig,
    stats: codec.FixedArithmeticStats,
) -> tuple[list[bytes], int, int]:
    size = config.radio_block_size
    unit_rows = y.shape[0] // size
    unit_columns = y.shape[1] // size
    units: list[bytes] = []

    for unit_y in range(unit_rows):
        for unit_x in range(unit_columns):
            parts: list[bytes] = []
            base_y = unit_y * size
            base_x = unit_x * size
            for offset_y in range(0, size, 16):
                for offset_x in range(0, size, 16):
                    y0 = base_y + offset_y
                    x0 = base_x + offset_x
                    c_y0 = y0 // 2
                    c_x0 = x0 // 2
                    parts.append(
                        encode_macroblock(
                            y[y0:y0 + 16, x0:x0 + 16],
                            cb[c_y0:c_y0 + 8, c_x0:c_x0 + 8],
                            cr[c_y0:c_y0 + 8, c_x0:c_x0 + 8],
                            config,
                            stats,
                        )
                    )
            units.append(b"".join(parts))
    return units, unit_rows, unit_columns



def packetize_radio_blocks(
    units: list[bytes],
    config: RadioConfig,
    frame_width: int,
    frame_height: int,
) -> tuple[list[bytes], int]:
    lf_backup_coefficients = config.lf_backup_coefficients
    if not units:
        return [], 0
    unit_bytes = len(units[0])
    if any(len(unit) != unit_bytes for unit in units):
        raise ValueError("radio blocks must have a fixed payload size")

    macroblocks_per_unit = (config.radio_block_size // 16) ** 2
    lf_bits_per_unit = (
        low_frequency_bits_per_macroblock(config, lf_backup_coefficients)
        * macroblocks_per_unit
    )

    # A full packet contains its primary units plus compact LF data for the
    # same number of units in the following packet.  Search the largest count
    # which remains below the requested target.
    units_per_packet = 0
    for candidate in range(1, len(units) + 1):
        backup_bytes = (candidate * lf_bits_per_unit + 7) // 8
        packet_bytes = PACKET_HEADER.size + candidate * unit_bytes + backup_bytes
        if packet_bytes > config.packet_bytes:
            break
        units_per_packet = candidate
    if units_per_packet < 1:
        minimum = PACKET_HEADER.size + unit_bytes + (lf_bits_per_unit + 7) // 8
        raise ValueError(
            f"packet target is too small; need at least {minimum} bytes "
            "for one radio block and its LF backup"
        )

    groups = [
        units[first:first + units_per_packet]
        for first in range(0, len(units), units_per_packet)
    ]
    packets: list[bytes] = []
    first_unit = 0
    for sequence, selected in enumerate(groups):
        next_group = groups[sequence + 1] if sequence + 1 < len(groups) else []
        primary_payload = b"".join(selected)
        # Packet N protects packet N+1.  The last packet has no successor and
        # therefore carries no redundant data; packet 0 itself is unprotected.
        backup_payload = extract_low_frequency_backup(
            next_group, config, lf_backup_coefficients
        )
        packet = build_packet(
            config,
            sequence,
            first_unit,
            len(selected),
            frame_width,
            frame_height,
            primary_payload + backup_payload,
        )
        if len(packet) > config.packet_bytes:
            raise AssertionError("packet exceeds configured target")
        packets.append(packet)
        first_unit += len(selected)
    return packets, units_per_packet


def receive_packets(
    packets: list[bytes],
    config: RadioConfig,
    total_units: int,
    unit_payload_bytes: int,
    units_per_full_packet: int,
    drop_mask: np.ndarray,
) -> tuple[dict[int, bytes], dict[int, bytes], int, int]:
    lf_backup_coefficients = config.lf_backup_coefficients
    received: dict[int, bytes] = {}
    redundant: dict[int, bytes] = {}
    dropped_packets = 0
    crc_failures = 0
    macroblocks_per_unit = (config.radio_block_size // 16) ** 2
    lf_bits_per_unit = (
        low_frequency_bits_per_macroblock(config, lf_backup_coefficients)
        * macroblocks_per_unit
    )
    packet_count = len(packets)

    for packet_index, raw in enumerate(packets):
        if bool(drop_mask[packet_index]):
            dropped_packets += 1
            continue
        try:
            packet = parse_packet(raw)
        except ValueError:
            crc_failures += 1
            continue
        if (
            packet.frame_id != config.frame_id
            or packet.flags != config.flags
            or packet.radio_block_size != config.radio_block_size
            or packet.bytes_per_mb != config.bytes_per_mb
            or packet.sequence != packet_index
        ):
            crc_failures += 1
            continue
        primary_size = packet.unit_count * unit_payload_bytes
        if len(packet.payload) < primary_size:
            crc_failures += 1
            continue
        if packet.first_unit + packet.unit_count > total_units:
            crc_failures += 1
            continue

        primary_payload = packet.payload[:primary_size]
        for local_index in range(packet.unit_count):
            unit_index = packet.first_unit + local_index
            start = local_index * unit_payload_bytes
            end = start + unit_payload_bytes
            if unit_index in received:
                raise ValueError("duplicate radio block in received packets")
            received[unit_index] = primary_payload[start:end]

        # Packet N contains LF backup for the deterministic primary group N+1.
        next_sequence = packet.sequence + 1
        if next_sequence < packet_count and lf_backup_coefficients > 0:
            backup_first = next_sequence * units_per_full_packet
            backup_count = min(units_per_full_packet, total_units - backup_first)
            expected_backup_bytes = (backup_count * lf_bits_per_unit + 7) // 8
            backup_payload = packet.payload[primary_size:]
            if len(backup_payload) != expected_backup_bytes:
                crc_failures += 1
                continue
            expanded = expand_low_frequency_backup(
                backup_payload,
                backup_count,
                config,
                lf_backup_coefficients,
            )
            for local_index, unit_payload in enumerate(expanded):
                redundant[backup_first + local_index] = unit_payload
        elif len(packet.payload) != primary_size:
            crc_failures += 1

    return received, redundant, dropped_packets, crc_failures


def decode_radio_blocks(
    received: dict[int, bytes],
    redundant: dict[int, bytes],
    padded_shape: tuple[int, int],
    unit_rows: int,
    unit_columns: int,
    config: RadioConfig,
    concealment: str,
    stats: codec.FixedArithmeticStats,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int, int, int]:
    padded_h, padded_w = padded_shape
    y = np.full((padded_h, padded_w), 128, dtype=np.int16)
    cb = np.full((padded_h // 2, padded_w // 2), 128, dtype=np.int16)
    cr = np.full((padded_h // 2, padded_w // 2), 128, dtype=np.int16)
    size = config.radio_block_size
    macroblock_bytes = macroblock_payload_layout(
        config.bytes_per_mb, config.luma_share
    )[-1]
    total_units = unit_rows * unit_columns
    primary_missing = total_units - len(received)
    recovered_indices = set(redundant).difference(received)
    available = dict(redundant)
    available.update(received)  # Full primary payload always wins.
    missing_units = np.ones((unit_rows, unit_columns), dtype=bool)

    for unit_index, payload in available.items():
        unit_y, unit_x = divmod(unit_index, unit_columns)
        missing_units[unit_y, unit_x] = False
        cursor = 0
        base_y = unit_y * size
        base_x = unit_x * size
        for offset_y in range(0, size, 16):
            for offset_x in range(0, size, 16):
                part = payload[cursor:cursor + macroblock_bytes]
                cursor += macroblock_bytes
                block_y, block_cb, block_cr = decode_macroblock(part, config, stats)
                y0 = base_y + offset_y
                x0 = base_x + offset_x
                c_y0 = y0 // 2
                c_x0 = x0 // 2
                y[y0:y0 + 16, x0:x0 + 16] = block_y
                cb[c_y0:c_y0 + 8, c_x0:c_x0 + 8] = block_cb
                cr[c_y0:c_y0 + 8, c_x0:c_x0 + 8] = block_cr
        if cursor != len(payload):
            raise ValueError("radio block payload has trailing bytes")

    if concealment == "nearest" and np.any(missing_units):
        scale = size // 16
        macroblock_drop_mask = np.repeat(
            np.repeat(missing_units, scale, axis=0), scale, axis=1
        )
        y, cb, cr, _ = codec.apply_packet_drop(
            y, cb, cr, macroblock_drop_mask, "nearest"
        )
    elif concealment != "gray":
        raise ValueError("concealment must be 'gray' or 'nearest'")

    unrecovered = int(missing_units.sum())
    return (
        y,
        cb,
        cr,
        primary_missing,
        len(recovered_indices),
        unrecovered,
    )


def simulate_radio(
    rgb: np.ndarray,
    config: RadioConfig,
    packet_drop_rate: float,
    packet_drop_seed: int,
    concealment: str,
    save_packets_dir: Path | None = None,
) -> RadioResult:
    if not 0.0 <= packet_drop_rate <= 1.0:
        raise ValueError("packet drop rate must be between 0.0 and 1.0")
    y, cb, cr, original_shape = prepare_planes(rgb, config.radio_block_size)
    encoder_stats = codec.FixedArithmeticStats()
    units, unit_rows, unit_columns = encode_radio_blocks(
        y, cb, cr, config, encoder_stats
    )
    packets, units_per_full_packet = packetize_radio_blocks(
        units, config, original_shape[1], original_shape[0]
    )

    if save_packets_dir is not None:
        save_packets_dir.mkdir(parents=True, exist_ok=True)
        for index, packet in enumerate(packets):
            (save_packets_dir / f"frame{config.frame_id:04d}_packet{index:04d}.bin").write_bytes(packet)

    rng = np.random.default_rng(packet_drop_seed)
    drop_mask = rng.random(len(packets)) < packet_drop_rate
    received, redundant, dropped_packets, crc_failures = receive_packets(
        packets,
        config,
        len(units),
        len(units[0]),
        units_per_full_packet,
        drop_mask,
    )
    decoder_stats = codec.FixedArithmeticStats()
    (
        ry,
        rcb,
        rcr,
        primary_missing,
        recovered_units,
        unrecovered_units,
    ) = decode_radio_blocks(
        received,
        redundant,
        y.shape,
        unit_rows,
        unit_columns,
        config,
        concealment,
        decoder_stats,
    )
    h, w = original_shape
    decoded_rgb = codec.ycbcr420_to_rgb(
        ry[:h, :w], rcb[:h // 2, :w // 2], rcr[:h // 2, :w // 2]
    )
    packet_sizes = [len(packet) for packet in packets]
    codec_payload_bytes = sum(len(unit) for unit in units)
    wire_bytes = sum(packet_sizes)
    redundancy_bytes = wire_bytes - codec_payload_bytes - len(packets) * PACKET_HEADER.size
    return RadioResult(
        rgb=decoded_rgb,
        psnr=codec.calculate_psnr(rgb[:h, :w], decoded_rgb),
        codec_payload_bytes=codec_payload_bytes,
        wire_bytes=wire_bytes,
        packet_count=len(packets),
        dropped_packets=dropped_packets,
        dropped_radio_blocks=primary_missing,
        low_frequency_recovered_blocks=recovered_units,
        unrecovered_radio_blocks=unrecovered_units,
        redundancy_bytes=redundancy_bytes,
        crc_failures=crc_failures,
        min_packet_bytes=min(packet_sizes),
        max_packet_bytes=max(packet_sizes),
        average_packet_bytes=float(np.mean(packet_sizes)),
        units_per_full_packet=units_per_full_packet,
        arithmetic_saturations=(
            encoder_stats.saturation_count + decoder_stats.saturation_count
        ),
    )

def make_comparison(original: np.ndarray, decoded: np.ndarray) -> Image.Image:
    h, w, _ = original.shape
    canvas = Image.new("RGB", (w * 2, h))
    canvas.paste(Image.fromarray(original), (0, 0))
    canvas.paste(Image.fromarray(decoded), (w, 0))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Encode, packetize, drop radio packets, and decode a fixed-rate frame"
    )
    parser.add_argument("input", type=Path)
    parser.add_argument(
        "--bytes-per-mb", type=int, default=24,
        help="codec payload bytes per 16x16 macroblock (default: 24)",
    )
    parser.add_argument(
        "--packet-bytes", type=int, default=1200,
        help="maximum target radio packet size including header and LF backup (default: 1200)",
    )
    parser.add_argument(
        "--radio-block-size", type=int, choices=[16, 32, 64], default=16,
        help="addressable loss unit; 32/64 group 4/16 compressed 16x16 macroblocks",
    )
    parser.add_argument(
        "--packet-drop-rate", type=float, default=0.0,
        help="probability of dropping a complete radio packet, from 0.0 to 1.0",
    )
    parser.add_argument("--packet-drop-seed", type=int, default=1234)
    parser.add_argument("--loss-concealment", choices=["gray", "nearest"], default="gray")
    parser.add_argument("--transform", choices=["integer", "hadamard"], default="integer")
    parser.add_argument("--dc-mode", choices=["hadamard", "block"], default="hadamard")
    parser.add_argument(
        "--lf-backup-coefficients", type=int, choices=[0, 1, 2, 3, 4], default=1,
        help="hierarchical DC coefficients copied from packet N+1 into packet N",
    )
    parser.add_argument("--quality-scale", type=float, default=64.0)
    parser.add_argument("--luma-share", type=float, default=0.75)
    parser.add_argument("--chroma-quality-factor", type=float, default=0.6)
    parser.add_argument("--frame-id", type=int, default=0)
    parser.add_argument(
        "--save-packets", action="store_true",
        help="save every pre-loss wire packet as a .bin file for inspection",
    )
    parser.add_argument("--output-dir", type=Path, default=Path("radio_results"))
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"input image not found: {args.input}")
    if not 3 <= args.bytes_per_mb <= 255:
        raise SystemExit("--bytes-per-mb must be in [3, 255]")
    if not 0 <= args.frame_id <= 65535:
        raise SystemExit("--frame-id must be in [0, 65535]")
    if args.packet_bytes > 65535:
        raise SystemExit("--packet-bytes must not exceed 65535")
    if args.lf_backup_coefficients > 0 and args.dc_mode != "hadamard":
        raise SystemExit("LF backup requires --dc-mode hadamard")

    image = Image.open(args.input).convert("RGB")
    rgb = np.asarray(image, dtype=np.uint8)
    h, w = rgb.shape[:2]
    rgb = rgb[:h - (h % 2), :w - (w % 2)]
    config = RadioConfig(
        bytes_per_mb=args.bytes_per_mb,
        packet_bytes=args.packet_bytes,
        radio_block_size=args.radio_block_size,
        transform=args.transform,
        dc_mode=args.dc_mode,
        quality_scale=args.quality_scale,
        luma_share=args.luma_share,
        chroma_quality_factor=args.chroma_quality_factor,
        frame_id=args.frame_id,
        lf_backup_coefficients=args.lf_backup_coefficients,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    packet_dir = args.output_dir / "packets" if args.save_packets else None
    result = simulate_radio(
        rgb,
        config,
        args.packet_drop_rate,
        args.packet_drop_seed,
        args.loss_concealment,
        packet_dir,
    )
    suffix = (
        f"{args.bytes_per_mb:02d}B_pkt{args.packet_bytes}_blk{args.radio_block_size}"
        f"_lf{args.lf_backup_coefficients}"
        f"_drop{int(round(args.packet_drop_rate * 100)):02d}"
    )
    decoded_path = args.output_dir / f"decoded_{suffix}.png"
    comparison_path = args.output_dir / f"comparison_{suffix}.png"
    Image.fromarray(result.rgb).save(decoded_path)
    make_comparison(rgb, result.rgb).save(comparison_path)

    header_bytes = result.packet_count * PACKET_HEADER.size
    overhead = header_bytes + result.redundancy_bytes
    overhead_percent = 100.0 * overhead / result.codec_payload_bytes
    print("radio packet simulation")
    print(f"  frame: {rgb.shape[1]}x{rgb.shape[0]}, id={args.frame_id}")
    print(f"  transform/DC: {args.transform}/{args.dc_mode}")
    print(f"  radio block: {args.radio_block_size}x{args.radio_block_size}")
    print(
        f"  LF backup: {args.lf_backup_coefficients} coefficient(s), "
        "packet N protects packet N+1"
    )
    print(f"  codec payload: {result.codec_payload_bytes} bytes")
    pixel_count = rgb.shape[0] * rgb.shape[1]
    codec_bpp = result.codec_payload_bytes * 8.0 / pixel_count
    wire_bpp = result.wire_bytes * 8.0 / pixel_count
    print(
        f"  bits/pixel: codec={codec_bpp:.4f}, "
        f"wire={wire_bpp:.4f} (headers + LF redundancy included)"
    )
    print(
        f"  packets: {result.packet_count}, target={args.packet_bytes}, "
        f"units/full_packet={result.units_per_full_packet}"
    )
    print(
        f"  packet bytes: min={result.min_packet_bytes}, "
        f"max={result.max_packet_bytes}, avg={result.average_packet_bytes:.2f}"
    )
    print(
        f"  wire bytes: {result.wire_bytes}, headers: {header_bytes}, "
        f"LF redundancy: {result.redundancy_bytes}, total overhead: "
        f"{overhead} ({overhead_percent:.2f}%)"
    )
    print(
        f"  dropped packets: {result.dropped_packets}/{result.packet_count}, "
        f"primary blocks lost: {result.dropped_radio_blocks}, "
        f"LF recovered: {result.low_frequency_recovered_blocks}, "
        f"unrecovered: {result.unrecovered_radio_blocks}, "
        f"CRC failures: {result.crc_failures}"
    )
    print(
        f"  PSNR: {result.psnr:.3f} dB, "
        f"arithmetic saturations: {result.arithmetic_saturations}"
    )
    print(f"  decoded: {decoded_path.resolve()}")
    print(f"  comparison: {comparison_path.resolve()}")


if __name__ == "__main__":
    main()
