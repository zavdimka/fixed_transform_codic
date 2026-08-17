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
        "source": source, "coefficient_blocks": [coefficients],
        "pixel_blocks": [pixels],
    }


def make_chroma_pair(index, quality=1):
    cb = make_block(index, True, True, quality)
    cr = make_block(index + 1, True, True, quality)
    return {
        "size8": True, "chroma": True, "quality": quality,
        "source": cb["source"] + cr["source"],
        "coefficient_blocks": (cb["coefficient_blocks"] +
                               cr["coefficient_blocks"]),
        "pixel_blocks": cb["pixel_blocks"] + cr["pixel_blocks"],
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


async def run_blocks(dut, commands, stall=False, source_stall=False):
    expected_coefficients = [block for command in commands
                             for block in command["coefficient_blocks"]]
    expected_pixels = [block for command in commands
                       for block in command["pixel_blocks"]]
    command_index = 0
    source_block = None
    source_index = 0
    coefficient_blocks = [[]]
    pixel_blocks = [[]]
    command_cycles = []
    source_last_cycles = []
    coefficient_first_cycles = []
    coefficient_last_cycles = []
    pixel_last_cycles = []
    forward_idle_wait_cycles = 0

    dut.coefficient_ready.value = 1
    dut.m_ready.value = 1
    for cycle in range(100000):
        if stall:
            dut.coefficient_ready.value = int(cycle % 5 != 1)
            dut.m_ready.value = int(cycle % 7 not in (2, 3))
        if command_index < len(commands) and not int(dut.command_valid.value):
            block = commands[command_index]
            dut.command_size8.value = block["size8"]
            dut.command_chroma.value = block["chroma"]
            dut.command_quality.value = block["quality"]
            dut.command_valid.value = 1
        source_may_start = not source_stall or cycle % 11 not in (3, 4, 5)
        if (source_block is not None and not int(dut.s_valid.value) and
                source_may_start):
            prediction, residual = commands[source_block]["source"][source_index]
            dut.s_prediction.value = prediction
            dut.s_residual.value = residual
            dut.s_valid.value = 1

        await Timer(1, units="ns")
        if (int(dut.command_valid.value) and
                not int(dut.command_ready.value) and int(dut.fstate.value) == 0):
            forward_idle_wait_cycles += 1
        command_fire = int(dut.command_valid.value) and int(dut.command_ready.value)
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        coefficient_fire = (int(dut.coefficient_valid.value) and
                            int(dut.coefficient_ready.value))
        pixel_fire = int(dut.m_valid.value) and int(dut.m_ready.value)

        if coefficient_fire:
            if not coefficient_blocks[-1]:
                coefficient_first_cycles.append(cycle)
            item = (dut.coefficient_data.value.signed_integer,
                    int(dut.coefficient_x.value), int(dut.coefficient_y.value),
                    int(dut.coefficient_nonzero.value),
                    bool(dut.coefficient_block_last.value))
            coefficient_blocks[-1].append(item)
            if item[-1]:
                coefficient_last_cycles.append(cycle)
            if item[-1] and len(coefficient_blocks) < len(expected_coefficients):
                coefficient_blocks.append([])
        if pixel_fire:
            item = (int(dut.m_reconstructed.value), int(dut.m_x.value),
                    int(dut.m_y.value), bool(dut.m_block_last.value),
                    bool(dut.m_block_error.value))
            pixel_blocks[-1].append(item)
            if item[3]:
                pixel_last_cycles.append(cycle)
                if len(pixel_blocks) < len(expected_pixels):
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
            if source_index == len(commands[source_block]["source"]):
                source_last_cycles.append(cycle)
                dut.s_valid.value = 0
                source_block = None
            elif source_stall:
                dut.s_valid.value = 0
            else:
                prediction, residual = commands[source_block]["source"][source_index]
                dut.s_prediction.value = prediction
                dut.s_residual.value = residual
        if len(pixel_last_cycles) == len(expected_pixels):
            break
    else:
        raise AssertionError("dual reconstruction timed out")

    assert expected_coefficients == coefficient_blocks
    if expected_pixels != pixel_blocks:
        for block_index, (expected, actual) in enumerate(
                zip(expected_pixels, pixel_blocks)):
            if expected != actual:
                for item_index, (expected_item, actual_item) in enumerate(
                        zip(expected, actual)):
                    if expected_item != actual_item:
                        raise AssertionError(
                            f"pixel mismatch block={block_index} item={item_index}: "
                            f"expected={expected_item} actual={actual_item}; "
                            f"expected_slice={expected[max(0, item_index-2):item_index+3]} "
                            f"actual_slice={actual[max(0, item_index-2):item_index+3]} "
                            f"lengths={len(expected)}/{len(actual)}")
                raise AssertionError(
                    f"pixel block length mismatch block={block_index}: "
                    f"expected={len(expected)} actual={len(actual)}")
        raise AssertionError("pixel block count mismatch")
    assert not int(dut.busy.value)
    dut._log.info("accepted %d paired commands, emitted %d coefficient blocks",
                  len(source_last_cycles), len(coefficient_last_cycles))
    dut._log.info("forward idle while next command waited: %d cycles",
                  forward_idle_wait_cycles)
    return command_cycles, pixel_last_cycles


@cocotb.test()
async def context_ring_overlaps_forward_and_inverse_in_order(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    commands = []
    for ctu in range(12):
        commands.extend((make_block(ctu * 3, False, False),
                         make_chroma_pair(ctu * 3 + 1)))
    command_cycles, pixel_last_cycles = await run_blocks(dut, commands)
    assert command_cycles[1] < pixel_last_cycles[0]
    block_intervals = [b - a for a, b in zip(command_cycles, command_cycles[1:])]
    dut._log.info("dual-core command interval values: %s",
                  sorted(set(block_intervals)))
    dut._log.info("dual-core first command intervals: %s", block_intervals[:8])
    dut._log.info("dual-core pixel-block interval values: %s", sorted(set(
        b - a for a, b in zip(pixel_last_cycles, pixel_last_cycles[1:]))))
    y_starts = command_cycles[0::2]
    ctu_intervals = [b - a for a, b in zip(y_starts[3:-1], y_starts[4:])]
    pixel_y_ends = pixel_last_cycles[0::3]
    pixel_ctu_intervals = [b - a for a, b in zip(
        pixel_y_ends[3:-1], pixel_y_ends[4:])]
    command_average = sum(ctu_intervals) / len(ctu_intervals)
    pixel_average = sum(pixel_ctu_intervals) / len(pixel_ctu_intervals)
    sustainable_interval = max(command_average, pixel_average)
    dut._log.info(
        "dual-core steady CTU interval: command %.1f, pixel %.1f cycles",
        command_average, pixel_average)
    # Paired Cb/Cr load, transform and reconstruction overlap; pixel output binds.
    # The registered inverse-quant DSP output adds one elastic stage to each
    # side of the alternating Y/C transaction without reducing throughput.
    assert sustainable_interval <= 754


@cocotb.test()
async def output_backpressure_preserves_block_order(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    commands = (make_block(21, False, False, 0),
                make_chroma_pair(22, 2))
    await run_blocks(dut, commands, stall=True, source_stall=True)
