from __future__ import annotations

import random
import sys
import types

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

if "PIL" not in sys.modules:
    pil_stub = types.ModuleType("PIL")
    pil_stub.Image = types.SimpleNamespace(Image=object)
    pil_stub.ImageDraw = types.SimpleNamespace()
    pil_stub.ImageFont = types.SimpleNamespace()
    sys.modules["PIL"] = pil_stub

import jpeg_radio_codec as core


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.stripe_start.value = 0
    dut.stripe_enhancement_available.value = 0
    dut.base_valid.value = 0
    dut.base_ctu_index.value = 0
    dut.base_block_index.value = 0
    dut.base_plane.value = 0
    dut.base_mode.value = 0
    dut.base_quality.value = 24
    dut.base_frame_id.value = 0
    dut.base_stripe_id.value = 0
    dut.base_coefficients.value = 0
    dut.enhancement_event_valid.value = 0
    dut.enhancement_event_kind.value = 0
    dut.enhancement_event_ctu_index.value = 0
    dut.enhancement_event_block_index.value = 0
    dut.enhancement_event_plane.value = 0
    dut.enhancement_event_scan_index.value = 0
    dut.enhancement_event_coefficient.value = 0
    dut.enhancement_event_quality.value = 24
    dut.enhancement_event_frame_id.value = 0
    dut.enhancement_event_stripe_id.value = 0
    dut.command_ready.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def start_stripe(dut, available):
    await FallingEdge(dut.clk)
    dut.stripe_enhancement_available.value = available
    dut.stripe_start.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.stripe_start.value = 0


async def send_event(dut, kind, *, ctu, block, plane, scan=0, value=0):
    dut.enhancement_event_kind.value = kind
    dut.enhancement_event_ctu_index.value = ctu
    dut.enhancement_event_block_index.value = block
    dut.enhancement_event_plane.value = plane
    dut.enhancement_event_scan_index.value = scan
    dut.enhancement_event_coefficient.value = value
    dut.enhancement_event_quality.value = 24
    dut.enhancement_event_frame_id.value = 0x1234
    dut.enhancement_event_stripe_id.value = 9
    dut.enhancement_event_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.enhancement_event_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.enhancement_event_valid.value = 0


async def send_base(dut, values, *, ctu, block, plane):
    packed = sum((value & 0xFFF) << (12 * index)
                 for index, value in enumerate(values))
    dut.base_ctu_index.value = ctu
    dut.base_block_index.value = block
    dut.base_plane.value = plane
    dut.base_mode.value = 2
    dut.base_quality.value = 24
    dut.base_frame_id.value = 0x1234
    dut.base_stripe_id.value = 9
    dut.base_coefficients.value = packed
    dut.base_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.base_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.base_valid.value = 0


def unpack_physical(value):
    return [((value >> (12 * index)) & 0xFFF) for index in range(64)]


@cocotb.test()
async def matching_layers_form_one_physical_coefficient_matrix(dut):
    await reset_dut(dut)
    await start_stripe(dut, 1)
    for args in (
        (0, 3, 2, 0, 0),
        (1, 3, 2, 6, -17),
        (1, 3, 2, 11, 29),
        (1, 3, 2, 63, -5),
        (2, 3, 2, 0, 0),
    ):
        await send_event(
            dut, args[0], ctu=args[1], block=args[2], plane=0,
            scan=args[3], value=args[4],
        )

    base = [120, -31, 22, 7, -9, 4]
    await send_base(dut, base, ctu=3, block=2, plane=0)
    rng = random.Random(0xC08B)
    while not int(dut.command_valid.value):
        await RisingEdge(dut.clk)
    for _ in range(7):
        dut.command_ready.value = int(rng.random() < 0.35)
        await RisingEdge(dut.clk)
        if int(dut.command_valid.value) and int(dut.command_ready.value):
            break
        await FallingEdge(dut.clk)
    else:
        dut.command_ready.value = 1
        await RisingEdge(dut.clk)

    physical = unpack_physical(int(dut.command_coefficients.value))
    expected = [0] * 64
    for scan, value in enumerate(base):
        row, column = core.ZIGZAG[scan]
        expected[row * 8 + column] = value & 0xFFF
    for scan, value in ((6, -17), (11, 29), (63, -5)):
        row, column = core.ZIGZAG[scan]
        expected[row * 8 + column] = value & 0xFFF
    assert physical == expected
    assert int(dut.command_enhanced.value)
    assert int(dut.command_ctu_index.value) == 3
    assert int(dut.command_block_index.value) == 2
    await FallingEdge(dut.clk)
    assert int(dut.enhanced_block_count.value) == 1
    assert not int(dut.alignment_error.value)


@cocotb.test()
async def missing_layer_falls_back_and_stalled_layer_times_out(dut):
    await reset_dut(dut)
    dut.command_ready.value = 1
    base = [50, -2, 3, 0, 0, 0]

    await start_stripe(dut, 0)
    await send_base(dut, base, ctu=0, block=0, plane=0)
    while not int(dut.command_valid.value):
        await RisingEdge(dut.clk)
    assert not int(dut.command_enhanced.value)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.fallback_block_count.value) == 1

    await start_stripe(dut, 1)
    await send_base(dut, base, ctu=1, block=0, plane=0)
    for _ in range(4200):
        await RisingEdge(dut.clk)
        if int(dut.command_valid.value):
            break
        await FallingEdge(dut.clk)
    else:
        raise AssertionError("enhancement watchdog did not release base block")
    assert not int(dut.command_enhanced.value)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.late_stripe_count.value) == 1
    assert int(dut.fallback_block_count.value) == 2
