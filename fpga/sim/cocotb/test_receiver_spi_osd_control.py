from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


async def clocks(dut, count: int) -> None:
    await ClockCycles(dut.clk, count)


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


@cocotb.test()
async def config_bulk_write_status_and_leds_work(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.spi_cs_n.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.pll2_lock.value = 1
    dut.osd_clear_busy.value = 0
    dut.osd_clear_done.value = 1
    dut.osd_write_ready.value = 1
    dut.hdmi_frame_count.value = 0x12345678
    dut.led_auto_on.value = 0b001101
    dut.link_fifo_level.value = 0x345
    dut.link_clock_enabled.value = 1
    dut.link_warning_level.value = 0
    dut.link_overflow_error.value = 0
    dut.link_framing_error.value = 0
    dut.link_byte_count.value = 0x89ABCDEF
    dut.link_transaction_count.value = 0x12345678
    dut.link_payload_xor.value = 0x5A
    dut.parser_busy.value = 1
    dut.parser_record_valid.value = 0
    dut.parser_payload_valid.value = 1
    dut.parser_record_type.value = 0x10
    dut.parser_stripe_id.value = 17
    dut.parser_payload_length.value = 0x0345
    dut.parser_payload_xor.value = 0xA6
    dut.parser_record_sequence.value = 0x5678
    dut.parser_accepted_count.value = 0x12345678
    dut.parser_rejected_count.value = 0x23456789
    dut.parser_crc_error_count.value = 0x3456789A
    dut.parser_length_error_count.value = 0x456789AB
    dut.parser_framing_error_count.value = 0x56789ABC
    dut.decoder_block_fifo_level.value = 2
    dut.decoder_transform_busy.value = 1
    dut.decoder_saturation_error.value = 1
    dut.decoder_residual_xor.value = 0xBEEF
    dut.decoder_completed_count.value = 0x6789ABCD
    dut.decoder_rejected_count.value = 0x789ABCDE
    dut.decoder_syntax_error_count.value = 0x89ABCDEF
    await clocks(dut, 5)
    dut.rst_n.value = 1
    await clocks(dut, 5)

    await spi_transaction(dut, bytes([0x01, 1, 0x12, 0x34, 0x56]))
    assert int(dut.osd_enable.value) == 1
    assert int(dut.osd_rgb.value) == 0x123456

    old_toggle = int(dut.test_pattern_toggle.value)
    await spi_transaction(dut, bytes([0x03, 3]))
    assert int(dut.test_pattern_mode.value) == 3
    assert int(dut.test_pattern_toggle.value) != old_toggle
    pattern = await spi_transaction(dut, bytes([0x82, 0]))
    assert pattern[1] == 3

    await spi_transaction(dut, bytes([0x10, 0x34, 0x02]))
    writes = []

    async def collect_write() -> None:
        for _ in range(800):
            await RisingEdge(dut.clk)
            if int(dut.osd_write_valid.value):
                writes.append((
                    int(dut.osd_write_address.value),
                    int(dut.osd_write_data.value),
                ))

    monitor = cocotb.start_soon(collect_write())
    await spi_transaction(dut, bytes([0x11, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
    await monitor
    assert writes == [
        (0x234, 0x0504030201),
        (0x235, 0x0A09080706),
    ]

    status = await spi_transaction(dut, bytes([0x80]) + bytes(9))
    assert status[1:3] == bytes([0xC5, 0x13])
    assert int.from_bytes(status[4:8], "little") == 0x12345678

    await spi_transaction(dut, bytes([0x02, 0x3F, 0x02]))
    assert int(dut.led_override_mask.value) == 0x3F
    assert int(dut.led_manual_on.value) == 0x02

    link_status = await spi_transaction(dut, bytes([0x90]) + bytes(12))
    assert int.from_bytes(link_status[1:3], "little") == 0x345
    assert link_status[3] == 0b100011
    assert int.from_bytes(link_status[4:8], "little") == 0x89ABCDEF
    assert int.from_bytes(link_status[8:12], "little") == 0x12345678
    assert link_status[12] == 0x5A

    parser_status = await spi_transaction(dut, bytes([0x91]) + bytes(8))
    assert parser_status[1] == 0b101
    assert parser_status[2:4] == bytes([0x10, 17])
    assert int.from_bytes(parser_status[4:6], "little") == 0x0345
    assert parser_status[6] == 0xA6
    assert int.from_bytes(parser_status[7:9], "little") == 0x5678

    parser_counts = await spi_transaction(dut, bytes([0x92]) + bytes(8))
    assert int.from_bytes(parser_counts[1:5], "little") == 0x12345678
    assert int.from_bytes(parser_counts[5:9], "little") == 0x23456789

    parser_errors = await spi_transaction(dut, bytes([0x93]) + bytes(12))
    assert int.from_bytes(parser_errors[1:5], "little") == 0x3456789A
    assert int.from_bytes(parser_errors[5:9], "little") == 0x456789AB
    assert int.from_bytes(parser_errors[9:13], "little") == 0x56789ABC

    decoder_status = await spi_transaction(dut, bytes([0x94]) + bytes(15))
    assert decoder_status[1] == 0b1110
    assert int.from_bytes(decoder_status[2:4], "little") == 0xBEEF
    assert int.from_bytes(decoder_status[4:8], "little") == 0x6789ABCD
    assert int.from_bytes(decoder_status[8:12], "little") == 0x789ABCDE
    assert int.from_bytes(decoder_status[12:16], "little") == 0x89ABCDEF

    await spi_transaction(dut, bytes([0x04, 0]))
    assert int(dut.link_drain_enable.value) == 0
    await spi_transaction(dut, bytes([0x04, 1]))
    assert int(dut.link_drain_enable.value) == 1
