from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_ctu_syntax import ctu16_yuv_syntax_bins
from hevc_reference.cu_syntax import CABAC_BYPASS, CABAC_REGULAR, CuSyntaxBin


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("ctu_start_valid", "cu_valid", "coefficient_valid",
                 "coefficient_block_done", "m_ready"):
        getattr(dut, name).value = 0
    dut.ctu_last_in_slice.value = 0
    dut.cu_luma_mode_dc.value = 0
    dut.cu_luma_cbf.value = 0
    dut.cu_cb_cbf.value = 0
    dut.cu_cr_cbf.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def y_cb_cr_blocks_are_serialized_before_termination(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x42016)
    blocks = (
        (CuSyntaxBin(1, CABAC_REGULAR, 64), CuSyntaxBin(0, CABAC_BYPASS)),
        (CuSyntaxBin(1, CABAC_REGULAR, 12),),
        (CuSyntaxBin(0, CABAC_REGULAR, 14), CuSyntaxBin(1, CABAC_BYPASS)),
    )
    expected_events = ctu16_yuv_syntax_bins(1, *blocks, True)
    expected = [(e.value, e.kind, e.context_address,
                 i == len(expected_events) - 1)
                for i, e in enumerate(expected_events)]

    dut.ctu_start_valid.value = 1
    dut.ctu_last_in_slice.value = 1
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0
    dut.cu_valid.value = 1
    dut.cu_luma_mode_dc.value = 1
    dut.cu_luma_cbf.value = 1
    dut.cu_cb_cbf.value = 1
    dut.cu_cr_cbf.value = 1

    block_index = event_index = 0
    descriptor_done = False
    observed = []
    stalled = None
    done_pending = False
    for _ in range(1500):
        dut.m_ready.value = int(rng.random() < 0.65)
        if descriptor_done and block_index < 3 and not done_pending:
            event = blocks[block_index][event_index]
            dut.coefficient_valid.value = 1
            dut.coefficient_bin.value = event.value
            dut.coefficient_kind.value = event.kind
            dut.coefficient_context_address.value = event.context_address
        else:
            dut.coefficient_valid.value = 0
        dut.coefficient_block_done.value = int(done_pending)
        await Timer(1, units="ns")
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        coefficient_fire = (int(dut.coefficient_valid.value) and
                            int(dut.coefficient_ready.value))
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
        await RisingEdge(dut.clk)
        if cu_fire:
            descriptor_done = True
            dut.cu_valid.value = 0
        if done_pending:
            done_pending = False
            block_index += 1
            event_index = 0
        elif coefficient_fire:
            event_index += 1
            if event_index == len(blocks[block_index]):
                done_pending = True
        assert not int(dut.protocol_error.value)
        if int(dut.ctu_done.value):
            break
    else:
        raise AssertionError("Y/Cb/Cr scheduler timed out")
    assert block_index == 3
    assert observed == expected
