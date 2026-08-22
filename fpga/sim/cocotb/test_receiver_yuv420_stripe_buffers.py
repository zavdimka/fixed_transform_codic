from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge


async def reset_dut(dut) -> None:
    cocotb.start_soon(Clock(dut.write_clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.pixel_clk, 14, units="ns").start())
    dut.write_rst_n.value = 0
    dut.pixel_rst_n.value = 0
    dut.record_valid.value = 0
    dut.record_type.value = 0
    dut.display_frame_id.value = 0
    dut.stripe_id.value = 0
    dut.fragment_index.value = 0
    dut.fragment_count.value = 1
    dut.payload_length.value = 0
    dut.payload_data.value = 0
    dut.payload_valid.value = 0
    dut.payload_last.value = 0
    dut.x.value = 0
    dut.y.value = 730
    dut.data_enable.value = 0
    dut.hsync.value = 0
    dut.vsync.value = 0
    await ClockCycles(dut.write_clk, 4)
    dut.write_rst_n.value = 1
    dut.pixel_rst_n.value = 1
    await ClockCycles(dut.write_clk, 3)


async def send_record(
    dut,
    payload: bytes,
    *,
    frame: int,
    stripe: int,
    fragment_index: int,
    fragment_count: int,
) -> None:
    dut.record_type.value = 0x20
    dut.display_frame_id.value = frame
    dut.stripe_id.value = stripe
    dut.fragment_index.value = fragment_index
    dut.fragment_count.value = fragment_count
    dut.payload_length.value = len(payload)
    dut.record_valid.value = 1
    while True:
        await RisingEdge(dut.write_clk)
        if int(dut.record_ready.value):
            break
    await FallingEdge(dut.write_clk)
    dut.record_valid.value = 0

    for offset, value in enumerate(payload):
        dut.payload_data.value = value
        dut.payload_valid.value = 1
        dut.payload_last.value = int(offset == len(payload) - 1)
        await RisingEdge(dut.write_clk)
        await FallingEdge(dut.write_clk)
    dut.payload_valid.value = 0
    dut.payload_last.value = 0


async def send_stripe(
    dut, payload: bytes, *, frame: int, stripe: int
) -> None:
    assert len(payload) == 30_720
    fragments = [payload[offset : offset + 1004]
                 for offset in range(0, len(payload), 1004)]
    for index, fragment in enumerate(fragments):
        await send_record(
            dut,
            fragment,
            frame=frame,
            stripe=stripe,
            fragment_index=index,
            fragment_count=len(fragments),
        )


async def select_next_stripe(dut, *, previous_y: int, x: int, y: int) -> int:
    await FallingEdge(dut.pixel_clk)
    dut.data_enable.value = 0
    dut.x.value = 1290
    dut.y.value = previous_y
    await RisingEdge(dut.pixel_clk)

    await FallingEdge(dut.pixel_clk)
    dut.x.value = x
    dut.y.value = y
    dut.data_enable.value = 1
    for _ in range(4):
        await RisingEdge(dut.pixel_clk)
    await ReadOnly()
    result = int(dut.rgb.value)
    await FallingEdge(dut.pixel_clk)
    return result


@cocotb.test()
async def complete_stripes_swap_atomically_and_missing_is_gray(dut) -> None:
    await reset_dut(dut)

    # A continuation without a first fragment is drained and rejected. It
    # cannot reserve a bank or expose partial pixels.
    await send_record(
        dut,
        b"bad",
        frame=7,
        stripe=0,
        fragment_index=1,
        fragment_count=2,
    )
    assert int(dut.rejected_stripe_count.value) == 1

    red = bytes([82]) * 20_480 + bytes([90]) * 5_120 + bytes([240]) * 5_120
    await send_stripe(dut, red, frame=7, stripe=0)
    assert int(dut.completed_stripe_count.value) == 1
    await ClockCycles(dut.pixel_clk, 4)

    red_rgb = await select_next_stripe(dut, previous_y=749, x=0, y=0)
    assert red_rgb == 0xFF0100
    assert int(dut.data_enable_out.value) == 1

    blue = bytes([41]) * 20_480 + bytes([240]) * 5_120 + bytes([110]) * 5_120
    await send_stripe(dut, blue, frame=7, stripe=1)
    assert int(dut.completed_stripe_count.value) == 2
    await ClockCycles(dut.pixel_clk, 4)

    blue_rgb = await select_next_stripe(dut, previous_y=15, x=0, y=16)
    assert blue_rgb == 0x0000FF

    # No stripe 2 was published. The old bank is released after its final
    # active line and neutral gray replaces it without leaking stale pixels.
    gray_rgb = await select_next_stripe(dut, previous_y=31, x=0, y=32)
    assert gray_rgb == 0x808080
    assert int(dut.displayed_stripe_count.value) == 2
    assert int(dut.missing_stripe_count.value) == 1
