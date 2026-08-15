from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import CABAC_INIT_I, CabacByteEncoder, coefficient_context_init_states
from hevc_reference.cu_syntax import CABAC_BYPASS, ctu16_intra_prefix_bins
from hevc_reference.intra import filtered_dc_prediction, planar_prediction_16, prediction_residual, reconstruct_sample, residual_sad
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16
from hevc_reference.transform import forward_transform_16, inverse_transform_16


def make_vectors():
    source = [[(31 + x * 5 + y * 7 + ((x * y) & 15)) & 255 for x in range(16)] for y in range(16)]
    refs = [128] * 19
    dc_prediction = filtered_dc_prediction(refs[1:17], refs[1:17])
    planar_prediction = planar_prediction_16(refs, refs)
    dc_residual = prediction_residual(source, dc_prediction)
    planar_residual = prediction_residual(source, planar_prediction)
    dc_mode = not (residual_sad(planar_residual) < residual_sad(dc_residual))
    prediction = dc_prediction if dc_mode else planar_prediction
    residual = dc_residual if dc_mode else planar_residual
    qp = QUALITY_QPS["medium"]
    coefficients = forward_transform_16(residual)[1]
    quantized = [[0] * 16 for _ in range(16)]
    dequantized = [[0] * 16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            quantized[y][x], dequantized[y][x] = quantize_dequantize_coefficient(coefficients[y][x], qp)
    restored = inverse_transform_16(dequantized)[1]
    pixels = [(reconstruct_sample(prediction[y][x], restored[y][x]), x, y, x == 15 and y == 15) for y in range(16) for x in range(16)]

    cbf = any(value for row in quantized for value in row)
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for event in ctu16_intra_prefix_bins(int(dc_mode), cbf):
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
    nal = build_annexb_nal(20, idr_slice_header_bytes(0, qp, 1, 1) + encoder.bytes())
    return [value for row in source for value in row], pixels, nal, int(dc_mode)


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.ctu_start_valid.value = 0
    dut.s_valid.value = 0
    dut.s_pixel.value = 0
    dut.s_quality.value = 1
    dut.recon_ready.value = 0
    dut.nal_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def raw_ctu16_pixels_match_reconstruction_and_annexb(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    source, expected_pixels, expected_nal, expected_mode = make_vectors()
    dut.slice_row.value = 0
    dut.qp.value = QUALITY_QPS["medium"]
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0xCA16_265)
    ctu_started = False
    source_index = 0
    pixels = []
    nal = bytearray()
    for _ in range(80000):
        dut.ctu_start_valid.value = int(not ctu_started)
        if ctu_started and source_index < 256:
            dut.s_valid.value = int(rng.random() < 0.84)
            dut.s_pixel.value = source[source_index]
        else:
            dut.s_valid.value = 0
        dut.recon_ready.value = int(rng.random() < 0.78)
        dut.nal_ready.value = int(rng.random() < 0.72)
        await Timer(1, units="ns")
        ctu_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        if int(dut.recon_valid.value) and int(dut.recon_ready.value):
            pixels.append((int(dut.recon_pixel.value), int(dut.recon_x.value), int(dut.recon_y.value), bool(dut.recon_block_last.value)))
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(int(dut.nal_byte.value))
        await RisingEdge(dut.clk)
        ctu_started |= bool(ctu_fire)
        source_index += int(source_fire)
        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert source_index == 256
            assert pixels == expected_pixels
            assert bytes(nal) == expected_nal
            assert int(dut.current_luma_mode_dc.value) == expected_mode
            return
    raise AssertionError("raw CTU16 pixel top timed out")
