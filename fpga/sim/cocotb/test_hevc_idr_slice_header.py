from __future__ import annotations

import os
import random

CTU_COLUMNS = int(os.environ.get("CTU_COLUMNS", "20"))
CTU_ROWS = int(os.environ.get("CTU_ROWS", "12"))
SLICE_CTU_ROWS = int(os.environ.get("SLICE_CTU_ROWS", "1"))
SLICE_COUNT = (CTU_ROWS + SLICE_CTU_ROWS - 1) // SLICE_CTU_ROWS

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.slice_header import idr_slice_header_bytes


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.slice_row.value = 0
    dut.qp.value = 26
    dut.no_output_of_prior_pics.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def emit_header(dut, row: int, qp: int, no_output: bool, seed: int) -> bytes:
    expected = idr_slice_header_bytes(
        row, qp, CTU_COLUMNS, CTU_ROWS, slice_ctu_rows=SLICE_CTU_ROWS, no_output_of_prior_pics=no_output
    )
    rng = random.Random(seed)

    dut.slice_row.value = row
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = int(no_output)
    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    received = bytearray()
    last_positions: list[int] = []
    stalled: tuple[int, int] | None = None
    for _ in range(1000):
        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        output = (int(dut.m_data.value), int(dut.m_last.value))
        if stalled is not None:
            assert valid
            assert output == stalled
        stalled = output if valid and not ready else None

        if valid and ready:
            received.append(output[0])
            if output[1]:
                last_positions.append(len(received) - 1)

        if int(dut.done.value):
            assert bytes(received) == expected
            assert last_positions == [len(expected) - 1]
            return bytes(received)

    raise AssertionError("slice-header stream timed out")


@cocotb.test()
async def configured_rows_and_quality_profiles_match_golden_model(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    cases = (
        (0, 28, False),
        (0, 34, True),
        (1, 34, False),
        (SLICE_COUNT // 2, 40, False),
        (SLICE_COUNT - 1, 0, False),
        (SLICE_COUNT - 1, 51, True),
    )
    for index, (row, qp, no_output) in enumerate(cases):
        await emit_header(dut, row, qp, no_output, 0x1D12 + index)


@cocotb.test()
async def invalid_row_and_qp_are_rejected(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    for row, qp in ((SLICE_COUNT, 34), (0, 52)):
        dut.slice_row.value = row
        dut.qp.value = qp
        dut.start_valid.value = 1
        await RisingEdge(dut.clk)
        dut.start_valid.value = 0
        await Timer(1, units="ns")
        assert int(dut.parameter_error.value)
        assert not int(dut.busy.value)
