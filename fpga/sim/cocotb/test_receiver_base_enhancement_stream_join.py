from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.stripe_start.value = 0
    dut.stripe_enhancement_available.value = 0
    dut.base_valid.value = 0
    dut.enhancement_event_valid.value = 0
    dut.load_start_ready.value = 1
    dut.load_coeff_ready.value = 1
    dut.load_base_ready.value = 1
    dut.load_commit_ready.value = 1
    for name in (
        "base_ctu_index", "base_block_index", "base_plane", "base_mode",
        "base_quality", "base_frame_id", "base_stripe_id",
        "base_coefficients", "enhancement_event_kind",
        "enhancement_event_ctu_index", "enhancement_event_block_index",
        "enhancement_event_plane", "enhancement_event_scan_index",
        "enhancement_event_coefficient", "enhancement_event_quality",
        "enhancement_event_frame_id", "enhancement_event_stripe_id",
    ):
        getattr(dut, name).value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def start_stripe(dut, enhancement):
    await FallingEdge(dut.clk)
    dut.stripe_enhancement_available.value = enhancement
    dut.stripe_start.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.stripe_start.value = 0


async def send_base(dut, values, *, ctu=3, block=2, plane=0):
    dut.base_ctu_index.value = ctu
    dut.base_block_index.value = block
    dut.base_plane.value = plane
    dut.base_mode.value = 2
    dut.base_quality.value = 24
    dut.base_frame_id.value = 0x1234
    dut.base_stripe_id.value = 9
    dut.base_coefficients.value = sum(
        (value & 0xFFF) << (12 * index)
        for index, value in enumerate(values)
    )
    dut.base_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.base_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.base_valid.value = 0


async def send_event(dut, kind, *, scan=0, value=0):
    dut.enhancement_event_kind.value = kind
    dut.enhancement_event_ctu_index.value = 3
    dut.enhancement_event_block_index.value = 2
    dut.enhancement_event_plane.value = 0
    dut.enhancement_event_scan_index.value = scan
    dut.enhancement_event_coefficient.value = value
    dut.enhancement_event_quality.value = 24
    dut.enhancement_event_frame_id.value = 0x1234
    dut.enhancement_event_stripe_id.value = 9
    dut.enhancement_event_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.enhancement_event_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.enhancement_event_valid.value = 0


async def collect_job(dut):
    writes = {}
    starts = 0
    for _ in range(100):
        await RisingEdge(dut.clk)
        if int(dut.load_start_valid.value) and int(dut.load_start_ready.value):
            starts += 1
        if int(dut.load_coeff_valid.value) and int(dut.load_coeff_ready.value):
            writes[int(dut.load_coeff_address.value)] = (
                int(dut.load_coeff_data.value) & 0xFFF
            )
        if int(dut.load_base_valid.value) and int(dut.load_base_ready.value):
            packed = int(dut.load_base_coefficients.value)
            addresses = (0, 1, 8) if int(dut.load_base_plane.value) else (0, 1, 8, 16, 9, 2)
            for index, address in enumerate(addresses):
                writes[address] = (packed >> (12 * index)) & 0xFFF
        if int(dut.load_commit_valid.value) and int(dut.load_commit_ready.value):
            return starts, writes
        await FallingEdge(dut.clk)
    raise AssertionError("stream join did not commit")


@cocotb.test()
async def enhancement_streams_first_and_base_overwrites_low_frequencies(dut):
    await reset_dut(dut)
    await start_stripe(dut, 1)
    collector = cocotb.start_soon(collect_job(dut))
    await send_event(dut, 0)
    await send_event(dut, 1, scan=0, value=-17)
    await send_event(dut, 1, scan=11, value=29)
    await send_event(dut, 2)
    await send_base(dut, [120, -31, 22, 7, -9, 4])
    starts, writes = await collector

    assert starts == 1
    assert writes[0] == 120
    assert writes[1] == (-31 & 0xFFF)
    assert writes[8] == 22
    assert writes[16] == 7
    assert writes[9] == (-9 & 0xFFF)
    assert writes[2] == 4
    assert writes[25] == 29
    await FallingEdge(dut.clk)
    assert int(dut.enhanced_block_count.value) == 1


@cocotb.test()
async def base_only_job_uses_one_start_six_writes_and_one_commit(dut):
    await reset_dut(dut)
    await start_stripe(dut, 0)
    collector = cocotb.start_soon(collect_job(dut))
    await send_base(dut, [50, -2, 3, 0, 0, 0])
    starts, writes = await collector
    assert starts == 1
    assert writes == {0: 50, 1: (-2 & 0xFFF), 8: 3, 16: 0, 9: 0, 2: 0}
    await FallingEdge(dut.clk)
    assert int(dut.fallback_block_count.value) == 1
