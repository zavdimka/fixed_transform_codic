from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer


async def reset_dut(dut) -> None:
    dut.link_rst_n.value = 0
    dut.read_rst_n.value = 0
    dut.par_cs.value = 0
    dut.par_data.value = 0
    dut.output_ready.value = 0
    await ClockCycles(dut.link_clk, 5)
    dut.link_rst_n.value = 1
    dut.read_rst_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.link_clk)
        if int(dut.par_clock_enabled.value):
            return
    raise AssertionError("PAR_CLK did not start after reset")


async def send_packet(dut, payload: bytes) -> None:
    assert int(dut.par_clock_enabled.value), "link paused before packet"
    for byte_index, value in enumerate(payload):
        for nibble in (value >> 4, value & 0xF):
            await FallingEdge(dut.link_clk)
            dut.par_cs.value = 1
            dut.par_data.value = nibble
            await RisingEdge(dut.link_clk)
            await ReadOnly()
            assert int(dut.par_clk.value) == 1
    await FallingEdge(dut.link_clk)
    dut.par_cs.value = 0
    dut.par_data.value = 0
    await RisingEdge(dut.link_clk)


async def collect_entries(dut, count: int) -> list[int]:
    result: list[int] = []
    while len(result) < count:
        await RisingEdge(dut.read_clk)
        await ReadOnly()
        if int(dut.output_valid.value) and int(dut.output_ready.value):
            result.append(int(dut.output_entry.value))
    return result


@cocotb.test()
async def packets_cross_clock_domains_with_boundary_markers(dut) -> None:
    cocotb.start_soon(Clock(dut.link_clk, 42, units="ns").start())
    cocotb.start_soon(Clock(dut.read_clk, 17, units="ns").start())
    await reset_dut(dut)
    dut.output_ready.value = 1

    first = bytes([0x12, 0x34, 0xAB])
    second = bytes([0x00, 0xFF])
    collector = cocotb.start_soon(
        collect_entries(dut, len(first) + len(second) + 2)
    )
    await send_packet(dut, first)
    await send_packet(dut, second)
    entries = await collector

    assert entries == [
        0x100 | first[0], first[1], first[2], 0x200,
        0x100 | second[0], second[1], 0x200,
    ]
    assert int(dut.overflow_error.value) == 0
    assert int(dut.framing_error.value) == 0


@cocotb.test()
async def clock_stops_at_packet_boundary_and_resumes_in_hardware(dut) -> None:
    cocotb.start_soon(Clock(dut.link_clk, 42, units="ns").start())
    cocotb.start_soon(Clock(dut.read_clk, 17, units="ns").start())
    await reset_dut(dut)

    payload = bytes((index * 29) & 0xFF for index in range(128))
    packet_count = 0
    while True:
        await send_packet(dut, payload)
        packet_count += 1
        await FallingEdge(dut.link_clk)
        await ReadOnly()
        if not int(dut.par_clock_enabled.value):
            break
        if packet_count > 30:
            raise AssertionError("link did not throttle at the high watermark")
    assert packet_count >= 22
    assert int(dut.write_level.value) >= 2816
    assert int(dut.par_cs.value) == 0

    await Timer(1, units="ns")
    dut.output_ready.value = 1
    for _ in range(10000):
        await RisingEdge(dut.link_clk)
        if int(dut.par_clock_enabled.value):
            break
    else:
        raise AssertionError("link did not resume after FIFO drained")
    assert int(dut.write_level.value) <= 2048
    assert int(dut.overflow_error.value) == 0
    assert int(dut.framing_error.value) == 0
