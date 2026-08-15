from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import CABAC_INIT_I, CabacByteEncoder, coefficient_context_init_states
from hevc_reference.chroma_coeff_syntax import coefficient_syntax_bins_8
from hevc_reference.chroma_ctu_syntax import ctu16_yuv_syntax_bins
from hevc_reference.chroma_tu8 import chroma_qp, forward_transform_8, inverse_transform_8, quantize_dequantize_8
from hevc_reference.cu_syntax import CABAC_BYPASS, CuSyntaxBin
from hevc_reference.intra import filtered_dc_prediction, planar_prediction_16, prediction_residual, reconstruct_sample, residual_sad
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16
from hevc_reference.transform import forward_transform_16, inverse_transform_16


def mapped(events):
    return tuple(CuSyntaxBin(event.value, CABAC_BYPASS if event.bypass else 0,
                             coefficient_context_address(event) or 0)
                 for event in events)


def luma_expected(source, qp):
    refs = [128] * 19
    dc_prediction = filtered_dc_prediction(refs[1:17], refs[1:17])
    planar_prediction = planar_prediction_16(refs, refs)
    dc_residual = prediction_residual(source, dc_prediction)
    planar_residual = prediction_residual(source, planar_prediction)
    dc_mode = not (residual_sad(planar_residual) < residual_sad(dc_residual))
    prediction = dc_prediction if dc_mode else planar_prediction
    residual = dc_residual if dc_mode else planar_residual
    transformed = forward_transform_16(residual)[1]
    pairs = [[quantize_dequantize_coefficient(transformed[y][x], qp)
              for x in range(16)] for y in range(16)]
    quantized = [[pairs[y][x][0] for x in range(16)] for y in range(16)]
    restored = inverse_transform_16([[pairs[y][x][1] for x in range(16)]
                                    for y in range(16)])[1]
    pixels = [(reconstruct_sample(prediction[y][x], restored[y][x]), x, y,
               x == 15 and y == 15) for y in range(16) for x in range(16)]
    return int(dc_mode), quantized, pixels


def chroma_expected(source, qp, plane):
    residual = [[source[y][x] - 128 for x in range(8)] for y in range(8)]
    transformed = forward_transform_8(residual)[1]
    cqp = chroma_qp(qp)
    pairs = [[quantize_dequantize_8(transformed[y][x], cqp)
              for x in range(8)] for y in range(8)]
    quantized = [[pairs[y][x][0] for x in range(8)] for y in range(8)]
    restored = inverse_transform_8([[pairs[y][x][1] for x in range(8)]
                                   for y in range(8)])[1]
    pixels = [(plane, reconstruct_sample(128, restored[y][x]), x, y,
               x == 7 and y == 7) for y in range(8) for x in range(8)]
    return quantized, pixels


def expected_nal(qp, mode_dc, y_coeff, cb_coeff, cr_coeff):
    events = ctu16_yuv_syntax_bins(
        mode_dc, mapped(coefficient_syntax_bins_16(y_coeff)),
        mapped(coefficient_syntax_bins_8(cb_coeff)),
        mapped(coefficient_syntax_bins_8(cr_coeff)), True)
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for event in events:
        if event.kind == 2:
            encoder.encode_terminate(event.value)
        elif event.kind == CABAC_BYPASS:
            encoder.encode_bypass(event.value)
        else:
            encoder.encode_regular(event.value, event.context_address)
    return build_annexb_nal(
        20, idr_slice_header_bytes(0, qp, 1, 1) + encoder.bytes())


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("start_valid", "ctu_start_valid", "y_valid", "cb_valid",
                 "cr_valid", "y_recon_ready", "chroma_recon_ready", "nal_ready"):
        getattr(dut, name).value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def raw_yuv420_ctu_matches_reconstruction_and_annexb(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    qp = QUALITY_QPS["medium"]
    y_source = [[(23 + x * 9 + y * 5 + ((x * y) & 31)) & 255
                 for x in range(16)] for y in range(16)]
    cb_source = [[(51 + x * 17 + y * 11) & 255 for x in range(8)]
                 for y in range(8)]
    cr_source = [[128] * 8 for _ in range(8)]
    mode_dc, y_coeff, expected_y = luma_expected(y_source, qp)
    cb_coeff, expected_cb = chroma_expected(cb_source, qp, 1)
    cr_coeff, expected_cr = chroma_expected(cr_source, qp, 2)
    expected_bytes = expected_nal(qp, mode_dc, y_coeff, cb_coeff, cr_coeff)
    sources = {
        "y": [value for row in y_source for value in row],
        "cb": [value for row in cb_source for value in row],
        "cr": [value for row in cr_source for value in row],
    }

    dut.slice_row.value = 0
    dut.qp.value = qp
    dut.quality.value = 1
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0
    dut.ctu_start_valid.value = 1

    indices = {name: 0 for name in sources}
    reconstructed_y = []
    reconstructed_chroma = []
    nal = bytearray()
    rng = random.Random(0x16_420_265)
    ctu_started = False

    for _ in range(140000):
        for name, source in sources.items():
            valid = getattr(dut, name + "_valid")
            if not int(valid.value) and indices[name] < len(source):
                getattr(dut, name + "_pixel").value = source[indices[name]]
                valid.value = int(rng.random() < 0.86)
        dut.y_recon_ready.value = int(rng.random() < 0.76)
        dut.chroma_recon_ready.value = int(rng.random() < 0.73)
        dut.nal_ready.value = int(rng.random() < 0.69)
        await Timer(1, units="ns")

        ctu_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
        fires = {name: int(getattr(dut, name + "_valid").value) and
                 int(getattr(dut, name + "_ready").value) for name in sources}
        if int(dut.y_recon_valid.value) and int(dut.y_recon_ready.value):
            reconstructed_y.append((int(dut.y_reconstructed.value),
                int(dut.y_recon_x.value), int(dut.y_recon_y.value),
                bool(dut.y_recon_block_last.value)))
        if int(dut.chroma_recon_valid.value) and int(dut.chroma_recon_ready.value):
            reconstructed_chroma.append((int(dut.chroma_recon_plane.value),
                int(dut.chroma_reconstructed.value), int(dut.chroma_recon_x.value),
                int(dut.chroma_recon_y.value),
                bool(dut.chroma_recon_block_last.value)))
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(int(dut.nal_byte.value))

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if ctu_fire:
            ctu_started = True
            dut.ctu_start_valid.value = 0
        for name, fire in fires.items():
            if fire:
                indices[name] += 1
                getattr(dut, name + "_valid").value = 0
        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert ctu_started
            assert indices == {"y": 256, "cb": 64, "cr": 64}
            assert reconstructed_y == expected_y
            assert reconstructed_chroma == expected_cb + expected_cr
            assert bytes(nal) == expected_bytes
            assert int(dut.current_luma_mode_dc.value) == mode_dc
            assert not int(dut.busy.value)
            return
    raise AssertionError(
        f"raw YUV CTU top timeout indices={indices} nal={len(nal)}")
