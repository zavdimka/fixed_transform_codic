from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import CABAC_INIT_I, CabacByteEncoder, coefficient_context_init_states
from hevc_reference.cu_syntax import CABAC_BYPASS, ctu16_intra_prefix_bins
from hevc_reference.quant import QUALITY_QPS
from hevc_reference.slice_header import idr_slice_header_bytes


CTU_COLUMNS = 2
CTU_ROWS = 4
SLICE_CTU_ROWS = 4


def expected_nal(qp: int) -> bytes:
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for index in range(CTU_COLUMNS * SLICE_CTU_ROWS):
        for event in ctu16_intra_prefix_bins(0, False):
            if event.kind == CABAC_BYPASS:
                encoder.encode_bypass(event.value)
            else:
                encoder.encode_regular(event.value, event.context_address)
        encoder.encode_terminate(int(index == CTU_COLUMNS * SLICE_CTU_ROWS - 1))
    return build_annexb_nal(
        20,
        idr_slice_header_bytes(0, qp, CTU_COLUMNS, CTU_ROWS, slice_ctu_rows=SLICE_CTU_ROWS)
        + encoder.bytes(),
    )


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.ctu_start_valid.value = 0
    dut.s_valid.value = 0
    dut.s_quality.value = 1
    dut.s_luma_mode_dc.value = 0
    dut.recon_ready.value = 0
    dut.nal_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def four_raster_rows_form_one_slice(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    qp = QUALITY_QPS["medium"]
    dut.slice_row.value = 0
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0x204_16)
    started = 0
    completed = 0
    pixel_index = 0
    reconstructed = []
    started_positions = []
    nal = bytearray()
    total_ctus = CTU_COLUMNS * SLICE_CTU_ROWS

    for _ in range(250000):
        need_start = started == completed and started < total_ctus
        dut.ctu_start_valid.value = int(need_start)
        active = started > completed
        if active and pixel_index < 256:
            x = pixel_index & 15
            y = pixel_index >> 4
            dut.s_valid.value = int(rng.random() < 0.86)
            dut.s_prediction.value = ((started - 1) * 23 + x * 5 + y * 7) & 255
            dut.s_residual.value = 0
        else:
            dut.s_valid.value = 0
        dut.recon_ready.value = int(rng.random() < 0.79)
        dut.nal_ready.value = int(rng.random() < 0.73)
        await Timer(1, units="ns")

        start_fire = int(dut.ctu_start_valid.value) and int(dut.ctu_start_ready.value)
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        if int(dut.recon_valid.value) and int(dut.recon_ready.value):
            reconstructed.append((int(dut.recon_pixel.value), int(dut.recon_x.value),
                                  int(dut.recon_y.value)))
        if int(dut.nal_valid.value) and int(dut.nal_ready.value):
            nal.append(int(dut.nal_byte.value))
        await RisingEdge(dut.clk)

        if start_fire:
            started_positions.append((int(dut.current_ctu_x.value), int(dut.current_ctu_y.value)))
            started += 1
            pixel_index = 0
        if source_fire:
            pixel_index += 1
        if int(dut.ctu_done.value):
            assert pixel_index == 256
            completed += 1
        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)

        if int(dut.done.value):
            assert started == completed == total_ctus
            assert len(reconstructed) == total_ctus * 256
            for index, (pixel, x, y) in enumerate(reconstructed):
                ctu_index, local = divmod(index, 256)
                assert pixel == (ctu_index * 23 + x * 5 + y * 7) & 255
                assert local == y * 16 + x
            assert started_positions == [(x, y) for y in range(4) for x in range(2)]
            assert bytes(nal) == expected_nal(qp)
            return
    raise AssertionError(f"multi-CTU slice timed out: {completed}/{total_ctus}")
