from pathlib import Path
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


ROOT = Path(__file__).resolve().parents[3]


def first_enhancement_stripe():
    data = (ROOT / "esp32/fs/test/decoder_enhancement.rxt").read_bytes()
    record_count = struct.unpack_from("<H", data, 8)[0]
    offset = 16
    stripes = {}
    for _ in range(record_count):
        length = struct.unpack_from("<H", data, offset)[0]
        offset += 2
        record = data[offset:offset + length]
        offset += length
        if record[3] == 0x11:
            stripe_id = record[10]
            payload, _ = stripes.setdefault(stripe_id, (bytearray(), 0))
            payload_length = struct.unpack_from("<H", record, 16)[0]
            payload.extend(record[18:18 + payload_length])
            stripes[stripe_id] = (payload, record[14])
    assert stripes
    stripe_id = min(stripes)
    payload, final_flags = stripes[stripe_id]
    return stripe_id, bytes(payload), final_flags


@cocotb.test()
async def precomputed_multifragment_stripe_completes(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.record_valid.value = 0
    dut.display_frame_id.value = 1
    stripe_id, payload, flags = first_enhancement_stripe()
    dut.stripe_id.value = stripe_id
    dut.quality.value = 24
    dut.fragment_index.value = 0
    dut.fragment_count.value = 1
    dut.record_flags.value = 0
    dut.payload_length.value = 0
    dut.payload_data.value = 0
    dut.payload_valid.value = 0
    dut.payload_last.value = 0
    dut.event_ready.value = 1
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    dut.record_flags.value = flags
    dut.payload_length.value = len(payload)
    dut.record_valid.value = 1
    for _ in range(100):
        await RisingEdge(dut.clk)
        if int(dut.record_ready.value):
            break
    else:
        raise AssertionError("record header was not accepted")
    await FallingEdge(dut.clk)
    dut.record_valid.value = 0

    for offset, value in enumerate(payload):
        dut.payload_data.value = value
        dut.payload_valid.value = 1
        dut.payload_last.value = int(offset + 1 == len(payload))
        for _ in range(100_000):
            await RisingEdge(dut.clk)
            if int(dut.payload_ready.value):
                break
        else:
            raise AssertionError(
                f"payload stalled at {offset}/{len(payload)} state={int(dut.state.value)} "
                f"ctu={int(dut.event_ctu_index.value)} block={int(dut.event_block_index.value)} "
                f"byte_valid={int(dut.byte_valid.value)} bits={int(dut.bits_remaining.value)}"
            )
        await FallingEdge(dut.clk)
    dut.payload_valid.value = 0
    dut.payload_last.value = 0

    for _ in range(1_000_000):
        await RisingEdge(dut.clk)
        if int(dut.completed_stripe_count.value):
            break
    else:
        raise AssertionError(
            f"stripe did not complete state={int(dut.state.value)} "
            f"ctu={int(dut.event_ctu_index.value)} block={int(dut.event_block_index.value)} "
            f"byte_valid={int(dut.byte_valid.value)} bits={int(dut.bits_remaining.value)} "
            f"stream_end={int(dut.stream_end_seen.value)}"
        )

    assert int(dut.rejected_stripe_count.value) == 0
    assert int(dut.syntax_error_count.value) == 0
