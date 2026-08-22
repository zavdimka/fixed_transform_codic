from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def make_record(
    payload: bytes,
    *,
    record_type: int = 0x10,
    sequence: int = 0x1234,
    display_frame: int = 0x4567,
    source_frame: int = 0x89AB,
    stripe: int = 17,
    quality: int = 24,
    fragment_index: int = 1,
    fragment_count: int = 3,
    flags: int = 0x05,
) -> bytes:
    header = bytes([0xC5, 0x3A, 0x01, record_type])
    header += struct.pack("<HHH", sequence, display_frame, source_frame)
    header += bytes([
        stripe, quality, fragment_index, fragment_count, flags, 0,
    ])
    header += struct.pack("<H", len(payload))
    assert len(header) == 18
    body = header + payload
    return body + struct.pack("<H", crc16_ccitt(body))


async def reset_dut(dut) -> None:
    dut.rst_n.value = 0
    dut.entry.value = 0
    dut.entry_valid.value = 0
    dut.record_ready.value = 0
    dut.payload_ready.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def push_entry(dut, value: int) -> None:
    while not int(dut.entry_ready.value):
        await RisingEdge(dut.clk)
    dut.entry.value = value
    dut.entry_valid.value = 1
    await RisingEdge(dut.clk)
    dut.entry_valid.value = 0


async def push_transaction(dut, transaction: bytes) -> None:
    for index, value in enumerate(transaction):
        tag = 0x100 if index == 0 else 0
        await push_entry(dut, tag | value)
    await push_entry(dut, 0x200)


async def receive_payload(dut, expected_length: int) -> bytes:
    result = bytearray()
    dut.payload_ready.value = 1
    while len(result) < expected_length:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.payload_valid.value):
            result.append(int(dut.payload_data.value))
            assert int(dut.payload_last.value) == (len(result) == expected_length)
    await Timer(1, units="ns")
    dut.payload_ready.value = 0
    return bytes(result)


@cocotb.test()
async def valid_record_is_released_only_after_crc(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    payload = bytes([0x00, 0x11, 0xFE, 0x7A, 0x55])
    transaction = make_record(payload)

    for index, value in enumerate(transaction[:-1]):
        await push_entry(dut, (0x100 if index == 0 else 0) | value)
        assert int(dut.record_valid.value) == 0
        assert int(dut.payload_valid.value) == 0
    await push_entry(dut, transaction[-1])
    assert int(dut.record_valid.value) == 0
    await push_entry(dut, 0x200)
    await ReadOnly()

    assert int(dut.record_valid.value) == 1
    assert int(dut.record_type.value) == 0x10
    assert int(dut.record_sequence.value) == 0x1234
    assert int(dut.display_frame_id.value) == 0x4567
    assert int(dut.source_frame_id.value) == 0x89AB
    assert int(dut.stripe_id.value) == 17
    assert int(dut.quality.value) == 24
    assert int(dut.fragment_index.value) == 1
    assert int(dut.fragment_count.value) == 3
    assert int(dut.record_flags.value) == 0x05
    assert int(dut.payload_length.value) == len(payload)

    await Timer(1, units="ns")
    dut.record_ready.value = 1
    await RisingEdge(dut.clk)
    dut.record_ready.value = 0
    assert await receive_payload(dut, len(payload)) == payload
    assert int(dut.accepted_count.value) == 1
    assert int(dut.rejected_count.value) == 0


@cocotb.test()
async def bad_crc_and_bad_length_are_atomic_and_parser_recovers(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    corrupt = bytearray(make_record(b"do not release"))
    corrupt[-1] ^= 0x80
    await push_transaction(dut, bytes(corrupt))
    await ClockCycles(dut.clk, 3)
    assert int(dut.record_valid.value) == 0
    assert int(dut.payload_valid.value) == 0
    assert int(dut.crc_error_count.value) == 1

    truncated = make_record(b"short")[:-3]
    await push_transaction(dut, truncated)
    await ClockCycles(dut.clk, 3)
    assert int(dut.record_valid.value) == 0
    assert int(dut.payload_valid.value) == 0
    assert int(dut.length_error_count.value) == 1

    payload = b"recovered"
    await push_transaction(dut, make_record(payload, sequence=9, fragment_index=0, fragment_count=1))
    await ReadOnly()
    assert int(dut.record_valid.value) == 1
    await Timer(1, units="ns")
    dut.record_ready.value = 1
    await RisingEdge(dut.clk)
    dut.record_ready.value = 0
    assert await receive_payload(dut, len(payload)) == payload
    assert int(dut.accepted_count.value) == 1
    assert int(dut.rejected_count.value) == 2


@cocotb.test()
async def maximum_1024_byte_transaction_is_accepted(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    payload = bytes((index * 73 + 11) & 0xFF for index in range(1004))
    transaction = make_record(
        payload, record_type=0x20, fragment_index=0, fragment_count=1
    )
    assert len(transaction) == 1024
    await push_transaction(dut, transaction)
    await ReadOnly()
    assert int(dut.record_valid.value) == 1
    assert int(dut.record_type.value) == 0x20
    await Timer(1, units="ns")
    dut.record_ready.value = 1
    await RisingEdge(dut.clk)
    dut.record_ready.value = 0
    assert await receive_payload(dut, len(payload)) == payload
    assert int(dut.accepted_count.value) == 1
    assert int(dut.length_error_count.value) == 0
