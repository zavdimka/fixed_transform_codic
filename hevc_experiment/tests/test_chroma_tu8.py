import unittest

from hevc_reference.chroma_tu8 import (
    chroma_qp, forward_transform_8, inverse_transform_8, quantize_dequantize_8,
)


class ChromaTu8ReferenceTests(unittest.TestCase):
    def test_constant_has_only_dc(self) -> None:
        _, coefficients = forward_transform_8([[7] * 8 for _ in range(8)])
        self.assertEqual(coefficients[0][0], 896)
        self.assertTrue(all(coefficients[y][x] == 0 for y in range(8) for x in range(8)
                            if (x, y) != (0, 0)))

    def test_quantized_reconstruction(self) -> None:
        residual = [[((x * 17 + y * 29) % 81) - 40 for x in range(8)] for y in range(8)]
        _, coefficients = forward_transform_8(residual)
        qp = chroma_qp(34)
        dequantized = [[quantize_dequantize_8(v, qp)[1] for v in row]
                       for row in coefficients]
        _, reconstructed = inverse_transform_8(dequantized)
        self.assertLessEqual(max(abs(reconstructed[y][x] - residual[y][x])
                                 for y in range(8) for x in range(8)), 40)

    def test_normative_chroma_qp_mapping(self) -> None:
        self.assertEqual([chroma_qp(v) for v in (28, 34, 40, 51)], [28, 33, 36, 45])
        self.assertEqual(chroma_qp(0, -12), 0)


if __name__ == "__main__":
    unittest.main()
