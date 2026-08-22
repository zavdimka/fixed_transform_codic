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
    dut.event_ready.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def send_fragment(dut, payload, index, count, valid_bits):
    await FallingEdge(dut.clk)
    dut.display_frame_id.value = 0x1357
    dut.stripe_id.value = 11
    dut.quality.value = 24
    dut.fragment_index.value = index
    dut.fragment_count.value = count
    dut.record_flags.value = valid_bits - 1 if index == count - 1 else 0
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


def expected_events(record):
    reader = core.BitReader(record.enhancement_data, record.enhancement_bits)
    result = []
    for ctu in range(80):
        for block in range(6):
            table_id = int(block >= 4)
            base_count = 3 if table_id else 6
            length = 64 - base_count
            values = codec.decode_ac_segment(
                reader, length, table_id, table_id == 0
            )
            result.append((0, ctu, block, None, None))
            for offset, value in enumerate(values):
                if value:
                    result.append((1, ctu, block, base_count + offset, value))
            result.append((2, ctu, block, None, None))
    assert reader.position == record.enhancement_bits
    return result


@cocotb.test()
async def real_enhancement_stream_emits_exact_sparse_coefficients(dut):
    await reset_dut(dut)
    ready_rng = random.Random(0xE11A)
    x = np.arange(1280, dtype=np.int16)[None, :]
    y_index = np.arange(16, dtype=np.int16)[:, None]
    y = ((5 * x + 19 * y_index + 31 * ((x // 23) & 3)) & 255).astype(np.int16)
    cx = np.arange(640, dtype=np.int16)[None, :]
    cy = np.arange(8, dtype=np.int16)[:, None]
    cb = ((9 * cx + 17 * cy + 41) & 255).astype(np.int16)
    cr = ((13 * cx + 7 * cy + 109) & 255).astype(np.int16)
    record = codec.encode_stripe(
        y, cb, cr, 24, 11, core.ArithmeticStats(),
        base_max_bytes=2048, enhancement_max_bytes=1536,
    )
    expected = expected_events(record)
    observed = []
    complete = False

    async def collect_events():
        nonlocal complete
        while not complete:
            await FallingEdge(dut.clk)
            dut.event_ready.value = int(ready_rng.random() < 0.79)
            await RisingEdge(dut.clk)
            if int(dut.event_valid.value) and int(dut.event_ready.value):
                kind = int(dut.event_kind.value)
                item = (
                    kind,
                    int(dut.event_ctu_index.value),
                    int(dut.event_block_index.value),
                    int(dut.event_scan_index.value) if kind == 1 else None,
                    dut.event_coefficient.value.signed_integer if kind == 1 else None,
                )
                observed.append(item)
                assert int(dut.event_frame_id.value) == 0x1357
                assert int(dut.event_stripe_id.value) == 11
                assert int(dut.event_quality.value) == 24
                if kind == 2 and item[1:3] == (79, 5):
                    complete = True

    collector = cocotb.start_soon(collect_events())
    chunks = [record.enhancement_data[i:i + 13]
              for i in range(0, len(record.enhancement_data), 13)]
    valid_bits = (record.enhancement_bits - 1) % 8 + 1
    for index, chunk in enumerate(chunks):
        await send_fragment(dut, chunk, index, len(chunks), valid_bits)
    for _ in range(100_000):
        if complete:
            break
        await RisingEdge(dut.clk)
    assert complete
    await collector
    assert observed == expected
    assert int(dut.completed_stripe_count.value) == 1
    assert int(dut.rejected_stripe_count.value) == 0
    assert int(dut.syntax_error_count.value) == 0
