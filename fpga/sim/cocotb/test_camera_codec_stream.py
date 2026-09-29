from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge


async def send_line(dut, line: int) -> None:
    await FallingEdge(dut.pixel_clk)
    dut.pixel_href.value = 1
    state = ((line + 1) * 0x9E3779B1) & 0xFFFFFFFF
    for byte_index in range(2560):
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        dut.pixel_data.value = (state >> 24) & 0xFF
        await FallingEdge(dut.pixel_clk)
    dut.pixel_href.value = 0
    dut.pixel_data.value = 0
    for _ in range(16):
        await FallingEdge(dut.pixel_clk)


@cocotb.test()
async def real_stripe_buffer_feeds_overlapped_scheduler(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 12.5, units="ns").start())
    # 66 MHz rounded to a whole number of simulator precision steps. This is
    # a cycle-accurate functional test, so the 0.5 ps difference is immaterial.
    cocotb.start_soon(Clock(dut.codec_clk, 15.152, units="ns").start())
    cocotb.start_soon(Clock(dut.link_clk, 41.668, units="ns").start())
    dut.pixel_rst_n.value = 0
    dut.codec_rst_n.value = 0
    dut.link_rst_n.value = 0
    dut.pixel_vsync.value = 0
    dut.pixel_href.value = 0
    dut.pixel_data.value = 0
    for _ in range(8):
        await RisingEdge(dut.codec_clk)
    dut.pixel_rst_n.value = 1
    dut.codec_rst_n.value = 1
    dut.link_rst_n.value = 1

    await FallingEdge(dut.pixel_clk)
    dut.pixel_vsync.value = 1
    await FallingEdge(dut.pixel_clk)
    dut.pixel_vsync.value = 0
    for line in range(16):
        await send_line(dut, line)

    for cycle in range(65000):
        await RisingEdge(dut.codec_clk)
        if int(dut.packet_commit.value):
            break
    else:
        raise AssertionError(
            "pipeline stalled: "
            f"ctu={int(dut.ctu_index.value)} "
            f"scheduler={int(dut.scheduler_state.value)} "
            f"frontend={int(dut.frontend_state.value)} "
            f"busy={int(dut.codec_busy.value)} "
            f"fatal={int(dut.fatal_error.value)}"
        )

    for _ in range(20000):
        await RisingEdge(dut.link_clk)
        if int(dut.packet_count.value):
            break
    assert int(dut.packet_count.value) > 0
    assert not int(dut.packet_overflow.value)
    assert int(dut.ctu_index.value) == 79
    assert not int(dut.fatal_error.value)
    assert not int(dut.buffer_overflow.value)
    assert int(dut.dropped_stripes.value) == 0
