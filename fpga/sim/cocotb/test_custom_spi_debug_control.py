from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def clocks(dut, count: int) -> None:
    for _ in range(count):
        await RisingEdge(dut.clk)


async def spi_transaction(dut, payload: bytes) -> bytes:
    received = bytearray()
    dut.spi_cs_n.value = 0
    await clocks(dut, 5)
    for output_byte in payload:
        input_byte = 0
        for shift in range(7, -1, -1):
            dut.spi_mosi.value = (output_byte >> shift) & 1
            await clocks(dut, 3)
            dut.spi_sck.value = 1
            await clocks(dut, 3)
            input_byte = (input_byte << 1) | int(dut.spi_miso.value)
            dut.spi_sck.value = 0
            await clocks(dut, 3)
        received.append(input_byte)
    dut.spi_cs_n.value = 1
    dut.spi_mosi.value = 0
    await clocks(dut, 6)
    return bytes(received)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.spi_cs_n.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.codec_busy.value = 0
    dut.codec_error.value = 0
    dut.coefficient_saturated.value = 0
    dut.packet_overflow.value = 0
    dut.packet_active.value = 0
    dut.packet_layer.value = 0
    dut.packet_byte_length.value = 0
    dut.packet_count.value = 0
    dut.quality24.value = 0
    dut.ctu_index.value = 0
    dut.capture_busy.value = 0
    dut.capture_done.value = 0
    dut.capture_error.value = 0
    dut.captured_lines.value = 0
    dut.last_line_bytes.value = 0
    dut.captured_words.value = 0
    dut.snapshot_read_valid.value = 0
    dut.snapshot_read_word.value = 0
    await clocks(dut, 6)
    dut.rst_n.value = 1
    await clocks(dut, 6)


@cocotb.test()
async def config_status_and_snapshot_word_are_accessible(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    await spi_transaction(dut, bytes([0x01, 0x40, 0x00, 0x02]))
    assert int(dut.gap_cycles.value) == 64
    assert int(dut.vsync_active_high.value) == 0
    assert int(dut.href_active_high.value) == 1

    dut.packet_count.value = 0x12345678
    dut.packet_byte_length.value = 1000
    dut.capture_done.value = 1
    status = await spi_transaction(dut, bytes([0x80]) + bytes(12))
    assert status[1:3] == bytes([0xC5, 0x01])
    assert status[3] & 0x04
    assert int.from_bytes(status[5:7], "little") == 64
    assert int.from_bytes(status[7:9], "little") == 1000
    assert int.from_bytes(status[9:13], "little") == 0x12345678

    await spi_transaction(dut, bytes([0x22, 0x34, 0x12]))
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.snapshot_read_request.value):
            break
    assert int(dut.snapshot_read_address.value) == 0x1234
    dut.snapshot_read_word.value = 0xA1B2C3D4E5
    dut.snapshot_read_valid.value = 1
    await RisingEdge(dut.clk)
    dut.snapshot_read_valid.value = 0
    await clocks(dut, 2)

    word = await spi_transaction(dut, bytes([0x82]) + bytes(6))
    assert word[1:6] == bytes.fromhex("e5d4c3b2a1")
    assert word[6] == 1


@cocotb.test()
async def arm_command_produces_single_cycle_pulse(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    seen = False

    async def monitor() -> None:
        nonlocal seen
        for _ in range(200):
            await RisingEdge(dut.clk)
            if int(dut.capture_arm.value):
                assert not seen
                seen = True

    monitor_task = cocotb.start_soon(monitor())
    await spi_transaction(dut, bytes([0x20]))
    await monitor_task
    assert seen

