from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import CABAC_INIT_I, CabacByteEncoder, coefficient_context_init_states
from hevc_reference.cu_syntax import CABAC_BYPASS, ctu16_intra_prefix_bins
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16
from hevc_reference.transform import forward_transform_16, inverse_transform_16


QUALITY_MEDIUM = 1


def make_vectors():
    prediction = [[80 + ((x + y) & 3) for x in range(16)] for y in range(16)]
    residual = [[12 if y < 8 else -9 for x in range(16)] for y in range(16)]
    coefficients = forward_transform_16(residual)[1]
    quantized = [[0] * 16 for _ in range(16)]
    dequantized = [[0] * 16 for _ in range(16)]
    qp = QUALITY_QPS["medium"]
    for y in range(16):
        for x in range(16):
            quantized[y][x], dequantized[y][x] = quantize_dequantize_coefficient(
                coefficients[y][x], qp
            )
    restored = inverse_transform_16(dequantized)[1]
    source = []
    reconstructed = []
    for y in range(16):
        for x in range(16):
            source.append((prediction[y][x], residual[y][x]))
            pixel = min(255, max(0, prediction[y][x] + restored[y][x]))
            reconstructed.append((pixel, x, y, x == 15 and y == 15))
    return quantized, source, reconstructed


def encode_cabac(qp, quantized):
    cbf = any(value for row in quantized for value in row)
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for event in ctu16_intra_prefix_bins(1, cbf):
        if event.kind == CABAC_BYPASS:
            encoder.encode_bypass(event.value)
        else:
            encoder.encode_regular(event.value, event.context_address)
    if cbf:
        for event in coefficient_syntax_bins_16(quantized):
            address = coefficient_context_address(event)
            if address is None:
                encoder.encode_bypass(event.value)
            else:
                encoder.encode_regular(event.value, address)
    encoder.encode_terminate(1)
    return encoder.bytes()


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.ctu_start_valid.value = 0
    dut.s_valid.value = 0
    dut.recon_ready.value = 0
    dut.nal_ready.value = 0
    dut.s_quality.value = QUALITY_MEDIUM
    dut.s_luma_mode_dc.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def complete_ctu16_matches_pixel_and_annexb_references(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    qp = QUALITY_QPS["medium"]
    quantized, source, expected_pixels = make_vectors()
    expected_nal = build_annexb_nal(
        20, idr_slice_header_bytes(0, qp, 1, 1) + encode_cabac(qp, quantized)
    )

    dut.slice_row.value = 0
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0x16_16_265)
    ctu_started = False
    source_index = 0
    pixels = []
    nal = bytearray()
    completed_tus = 0
    for _ in range(60000):
        dut.ctu_start_valid.value = int(not ctu_started)
        if ctu_started and source_index < len(source):
            dut.s_valid.value = 1
            dut.s_prediction.value, dut.s_residual.value = source[source_index]
        else:
            dut.s_valid.value = 0
        dut.recon_ready.value = int(rng.random() < 0.76)
        dut.nal_ready.value = int(rng.random() < 0.71)
        await Timer(1, units="ns")
        ctu_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        if int(dut.recon_valid.value) and int(dut.recon_ready.value):
            pixels.append((int(dut.recon_pixel.value), int(dut.recon_x.value),
                           int(dut.recon_y.value), bool(dut.recon_block_last.value)))
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(int(dut.nal_byte.value))
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        ctu_started |= bool(ctu_fire)
        source_index += int(source_fire)
        completed_tus += int(dut.tu_done.value)
        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert source_index == 256
            assert completed_tus == 1
            assert pixels == expected_pixels
            assert bytes(nal) == expected_nal
            return
    raise AssertionError("CTU16 luma NAL timed out")
