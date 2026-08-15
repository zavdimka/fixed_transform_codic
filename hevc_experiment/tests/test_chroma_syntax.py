import unittest

from hevc_reference.chroma_syntax import (
    DIAGONAL_SCAN_8, coefficient_scan_metadata_8,
    last_significant_bins_8, significance_bins_8,
)


class ChromaSyntaxReferenceTests(unittest.TestCase):
    def test_tu8_scan_is_normative_permutation(self) -> None:
        self.assertEqual(DIAGONAL_SCAN_8[:20], (
            0, 8, 1, 16, 9, 2, 24, 17, 10, 3, 25, 18, 11, 26, 19, 27,
            32, 40, 33, 48,
        ))
        self.assertEqual(set(DIAGONAL_SCAN_8), set(range(64)))

    def test_metadata_last_and_groups(self) -> None:
        block = [[0] * 8 for _ in range(8)]
        for position in (2, 17, 53):
            address = DIAGONAL_SCAN_8[position]
            block[address >> 3][address & 7] = position + 1
        flags, last = coefficient_scan_metadata_8(block)
        self.assertEqual(flags, (True, False, True, True))
        self.assertEqual(last, 53)

    def test_chroma_context_ranges(self) -> None:
        block = [[0] * 8 for _ in range(8)]
        block[7][7] = 3
        block[4][1] = -2
        block[0][0] = 1
        last = last_significant_bins_8(63)
        self.assertTrue(all(event.bypass or event.context_index <= 5 for event in last))
        significance = significance_bins_8(block)
        self.assertTrue(all(
            event.context_index <= 1 if event.coded_sub_block
            else event.context_index == 0 or 12 <= event.context_index <= 14
            for event in significance
        ))


if __name__ == "__main__":
    unittest.main()
