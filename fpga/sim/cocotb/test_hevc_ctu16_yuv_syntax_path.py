from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_coeff_syntax import coefficient_syntax_bins_8
from hevc_reference.chroma_ctu_syntax import ctu16_yuv_syntax_bins
from hevc_reference.cu_syntax import CABAC_BYPASS, CABAC_REGULAR, CuSyntaxBin
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16


def mapped_bins(events):
    result = []
    for event in events:
        address = coefficient_context_address(event)
        result.append(CuSyntaxBin(
            event.value,
            CABAC_BYPASS if event.bypass else CABAC_REGULAR,
            0 if address is None else address,
        ))
    return tuple(result)


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("ctu_start_valid", "cu_valid", "y_valid", "cb_valid",
                 "cr_valid", "m_ready"):
        getattr(dut, name).value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def three_raw_coefficient_blocks_form_one_ordered_cabac_stream(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x16_420)
    y = [[0] * 16 for _ in range(16)]
    cb = [[0] * 8 for _ in range(8)]
    cr = [[0] * 8 for _ in range(8)]
    for address, value in ((0, 3), (17, -2), (85, 7), (255, -1)):
        y[address >> 4][address & 15] = value
    for address, value in ((0, -1), (19, 4), (63, -9)):
        cb[address >> 3][address & 7] = value
    for address, value in ((0, 2), (9, -3), (52, 11)):
        cr[address >> 3][address & 7] = value

    indices = [0, 0, 0]
    for _ in range(2000):
        for plane, prefix, size, block in (
            (0, "y", 256, y), (1, "cb", 64, cb), (2, "cr", 64, cr)
        ):
            valid = getattr(dut, f"{prefix}_valid")
            ready = getattr(dut, f"{prefix}_ready")
            if indices[plane] < size and not int(valid.value) and int(ready.value):
                address = indices[plane]
                getattr(dut, f"{prefix}_raster_address").value = address
                getattr(dut, f"{prefix}_coefficient").value = block[
                    address >> (4 if plane == 0 else 3)
                ][address & (15 if plane == 0 else 7)]
                getattr(dut, f"{prefix}_block_last").value = int(address == size - 1)
                valid.value = 1
        await RisingEdge(dut.clk)
        for plane, prefix in enumerate(("y", "cb", "cr")):
            valid = getattr(dut, f"{prefix}_valid")
            ready = getattr(dut, f"{prefix}_ready")
            if int(valid.value) and int(ready.value):
                indices[plane] += 1
                valid.value = 0
        if indices == [256, 64, 64]:
            break
    assert indices == [256, 64, 64]

    y_bins = mapped_bins(coefficient_syntax_bins_16(y))
    cb_bins = mapped_bins(coefficient_syntax_bins_8(cb))
    cr_bins = mapped_bins(coefficient_syntax_bins_8(cr))
    golden = ctu16_yuv_syntax_bins(1, y_bins, cb_bins, cr_bins, True)
    expected = [(e.value, e.kind, e.context_address, i == len(golden) - 1)
                for i, e in enumerate(golden)]

    dut.ctu_start_valid.value = 1
    dut.ctu_last_in_slice.value = 1
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0
    dut.cu_valid.value = 1
    dut.cu_luma_mode_dc.value = 1
    dut.cu_luma_cbf.value = 1
    dut.cu_cb_cbf.value = 1
    dut.cu_cr_cbf.value = 1
    observed = []
    coefficient_planes = []
    stalled = None
    for _ in range(30000):
        dut.m_ready.value = int(rng.random() < 0.7)
        await Timer(1, units="ns")
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        valid, ready = int(dut.m_valid.value), int(dut.m_ready.value)
        output = None
        if valid:
            output = (int(dut.m_bin.value), int(dut.m_kind.value),
                      int(dut.m_context_address.value), bool(dut.m_last.value))
        if stalled is not None:
            assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            observed.append(output)
            if len(observed) > len(golden) - (len(y_bins) + len(cb_bins) + len(cr_bins)):
                coefficient_planes.append(int(dut.active_coefficient_plane.value))
        await RisingEdge(dut.clk)
        if cu_fire:
            dut.cu_valid.value = 0
        assert not int(dut.protocol_error.value)
        if int(dut.ctu_done.value):
            break
    else:
        raise AssertionError("integrated Y/Cb/Cr syntax path timed out")
    assert observed == expected
    assert 0 in coefficient_planes and 1 in coefficient_planes and 2 in coefficient_planes
