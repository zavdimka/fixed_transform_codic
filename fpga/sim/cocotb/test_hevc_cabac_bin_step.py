from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cabac import cabac_bin_step


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    dut.s_bin.value = 0
    dut.s_bypass.value = 0
    dut.s_low.value = 0
    dut.s_range.value = 510
    dut.s_state_index.value = 0
    dut.s_mps.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def output_tuple(dut):
    return (
        int(dut.m_low.value),
        int(dut.m_range.value),
        int(dut.m_state_index.value),
        int(dut.m_mps.value),
        int(dut.m_renorm_bits.value),
    )


@cocotb.test()
async def exhaustive_tables_and_random_backpressure_match_reference(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xCABAC265)

    vectors = []
    for state in range(64):
        for range_value in (256, 319, 320, 383, 384, 447, 448, 510):
            for mps in (0, 1):
                for bin_value in (0, 1):
                    vectors.append((
                        rng.getrandbits(32), range_value, state,
                        mps, bin_value, False,
                    ))
    for _ in range(1000):
        vectors.append((
            rng.getrandbits(32), rng.randrange(256, 511),
            rng.randrange(64), rng.randrange(2), rng.randrange(2), True,
        ))

    sent = 0
    expected = []
    received = []
    stalled = None
    for _ in range(100000):
        if sent < len(vectors):
            low, range_value, state, mps, bin_value, bypass = vectors[sent]
            dut.s_valid.value = 1
            dut.s_low.value = low
            dut.s_range.value = range_value
            dut.s_state_index.value = state
            dut.s_mps.value = mps
            dut.s_bin.value = bin_value
            dut.s_bypass.value = bypass
        else:
            dut.s_valid.value = 0
        dut.m_ready.value = int(rng.random() < 0.67)
        await Timer(1, units="ns")

        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        output = output_tuple(dut)
        if stalled is not None:
            assert valid == 1
            assert output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            received.append(output)

        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        if input_fire:
            result = cabac_bin_step(
                low, range_value, state, mps, bin_value, bypass
            )
            expected.append((
                result.low, result.range, result.state_index,
                result.mps, result.renorm_bits,
            ))
            sent += 1

        await RisingEdge(dut.clk)
        if len(received) == len(vectors):
            break

    assert sent == len(vectors)
    assert received == expected


@cocotb.test()
async def chained_bins_keep_range_normalized(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.m_ready.value = 1
    low, range_value, state, mps = 0, 510, 17, 0
    for bin_value, bypass in ((0, False), (1, False), (1, True),
                              (0, False)) * 40:
        expected = cabac_bin_step(
            low, range_value, state, mps, bin_value, bypass
        )
        dut.s_valid.value = 1
        dut.s_low.value = low
        dut.s_range.value = range_value
        dut.s_state_index.value = state
        dut.s_mps.value = mps
        dut.s_bin.value = bin_value
        dut.s_bypass.value = bypass
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert output_tuple(dut) == (
            expected.low, expected.range, expected.state_index,
            expected.mps, expected.renorm_bits,
        )
        low, range_value = expected.low, expected.range
        state, mps = expected.state_index, expected.mps
        assert 256 <= range_value <= 510
