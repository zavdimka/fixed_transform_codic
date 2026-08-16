from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Event, RisingEdge, with_timeout

from hevc_reference.quant import QUALITY_QPS
from test_hevc_yuv_pixel_ctu16_idr_nal import (
    chroma_expected,
    expected_nal,
    luma_expected,
)


CMD_CONFIG = 0x01
CMD_START_SLICE = 0x02
CMD_LOAD_CTU = 0x10
CMD_RUN_CTU = 0x11
CMD_READ_STATUS = 0x80
CMD_READ_SIGNATURES = 0x81


def crc16_ccitt(payload: bytes) -> int:
    crc = 0xFFFF
    for value in payload:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 \
                else (crc << 1) & 0xFFFF
    return crc


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


async def capture_nibbles(dut, received: list[int], finished: Event) -> None:
    while True:
        await RisingEdge(dut.clk)
        if int(dut.nibble_valid.value) and int(dut.nibble_ready.value):
            received.append(int(dut.nibble_data.value))
            if int(dut.nibble_last.value):
                finished.set()


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.spi_cs_n.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.nibble_ready.value = 1
    await clocks(dut, 6)
    dut.rst_n.value = 1
    await clocks(dut, 6)


@cocotb.test()
async def spi_loaded_ctu_produces_byte_exact_nibbled_nal(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    qp = QUALITY_QPS["medium"]
    y_source = [[(23 + x * 9 + y * 5 + ((x * y) & 31)) & 255
                 for x in range(16)] for y in range(16)]
    cb_source = [[(51 + x * 17 + y * 11) & 255 for x in range(8)]
                 for y in range(8)]
    cr_source = [[128] * 8 for _ in range(8)]
    mode_dc, y_coeff, _ = luma_expected(y_source, qp)
    cb_coeff, _ = chroma_expected(cb_source, qp, 1)
    cr_coeff, _ = chroma_expected(cr_source, qp, 2)
    expected = expected_nal(qp, mode_dc, y_coeff, cb_coeff, cr_coeff)
    ctu = bytes(value for row in y_source for value in row)
    ctu += bytes(value for row in cb_source for value in row)
    ctu += bytes(value for row in cr_source for value in row)
    assert len(ctu) == 384
    crc = crc16_ccitt(ctu)

    nibbles: list[int] = []
    nal_finished = Event()
    cocotb.start_soon(capture_nibbles(dut, nibbles, nal_finished))

    await spi_transaction(dut, bytes([CMD_CONFIG, 0, qp, 1]))
    await spi_transaction(dut, bytes([CMD_START_SLICE]))
    await spi_transaction(
        dut, bytes([CMD_LOAD_CTU]) + ctu + crc.to_bytes(2, "big"))

    status_response = await spi_transaction(
        dut, bytes([CMD_READ_STATUS]) + bytes(7))
    assert status_response[1] & 0x01
    assert not int(dut.debug_error.value)

    await spi_transaction(dut, bytes([CMD_RUN_CTU]))
    await with_timeout(nal_finished.wait(), 2, "ms")
    await clocks(dut, 20)

    assert len(nibbles) % 2 == 0
    received = bytes((nibbles[index] << 4) | nibbles[index + 1]
                     for index in range(0, len(nibbles), 2))
    assert received == expected
    assert int(dut.nal_byte_count.value) == len(expected)
    assert int(dut.current_ctu_x.value) == 0
    assert int(dut.current_ctu_y.value) == 0
    assert not int(dut.debug_error.value)

    signatures = await spi_transaction(
        dut, bytes([CMD_READ_SIGNATURES]) + bytes(16))
    reported_size = int.from_bytes(signatures[1:5], "little")
    assert reported_size == len(expected)
    assert int.from_bytes(signatures[5:7], "big") == crc
    assert int.from_bytes(signatures[13:15], "little") == 256
    assert int.from_bytes(signatures[15:17], "little") == 128


@cocotb.test()
async def bad_ctu_crc_is_rejected_without_starting_codec(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    payload = bytes([128] * 384)
    await spi_transaction(
        dut, bytes([CMD_LOAD_CTU]) + payload + bytes.fromhex("0000"))
    status_response = await spi_transaction(
        dut, bytes([CMD_READ_STATUS]) + bytes(7))

    assert not (status_response[1] & 0x01)
    assert status_response[1] & 0x80
    assert status_response[7] & 0x04
    assert int(dut.debug_error.value)
