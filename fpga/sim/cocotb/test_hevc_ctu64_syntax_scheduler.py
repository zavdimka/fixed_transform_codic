from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cu_syntax import (
    CABAC_BYPASS,
    CABAC_REGULAR,
    CuSyntaxBin,
    ctu64_syntax_bins,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.ctu_start_valid.value = 0
    dut.ctu_x.value = 0
    dut.ctu_last_in_slice.value = 0
    dut.cu_valid.value = 0
    dut.cu_luma_mode_dc.value = 0
    dut.cu_luma_cbf.value = 0
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


def coefficient_blocks(cbfs):
    blocks = []
    for cu_index, cbf in enumerate(cbfs):
        if cbf:
            blocks.append((
                CuSyntaxBin(cu_index & 1, CABAC_REGULAR, 64 + cu_index),
                CuSyntaxBin((cu_index >> 1) & 1, CABAC_BYPASS),
                CuSyntaxBin(1, CABAC_REGULAR, 96 + cu_index),
            ))
        else:
            blocks.append(())
    return tuple(blocks)


async def run_ctu(dut, ctu_x, last_ctu, modes, cbfs, rng):
    blocks_by_cu = coefficient_blocks(cbfs)
    golden = ctu64_syntax_bins(
        ctu_x, modes, cbfs, blocks_by_cu, last_ctu
    )
    expected = [
        (event.value, event.kind, event.context_address,
         index == len(golden) - 1)
        for index, event in enumerate(golden)
    ]

    dut.ctu_start_valid.value = 1
    dut.ctu_x.value = ctu_x
    dut.ctu_last_in_slice.value = int(last_ctu)
    await Timer(1, units="ns")
    assert int(dut.ctu_start_ready.value)
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0

    cu_index = 0
    coefficient_blocks_pending = [block for block in blocks_by_cu if block]
    coefficient_block_index = 0
    coefficient_event_index = 0
    done_delay = None
    observed = []
    stalled = None
    ctu_done_seen = False
    slice_termination_seen = False

    for _ in range(10000):
        if cu_index < 16:
            dut.cu_valid.value = 1
            dut.cu_luma_mode_dc.value = int(modes[cu_index] == 1)
            dut.cu_luma_cbf.value = int(cbfs[cu_index])
        else:
            dut.cu_valid.value = 0

        send_coefficient = (
            coefficient_block_index < len(coefficient_blocks_pending)
            and done_delay is None
        )
        if send_coefficient:
            event = coefficient_blocks_pending[coefficient_block_index][
                coefficient_event_index
            ]
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
        coefficient_fire = (
            int(dut.coefficient_valid.value)
            and int(dut.coefficient_ready.value)
        )
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output = None
        if output_valid:
            output = (
                int(dut.m_bin.value),
                int(dut.m_kind.value),
                int(dut.m_context_address.value),
                bool(dut.m_last.value),
            )
        if stalled is not None:
            assert output_valid
            assert output == stalled
        stalled = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            observed.append(output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if cu_fire:
            cu_index += 1
        if coefficient_fire:
            block = coefficient_blocks_pending[coefficient_block_index]
            if coefficient_event_index == len(block) - 1:
                coefficient_event_index = 0
                done_delay = rng.randrange(0, 4)
            else:
                coefficient_event_index += 1
        if done_pulse:
            coefficient_block_index += 1
            done_delay = None
        elif done_delay is not None and not coefficient_fire:
            done_delay -= 1

        assert not int(dut.protocol_error.value)
        if int(dut.ctu_done.value):
            ctu_done_seen = True
            slice_termination_seen = bool(dut.slice_termination.value)
            break
    else:
        raise AssertionError(
            f"CTU64 syntax scheduling timed out: cu={cu_index} "
            f"coefficient_block={coefficient_block_index} "
            f"event={coefficient_event_index} delay={done_delay} "
            f"cu_ready={int(dut.cu_ready.value)} "
            f"coefficient_ready={int(dut.coefficient_ready.value)} "
            f"m_valid={int(dut.m_valid.value)} busy={int(dut.busy.value)}"
        )

    assert ctu_done_seen
    assert slice_termination_seen == bool(last_ctu)
    assert cu_index == 16
    assert coefficient_block_index == len(coefficient_blocks_pending)
    assert observed == expected
    assert not int(dut.busy.value)


@cocotb.test()
async def two_ctus_serialize_prefix_coefficients_and_termination(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC7A64)
    modes = tuple(index & 1 for index in range(16))
    cbfs = tuple(index in (0, 3, 8, 15) for index in range(16))

    await run_ctu(dut, 0, False, modes, cbfs, rng)
    await run_ctu(dut, 1, True, modes[::-1], cbfs, rng)

    dut.coefficient_block_done.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.protocol_error.value)
    dut.coefficient_block_done.value = 0


@cocotb.test()
async def coefficient_stream_cannot_inject_termination(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    dut.ctu_start_valid.value = 1
    dut.ctu_x.value = 0
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0

    dut.cu_valid.value = 1
    dut.cu_luma_mode_dc.value = 0
    dut.cu_luma_cbf.value = 1
    while True:
        dut.m_ready.value = 1
        await Timer(1, units="ns")
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        await RisingEdge(dut.clk)
        if cu_fire:
            break
    dut.cu_valid.value = 0

    dut.coefficient_valid.value = 1
    dut.coefficient_kind.value = 2
    dut.coefficient_bin.value = 0
    for _ in range(40):
        await Timer(1, units="ns")
        coefficient_fire = (
            int(dut.coefficient_valid.value)
            and int(dut.coefficient_ready.value)
        )
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if coefficient_fire:
            assert not int(dut.m_valid.value)
            assert int(dut.protocol_error.value)
            break
    else:
        raise AssertionError("scheduler never requested coefficient syntax")
