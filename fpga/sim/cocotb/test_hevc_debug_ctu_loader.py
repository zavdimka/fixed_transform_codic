from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CTU_BYTES = 384


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.load_clear.value = 0
    dut.load_write_valid.value = 0
    dut.load_write_data.value = 0
    dut.load_commit.value = 0
    dut.run_valid.value = 0
    dut.ctu_start_ready.value = 0
    dut.y_ready.value = 0
    dut.cb_ready.value = 0
    dut.cr_ready.value = 0
    dut.ctu_done.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load(dut, payload: bytes) -> None:
    await FallingEdge(dut.clk)
    dut.load_clear.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.load_clear.value = 0
    for value in payload:
        dut.load_write_valid.value = 1
        dut.load_write_data.value = value
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
    dut.load_write_valid.value = 0
    dut.load_commit.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.load_commit.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


@cocotb.test()
async def complete_ctu_streams_y_cb_cr_in_order_with_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    payload = bytes(((index * 73) ^ (index >> 1) ^ 0xA5) & 0xFF
                    for index in range(CTU_BYTES))
    await load(dut, payload)
    assert int(dut.loaded.value)
    assert int(dut.load_count.value) == CTU_BYTES
    assert not int(dut.load_error.value)

    await FallingEdge(dut.clk)
    dut.run_valid.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.run_valid.value = 0
    while not int(dut.ctu_start_valid.value):
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
    dut.ctu_start_ready.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.ctu_start_ready.value = 0

    rng = random.Random(0xC7A)
    received = [[], [], []]
    for _ in range(5000):
        dut.y_ready.value = int(rng.random() < 0.74)
        dut.cb_ready.value = int(rng.random() < 0.61)
        dut.cr_ready.value = int(rng.random() < 0.67)
        await RisingEdge(dut.clk)

        if int(dut.y_valid.value) and int(dut.y_ready.value):
            received[0].append(int(dut.y_pixel.value))
        if int(dut.cb_valid.value) and int(dut.cb_ready.value):
            received[1].append(int(dut.cb_pixel.value))
        if int(dut.cr_valid.value) and int(dut.cr_ready.value):
            received[2].append(int(dut.cr_pixel.value))

        if [len(plane) for plane in received] == [256, 64, 64]:
            await FallingEdge(dut.clk)
            dut.ctu_done.value = 1
            await RisingEdge(dut.clk)
            await Timer(1, units="ns")
            dut.ctu_done.value = 0
            assert int(dut.run_done.value)
            assert not int(dut.busy.value)
            assert bytes(received[0]) == payload[:256]
            assert bytes(received[1]) == payload[256:320]
            assert bytes(received[2]) == payload[320:384]
            return

        await FallingEdge(dut.clk)

    raise AssertionError(f"CTU stream timed out: {[len(plane) for plane in received]}")


@cocotb.test()
async def short_ctu_is_rejected(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    await load(dut, bytes(range(32)))
    assert not int(dut.loaded.value)
    assert int(dut.load_error.value)
    assert not int(dut.run_ready.value)
