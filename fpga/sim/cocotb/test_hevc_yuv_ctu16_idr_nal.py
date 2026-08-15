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
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16
from hevc_reference.transform import forward_transform_16, inverse_transform_16


def mapped(events):
    return tuple(CuSyntaxBin(e.value, CABAC_BYPASS if e.bypass else 0,
                             coefficient_context_address(e) or 0) for e in events)


def luma_expected(prediction, residual, qp):
    transformed = forward_transform_16(residual)[1]
    pairs = [[quantize_dequantize_coefficient(transformed[y][x], qp)
              for x in range(16)] for y in range(16)]
    quantized = [[pairs[y][x][0] for x in range(16)] for y in range(16)]
    restored = inverse_transform_16([[pairs[y][x][1] for x in range(16)]
                                    for y in range(16)])[1]
    pixels = [(min(255, max(0, prediction[y][x] + restored[y][x])), x, y,
               x == 15 and y == 15) for y in range(16) for x in range(16)]
    return quantized, pixels


def chroma_expected(source, qp, plane):
    prediction = [[128] * 8 for _ in range(8)]
    residual = [[source[y][x] - 128 for x in range(8)] for y in range(8)]
    transformed = forward_transform_8(residual)[1]
    cqp = chroma_qp(qp)
    pairs = [[quantize_dequantize_8(transformed[y][x], cqp)
              for x in range(8)] for y in range(8)]
    quantized = [[pairs[y][x][0] for x in range(8)] for y in range(8)]
    restored = inverse_transform_8([[pairs[y][x][1] for x in range(8)]
                                   for y in range(8)])[1]
    pixels = [(plane, min(255, max(0, 128 + restored[y][x])), x, y,
               x == 7 and y == 7) for y in range(8) for x in range(8)]
    return quantized, pixels


def annexb_expected(qp, y, cb, cr):
    events = ctu16_yuv_syntax_bins(
        1, mapped(coefficient_syntax_bins_16(y)),
        mapped(coefficient_syntax_bins_8(cb)),
        mapped(coefficient_syntax_bins_8(cr)), True)
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for event in events:
        if event.kind == 2: encoder.encode_terminate(event.value)
        elif event.kind == CABAC_BYPASS: encoder.encode_bypass(event.value)
        else: encoder.encode_regular(event.value, event.context_address)
    return build_annexb_nal(
        20, idr_slice_header_bytes(0, qp, 1, 1) + encoder.bytes())


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("start_valid", "ctu_start_valid", "y_valid", "cb_valid",
                 "cr_valid", "y_recon_ready", "chroma_recon_ready", "nal_ready"):
        getattr(dut, name).value = 0
    for _ in range(3): await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def prepared_luma_and_raw_chroma_form_one_colour_idr(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    qp = QUALITY_QPS["medium"]
    prediction = [[80 + ((x + y) & 3) for x in range(16)] for y in range(16)]
    residual = [[12 if y < 8 else -9 for _ in range(16)] for y in range(16)]
    y_coeff, expected_y = luma_expected(prediction, residual, qp)
    cb_source = [[(47 + x * 23 + y * 19) & 255 for x in range(8)] for y in range(8)]
    cr_source = [[128] * 8 for _ in range(8)]
    cb_coeff, expected_cb = chroma_expected(cb_source, qp, 1)
    cr_coeff, expected_cr = chroma_expected(cr_source, qp, 2)
    expected_nal = annexb_expected(qp, y_coeff, cb_coeff, cr_coeff)
    y_source = [(prediction[y][x], residual[y][x]) for y in range(16) for x in range(16)]
    cb_flat = [v for row in cb_source for v in row]
    cr_flat = [v for row in cr_source for v in row]

    dut.slice_row.value = 0; dut.qp.value = qp
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns"); assert int(dut.start_ready.value)
    await RisingEdge(dut.clk); dut.start_valid.value = 0
    dut.ctu_start_valid.value = 1
    dut.quality.value = 1; dut.y_luma_mode_dc.value = 1
    indices = {"y": 0, "cb": 0, "cr": 0}
    y_pixels, chroma_pixels, nal = [], [], bytearray()
    rng = random.Random(0x42016)
    ctu_started = False

    for _ in range(120000):
        if not int(dut.y_valid.value) and indices["y"] < 256:
            p, r = y_source[indices["y"]]
            dut.y_prediction.value = p; dut.y_residual.value = r; dut.y_valid.value = 1
        for name, source in (("cb", cb_flat), ("cr", cr_flat)):
            if not int(getattr(dut, name + "_valid").value) and indices[name] < 64:
                getattr(dut, name + "_pixel").value = source[indices[name]]
                getattr(dut, name + "_valid").value = 1
        dut.y_recon_ready.value = int(rng.random() < .74)
        dut.chroma_recon_ready.value = int(rng.random() < .71)
        dut.nal_ready.value = int(rng.random() < .69)
        await Timer(1, units="ns")
        ctu_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
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
        await RisingEdge(dut.clk); await Timer(1, units="ns")
        if ctu_fire:
            ctu_started = True; dut.ctu_start_valid.value = 0
        for name, fire in fires.items():
            if fire:
                indices[name] += 1; getattr(dut, name + "_valid").value = 0
        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert ctu_started and indices == {"y": 256, "cb": 64, "cr": 64}
            assert y_pixels == expected_y
            assert chroma_pixels == expected_cb + expected_cr
            assert bytes(nal) == expected_nal
            assert not int(dut.busy.value)
            return
    raise AssertionError(f"YUV CTU top timeout indices={indices} nal={len(nal)}")
