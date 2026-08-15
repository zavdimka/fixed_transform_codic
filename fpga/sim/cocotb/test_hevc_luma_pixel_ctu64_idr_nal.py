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
from hevc_reference.intra import (
    filtered_dc_prediction,
    planar_prediction_16,
    prediction_residual,
    reconstruct_sample,
    residual_sad,
)
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import (
    coefficient_context_address,
    coefficient_syntax_bins_16,
)
from hevc_reference.transform import forward_transform_16, inverse_transform_16
from test_hevc_luma_reference_line_store import substitute_references, z_to_xy


QUALITY_MEDIUM = 1


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
    completed: set[int] = set()
    bottom: dict[int, list[int]] = {}
    right: dict[int, list[int]] = {}
    previous_right = [128] * 64
    qp = QUALITY_QPS["medium"]

    source_stream = []
    expected_pixels = []
    modes = []
    cbfs = []
    quantized_blocks = []

    for cu_index in range(16):
        bx, by = z_to_xy(cu_index)
        top, left = substitute_references(
            0, cu_index, completed, bottom, right, previous_right
        )
        source = [
            [
                (31 + bx * 43 + by * 29 + x * 5 + y * 7
                 + ((x * y + cu_index) & 15)) & 255
                for x in range(16)
            ]
            for y in range(16)
        ]
        dc_prediction = filtered_dc_prediction(top[1:17], left[1:17])
        planar_prediction = planar_prediction_16(top, left)
        dc_residual = prediction_residual(source, dc_prediction)
        planar_residual = prediction_residual(source, planar_prediction)
        planar_selected = residual_sad(planar_residual) < residual_sad(dc_residual)
        prediction = planar_prediction if planar_selected else dc_prediction
        residual = planar_residual if planar_selected else dc_residual
        modes.append(0 if planar_selected else 1)

        coefficients = forward_transform_16(residual)[1]
        quantized = [[0] * 16 for _ in range(16)]
        dequantized = [[0] * 16 for _ in range(16)]
        for y in range(16):
            for x in range(16):
                quantized[y][x], dequantized[y][x] = (
                    quantize_dequantize_coefficient(coefficients[y][x], qp)
                )
        restored = inverse_transform_16(dequantized)[1]
        reconstructed = [
            [reconstruct_sample(prediction[y][x], restored[y][x]) for x in range(16)]
            for y in range(16)
        ]

        quantized_blocks.append(quantized)
        cbfs.append(any(value for row in quantized for value in row))
        for y in range(16):
            for x in range(16):
                source_stream.append(source[y][x])
                expected_pixels.append(
                    (cu_index, reconstructed[y][x], x, y, x == 15 and y == 15)
                )

        raster = by * 4 + bx
        bottom[raster] = reconstructed[15][:]
        right[raster] = [reconstructed[y][15] for y in range(16)]
        completed.add(raster)
        if bx == 3:
            for y in range(16):
                previous_right[by * 16 + y] = reconstructed[y][15]

    expected_nal = build_annexb_nal(
        20,
        idr_slice_header_bytes(0, qp, 1, 1)
        + encode_cabac(qp, modes, cbfs, quantized_blocks),
    )
    return source_stream, expected_pixels, expected_nal


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.slice_row.value = 0
    dut.qp.value = QUALITY_QPS["medium"]
    dut.no_output_of_prior_pics.value = 0
    dut.ctu_start_valid.value = 0
    dut.s_valid.value = 0
    dut.s_pixel.value = 0
    dut.s_quality.value = QUALITY_MEDIUM
    dut.recon_ready.value = 0
    dut.nal_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def raw_pixels_drive_reconstruction_and_annexb(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    source, expected_pixels, expected_nal = make_vectors()

    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0xCA6E_265)
    ctu_started = False
    source_index = 0
    pixels = []
    nal = bytearray()
    stalled_pixel = None
    stalled_nal = None

    for _ in range(400000):
        dut.ctu_start_valid.value = int(not ctu_started)
        if ctu_started and source_index < len(source):
            dut.s_valid.value = int(rng.random() < 0.84)
            dut.s_pixel.value = source[source_index]
        else:
            dut.s_valid.value = 0
        dut.recon_ready.value = int(rng.random() < 0.78)
        dut.nal_ready.value = int(rng.random() < 0.72)
        await Timer(1, units="ns")

        ctu_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
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
            pixel if int(dut.recon_valid.value) and not int(dut.recon_ready.value)
            else None
        )
        stalled_nal = (
            nal_beat if int(dut.nal_valid.value) and not int(dut.nal_ready.value)
            else None
        )
        if int(dut.recon_valid.value) and int(dut.recon_ready.value):
            pixels.append(pixel)
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(nal_beat[0])

        await RisingEdge(dut.clk)
        if ctu_fire:
            ctu_started = True
        if source_fire:
            source_index += 1

        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert source_index == 4096
            assert pixels == expected_pixels
            assert bytes(nal) == expected_nal
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"pixel top timed out source={source_index}/4096 "
        f"pixels={len(pixels)}/4096 nal={len(nal)}/{len(expected_nal)}"
    )
