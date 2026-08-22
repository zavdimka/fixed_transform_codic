from __future__ import annotations

import sys
import types

import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

# Codec arithmetic does not use Pillow; keep the RTL test environment lean by
# satisfying the command-line preview module's optional image-I/O imports.
if "PIL" not in sys.modules:
    pil_stub = types.ModuleType("PIL")
    pil_stub.Image = types.SimpleNamespace(Image=object)
    pil_stub.ImageDraw = types.SimpleNamespace()
    pil_stub.ImageFont = types.SimpleNamespace()
    sys.modules["PIL"] = pil_stub

import custom_codec_experiment as codec
import jpeg_radio_codec as core


def signed12(value: int) -> int:
    return value - 4096 if value & 0x800 else value


def reference_blocks(data: bytes, bit_length: int, ctu_count: int):
    reader = core.BitReader(data, bit_length)
    result = []
    for ctu in range(ctu_count):
        mode = reader.read(core.INTRA_MODE_BITS)
        for block in range(6):
            table_id = int(block >= 4)
            coefficient_count = 3 if table_id else 6
            category = core.huffman_read(reader, 0, table_id)
            dc = core.amplitude_value(reader.read(category), category)
            ac = codec.decode_ac_segment(
                reader, coefficient_count - 1, table_id, table_id == 0
            )
            values = [dc] + ac + [0] * (6 - coefficient_count)
            result.append((ctu, block, table_id and block - 3, mode, values))
    assert reader.position == bit_length
    return result


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.record_valid.value = 0
    dut.display_frame_id.value = 0
    dut.stripe_id.value = 0
    dut.quality.value = 0
    dut.fragment_index.value = 0
    dut.fragment_count.value = 0
    dut.record_flags.value = 0
    dut.payload_length.value = 0
    dut.payload_data.value = 0
    dut.payload_valid.value = 0
    dut.payload_last.value = 0
    dut.block_ready.value = 1
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def send_fragment(dut, payload, index, count, final_valid_bits):
    await FallingEdge(dut.clk)
    dut.display_frame_id.value = 0x1234
    dut.stripe_id.value = 7
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
async def decodes_real_encoder_base_stream_across_fragments(dut):
    await reset_dut(dut)

    x = np.arange(1280, dtype=np.int16)[None, :]
    y = np.arange(16, dtype=np.int16)[:, None]
    luma = ((3 * x + 17 * y + 29 * ((x // 37) & 3)) & 255).astype(np.int16)
    cb = ((7 * np.arange(640)[None, :] + 13 * np.arange(8)[:, None] + 73)
          & 255).astype(np.int16)
    cr = ((11 * np.arange(640)[None, :] + 5 * np.arange(8)[:, None] + 121)
          & 255).astype(np.int16)
    record = codec.encode_stripe(
        luma, cb, cr, 24, 0, core.ArithmeticStats(),
        base_max_bytes=2048, enhancement_max_bytes=1536,
    )
    expected = reference_blocks(record.base_data, record.base_bits, 80)

    observed = []
    done = False

    async def monitor():
        nonlocal done
        while not done:
            await RisingEdge(dut.clk)
            if int(dut.block_valid.value) and int(dut.block_ready.value):
                packed = int(dut.block_coefficients.value)
                values = [signed12((packed >> (12 * i)) & 0xFFF)
                          for i in range(6)]
                observed.append((
                    int(dut.block_ctu_index.value),
                    int(dut.block_index.value),
                    int(dut.block_plane.value),
                    int(dut.block_mode.value),
                    values,
                ))
            if int(dut.stripe_done.value):
                done = True

    monitor_task = cocotb.start_soon(monitor())
    chunks = [record.base_data[i:i + 11]
              for i in range(0, len(record.base_data), 11)]
    final_valid_bits = (record.base_bits - 1) % 8 + 1
    for index, chunk in enumerate(chunks):
        await send_fragment(dut, chunk, index, len(chunks), final_valid_bits)

    for _ in range(10000):
        if done:
            break
        await RisingEdge(dut.clk)
    assert done, (
        f"state={int(dut.state.value)} blocks={len(observed)} "
        f"completed={int(dut.completed_stripe_count.value)} "
        f"rejected={int(dut.rejected_stripe_count.value)} "
        f"syntax={int(dut.syntax_error_count.value)} "
        f"ctu={int(dut.block_ctu_index.value)} "
        f"block={int(dut.block_index.value)}"
    )
    await monitor_task
    assert observed == expected
    assert int(dut.completed_stripe_count.value) == 1
    assert int(dut.rejected_stripe_count.value) == 0
    assert int(dut.syntax_error_count.value) == 0
    assert int(dut.stripe_frame_id.value) == 0x1234
    assert int(dut.completed_stripe_id.value) == 7
    assert int(dut.stripe_quality.value) == 24
