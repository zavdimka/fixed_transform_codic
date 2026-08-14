from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.nal_unit_type.value = 0
    dut.temporal_id_plus1.value = 1
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_last.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def transfer_nal(
    dut,
    nal_type: int,
    temporal_id_plus1: int,
    rbsp: bytes,
    seed: int,
) -> bytes:
    assert rbsp
    expected = build_annexb_nal(nal_type, rbsp, temporal_id_plus1)
    rng = random.Random(seed)

    dut.nal_unit_type.value = nal_type
    dut.temporal_id_plus1.value = temporal_id_plus1
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

    for _ in range(10000):
        if not int(dut.s_valid.value) and source_index < len(rbsp):
            if rng.random() < 0.75:
                dut.s_valid.value = 1
                dut.s_data.value = rbsp[source_index]
                dut.s_last.value = int(source_index == len(rbsp) - 1)

        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output = (int(dut.m_data.value), int(dut.m_last.value))

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
            dut.s_valid.value = 0
            dut.s_last.value = 0

        if source_index == len(rbsp) and not int(dut.busy.value):
            assert bytes(received) == expected
            assert last_positions == [len(expected) - 1]
            return bytes(received)

    raise AssertionError("NAL writer transfer timed out")


@cocotb.test()
async def randomized_backpressure_matches_golden_model(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    payloads = (
        (32, 1, bytes((0, 0, 1, 0x80))),
        (19, 1, bytes((0, 0, 0, 1, 2, 3, 4, 0, 0, 3, 0, 0, 4))),
        (1, 7, bytes(range(256))),
    )
    for index, (nal_type, temporal_id, rbsp) in enumerate(payloads):
        await transfer_nal(dut, nal_type, temporal_id, rbsp, 0x4E414C + index)


@cocotb.test()
async def temporal_id_zero_is_rejected(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    dut.nal_unit_type.value = 19
    dut.temporal_id_plus1.value = 0
    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0
    await Timer(1, units="ns")
    assert int(dut.parameter_error.value)
    assert not int(dut.busy.value)
    assert not int(dut.m_valid.value)
