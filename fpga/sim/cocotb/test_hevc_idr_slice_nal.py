from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.slice_header import idr_slice_header_bytes


CTU_COLUMNS = int(os.environ.get("CTU_COLUMNS", "20"))
CTU_ROWS = int(os.environ.get("CTU_ROWS", "12"))
SLICE_CTU_ROWS = int(os.environ.get("SLICE_CTU_ROWS", "1"))
SLICE_COUNT = (CTU_ROWS + SLICE_CTU_ROWS - 1) // SLICE_CTU_ROWS


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.slice_row.value = 0
    dut.qp.value = 26
    dut.no_output_of_prior_pics.value = 0
    dut.s_valid.value = 0
    dut.s_byte.value = 0
    dut.s_last.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def transfer_slice(
    dut,
    row: int,
    qp: int,
    no_output: bool,
    cabac_payload: bytes,
    seed: int,
) -> bytes:
    assert cabac_payload
    header = idr_slice_header_bytes(
        row,
        qp,
        CTU_COLUMNS,
        CTU_ROWS,
        no_output_of_prior_pics=no_output,
        slice_ctu_rows=SLICE_CTU_ROWS,
    )
    expected = build_annexb_nal(20, header + cabac_payload)
    rng = random.Random(seed)

    dut.slice_row.value = row
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = int(no_output)
    dut.start_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.start_ready.value):
            break
    dut.start_valid.value = 0

    source_index = 0
    received = bytearray()
    last_positions: list[int] = []
    stalled: tuple[int, int] | None = None
    saw_done = False

    # Present CABAC immediately; the wrapper must hold it off until the header
    # has crossed the shared NAL input.
    dut.s_valid.value = 1
    dut.s_byte.value = cabac_payload[0]
    dut.s_last.value = int(len(cabac_payload) == 1)

    for _ in range(10000):
        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output = (int(dut.m_byte.value), int(dut.m_last.value))
        if stalled is not None:
            assert output_valid
            assert output == stalled
        stalled = output if output_valid and not output_ready else None

        if output_valid and output_ready:
            received.append(output[0])
            if output[1]:
                last_positions.append(len(received) - 1)

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            if source_index == len(cabac_payload):
                dut.s_valid.value = 0
                dut.s_last.value = 0
            else:
                dut.s_valid.value = int(rng.random() < 0.8)
                dut.s_byte.value = cabac_payload[source_index]
                dut.s_last.value = int(source_index == len(cabac_payload) - 1)
        elif not int(dut.s_valid.value) and source_index < len(cabac_payload):
            if rng.random() < 0.8:
                dut.s_valid.value = 1
                dut.s_byte.value = cabac_payload[source_index]
                dut.s_last.value = int(source_index == len(cabac_payload) - 1)

        if int(dut.done.value):
            saw_done = True
            assert last_positions == [len(received) - 1]

        if saw_done and not int(dut.busy.value):
            assert source_index == len(cabac_payload)
            assert bytes(received) == expected
            return bytes(received)

    raise AssertionError("IDR slice NAL transfer timed out")


@cocotb.test()
async def header_and_cabac_form_one_annexb_nal(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    cases = (
        (0, 34, True, bytes((0x00, 0x00, 0x01, 0x80))),
        (1, 28, False, bytes((0x12, 0x00, 0x00, 0x02, 0xFF))),
        (
            SLICE_COUNT - 1,
            40,
            False,
            bytes((0x00, 0x00, 0x03, 0x00, 0x00, 0x04, 0x80)),
        ),
    )
    for index, case in enumerate(cases):
        await transfer_slice(dut, *case, seed=0x1D4E414C + index)


@cocotb.test()
async def invalid_parameters_emit_no_partial_nal(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    for row, qp in ((CTU_ROWS, 34), (0, 52)):
        dut.slice_row.value = row
        dut.qp.value = qp
        dut.start_valid.value = 1
        await RisingEdge(dut.clk)
        dut.start_valid.value = 0
        await Timer(1, units="ns")
        assert int(dut.parameter_error.value)
        assert not int(dut.busy.value)
        assert not int(dut.m_valid.value)
