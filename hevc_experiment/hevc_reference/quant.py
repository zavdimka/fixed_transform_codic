"""Integer HEVC flat-scaling quantization primitives for 16x16 TU blocks."""

from __future__ import annotations


QUANT_SCALES = (26214, 23302, 20560, 18396, 16384, 14564)
INVERSE_QUANT_SCALES = (40, 45, 51, 57, 64, 72)
QUALITY_QPS = {"good": 28, "medium": 34, "poor": 40}


def split_qp(qp: int) -> tuple[int, int]:
    if not 0 <= qp <= 51:
        raise ValueError("HEVC QP must be in [0, 51]")
    return divmod(qp, 6)


def quantize_coefficient(coefficient: int, qp: int, intra: bool = True) -> int:
    """Apply the Kvazaar/HM-style flat encoder quantizer for TU16, 8-bit."""

    if not -32768 <= coefficient <= 32767:
        raise ValueError("transform coefficient outside signed 16-bit range")
    qp_per, qp_rem = split_qp(qp)
    q_bits = 17 + qp_per
    offset = (171 if intra else 85) << (q_bits - 9)
    magnitude = (abs(coefficient) * QUANT_SCALES[qp_rem] + offset) >> q_bits
    quantized = -magnitude if coefficient < 0 else magnitude
    return min(32767, max(-32768, quantized))


def dequantize_coefficient(quantized: int, qp: int) -> int:
    """Apply normative flat inverse quantization for TU16, 8-bit."""

    if not -32768 <= quantized <= 32767:
        raise ValueError("quantized coefficient outside signed 16-bit range")
    qp_per, qp_rem = split_qp(qp)
    scale = INVERSE_QUANT_SCALES[qp_rem] << qp_per
    dequantized = (quantized * scale + 4) >> 3
    return min(32767, max(-32768, dequantized))


def quantize_dequantize_coefficient(
    coefficient: int, qp: int, intra: bool = True
) -> tuple[int, int]:
    quantized = quantize_coefficient(coefficient, qp, intra)
    return quantized, dequantize_coefficient(quantized, qp)
