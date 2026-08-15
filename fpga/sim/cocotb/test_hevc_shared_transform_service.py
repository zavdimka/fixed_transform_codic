from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_tu8 import forward_transform_8, inverse_transform_8
from hevc_reference.transform import forward_transform_16


PLANES = ("y", "cb", "cr")


async def reset(dut):
    dut.rst_n.value = 0
    for name in PLANES:
        getattr(dut, f"{name}_request_valid").value = 0
        getattr(dut, f"{name}_s_valid").value = 0
        getattr(dut, f"{name}_m_ready").value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def y_cb_cr_share_one_bit_exact_core(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC07E5)

    y = [[rng.randrange(-255, 256) for _ in range(16)] for _ in range(16)]
    cb = [[rng.randrange(-255, 256) for _ in range(8)] for _ in range(8)]
    cr = [[rng.randrange(-8192, 8193) for _ in range(8)] for _ in range(8)]
    sources = {"y": y, "cb": cb, "cr": cr}
    expected_matrices = {
        "y": forward_transform_16(y)[1],
        "cb": forward_transform_8(cb)[1],
        "cr": inverse_transform_8(cr)[1],
    }
    inverse = {"y": 0, "cb": 0, "cr": 1}
    sizes = {"y": 16, "cb": 8, "cr": 8}
    flat = {name: [value for row in matrix for value in row]
            for name, matrix in sources.items()}
    source_index = {name: 0 for name in PLANES}
    received = {name: [] for name in PLANES}
    accepted = []
    completed = []

    for name in PLANES:
        getattr(dut, f"{name}_inverse").value = inverse[name]
        getattr(dut, f"{name}_request_valid").value = 1

    stalled = {name: None for name in PLANES}
    for _ in range(30000):
        for name in PLANES:
            if (source_index[name] < len(flat[name]) and
                    not int(getattr(dut, f"{name}_s_valid").value) and
                    rng.random() < 0.87):
                getattr(dut, f"{name}_s_data").value = flat[name][source_index[name]]
                getattr(dut, f"{name}_s_valid").value = 1
            getattr(dut, f"{name}_m_ready").value = int(rng.random() < 0.73)

        await Timer(1, units="ns")
        request_fire = {
            name: int(getattr(dut, f"{name}_request_valid").value) and
                  int(getattr(dut, f"{name}_request_ready").value)
            for name in PLANES
        }
        input_fire = {
            name: int(getattr(dut, f"{name}_s_valid").value) and
                  int(getattr(dut, f"{name}_s_ready").value)
            for name in PLANES
        }
        for name in PLANES:
            output = (
                getattr(dut, f"{name}_m_data").value.signed_integer,
                int(getattr(dut, f"{name}_m_x").value),
                int(getattr(dut, f"{name}_m_y").value),
                bool(getattr(dut, f"{name}_m_block_last").value),
            )
            valid = int(getattr(dut, f"{name}_m_valid").value)
            ready = int(getattr(dut, f"{name}_m_ready").value)
            if stalled[name] is not None:
                assert valid and output == stalled[name]
            stalled[name] = output if valid and not ready else None
            if valid and ready:
                received[name].append(output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        for name in PLANES:
            if request_fire[name]:
                accepted.append(name)
                getattr(dut, f"{name}_request_valid").value = 0
            if input_fire[name]:
                source_index[name] += 1
                getattr(dut, f"{name}_s_valid").value = 0
        if int(dut.block_done.value):
            completed.append(PLANES[int(dut.completed_plane.value)])
        assert not int(dut.protocol_error.value)
        if len(completed) == 3:
            break
    else:
        raise AssertionError("shared transform service timed out")

    assert accepted == ["y", "cb", "cr"]
    assert completed == accepted
    for name in PLANES:
        size = sizes[name]
        matrix = expected_matrices[name]
        expected = [(matrix[index // size][index % size], index % size,
                     index // size, index == size * size - 1)
                    for index in range(size * size)]
        assert received[name] == expected
    assert not int(dut.busy.value)
