from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cabac import (
    CABAC_INIT_B,
    CABAC_INIT_I,
    CABAC_INIT_P,
    cabac_context_init_state,
    coefficient_context_init_values,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.slice_type.value = 0
    dut.qp.value = 0
    dut.cfg_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load_contexts(dut, slice_type: int, qp: int, rng) -> list:
    dut.start_valid.value = 1
    dut.slice_type.value = slice_type
    dut.qp.value = qp
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    writes = []
    stalled = None
    for _ in range(2000):
        dut.cfg_ready.value = int(rng.random() < 0.67)
        await Timer(1, units="ns")
        valid = int(dut.cfg_valid.value)
        ready = int(dut.cfg_ready.value)
        output = None
        if valid:
            output = (
                int(dut.cfg_context_address.value),
                int(dut.cfg_state_index.value),
                int(dut.cfg_mps.value),
            )
        if stalled is not None:
            assert valid
            assert output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            writes.append(output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert not int(dut.parameter_error.value)
        if int(dut.done.value):
            break
    else:
        raise AssertionError("coefficient context initialization timed out")

    assert not int(dut.busy.value)
    return writes


@cocotb.test()
async def hm_tables_and_qp_conversion_match_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1A17CAB)

    for slice_type, qp in (
        (CABAC_INIT_B, 0),
        (CABAC_INIT_P, 34),
        (CABAC_INIT_I, 51),
        (CABAC_INIT_I, 63),
    ):
        writes = await load_contexts(dut, slice_type, qp, rng)
        expected = [
            (address, *cabac_context_init_state(qp, init_value))
            for address, init_value in enumerate(
                coefficient_context_init_values(slice_type)
            )
        ]
        assert writes == expected

    dut.start_valid.value = 1
    dut.slice_type.value = 3
    dut.qp.value = 34
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.parameter_error.value)
    assert not int(dut.busy.value)
    assert not int(dut.cfg_valid.value)
    dut.start_valid.value = 0
