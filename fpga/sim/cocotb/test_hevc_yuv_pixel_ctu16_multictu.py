from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import CABAC_INIT_I, CabacByteEncoder, coefficient_context_init_states
from hevc_reference.chroma_coeff_syntax import coefficient_syntax_bins_8
from hevc_reference.chroma_ctu_syntax import ctu16_yuv_syntax_bins
from hevc_reference.chroma_intra import chroma_dc_prediction_8, chroma_planar_prediction_8
from hevc_reference.chroma_tu8 import chroma_qp, forward_transform_8, inverse_transform_8, quantize_dequantize_8
from hevc_reference.cu_syntax import CABAC_BYPASS, CuSyntaxBin
from hevc_reference.intra import filtered_dc_prediction, planar_prediction_16, prediction_residual, reconstruct_sample, residual_sad
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16
from hevc_reference.transform import forward_transform_16, inverse_transform_16


CTU_COLUMNS = 2
CTU_ROWS = 1


def mapped(events):
    return tuple(CuSyntaxBin(event.value, CABAC_BYPASS if event.bypass else 0,
                             coefficient_context_address(event) or 0)
                 for event in events)


def luma_expected(source, qp, top, left):
    dc_prediction = filtered_dc_prediction(top[1:17], left[1:17])
    planar_prediction = planar_prediction_16(top, left)
    dc_residual = prediction_residual(source, dc_prediction)
    planar_residual = prediction_residual(source, planar_prediction)
    mode_dc = not (residual_sad(planar_residual) < residual_sad(dc_residual))
    prediction = dc_prediction if mode_dc else planar_prediction
    residual = dc_residual if mode_dc else planar_residual
    transformed = forward_transform_16(residual)[1]
    pairs = [[quantize_dequantize_coefficient(transformed[y][x], qp)
              for x in range(16)] for y in range(16)]
    quantized = [[pairs[y][x][0] for x in range(16)] for y in range(16)]
    restored = inverse_transform_16([[pairs[y][x][1] for x in range(16)]
                                    for y in range(16)])[1]
    reconstructed = [[reconstruct_sample(prediction[y][x], restored[y][x])
                      for x in range(16)] for y in range(16)]
    pixels = [(reconstructed[y][x], x, y, x == 15 and y == 15)
              for y in range(16) for x in range(16)]
    return int(mode_dc), quantized, reconstructed, pixels


def chroma_expected(source, qp, plane, mode_dc, top, left):
    prediction = (chroma_dc_prediction_8(top, left) if mode_dc else
                  chroma_planar_prediction_8(top, left))
    residual = prediction_residual(source, prediction)
    transformed = forward_transform_8(residual)[1]
    cqp = chroma_qp(qp)
    pairs = [[quantize_dequantize_8(transformed[y][x], cqp)
              for x in range(8)] for y in range(8)]
    quantized = [[pairs[y][x][0] for x in range(8)] for y in range(8)]
    restored = inverse_transform_8([[pairs[y][x][1] for x in range(8)]
                                   for y in range(8)])[1]
    reconstructed = [[reconstruct_sample(prediction[y][x], restored[y][x])
                      for x in range(8)] for y in range(8)]
    pixels = [(plane, reconstructed[y][x], x, y, x == 7 and y == 7)
              for y in range(8) for x in range(8)]
    return quantized, reconstructed, pixels


def right_edge_references(block, size):
    edge = [block[y][size - 1] for y in range(size)]
    top = [edge[0]] * (size + 2 if size == 8 else size + 3)
    left = [edge[0], *edge, edge[-1]]
    if size == 16:
        left.append(edge[-1])
    return top, left


def build_vectors(qp):
    vectors = []
    previous = {"y": None, "cb": None, "cr": None}
    for index in range(CTU_COLUMNS):
        y_source = [[(19 + index * 53 + x * 7 + y * 11 + ((x * y) & 15)) & 255
                     for x in range(16)] for y in range(16)]
        cb_source = [[(43 + index * 37 + x * 13 + y * 17) & 255
                      for x in range(8)] for y in range(8)]
        cr_source = [[(157 + index * 29 - x * 9 + y * 5) & 255
                      for x in range(8)] for y in range(8)]
        if index == 0:
            y_top = y_left = [128] * 19
            cb_top = cb_left = [128] * 10
            cr_top = cr_left = [128] * 10
        else:
            y_top, y_left = right_edge_references(previous["y"], 16)
            cb_top, cb_left = right_edge_references(previous["cb"], 8)
            cr_top, cr_left = right_edge_references(previous["cr"], 8)
        mode_dc, y_coeff, y_recon, y_pixels = luma_expected(
            y_source, qp, y_top, y_left)
        cb_coeff, cb_recon, cb_pixels = chroma_expected(
            cb_source, qp, 1, mode_dc, cb_top, cb_left)
        cr_coeff, cr_recon, cr_pixels = chroma_expected(
            cr_source, qp, 2, mode_dc, cr_top, cr_left)
        previous = {"y": y_recon, "cb": cb_recon, "cr": cr_recon}
        vectors.append({
            "source": {
                "y": [value for row in y_source for value in row],
                "cb": [value for row in cb_source for value in row],
                "cr": [value for row in cr_source for value in row],
            },
            "mode_dc": mode_dc,
            "y_coeff": y_coeff,
            "cb_coeff": cb_coeff,
            "cr_coeff": cr_coeff,
            "y_pixels": y_pixels,
            "chroma_pixels": cb_pixels + cr_pixels,
        })
    return vectors


def expected_nal(qp, vectors):
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for index, vector in enumerate(vectors):
        events = ctu16_yuv_syntax_bins(
            vector["mode_dc"], mapped(coefficient_syntax_bins_16(vector["y_coeff"])),
            mapped(coefficient_syntax_bins_8(vector["cb_coeff"])),
            mapped(coefficient_syntax_bins_8(vector["cr_coeff"])),
            index == len(vectors) - 1)
        for event in events:
            if event.kind == 2:
                encoder.encode_terminate(event.value)
            elif event.kind == CABAC_BYPASS:
                encoder.encode_bypass(event.value)
            else:
                encoder.encode_regular(event.value, event.context_address)
    return build_annexb_nal(
        20, idr_slice_header_bytes(0, qp, CTU_COLUMNS, CTU_ROWS,
                                   slice_ctu_rows=1) + encoder.bytes())


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("start_valid", "ctu_start_valid", "y_valid", "cb_valid",
                 "cr_valid", "y_recon_ready", "chroma_recon_ready", "nal_ready"):
        getattr(dut, name).value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_two_ctus(dut, random_stalls):
    qp = QUALITY_QPS["medium"]
    vectors = build_vectors(qp)
    expected_bytes = expected_nal(qp, vectors)
    expected_y = [pixel for vector in vectors for pixel in vector["y_pixels"]]
    expected_chroma = [pixel for vector in vectors
                       for pixel in vector["chroma_pixels"]]

    dut.slice_row.value = 0
    dut.qp.value = qp
    dut.quality.value = 1
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0x2_16_420_265)
    started = completed = 0
    indices = {"y": 0, "cb": 0, "cr": 0}
    y_pixels, chroma_pixels, nal = [], [], bytearray()
    start_cycles, done_cycles, started_positions = [], [], []
    luma_done_cycles, chroma_done_cycles = [], []

    for cycle in range(300000):
        dut.ctu_start_valid.value = int(started == completed and started < CTU_COLUMNS)
        active = started > completed
        source = vectors[started - 1]["source"] if active else None
        for name in indices:
            valid = getattr(dut, name + "_valid")
            if (active and not int(valid.value) and indices[name] < len(source[name])):
                getattr(dut, name + "_pixel").value = source[name][indices[name]]
                valid.value = int(not random_stalls or rng.random() < 0.86)
            elif not active:
                valid.value = 0
        dut.y_recon_ready.value = int(not random_stalls or rng.random() < 0.78)
        dut.chroma_recon_ready.value = int(not random_stalls or rng.random() < 0.74)
        dut.nal_ready.value = int(not random_stalls or rng.random() < 0.70)
        await Timer(1, units="ns")

        start_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
        fires = {name: int(getattr(dut, name + "_valid").value) and
                 int(getattr(dut, name + "_ready").value) for name in indices}
        if int(dut.y_recon_valid.value) and int(dut.y_recon_ready.value):
            y_pixels.append((int(dut.y_reconstructed.value), int(dut.y_recon_x.value),
                             int(dut.y_recon_y.value), bool(dut.y_recon_block_last.value)))
        if int(dut.chroma_recon_valid.value) and int(dut.chroma_recon_ready.value):
            chroma_pixels.append((int(dut.chroma_recon_plane.value),
                int(dut.chroma_reconstructed.value), int(dut.chroma_recon_x.value),
                int(dut.chroma_recon_y.value), bool(dut.chroma_recon_block_last.value)))
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(int(dut.nal_byte.value))

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if start_fire:
            start_cycles.append(cycle)
            started_positions.append((int(dut.current_ctu_x.value),
                                      int(dut.current_ctu_y.value)))
            started += 1
            indices = {"y": 0, "cb": 0, "cr": 0}
        for name, fire in fires.items():
            if fire:
                indices[name] += 1
                getattr(dut, name + "_valid").value = 0
        if int(dut.ctu_done.value):
            assert indices == {"y": 256, "cb": 64, "cr": 64}
            completed += 1
            done_cycles.append(cycle)
        if int(dut.luma_tu_done.value):
            luma_done_cycles.append(cycle)
        if int(dut.chroma_tu_done.value):
            chroma_done_cycles.append(cycle)
        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)

        if int(dut.done.value):
            assert started == completed == CTU_COLUMNS
            assert started_positions == [(0, 0), (1, 0)]
            assert y_pixels == expected_y
            assert chroma_pixels == expected_chroma
            assert bytes(nal) == expected_bytes
            assert not int(dut.busy.value)
            return (start_cycles, done_cycles, luma_done_cycles,
                    chroma_done_cycles, len(nal))
    raise AssertionError(f"two-CTU YUV slice timed out: {completed}/{CTU_COLUMNS}")


@cocotb.test()
async def adjacent_ctus_preserve_luma_chroma_references_under_stalls(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await run_two_ctus(dut, random_stalls=True)


@cocotb.test()
async def adjacent_ctus_report_full_path_interval_without_stalls(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    starts, completions, luma_done, chroma_done, nal_bytes = await run_two_ctus(
        dut, random_stalls=False)
    assert starts[1] - starts[0] == 3275
    assert [done - start for start, done in zip(starts, luma_done)] == [1699, 1699]
    assert [done - start for start, done in zip(starts, chroma_done)] == [1908, 1908]
    dut._log.info("full YUV camera-to-NAL start interval: %d cycles",
                  starts[1] - starts[0])
    dut._log.info("full YUV camera-to-NAL CTU service cycles: %s",
                  [done - start for start, done in zip(starts, completions)])
    dut._log.info("two-CTU Annex-B size: %d bytes", nal_bytes)
    dut._log.info("luma completion offsets: %s",
                  [done - start for start, done in zip(starts, luma_done)])
    dut._log.info("chroma completion offsets: %s",
                  [done - start for start, done in zip(starts, chroma_done)])
