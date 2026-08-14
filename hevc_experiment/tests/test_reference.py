from __future__ import annotations

import unittest

from hevc_reference.annexb import NalUnit, annexb_nals, build_annexb
from hevc_reference.debug_interface import (
    DebugSnapshot,
    bytes_to_nibbles,
    nibbles_to_bytes,
)
from hevc_reference.radio import packetize, parse_packet, reassemble, simulate_loss
from hevc_reference.fixed_math import biased_round_shift, saturate_signed, wrap_signed
from hevc_reference.intra import (
    filtered_dc_prediction,
    filtered_planar_references_16,
    planar_prediction_16,
    prediction_residual,
    reconstruct_sample,
    select_planar_by_sad,
)


def nal(nal_type: int, payload: bytes) -> NalUnit:
    header = bytes(((nal_type << 1) & 0x7E, 1))
    return NalUnit(nal_type, header + payload)


class AnnexBTests(unittest.TestCase):
    def test_three_and_four_byte_start_codes(self) -> None:
        source = [nal(32, b"vps"), nal(19, b"slice")]
        mixed = b"\x00\x00\x01" + source[0].data + build_annexb(source[1:])
        self.assertEqual(annexb_nals(mixed), source)
        self.assertEqual(annexb_nals(build_annexb(source)), source)


class RadioTests(unittest.TestCase):
    def test_packet_roundtrip_with_cached_parameter_sets_and_xor(self) -> None:
        source = [nal(32, b"parameter"), nal(19, bytes(range(256)) * 4)]
        packets, cached = packetize(source, 160, 7, True, 1, 2, "round-robin")
        # Remove one original fragment; one of the two parity groups repairs it.
        received = [packet for packet in packets if not (
            packet.nal_index == 1 and packet.fragment_index == 1 and not packet.parity
        )]
        recovered, complete, incomplete, repaired, concealed = reassemble(
            received, cached, source, 160
        )
        self.assertEqual(recovered, build_annexb(source))
        self.assertEqual((complete, incomplete, repaired, concealed), (1, 0, 1, 0))

    def test_crc_rejects_corruption(self) -> None:
        packets, _ = packetize([nal(19, b"payload")], 64, 0, False, 1, 0, "nal")
        damaged = bytearray(packets[0].raw)
        damaged[-1] ^= 1
        with self.assertRaises(ValueError):
            parse_packet(bytes(damaged), 64)

    def test_burst_loss_is_deterministic(self) -> None:
        packets, _ = packetize([nal(19, bytes(range(128)) * 8)], 96, 0, False, 1, 0, "nal")
        first = simulate_loss(packets, 96, 0.25, 96, 123, "burst", 2, 5)
        second = simulate_loss(packets, 96, 0.25, 96, 123, "burst", 2, 5)
        self.assertEqual([packet.raw for packet in first[0]], [packet.raw for packet in second[0]])
        self.assertEqual(first[1:], second[1:])


class DebugContractTests(unittest.TestCase):
    def test_nibble_bus_roundtrip(self) -> None:
        data = bytes((0x00, 0x12, 0xAB, 0xFF))
        self.assertEqual(bytes_to_nibbles(data), [0, 0, 1, 2, 10, 11, 15, 15])
        self.assertEqual(nibbles_to_bytes(bytes_to_nibbles(data)), data)

    def test_snapshot_roundtrip(self) -> None:
        source = DebugSnapshot(
            snapshot_sequence=9, frame_id=4, packet_count=17,
            output_bytes=12345, slice_index=3, ctu_x=7, ctu_y=2,
            fifo_high_water=811, error_flags=2,
        )
        encoded = source.to_bytes()
        self.assertEqual(len(encoded), 64)
        self.assertEqual(encoded[:4], b"HDBG")
        self.assertEqual(DebugSnapshot.from_bytes(encoded), source)


class FixedMathTests(unittest.TestCase):
    def test_explicit_width_and_rounding(self) -> None:
        self.assertEqual(saturate_signed(200, 8), 127)
        self.assertEqual(saturate_signed(-200, 8), -128)
        self.assertEqual(wrap_signed(255, 8), -1)
        self.assertEqual(wrap_signed(128, 8), -128)
        self.assertEqual(biased_round_shift(7, 2), 2)
        self.assertEqual(biased_round_shift(-7, 2), -2)


class IntraTests(unittest.TestCase):
    def test_filtered_dc16_and_residual(self) -> None:
        top = [10] * 16
        left = [20] * 16
        prediction = filtered_dc_prediction(top, left)
        self.assertEqual(prediction[0][0], 15)
        self.assertEqual(prediction[0][1], 14)
        self.assertEqual(prediction[1][0], 16)
        self.assertEqual(prediction[1][1], 15)
        residual = prediction_residual([[17] * 16 for _ in range(16)], prediction)
        self.assertEqual(residual[0][:2], [2, 3])
        self.assertEqual(residual[1][:2], [1, 2])

    def test_reconstruction_clips_to_8_bit(self) -> None:
        self.assertEqual(reconstruct_sample(10, -20), 0)
        self.assertEqual(reconstruct_sample(100, 20), 120)
        self.assertEqual(reconstruct_sample(250, 20), 255)

    def test_planar16_uses_filtered_extended_references(self) -> None:
        top = [64] + [20 + index * 3 for index in range(18)]
        left = [64] + [180 - index * 4 for index in range(18)]
        filtered_top, filtered_left = filtered_planar_references_16(top, left)
        prediction = planar_prediction_16(top, left)
        self.assertEqual(filtered_top[:3], [82, 32, 23])
        self.assertEqual(filtered_left[:3], [82, 150, 176])
        self.assertEqual(prediction[0][0], 91)
        self.assertEqual(prediction[0][15], 68)
        self.assertEqual(prediction[15][0], 116)
        self.assertEqual(prediction[15][15], 92)

    def test_sad_selector_prefers_dc_on_tie(self) -> None:
        dc = [[1, -2], [3, -4]]
        planar = [[0, -1], [1, -1]]
        self.assertEqual(select_planar_by_sad(dc, planar), (True, 10, 3))
        self.assertEqual(select_planar_by_sad(dc, dc), (False, 10, 10))


if __name__ == "__main__":
    unittest.main()
