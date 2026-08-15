from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_hevc_shared_reconstruction_core import expected_block


def make_block(index, size8, chroma, quality=1):
    size = 8 if size8 else 16
    prediction = [[(91 + index * 13 + x * 3 + y * 5) & 255
                   for x in range(size)] for y in range(size)]
    residual = [[((index * 19 + x * 7 + y * 11) & 63) - 32
                 for x in range(size)] for y in range(size)]
    coefficients, pixels = expected_block(
        prediction, residual, size8, chroma, quality)
    source = [(prediction[y][x], residual[y][x])
              for y in range(size) for x in range(size)]
    return {
        "size8": size8, "chroma": chroma, "quality": quality,
        "source": source, "coefficients": coefficients, "pixels": pixels,
    }


async def reset(dut):
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.s_valid.value = 0
    dut.coefficient_ready.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_blocks(dut, blocks, stall=False, source_stall=False):
    command_index = 0
    source_block = None
    source_index = 0
    coefficient_blocks = [[]]
    pixel_blocks = [[]]
    command_cycles = []
    pixel_last_cycles = []

    dut.coefficient_ready.value = 1
    dut.m_ready.value = 1
    for cycle in range(100000):
        if stall:
            dut.coefficient_ready.value = int(cycle % 5 != 1)
            dut.m_ready.value = int(cycle % 7 not in (2, 3))
        if command_index < len(blocks) and not int(dut.command_valid.value):
            block = blocks[command_index]
            dut.command_size8.value = block["size8"]
            dut.command_chroma.value = block["chroma"]
            dut.command_quality.value = block["quality"]
            dut.command_valid.value = 1
        source_may_start = not source_stall or cycle % 11 not in (3, 4, 5)
        if (source_block is not None and not int(dut.s_valid.value) and
                source_may_start):
            prediction, residual = blocks[source_block]["source"][source_index]
            dut.s_prediction.value = prediction
            dut.s_residual.value = residual
            dut.s_valid.value = 1

        await Timer(1, units="ns")
        command_fire = int(dut.command_valid.value) and int(dut.command_ready.value)
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        coefficient_fire = (int(dut.coefficient_valid.value) and
                            int(dut.coefficient_ready.value))
        pixel_fire = int(dut.m_valid.value) and int(dut.m_ready.value)

        if coefficient_fire:
            item = (dut.coefficient_data.value.signed_integer,
                    int(dut.coefficient_x.value), int(dut.coefficient_y.value),
                    int(dut.coefficient_nonzero.value),
                    bool(dut.coefficient_block_last.value))
            coefficient_blocks[-1].append(item)
            if item[-1] and len(coefficient_blocks) < len(blocks):
                coefficient_blocks.append([])
        if pixel_fire:
            item = (int(dut.m_reconstructed.value), int(dut.m_x.value),
                    int(dut.m_y.value), bool(dut.m_block_last.value),
                    bool(dut.m_block_error.value))
            pixel_blocks[-1].append(item)
            if item[3]:
                pixel_last_cycles.append(cycle)
                if len(pixel_blocks) < len(blocks):
                    pixel_blocks.append([])

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if command_fire:
            assert source_block is None
            source_block = command_index
            source_index = 0
            command_cycles.append(cycle)
            command_index += 1
            dut.command_valid.value = 0
        if source_fire:
            source_index += 1
            dut.s_valid.value = 0
            if source_index == len(blocks[source_block]["source"]):
                source_block = None
        if len(pixel_last_cycles) == len(blocks):
            break
    else:
        raise AssertionError("dual reconstruction timed out")

    assert [block["coefficients"] for block in blocks] == coefficient_blocks
    assert [block["pixels"] for block in blocks] == pixel_blocks
    assert not int(dut.busy.value)
    return command_cycles, pixel_last_cycles


@cocotb.test()
async def context_ring_overlaps_forward_and_inverse_in_order(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    blocks = []
    for ctu in range(5):
        blocks.extend((make_block(ctu * 3, False, False),
                       make_block(ctu * 3 + 1, True, True),
                       make_block(ctu * 3 + 2, True, True)))
    command_cycles, pixel_last_cycles = await run_blocks(dut, blocks)
    assert command_cycles[1] < pixel_last_cycles[0]
    block_intervals = [b - a for a, b in zip(command_cycles, command_cycles[1:])]
    dut._log.info("dual-core command intervals: %s", block_intervals)
    y_starts = command_cycles[0::3]
    ctu_intervals = [b - a for a, b in zip(y_starts[1:-1], y_starts[2:])]
    average = sum(ctu_intervals) / len(ctu_intervals)
    dut._log.info("dual-core steady CTU16 Y+Cb+Cr interval: %.1f cycles", average)
    # PASS1 overlaps row loading; only the last row remains as a transform tail.
    assert average <= 1210


@cocotb.test()
async def output_backpressure_preserves_block_order(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    blocks = (make_block(21, False, False, 0),
              make_block(22, True, True, 2),
              make_block(23, True, True, 1))
    await run_blocks(dut, blocks, stall=True, source_stall=True)
