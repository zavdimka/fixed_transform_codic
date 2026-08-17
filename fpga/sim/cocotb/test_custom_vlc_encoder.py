from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_fixed_vlc import AC_ROM, DC_ROM, VlcClass, encode_vlc_token


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.clear_error.value = 0
    dut.s_valid.value = 0
    dut.s_table_class.value = 0
    dut.s_table_id.value = 0
    dut.s_symbol.value = 0
    dut.s_amplitude.value = 0
    dut.s_amplitude_length.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def encode_one(
    dut,
    table_class: VlcClass,
    table_id: int,
    symbol: int,
    amplitude: int,
    amplitude_length: int,
    rng: random.Random,
) -> tuple[int, int]:
    dut.s_table_class.value = int(table_class)
    dut.s_table_id.value = table_id
    dut.s_symbol.value = symbol
    dut.s_amplitude.value = amplitude
    dut.s_amplitude_length.value = amplitude_length
    dut.s_valid.value = 1
    await Timer(1, units="ns")
    while not int(dut.s_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.s_valid.value = 0

    stalled = None
    for _ in range(100):
        dut.m_ready.value = int(rng.random() < 0.65)
        await Timer(1, units="ns")
        current = None
        if int(dut.m_valid.value):
            current = (int(dut.m_bits.value), int(dut.m_length.value))
        if stalled is not None:
            assert current == stalled
        fire = current is not None and bool(int(dut.m_ready.value))
        stalled = current if current is not None and not fire else None
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if fire:
            return current
    raise AssertionError("VLC encoder timed out")


@cocotb.test()
async def every_valid_rom_entry_matches_python(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x564C43)

    masked_expected = encode_vlc_token(VlcClass.DC, 0, 2, 0x7FF, 2)
    masked_actual = await encode_one(dut, VlcClass.DC, 0, 2, 0x7FF, 2, rng)
    assert masked_actual == (masked_expected.bits, masked_expected.bit_length)

    tested = 0
    for table_class, rom, symbol_count, address_shift in (
        (VlcClass.DC, DC_ROM, 16, 4),
        (VlcClass.AC, AC_ROM, 256, 8),
    ):
        for table_id in (0, 1):
            for symbol in range(symbol_count):
                if not rom[(table_id << address_shift) | symbol]:
                    continue
                size = symbol if table_class is VlcClass.DC else symbol & 15
                if table_class is VlcClass.AC and symbol == 0xF0:
                    size = 0
                amplitude = rng.getrandbits(size) if size else 0
                expected = encode_vlc_token(
                    table_class, table_id, symbol, amplitude, size
                )
                actual = await encode_one(
                    dut, table_class, table_id, symbol, amplitude, size, rng
                )
                assert actual == (expected.bits, expected.bit_length)
                assert not int(dut.input_error.value)
                tested += 1
    assert tested == 348


@cocotb.test()
async def invalid_semantics_set_and_clear_sticky_error(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    dut.s_table_class.value = int(VlcClass.AC)
    dut.s_table_id.value = 0
    dut.s_symbol.value = 0x00
    dut.s_amplitude.value = 1
    dut.s_amplitude_length.value = 1
    dut.s_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.s_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.s_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
    assert int(dut.input_error.value)
    assert not int(dut.m_valid.value)

    dut.clear_error.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.clear_error.value = 0
    assert not int(dut.input_error.value)
