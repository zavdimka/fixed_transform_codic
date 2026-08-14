from __future__ import annotations

import unittest

from hevc_reference.annexb import NalUnit, annexb_nals, build_annexb
from hevc_reference.debug_interface import (
    DebugSnapshot,
    bytes_to_nibbles,
    nibbles_to_bytes,
)
from hevc_reference.radio import packetize, parse_packet, reassemble, simulate_loss
from hevc_reference.transform import forward_transform_16, inverse_transform_16
from hevc_reference.cabac import (
    CABAC_INIT_B,
    CABAC_INIT_I,
    CABAC_INIT_P,
    CabacByteEncoder,
    cabac_bin_step,
    cabac_context_init_state,
    coefficient_context_init_states,
    coefficient_context_init_values,
)
from hevc_reference.quant import (
    QUALITY_QPS,
    dequantize_coefficient,
    quantize_coefficient,
    quantize_dequantize_coefficient,
    split_qp,
)
from hevc_reference.fixed_math import biased_round_shift, saturate_signed, wrap_signed
from hevc_reference.intra import (
    filtered_dc_prediction,
    filtered_planar_references_16,
    planar_prediction_16,
    prediction_residual,
    reconstruct_sample,
    select_planar_by_sad,
)
from hevc_reference.scan import (
    DIAGONAL_SCAN_4,
    DIAGONAL_SCAN_16,
    coefficient_scan_metadata_16,
    scan_coefficients_16,
)
from hevc_reference.syntax import (
    LEVEL_GREATER1,
    LEVEL_GREATER2,
    LEVEL_SIGN,
    CoefficientSyntaxBin,
    coefficient_context_address,
    coefficient_level_bins_16,
    coefficient_syntax_bins_16,
    last_significant_bins_16,
    significance_bins_16,
    SYNTAX_SOURCE_LAST,
    SYNTAX_SOURCE_LEVEL,
    SYNTAX_SOURCE_SIGNIFICANCE,
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

class CabacTests(unittest.TestCase):
    def test_normative_coefficient_context_initialization(self) -> None:
        self.assertEqual(cabac_context_init_state(34, 110), (0, 1))
        self.assertEqual(cabac_context_init_state(34, 153), (7, 0))
        self.assertEqual(
            cabac_context_init_state(63, 110),
            cabac_context_init_state(51, 110),
        )
        for slice_type in (CABAC_INIT_B, CABAC_INIT_P, CABAC_INIT_I):
            values = coefficient_context_init_values(slice_type)
            contexts = coefficient_context_init_states(slice_type, 34)
            self.assertEqual(len(values), 128)
            self.assertEqual(len(contexts), 256)
            self.assertEqual(
                contexts[115], cabac_context_init_state(34, values[115])
            )
        with self.assertRaises(ValueError):
            coefficient_context_init_values(3)

    def test_hm_byte_vectors_and_restart(self) -> None:
        encoder = CabacByteEncoder([(0, 0)] * 256)
        encoder.encode_terminate(1)
        self.assertEqual(encoder.bytes(), bytes.fromhex("fe80"))

        encoder.start()
        encoder.encode_regular(0, 0)
        encoder.encode_terminate(1)
        self.assertEqual(encoder.bytes(), bytes.fromhex("8680"))

    def test_context_update_and_finish_guard(self) -> None:
        encoder = CabacByteEncoder([(0, 0)] * 256)
        context = encoder.encode_regular(1, 7)
        self.assertEqual((context.state_index, context.mps), (0, 1))
        with self.assertRaises(ValueError):
            encoder.bytes()
        encoder.encode_terminate(1)
        with self.assertRaises(ValueError):
            encoder.encode_bypass(0)

    def test_regular_mps_lps_and_context_toggle(self) -> None:
        mps = cabac_bin_step(0, 510, 0, 0, 0)
        self.assertEqual(
            (mps.low, mps.range, mps.state_index, mps.mps,
             mps.renorm_bits),
            (0, 270, 1, 0, 0),
        )
        lps = cabac_bin_step(0, 510, 0, 0, 1)
        self.assertEqual(
            (lps.low, lps.range, lps.state_index, lps.mps,
             lps.renorm_bits),
            (540, 480, 0, 1, 1),
        )

    def test_bypass_preserves_context_and_range(self) -> None:
        result = cabac_bin_step(0x80000000, 333, 22, 1, 1, True)
        self.assertEqual(result.low, 333)
        self.assertEqual(
            (result.range, result.state_index, result.mps,
             result.renorm_bits),
            (333, 22, 1, 1),
        )

    def test_invalid_range_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            cabac_bin_step(0, 255, 0, 0, 0)



class QuantTests(unittest.TestCase):
    def test_quality_profiles_and_qp_split(self) -> None:
        self.assertEqual(QUALITY_QPS, {"good": 28, "medium": 34, "poor": 40})
        self.assertEqual(split_qp(28), (4, 4))
        self.assertEqual(split_qp(34), (5, 4))
        self.assertEqual(split_qp(40), (6, 4))
        with self.assertRaises(ValueError):
            split_qp(52)

    def test_flat_quant_dequant_known_values(self) -> None:
        self.assertEqual(quantize_dequantize_coefficient(0, 34), (0, 0))
        self.assertEqual(quantize_dequantize_coefficient(4096, 34), (16, 4096))
        self.assertEqual(quantize_dequantize_coefficient(-4096, 34), (-16, -4096))
        self.assertEqual(quantize_coefficient(32767, 0), 6553)
        self.assertEqual(dequantize_coefficient(32767, 51), 32767)
        self.assertEqual(dequantize_coefficient(-32768, 51), -32768)


class TransformTests(unittest.TestCase):
    def test_constant_transform16_has_only_dc(self) -> None:
        intermediate, coefficients = forward_transform_16([[1] * 16 for _ in range(16)])
        self.assertEqual(intermediate, [[128] + [0] * 15 for _ in range(16)])
        self.assertEqual(coefficients[0][0], 128)
        self.assertEqual(sum(abs(value) for row in coefficients for value in row), 128)

    def test_transform16_rejects_invalid_dimensions_and_range(self) -> None:
        with self.assertRaises(ValueError):
            forward_transform_16([[0] * 8 for _ in range(8)])
        block = [[0] * 16 for _ in range(16)]
        block[3][4] = 256
        with self.assertRaises(ValueError):
            forward_transform_16(block)

    def test_inverse_transform16_dc_and_roundtrip(self) -> None:
        coefficients = [[0] * 16 for _ in range(16)]
        coefficients[0][0] = 128
        _, residual = inverse_transform_16(coefficients)
        self.assertEqual(residual, [[1] * 16 for _ in range(16)])

        source = [[(x * 17 + y * 29) % 511 - 255
                   for x in range(16)] for y in range(16)]
        transformed = forward_transform_16(source)[1]
        reconstructed = inverse_transform_16(transformed)[1]
        maximum_error = max(
            abs(source[y][x] - reconstructed[y][x])
            for y in range(16) for x in range(16)
        )
        self.assertLessEqual(maximum_error, 4)

    def test_inverse_transform16_rejects_invalid_input(self) -> None:
        with self.assertRaises(ValueError):
            inverse_transform_16([[0] * 8 for _ in range(8)])
        coefficients = [[0] * 16 for _ in range(16)]
        coefficients[2][7] = 32768
        with self.assertRaises(ValueError):
            inverse_transform_16(coefficients)

    def test_quantized_inverse_quality_profiles_are_ordered(self) -> None:
        source = [[(x * 17 + y * 29) % 511 - 255
                   for x in range(16)] for y in range(16)]
        coefficients = forward_transform_16(source)[1]
        squared_errors = []
        for qp in (28, 34, 40):
            dequantized = [
                [quantize_dequantize_coefficient(
                    coefficients[y][x], qp
                )[1] for x in range(16)]
                for y in range(16)
            ]
            restored = inverse_transform_16(dequantized)[1]
            squared_errors.append(sum(
                (source[y][x] - restored[y][x]) ** 2
                for y in range(16) for x in range(16)
            ))
        self.assertLess(squared_errors[0], squared_errors[1])
        self.assertLess(squared_errors[1], squared_errors[2])


class CoefficientScanTests(unittest.TestCase):
    def test_tu16_diagonal_scan_matches_known_prefix_and_is_permutation(self) -> None:
        self.assertEqual(DIAGONAL_SCAN_4, (
            0, 4, 1, 8, 5, 2, 12, 9, 6, 3, 13, 10, 7, 14, 11, 15,
        ))
        self.assertEqual(DIAGONAL_SCAN_16[:20], (
            0, 16, 1, 32, 17, 2, 48, 33, 18, 3, 49, 34, 19, 50, 35, 51,
            64, 80, 65, 96,
        ))
        self.assertEqual(sorted(DIAGONAL_SCAN_16), list(range(256)))

    def test_scan_values_groups_and_last_nonzero(self) -> None:
        block = [[y * 16 + x for x in range(16)] for y in range(16)]
        self.assertEqual(scan_coefficients_16(block), DIAGONAL_SCAN_16)

        sparse = [[0] * 16 for _ in range(16)]
        for position in (2, 17, 173):
            address = DIAGONAL_SCAN_16[position]
            sparse[address >> 4][address & 15] = 1
        group_flags, last_nonzero = coefficient_scan_metadata_16(sparse)
        expected_groups = [False] * 16
        for position in (2, 17, 173):
            expected_groups[DIAGONAL_SCAN_4[position >> 4]] = True
        self.assertEqual(group_flags, tuple(expected_groups))
        self.assertEqual(last_nonzero, 173)

    def test_scan_rejects_wrong_shape(self) -> None:
        with self.assertRaises(ValueError):
            scan_coefficients_16([[0] * 8 for _ in range(8)])


class CoefficientSyntaxTests(unittest.TestCase):
    def test_compact_cabac_context_banks_do_not_overlap(self) -> None:
        cases = (
            (CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_LAST, context_index=6,
            ), 6),
            (CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_LAST, context_index=6,
                last_axis_y=True,
            ), 22),
            (CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_SIGNIFICANCE, context_index=1,
                significance_coded_sub_block=True,
            ), 33),
            (CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_SIGNIFICANCE, context_index=27,
            ), 91),
            (CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_LEVEL,
                level_kind=LEVEL_GREATER1, context_index=15,
            ), 111),
            (CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_LEVEL,
                level_kind=LEVEL_GREATER2, context_index=3,
            ), 115),
            (CoefficientSyntaxBin(
                0, True, SYNTAX_SOURCE_LEVEL, level_kind=LEVEL_SIGN,
            ), None),
        )
        self.assertEqual(
            [coefficient_context_address(event) for event, _ in cases],
            [address for _, address in cases],
        )
        with self.assertRaises(ValueError):
            coefficient_context_address(CoefficientSyntaxBin(
                0, False, SYNTAX_SOURCE_SIGNIFICANCE, context_index=28,
            ))

    def test_last_significant_shortest_and_longest_codes(self) -> None:
        shortest = last_significant_bins_16(0x00)
        self.assertEqual(
            [(item.value, item.bypass, item.axis_y, item.context_index,
              item.syntax_last) for item in shortest],
            [(0, False, False, 6, False), (0, False, True, 6, True)],
        )

        longest = last_significant_bins_16(0xFF)
        self.assertEqual(len(longest), 18)
        self.assertEqual(sum(item.bypass for item in longest), 4)
        self.assertTrue(longest[-1].syntax_last)

    def test_last_significant_rejects_invalid_address(self) -> None:
        for address in (-1, 256):
            with self.assertRaises(ValueError):
                last_significant_bins_16(address)

    def test_significance_bins_handle_dc_only_and_group_contexts(self) -> None:
        dc_only = [[0] * 16 for _ in range(16)]
        dc_only[0][0] = 1
        self.assertEqual(significance_bins_16(dc_only), ())

        block = [[0] * 16 for _ in range(16)]
        for position in (0, 16, 32, 79, 173):
            address = DIAGONAL_SCAN_16[position]
            block[address >> 4][address & 15] = 1
        events = significance_bins_16(block)
        self.assertTrue(any(event.coded_sub_block for event in events))
        self.assertTrue(any(not event.coded_sub_block for event in events))
        self.assertTrue(events[-1].syntax_last)
        self.assertEqual(events[-1].scan_position, 0)

    def test_dc_level_bins_and_large_rice_escape(self) -> None:
        block = [[0] * 16 for _ in range(16)]
        block[0][0] = -1
        events = coefficient_level_bins_16(block)
        self.assertEqual(
            [(event.value, event.kind, event.bypass, event.context_index)
             for event in events],
            [(0, LEVEL_GREATER1, False, 1),
             (1, LEVEL_SIGN, True, 0)],
        )

        block[0][0] = -32768
        events = coefficient_level_bins_16(block)
        self.assertTrue(any(event.kind == 3 for event in events))
        self.assertTrue(events[-1].syntax_last)

    def test_combined_syntax_order_and_all_zero_bypass(self) -> None:
        self.assertEqual(coefficient_syntax_bins_16(
            [[0] * 16 for _ in range(16)]
        ), ())

        block = [[0] * 16 for _ in range(16)]
        for position, value in ((0, -2), (17, 3), (173, -9)):
            address = DIAGONAL_SCAN_16[position]
            block[address >> 4][address & 15] = value
        events = coefficient_syntax_bins_16(block)
        sources = [event.source for event in events]
        first_significance = sources.index(1)
        first_level = sources.index(2)
        self.assertTrue(all(
            source == 0 for source in sources[:first_significance]
        ))
        self.assertTrue(all(
            source == 1
            for source in sources[first_significance:first_level]
        ))
        self.assertTrue(all(
            source == 2 for source in sources[first_level:]
        ))


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
