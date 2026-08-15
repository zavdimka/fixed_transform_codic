import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_syntax import DIAGONAL_SCAN_8, coefficient_scan_metadata_8


async def reset(dut):
    dut.rst_n.value = 0; dut.s_valid.value = 0; dut.m_ready.value = 0
    for _ in range(3): await RisingEdge(dut.clk)
    dut.rst_n.value = 1; await RisingEdge(dut.clk)


@cocotb.test()
async def tu8_diagonal_scan_and_metadata_survive_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x8CA8)
    block = [[0] * 8 for _ in range(8)]
    for position in (0, 2, 17, 36, 53):
        address = DIAGONAL_SCAN_8[position]
        block[address >> 3][address & 7] = position - 20
    flags, last = coefficient_scan_metadata_8(block)
    source = [(a, block[a >> 3][a & 7], a == 63) for a in range(64)]
    sent = 0; received = []; stalled = None
    for _ in range(3000):
        if not int(dut.s_valid.value) and sent < 64 and rng.random() < 0.8:
            a, value, final = source[sent]
            dut.s_raster_address.value = a; dut.s_coefficient.value = value
            dut.s_block_last.value = final; dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)
        output = (dut.m_coefficient.value.signed_integer,
                  int(dut.m_raster_address.value), int(dut.m_scan_position.value),
                  bool(dut.m_block_last.value), bool(dut.m_group_nonzero.value))
        valid, ready = int(dut.m_valid.value), int(dut.m_ready.value)
        if stalled is not None: assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready: received.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            sent += 1; dut.s_valid.value = 0
        if len(received) == last + 1: break
    assert sent == 64
    expected = []
    for position in range(last, -1, -1):
        address = DIAGONAL_SCAN_8[position]
        expected.append((block[address >> 3][address & 7], address, position,
                         position == 0, flags[(0, 2, 1, 3)[position >> 4]]))
    assert received == expected
    assert int(dut.significant_group_flags.value) == sum(int(v) << i for i, v in enumerate(flags))
    assert int(dut.last_nonzero_scan_position.value) == last
    assert not int(dut.input_error.value)
