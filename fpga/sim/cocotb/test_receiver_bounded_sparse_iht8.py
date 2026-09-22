from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


def inverse_iht8(v: list[int]) -> list[int]:
    c0, c1, c2, c3, c4, c5, c6, c7 = v
    a0, a2 = c0 + c4, c0 - c4
    a4, a6 = (c2 >> 1) - c6, c2 + (c6 >> 1)
    a1 = -c3 + c5 - c7 - (c7 >> 1)
    a3 = c1 + c7 - c3 - (c3 >> 1)
    a5 = -c1 + c7 + c5 + (c5 >> 1)
    a7 = c3 + c5 + c1 + (c1 >> 1)
    b0, b2, b4, b6 = a0 + a6, a2 + a4, a2 - a4, a0 - a6
    b1, b3 = a1 + (a7 >> 2), a3 + (a5 >> 2)
    b5, b7 = (a3 >> 2) - a5, a7 - (a1 >> 2)
    return [b0 + b7, b2 + b5, b4 + b3, b6 + b1,
            b6 - b1, b4 - b3, b2 - b5, b0 - b7]


def dequantize(value: int, address: int, quant_shift: int) -> int:
    diagonal = (address >> 3) + (address & 7)
    weight_shift = 0 if diagonal <= 1 else 1 if diagonal <= 3 else 2 if diagonal <= 5 else 3
    return value << min(quant_shift + weight_shift, 6)


def round_clip16(value: int) -> int:
    return max(-32768, min(32767, (value + 32) >> 6))


def model_block(coefficients: dict[int, int], quant_shift: int) -> list[int]:
    matrix = [[dequantize(coefficients.get(row * 8 + column, 0),
                          row * 8 + column, quant_shift)
               for column in range(8)] for row in range(8)]
    rows = [inverse_iht8(row) for row in matrix]
    columns = [inverse_iht8([rows[row][column] for row in range(8)])
               for column in range(8)]
    return [round_clip16(columns[column][row])
            for row in range(8) for column in range(8)]


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.load_start_valid.value = 0
    dut.load_coeff_valid.value = 0
    dut.load_commit_valid.value = 0
    dut.load_abort.value = 0
    dut.pixel_ready.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def pulse_when_ready(dut, valid, ready) -> None:
    while True:
        await FallingEdge(dut.clk)
        if int(ready.value):
            valid.value = 1
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            valid.value = 0
            return


async def send_block(dut, block_id: int, plane: int, quant_shift: int,
                     events: list[tuple[int, int]]) -> None:
    dut.load_ctu_index.value = block_id & 0x7f
    dut.load_block_index.value = block_id & 7
    dut.load_plane.value = plane
    dut.load_mode.value = (block_id >> 1) & 3
    dut.load_quant_shift.value = quant_shift
    await pulse_when_ready(dut, dut.load_start_valid, dut.load_start_ready)
    for address, value in events:
        dut.load_coeff_address.value = address
        dut.load_coeff_data.value = value
        await pulse_when_ready(dut, dut.load_coeff_valid,
                               dut.load_coeff_ready)
    await pulse_when_ready(dut, dut.load_commit_valid,
                           dut.load_commit_ready)


async def collect_blocks(dut, count: int, apply_backpressure: bool = False):
    blocks = []
    current = []
    cycle = 0
    while len(blocks) < count:
        await FallingEdge(dut.clk)
        ready = not apply_backpressure or cycle % 7 != 3
        dut.pixel_ready.value = ready
        if ready and int(dut.pixel_valid.value):
            current.append(int(dut.pixel_residual.value.signed_integer))
            assert int(dut.pixel_index.value) == len(current) - 1
            if int(dut.pixel_last.value):
                assert len(current) == 64
                blocks.append((int(dut.pixel_ctu_index.value),
                               int(dut.pixel_block_index.value),
                               int(dut.pixel_plane.value),
                               int(dut.pixel_mode.value), current))
                current = []
        cycle += 1
    dut.pixel_ready.value = 1
    return blocks, cycle


@cocotb.test()
async def sparse_blocks_are_bit_exact_with_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xB0A8D)
    descriptions = []
    for block_id in range(16):
        plane = 0 if block_id % 3 else 1
        limit = 12 if plane == 0 else 6
        addresses = rng.sample(range(1, 64), rng.randint(0, limit))
        events = [(0, rng.randint(-128, 127))]
        events += [(address, rng.randint(-63, 63)) for address in addresses]
        quant_shift = rng.randint(0, 3)
        descriptions.append((plane, quant_shift, events))

    collector = cocotb.start_soon(collect_blocks(dut, len(descriptions), True))
    for block_id, (plane, quant_shift, events) in enumerate(descriptions):
        await send_block(dut, block_id, plane, quant_shift, events)
    observed, _ = await collector

    for block_id, ((plane, quant_shift, events), actual) in enumerate(zip(descriptions, observed)):
        ctu, block, actual_plane, mode, pixels = actual
        assert (ctu, block, actual_plane, mode) == (
            block_id & 0x7f, block_id & 7, plane, (block_id >> 1) & 3)
        assert pixels == model_block(dict(events), quant_shift)


@cocotb.test()
async def extreme_12bit_coefficients_do_not_overflow_transform(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    descriptions = [
        [(address, 2047 if address & 1 else -2048)
         for address in range(13)],
        [(address, -2048 if address & 1 else 2047)
         for address in range(13)],
    ]
    collector = cocotb.start_soon(collect_blocks(dut, len(descriptions), True))
    for block_id, events in enumerate(descriptions):
        await send_block(dut, block_id, 0, 7, events)
    observed, _ = await collector
    for events, actual in zip(descriptions, observed):
        assert actual[4] == model_block(dict(events), 7)


@cocotb.test()
async def excess_and_duplicate_coefficients_are_bounded(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    events = [(0, 19)] + [(address, address - 20) for address in range(1, 15)]
    events.insert(5, (3, 777))
    collector = cocotb.start_soon(collect_blocks(dut, 1))
    await send_block(dut, 9, 0, 2, events)
    observed, _ = await collector
    accepted = {0: 19}
    for address in range(1, 13):
        accepted[address] = address - 20
    assert observed[0][4] == model_block(accepted, 2)
    assert int(dut.limit_error.value) == 1
    assert int(dut.duplicate_error.value) == 1


@cocotb.test()
async def worst_case_stripe_fits_conservative_deadline(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block_count = 480
    collector = cocotb.start_soon(collect_blocks(dut, block_count))
    for block_id in range(block_count):
        events = [(0, (block_id & 31) - 16)]
        events += [(address, ((block_id + address) % 31) - 15)
                   for address in range(1, 13)]
        await send_block(dut, block_id, 0, 2, events)
    _, cycles = await collector
    await ClockCycles(dut.clk, 2)
    assert cycles <= 42927, f"stripe took {cycles} cycles"
    assert int(dut.completed_block_count.value) == block_count
