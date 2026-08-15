from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cu_syntax import (
    CABAC_BYPASS,
    CABAC_REGULAR,
    CuSyntaxBin,
    ctu16_syntax_bins,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.ctu_start_valid.value = 0
    dut.ctu_last_in_slice.value = 0
    dut.cu_valid.value = 0
    dut.cu_luma_mode_dc.value = 0
    dut.cu_luma_cbf.value = 0
    dut.cu_cb_cbf.value = 0
    dut.cu_cr_cbf.value = 0
    dut.coefficient_valid.value = 0
    dut.coefficient_kind.value = 0
    dut.coefficient_bin.value = 0
    dut.coefficient_context_address.value = 0
    dut.coefficient_block_done.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_ctu(dut, last_ctu, mode, cbf, coefficients, rng):
    golden = ctu16_syntax_bins(mode, cbf, coefficients, last_ctu)
    expected = [
        (event.value, event.kind, event.context_address, index == len(golden) - 1)
        for index, event in enumerate(golden)
    ]

    dut.ctu_start_valid.value = 1
    dut.ctu_last_in_slice.value = int(last_ctu)
    await Timer(1, units="ns")
    assert int(dut.ctu_start_ready.value)
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0

    cu_pending = True
    coefficient_index = 0
    done_delay = None
    observed = []
    stalled = None
    for _ in range(1000):
        dut.cu_valid.value = int(cu_pending)
        dut.cu_luma_mode_dc.value = int(mode == 1)
        dut.cu_luma_cbf.value = int(cbf)

        send_coefficient = cbf and coefficient_index < len(coefficients) and done_delay is None
        if send_coefficient:
            event = coefficients[coefficient_index]
            dut.coefficient_valid.value = 1
            dut.coefficient_kind.value = event.kind
            dut.coefficient_bin.value = event.value
            dut.coefficient_context_address.value = event.context_address
        else:
            dut.coefficient_valid.value = 0
        done_pulse = done_delay == 0
        dut.coefficient_block_done.value = int(done_pulse)
        dut.m_ready.value = int(rng.random() < 0.68)
        await Timer(1, units="ns")

        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        coefficient_fire = int(dut.coefficient_valid.value) and int(dut.coefficient_ready.value)
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        output = None
        if valid:
            output = (
                int(dut.m_bin.value), int(dut.m_kind.value),
                int(dut.m_context_address.value), bool(dut.m_last.value),
            )
        if stalled is not None:
            assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            observed.append(output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if cu_fire:
            cu_pending = False
        if coefficient_fire:
            coefficient_index += 1
            if coefficient_index == len(coefficients):
                done_delay = rng.randrange(0, 4)
        if done_pulse:
            done_delay = None
        elif done_delay is not None and not coefficient_fire:
            done_delay -= 1

        assert not int(dut.protocol_error.value)
        if int(dut.ctu_done.value):
            assert bool(dut.slice_termination.value) == bool(last_ctu)
            break
    else:
        raise AssertionError("CTU16 syntax scheduling timed out")

    assert not cu_pending
    assert coefficient_index == len(coefficients)
    assert observed == expected
    assert not int(dut.busy.value)


@cocotb.test()
async def one_cu_per_ctu_serializes_prefix_coefficients_and_termination(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC7A16)
    coefficients = (
        CuSyntaxBin(1, CABAC_REGULAR, 64),
        CuSyntaxBin(0, CABAC_BYPASS),
        CuSyntaxBin(1, CABAC_REGULAR, 96),
    )
    await run_ctu(dut, False, 0, False, (), rng)
    await run_ctu(dut, True, 1, True, coefficients, rng)
