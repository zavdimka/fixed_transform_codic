from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.record_valid.value = 0
    dut.display_frame_id.value = 0
    dut.stripe_id.value = 0
    dut.quality.value = 24
    dut.fragment_index.value = 0
    dut.fragment_count.value = 1
    dut.record_flags.value = 0
    dut.payload_length.value = 0
    dut.payload_data.value = 0
    dut.payload_valid.value = 0
    dut.payload_last.value = 0
    dut.request_valid.value = 0
    dut.request_frame_id.value = 0
    dut.request_stripe_id.value = 0
    dut.replay_record_ready.value = 0
    dut.replay_payload_ready.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def send_fragment(
    dut, payload, *, frame, stripe, quality, index, count, flags=0
):
    await FallingEdge(dut.clk)
    dut.display_frame_id.value = frame
    dut.stripe_id.value = stripe
    dut.quality.value = quality
    dut.fragment_index.value = index
    dut.fragment_count.value = count
    dut.record_flags.value = flags
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


async def request_replay(dut, *, frame, stripe):
    await FallingEdge(dut.clk)
    dut.request_frame_id.value = frame
    dut.request_stripe_id.value = stripe
    dut.request_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.request_ready.value):
            break
    await FallingEdge(dut.clk)
    dut.request_valid.value = 0


async def collect_replay(dut, rng):
    while not int(dut.replay_record_valid.value):
        await RisingEdge(dut.clk)
    assert int(dut.replay_frame_id.value) == 0x2345
    assert int(dut.replay_stripe_id.value) == 19
    assert int(dut.replay_quality.value) == 24
    assert int(dut.replay_record_flags.value) == 5
    assert int(dut.replay_payload_length.value) == 1400
    await FallingEdge(dut.clk)
    dut.replay_record_ready.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.replay_record_ready.value = 0

    result = bytearray()
    held = None
    for _ in range(20_000):
        dut.replay_payload_ready.value = int(rng.random() < 0.71)
        await RisingEdge(dut.clk)
        valid = int(dut.replay_payload_valid.value)
        current = None
        if valid:
            current = (
                int(dut.replay_payload_data.value),
                int(dut.replay_payload_last.value),
            )
        if held is not None and not int(dut.replay_payload_ready.value):
            assert current == held
        held = current if valid and not int(dut.replay_payload_ready.value) else None
        if valid and int(dut.replay_payload_ready.value):
            result.append(current[0])
            if current[1]:
                break
        await FallingEdge(dut.clk)
    dut.replay_payload_ready.value = 0
    return bytes(result)


@cocotb.test()
async def ordered_fragments_are_stored_and_replayed_from_synchronous_ram(dut):
    await reset_dut(dut)
    payload = bytes((index * 37 + 11) & 255 for index in range(1400))
    await send_fragment(
        dut, payload[:900], frame=0x2345, stripe=19, quality=24,
        index=0, count=2,
    )
    assert not int(dut.stored_valid.value)
    await send_fragment(
        dut, payload[900:], frame=0x2345, stripe=19, quality=24,
        index=1, count=2, flags=5,
    )
    assert int(dut.stored_valid.value)
    assert int(dut.stored_count.value) == 1

    # A request for another stripe is a non-blocking miss and leaves the
    # matching layer available for the base decoder.
    await request_replay(dut, frame=0x2345, stripe=18)
    await RisingEdge(dut.clk)
    assert int(dut.request_miss_count.value) == 1
    assert int(dut.stored_valid.value)

    collector = cocotb.start_soon(collect_replay(dut, random.Random(0x5110)))
    await request_replay(dut, frame=0x2345, stripe=19)
    observed = await collector
    await FallingEdge(dut.clk)
    assert observed == payload
    assert not int(dut.stored_valid.value)
    assert int(dut.replayed_count.value) == 1
    assert int(dut.rejected_count.value) == 0


@cocotb.test()
async def oversized_or_out_of_order_assembly_is_rejected_and_recovers(dut):
    await reset_dut(dut)
    first = bytes([0xA5]) * 1000
    second = bytes([0x5A]) * 600
    await send_fragment(
        dut, first, frame=7, stripe=3, quality=20, index=0, count=2
    )
    await send_fragment(
        dut, second, frame=7, stripe=3, quality=20, index=1, count=2
    )
    assert not int(dut.stored_valid.value)
    assert int(dut.rejected_count.value) == 1

    await send_fragment(
        dut, bytes([0x33]) * 12, frame=7, stripe=3, quality=20,
        index=1, count=2,
    )
    assert not int(dut.stored_valid.value)
    assert int(dut.rejected_count.value) == 2

    good = bytes(range(64))
    await send_fragment(
        dut, good, frame=8, stripe=4, quality=20, index=0, count=1,
        flags=7,
    )
    assert int(dut.stored_valid.value)
    assert int(dut.stored_frame_id.value) == 8
    assert int(dut.stored_stripe_id.value) == 4
    assert int(dut.stored_count.value) == 1
