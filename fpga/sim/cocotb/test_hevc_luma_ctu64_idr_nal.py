from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import (
    CABAC_INIT_I,
    CabacByteEncoder,
    coefficient_context_init_states,
)
from hevc_reference.cu_syntax import CABAC_BYPASS, intra_cu16_prefix_bins
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import (
    coefficient_context_address,
    coefficient_syntax_bins_16,
)
from hevc_reference.transform import forward_transform_16, inverse_transform_16


QUALITY_MEDIUM = 1
CTU_COLUMNS = 1
CTU_ROWS = 1


def encode_cabac(qp, modes, cbfs, quantized_blocks):
    contexts = coefficient_context_init_states(CABAC_INIT_I, qp)
    encoder = CabacByteEncoder(contexts)
    for cu_index in range(16):
        for event in intra_cu16_prefix_bins(
            cu_index, 0, modes[cu_index], cbfs[cu_index]
        ):
            if event.kind == CABAC_BYPASS:
                encoder.encode_bypass(event.value)
            else:
                encoder.encode_regular(event.value, event.context_address)
        if cbfs[cu_index]:
            for event in coefficient_syntax_bins_16(quantized_blocks[cu_index]):
                address = coefficient_context_address(event)
                if address is None:
                    encoder.encode_bypass(event.value)
                else:
                    encoder.encode_regular(event.value, address)
    encoder.encode_terminate(1)
    return encoder.bytes()


def make_vectors():
    modes = tuple(index & 1 for index in range(16))
    source = []
    reconstructed = []
    quantized_blocks = []
    cbfs = []
    qp = QUALITY_QPS["medium"]

    for cu_index in range(16):
        prediction = [
            [64 + cu_index * 3 + ((x + y) & 3) for x in range(16)]
            for y in range(16)
        ]
        if cu_index == 0:
            residual = [[12] * 16 for _ in range(16)]
        elif cu_index == 7:
            residual = [[-9] * 16 for _ in range(16)]
        else:
            residual = [[0] * 16 for _ in range(16)]

        coefficients = forward_transform_16(residual)[1]
        quantized = [[0] * 16 for _ in range(16)]
        dequantized = [[0] * 16 for _ in range(16)]
        for y in range(16):
            for x in range(16):
                quantized[y][x], dequantized[y][x] = (
                    quantize_dequantize_coefficient(coefficients[y][x], qp)
                )
        restored = inverse_transform_16(dequantized)[1]
        quantized_blocks.append(quantized)
        cbfs.append(any(value for row in quantized for value in row))

        for y in range(16):
            for x in range(16):
                source.append((prediction[y][x], residual[y][x], modes[cu_index]))
                pixel = min(255, max(0, prediction[y][x] + restored[y][x]))
                reconstructed.append((cu_index, pixel, x, y, x == 15 and y == 15))

    return modes, tuple(cbfs), tuple(quantized_blocks), source, reconstructed


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.slice_row.value = 0
    dut.qp.value = QUALITY_QPS["medium"]
    dut.no_output_of_prior_pics.value = 0
    dut.ctu_start_valid.value = 0
    dut.s_valid.value = 0
    dut.s_prediction.value = 0
    dut.s_residual.value = 0
    dut.s_quality.value = QUALITY_MEDIUM
    dut.s_luma_mode_dc.value = 0
    dut.recon_ready.value = 0
    dut.nal_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def complete_luma_ctu_matches_pixel_and_annexb_references(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    qp = QUALITY_QPS["medium"]
    modes, cbfs, blocks, source, expected_pixels = make_vectors()
    expected_nal = build_annexb_nal(
        20,
        idr_slice_header_bytes(0, qp, CTU_COLUMNS, CTU_ROWS)
        + encode_cabac(qp, modes, cbfs, blocks),
    )

    dut.slice_row.value = 0
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0x64_16_265)
    ctu_started = False
    source_index = 0
    pixels = []
    nal = bytearray()
    nal_last_positions = []
    completed_tus = 0
    stalled_pixel = None
    stalled_nal = None

    for _ in range(250000):
        dut.ctu_start_valid.value = int(not ctu_started)
        if ctu_started and source_index < len(source):
            prediction, residual, mode = source[source_index]
            dut.s_valid.value = 1
            dut.s_prediction.value = prediction
            dut.s_residual.value = residual
            dut.s_quality.value = QUALITY_MEDIUM
            dut.s_luma_mode_dc.value = mode
        else:
            dut.s_valid.value = 0

        dut.recon_ready.value = int(rng.random() < 0.76)
        dut.nal_ready.value = int(rng.random() < 0.71)
        await Timer(1, units="ns")

        ctu_start_fire = int(dut.ctu_start_valid.value) and int(
            dut.ctu_start_ready.value
        )
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        pixel = (
            int(dut.current_cu_index.value),
            int(dut.recon_pixel.value),
            int(dut.recon_x.value),
            int(dut.recon_y.value),
            bool(dut.recon_block_last.value),
        )
        nal_beat = (int(dut.nal_byte.value), bool(dut.nal_last.value))

        if stalled_pixel is not None:
            assert int(dut.recon_valid.value)
            assert pixel == stalled_pixel
        if stalled_nal is not None:
            assert int(dut.nal_valid.value)
            assert nal_beat == stalled_nal
        stalled_pixel = (
            pixel
            if int(dut.recon_valid.value) and not int(dut.recon_ready.value)
            else None
        )
        stalled_nal = (
            nal_beat
            if int(dut.nal_valid.value) and not int(dut.nal_ready.value)
            else None
        )

        if int(dut.recon_valid.value) and int(dut.recon_ready.value):
            pixels.append(pixel)
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(nal_beat[0])
            if nal_beat[1]:
                nal_last_positions.append(len(nal) - 1)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if ctu_start_fire:
            ctu_started = True
        if source_fire:
            source_index += 1
        if int(dut.tu_done.value):
            completed_tus += 1

        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value), (
            f"protocol: nal={int(dut.nal_protocol_error.value)} "
            f"bridge={int(dut.bridge_error.value)} cu={int(dut.cu_index.value)} "
            f"bridge_done={int(dut.bridge_done.value)} "
            f"nal_ctu_done={int(dut.nal_ctu_done.value)} tus={completed_tus}"
        )

        if int(dut.done.value):
            assert source_index == 16 * 256
            assert completed_tus == 16
            assert pixels == expected_pixels
            assert bytes(nal) == expected_nal
            assert nal_last_positions == [len(nal) - 1]
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"full luma CTU timed out: source={source_index}/4096 "
        f"pixels={len(pixels)}/4096 tus={completed_tus} "
        f"nal={len(nal)}/{len(expected_nal)} busy={int(dut.busy.value)}"
    )
