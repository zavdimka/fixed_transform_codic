from __future__ import annotations

import random
import sys
import types

import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

if "PIL" not in sys.modules:
    pil_stub = types.ModuleType("PIL")
    pil_stub.Image = types.SimpleNamespace(Image=object)
    pil_stub.ImageDraw = types.SimpleNamespace()
    pil_stub.ImageFont = types.SimpleNamespace()
    sys.modules["PIL"] = pil_stub

import custom_codec_experiment as codec
import jpeg_radio_codec as core


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.record_valid.value = 0
    dut.display_frame_id.value = 0
    dut.stripe_id.value = 0
    dut.quality.value = 24
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


async def send_fragment(dut, payload, index, count, final_valid_bits):
    await FallingEdge(dut.clk)
    dut.display_frame_id.value = 0x4321
    dut.stripe_id.value = 9
    dut.quality.value = 24
    dut.fragment_index.value = index
    dut.fragment_count.value = count
    dut.record_flags.value = final_valid_bits - 1 if index == count - 1 else 0
    dut.payload_length.value = len(payload)
    dut.record_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.record_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.record_valid.value = 0

    for offset, value in enumerate(payload):
        dut.payload_data.value = value
        dut.payload_valid.value = 1
        dut.payload_last.value = int(offset == len(payload) - 1)
        while True:
            await RisingEdge(dut.clk)
            if int(dut.payload_ready.value):
                break
        await FallingEdge(dut.clk)
    dut.payload_valid.value = 0
    dut.payload_last.value = 0


@cocotb.test()
async def real_base_stream_reconstructs_bit_exact_yuv_stripe(dut):
    await reset_dut(dut)
    rng = random.Random(0xB453)

    x = np.arange(1280, dtype=np.int16)[None, :]
    y = np.arange(16, dtype=np.int16)[:, None]
    luma = ((3 * x + 17 * y + 29 * ((x // 37) & 3)) & 255).astype(np.int16)
    cx = np.arange(640, dtype=np.int16)[None, :]
    cy = np.arange(8, dtype=np.int16)[:, None]
    cb = ((7 * cx + 13 * cy + 73) & 255).astype(np.int16)
    cr = ((11 * cx + 5 * cy + 121) & 255).astype(np.int16)
    record = codec.encode_stripe(
        luma, cb, cr, 24, 9, core.ArithmeticStats(),
        base_max_bytes=2048, enhancement_max_bytes=1536,
    )
    expected, _ = codec.decode_stripe(
        record, 24, core.ArithmeticStats(), enhancement=False
    )
    observed = [
        np.full(plane.shape, -1, dtype=np.int16) for plane in expected
    ]
    write_count = 0
    start_count = 0
    last_count = 0
    finished = False

    async def output_driver():
        nonlocal write_count, start_count, last_count, finished
        while not finished:
            await FallingEdge(dut.clk)
            dut.decoded_write_ready.value = int(rng.random() < 0.83)
            await RisingEdge(dut.clk)
            if (int(dut.decoded_write_valid.value)
                    and int(dut.decoded_write_ready.value)):
                plane = int(dut.decoded_plane.value)
                address = int(dut.decoded_address.value)
                width = 1280 if plane == 0 else 640
                row, column = divmod(address, width)
                assert observed[plane][row, column] == -1
                observed[plane][row, column] = int(dut.decoded_data.value)
                write_count += 1
                if int(dut.decoded_write_start.value):
                    start_count += 1
                    assert write_count == 1
                    assert int(dut.decoded_frame_id.value) == 0x4321
                    assert int(dut.decoded_stripe_id.value) == 9
                if int(dut.decoded_write_last.value):
                    last_count += 1
                    finished = True

    output_task = cocotb.start_soon(output_driver())
    chunks = [record.base_data[i:i + 11]
              for i in range(0, len(record.base_data), 11)]
    valid_bits = (record.base_bits - 1) % 8 + 1
    for index, chunk in enumerate(chunks):
        await send_fragment(dut, chunk, index, len(chunks), valid_bits)

    for _ in range(100_000):
        if finished:
            break
        await RisingEdge(dut.clk)
    assert finished
    await output_task

    assert write_count == 30_720
    assert start_count == 1
    assert last_count == 1
    for actual, reference in zip(observed, expected):
        np.testing.assert_array_equal(actual, reference)
    assert int(dut.completed_stripe_count.value) == 1
    assert int(dut.rejected_stripe_count.value) == 0
    assert int(dut.syntax_error_count.value) == 0
    assert int(dut.saturation_error.value) == 0
    assert int(dut.prediction_mode_error.value) == 0
