from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_intra import (
    chroma_dc_prediction_8,
    chroma_planar_prediction_8,
)
from hevc_reference.chroma_tu8 import (
    chroma_qp,
    forward_transform_8,
    inverse_transform_8,
    quantize_dequantize_8,
)
from hevc_reference.quant import QUALITY_QPS


FRAME_WIDTH = 32
CHROMA_WIDTH = FRAME_WIDTH // 2
QUALITY_CODES = {"good": 0, "medium": 1, "poor": 2}


def expected_references(
    top_line, left_edge, carried_top_left, ctu_x, top_available
):
    base = ctu_x * 8
    raw = [128] * 19
    available = [False] * 19
    for scan_index in range(19):
        if scan_index < 9:
            offset = 8 - scan_index
            if ctu_x != 0 and offset < 8:
                raw[scan_index] = left_edge[offset]
                available[scan_index] = True
        elif scan_index == 9:
            if top_available and ctu_x != 0:
                raw[scan_index] = carried_top_left
                available[scan_index] = True
        else:
            offset = scan_index - 10
            if top_available and base + offset < CHROMA_WIDTH:
                raw[scan_index] = top_line[base + offset]
                available[scan_index] = True

    first = next((value for value, valid in zip(raw, available) if valid), 128)
    filled = []
    running = first
    for value, valid in zip(raw, available):
        if valid:
            running = value
        filled.append(running)
    pairs = [
        (filled[9], filled[9]) if index == 0 else
        (filled[9 + index], filled[9 - index])
        for index in range(10)
    ]
    return [pair[0] for pair in pairs], [pair[1] for pair in pairs]


def expected_block(prediction, source, quality, plane):
    residual = [
        [source[y][x] - prediction[y][x] for x in range(8)]
        for y in range(8)
    ]
    transformed = forward_transform_8(residual)[1]
    qp = chroma_qp(QUALITY_QPS[quality])
    pairs = [
        [quantize_dequantize_8(transformed[y][x], qp) for x in range(8)]
        for y in range(8)
    ]
    quantized = [[pairs[y][x][0] for x in range(8)] for y in range(8)]
    dequantized = [[pairs[y][x][1] for x in range(8)] for y in range(8)]
    restored = inverse_transform_8(dequantized)[1]
    cbf = any(value != 0 for row in quantized for value in row)
    coefficients = [
        (plane, quantized[y][x], y * 8 + x, x == 7 and y == 7)
        for y in range(8) for x in range(8)
    ] if cbf else []
    reconstructed = [
        [min(255, max(0, prediction[y][x] + restored[y][x]))
         for x in range(8)] for y in range(8)
    ]
    pixels = [
        (plane, reconstructed[y][x], x, y, x == 7 and y == 7)
        for y in range(8) for x in range(8)
    ]
    return cbf, coefficients, reconstructed, pixels


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.cb_valid.value = 0
    dut.cr_valid.value = 0
    dut.m_ready.value = 0
    dut.descriptor_ready.value = 0
    dut.coefficient_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_ctu(
    dut, ctu_x, top_available, mode_dc, quality, cb_source, cr_source,
    expected_pixels, expected_coefficients, expected_descriptor, seed,
):
    while not int(dut.start_ready.value):
        await RisingEdge(dut.clk)
    dut.ctu_x.value = ctu_x
    dut.top_available.value = top_available
    dut.luma_mode_dc.value = mode_dc
    dut.quality.value = QUALITY_CODES[quality]
    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    sources = {
        "cb": [value for row in cb_source for value in row],
        "cr": [value for row in cr_source for value in row],
    }
    indices = {"cb": 0, "cr": 0}
    pixels = []
    coefficients = []
    descriptors = []
    stalled_pixel = None
    stalled_coefficient = None
    stalled_descriptor = None
    rng = random.Random(seed)

    for _ in range(40000):
        for name in ("cb", "cr"):
            valid = getattr(dut, f"{name}_valid")
            if (not int(valid.value) and indices[name] < 64 and
                    rng.random() < 0.84):
                getattr(dut, f"{name}_pixel").value = sources[name][indices[name]]
                valid.value = 1

        dut.m_ready.value = int(rng.random() < 0.71)
        dut.coefficient_ready.value = int(rng.random() < 0.68)
        dut.descriptor_ready.value = int(rng.random() < 0.66)
        await Timer(1, units="ns")

        source_fires = {
            name: int(getattr(dut, f"{name}_valid").value) and
            int(getattr(dut, f"{name}_ready").value)
            for name in ("cb", "cr")
        }
        pixel_valid = int(dut.m_valid.value)
        pixel_ready = int(dut.m_ready.value)
        pixel = (
            int(dut.m_plane.value), int(dut.m_reconstructed.value),
            int(dut.m_x.value), int(dut.m_y.value),
            bool(dut.m_block_last.value),
        )
        coefficient_valid = int(dut.coefficient_valid.value)
        coefficient_ready = int(dut.coefficient_ready.value)
        coefficient = (
            int(dut.coefficient_plane.value),
            dut.coefficient.value.signed_integer,
            int(dut.coefficient_raster_address.value),
            bool(dut.coefficient_block_last.value),
        )
        descriptor_valid = int(dut.descriptor_valid.value)
        descriptor_ready = int(dut.descriptor_ready.value)
        descriptor = (bool(dut.cb_cbf.value), bool(dut.cr_cbf.value))

        if stalled_pixel is not None:
            assert pixel_valid and pixel == stalled_pixel
        if stalled_coefficient is not None:
            assert coefficient_valid and coefficient == stalled_coefficient
        if stalled_descriptor is not None:
            assert descriptor_valid and descriptor == stalled_descriptor
        stalled_pixel = pixel if pixel_valid and not pixel_ready else None
        stalled_coefficient = (
            coefficient if coefficient_valid and not coefficient_ready else None
        )
        stalled_descriptor = (
            descriptor if descriptor_valid and not descriptor_ready else None
        )

        if pixel_valid and pixel_ready:
            pixels.append(pixel)
        if coefficient_valid and coefficient_ready:
            coefficients.append(coefficient)
        if descriptor_valid and descriptor_ready:
            descriptors.append(descriptor)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        for name, fired in source_fires.items():
            if fired:
                indices[name] += 1
                getattr(dut, f"{name}_valid").value = 0

        if int(dut.block_done.value):
            assert indices == {"cb": 64, "cr": 64}
            assert pixels == expected_pixels
            assert coefficients == expected_coefficients
            assert descriptors == [expected_descriptor]
            assert not int(dut.block_error.value), (
                f"block_error error_latched={int(dut.error_latched.value)} "
                f"bridge_error={int(dut.bridge_error.value)} "
                f"cb_commit={int(dut.cb_commit_seen.value)} "
                f"cr_commit={int(dut.cr_commit_seen.value)} "
                f"cb_ref_error={int(dut.cb_ref_error.value)} "
                f"cr_ref_error={int(dut.cr_ref_error.value)} "
                f"predictor_error={int(dut.predictor_error.value)}"
            )
            assert not int(dut.protocol_error.value)
            assert not int(dut.parameter_error.value)
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"chroma CTU controller timed out indices={indices} "
        f"pixels={len(pixels)} coefficients={len(coefficients)} "
        f"descriptors={descriptors} busy={int(dut.busy.value)}"
    )


@cocotb.test()
async def cb_then_cr_share_datapath_and_keep_independent_references(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    state = {
        plane: {
            "top": [128] * CHROMA_WIDTH,
            "left": [128] * 8,
            "corner": 128,
        }
        for plane in (1, 2)
    }

    block_index = 0
    for block_y in range(2):
        for ctu_x in range(2):
            top_available = block_y != 0
            mode_dc = block_index % 2 == 0
            quality = ("medium", "good", "poor", "medium")[block_index]
            expected_pixels = []
            expected_coefficients = []
            descriptor = []
            sources = {}

            for plane, name in ((1, "cb"), (2, "cr")):
                plane_state = state[plane]
                top, left = expected_references(
                    plane_state["top"], plane_state["left"],
                    plane_state["corner"], ctu_x, top_available,
                )
                prediction = (
                    chroma_dc_prediction_8(top, left) if mode_dc else
                    chroma_planar_prediction_8(top, left)
                )
                if block_index == 1 and plane == 2:
                    source = [row[:] for row in prediction]
                else:
                    source = [
                        [((plane * 47 + block_index * 31 + y * 19 + x * 23) &
                          255) for x in range(8)]
                        for y in range(8)
                    ]
                cbf, coefficients, reconstructed, pixels = expected_block(
                    prediction, source, quality, plane
                )
                descriptor.append(cbf)
                expected_coefficients.extend(coefficients)
                expected_pixels.extend(pixels)
                sources[name] = source

                base = ctu_x * 8
                if top_available:
                    plane_state["corner"] = plane_state["top"][base + 7]
                plane_state["top"][base:base + 8] = reconstructed[7]
                plane_state["left"] = [reconstructed[y][7] for y in range(8)]

            await run_ctu(
                dut, ctu_x, top_available, mode_dc, quality,
                sources["cb"], sources["cr"], expected_pixels,
                expected_coefficients, tuple(descriptor), 0xC700 + block_index,
            )
            block_index += 1
