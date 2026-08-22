from __future__ import annotations

import random
import sys
import types

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

if "PIL" not in sys.modules:
    pil_stub = types.ModuleType("PIL")
    pil_stub.Image = types.SimpleNamespace(Image=object)
    pil_stub.ImageDraw = types.SimpleNamespace()
    pil_stub.ImageFont = types.SimpleNamespace()
    sys.modules["PIL"] = pil_stub

import custom_codec_experiment as codec


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.record_valid.value = 0
    dut.display_frame_id.value = 0
    dut.stripe_id.value = 0
    dut.fragment_index.value = 0
    dut.fragment_count.value = 0
    dut.record_flags.value = 0
    dut.payload_length.value = 0
    dut.payload_data.value = 0
    dut.payload_valid.value = 0
    dut.payload_last.value = 0
    dut.decoded_write_ready.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def send_record(dut, payload, *, frame=0x2468, stripe=17,
                      fragment_index=0, fragment_count=1, flags=0):
    await FallingEdge(dut.clk)
    dut.display_frame_id.value = frame
    dut.stripe_id.value = stripe
    dut.fragment_index.value = fragment_index
    dut.fragment_count.value = fragment_count
    dut.record_flags.value = flags
    dut.payload_length.value = len(payload)
    dut.record_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.record_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.record_valid.value = 0
    for index, value in enumerate(payload):
        dut.payload_data.value = value
        dut.payload_valid.value = 1
        dut.payload_last.value = int(index == len(payload) - 1)
        while True:
            await RisingEdge(dut.clk)
            if int(dut.payload_ready.value):
                break
        await FallingEdge(dut.clk)
    dut.payload_valid.value = 0
    dut.payload_last.value = 0


@cocotb.test()
async def coarse_summary_expands_bit_exact_with_backpressure(dut):
    await reset_dut(dut)
    rng = random.Random(0x1F16)
    source_rng = np.random.default_rng(0xC0A25E)
    y = source_rng.integers(0, 256, (16, 1280), dtype=np.int16)
    cb = source_rng.integers(0, 256, (8, 640), dtype=np.int16)
    cr = source_rng.integers(0, 256, (8, 640), dtype=np.int16)
    payload = codec.encode_coarse_stripe(y, cb, cr)
    expected = codec.decode_coarse_stripe(payload, 1280)
    observed = [np.full(plane.shape, -1, dtype=np.int16)
                for plane in expected]
    complete = False
    starts = 0
    lasts = 0

    async def collect_output():
        nonlocal complete, starts, lasts
        while not complete:
            await FallingEdge(dut.clk)
            dut.decoded_write_ready.value = int(rng.random() < 0.73)
            await RisingEdge(dut.clk)
            if (int(dut.decoded_write_valid.value)
                    and int(dut.decoded_write_ready.value)):
                plane = int(dut.decoded_plane.value)
                address = int(dut.decoded_address.value)
                width = 1280 if plane == 0 else 640
                row, column = divmod(address, width)
                assert observed[plane][row, column] == -1
                observed[plane][row, column] = int(dut.decoded_data.value)
                if int(dut.decoded_write_start.value):
                    starts += 1
                    assert plane == 0 and address == 0
                    assert int(dut.decoded_frame_id.value) == 0x2468
                    assert int(dut.decoded_stripe_id.value) == 17
                if int(dut.decoded_write_last.value):
                    lasts += 1
                    complete = True

    collector = cocotb.start_soon(collect_output())
    await send_record(dut, payload)
    for _ in range(100_000):
        if complete:
            break
        await RisingEdge(dut.clk)
    assert complete
    await collector
    assert starts == 1
    assert lasts == 1
    assert int(dut.completed_stripe_count.value) == 1
    assert int(dut.rejected_stripe_count.value) == 0
    for actual, reference in zip(observed, expected):
        np.testing.assert_array_equal(actual, reference)


@cocotb.test()
async def malformed_metadata_is_drained_and_next_record_recovers(dut):
    await reset_dut(dut)
    dut.decoded_write_ready.value = 1
    await send_record(dut, bytes(range(10)), fragment_count=2)
    assert int(dut.rejected_stripe_count.value) == 1
    assert int(dut.busy.value) == 0
    payload = bytes([0x12, 0x34] * 80)
    await send_record(dut, payload, frame=7, stripe=3)
    for _ in range(40_000):
        if int(dut.completed_stripe_count.value):
            break
        await RisingEdge(dut.clk)
    assert int(dut.completed_stripe_count.value) == 1
    assert int(dut.rejected_stripe_count.value) == 1
