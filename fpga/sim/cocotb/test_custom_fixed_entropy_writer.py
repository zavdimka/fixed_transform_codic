from __future__ import annotations

from dataclasses import dataclass
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer
from custom_fixed_vlc import AC_ROM, VlcClass, encode_vlc_token
from custom_token_byte_packer import TokenBytePacker


@dataclass(frozen=True)
class Descriptor:
    layer: Layer
    mandatory: bool
    reserve_release: int
    table_class: VlcClass
    table_id: int
    symbol: int
    amplitude: int
    amplitude_length: int


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.s_valid.value = 0
    dut.s_layer.value = 0
    dut.s_mandatory.value = 0
    dut.s_reserve_release.value = 0
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


@cocotb.test()
async def descriptor_to_bounded_bytes_matches_python(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    limits = (128, 96)
    reserves = (8, 8)
    dut.base_limit_bits.value, dut.enhancement_limit_bits.value = limits
    dut.base_reserved_bits.value, dut.enhancement_reserved_bits.value = reserves
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0

    rng = random.Random(0xE17120)
    valid_ac = [
        (table_id, symbol)
        for table_id in (0, 1)
        for symbol in range(256)
        if AC_ROM[(table_id << 8) | symbol] and symbol != 0xF0
    ]
    descriptors: list[Descriptor] = []
    for _ in range(40):
        if rng.random() < 0.25:
            size = rng.randrange(0, 12)
            descriptors.append(Descriptor(
                Layer(rng.randrange(2)), False, 0, VlcClass.DC,
                rng.randrange(2), size, rng.getrandbits(size) if size else 0, size,
            ))
        else:
            table_id, symbol = rng.choice(valid_ac)
            size = symbol & 15
            descriptors.append(Descriptor(
                Layer(rng.randrange(2)), False, 0, VlcClass.AC,
                table_id, symbol, rng.getrandbits(size) if size else 0, size,
            ))
    descriptors.extend((
        Descriptor(Layer.BASE, True, 8, VlcClass.AC, 0, 0x00, 0, 0),
        Descriptor(Layer.ENHANCEMENT, True, 8, VlcClass.AC, 1, 0x00, 0, 0),
    ))

    guard = DualBudgetWriter(*limits, *reserves)
    expected_drops = 0
    for descriptor in descriptors:
        token = encode_vlc_token(
            descriptor.table_class, descriptor.table_id, descriptor.symbol,
            descriptor.amplitude, descriptor.amplitude_length,
        )
        admission = guard.submit(BudgetToken(
            descriptor.layer, token.bits, token.bit_length,
            descriptor.mandatory, descriptor.reserve_release,
        ))
        expected_drops += admission is Admission.DROPPED
    guard.finish()
    assert not guard.fatal

    packer = TokenBytePacker()
    for token in guard.accepted:
        packer.submit(token.layer, token.value, token.bit_length)
    packer.finish()
    expected_bytes = [(int(item.layer), item.value) for item in packer.output]

    source_index = 0
    source_active = False
    finish_active = False
    observed_bytes: list[tuple[int, int]] = []
    observed_drops = 0
    stalled = None
    drive_rng = random.Random(0xF17ED)

    for _ in range(50000):
        if not source_active and source_index < len(descriptors) and drive_rng.random() < 0.8:
            item = descriptors[source_index]
            dut.s_layer.value = int(item.layer)
            dut.s_mandatory.value = item.mandatory
            dut.s_reserve_release.value = item.reserve_release
            dut.s_table_class.value = int(item.table_class)
            dut.s_table_id.value = item.table_id
            dut.s_symbol.value = item.symbol
            dut.s_amplitude.value = item.amplitude
            dut.s_amplitude_length.value = item.amplitude_length
            dut.s_valid.value = 1
            source_active = True
        if source_index == len(descriptors) and not source_active and not finish_active:
            dut.finish_valid.value = 1
            finish_active = True

        dut.m_ready.value = int(drive_rng.random() < 0.6)
        await Timer(1, units="ns")
        current = None
        if int(dut.m_valid.value):
            current = (int(dut.m_layer.value), int(dut.m_byte.value))
        if stalled is not None:
            assert current == stalled
        source_fire = source_active and bool(int(dut.s_ready.value))
        finish_fire = finish_active and bool(int(dut.finish_ready.value))
        output_fire = current is not None and bool(int(dut.m_ready.value))
        stalled = current if current is not None and not output_fire else None
        if output_fire:
            observed_bytes.append(current)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.drop_pulse.value):
            observed_drops += 1
        if source_fire:
            source_index += 1
            source_active = False
            dut.s_valid.value = 0
        if finish_fire:
            finish_active = False
            dut.finish_valid.value = 0
        if int(dut.finish_done.value):
            break
    else:
        raise AssertionError("fixed entropy writer timed out")

    assert not int(dut.fatal_error.value)
    assert observed_drops == expected_drops
    assert observed_bytes == expected_bytes
    assert int(dut.base_used_bits.value) == guard.used[0]
    assert int(dut.enhancement_used_bits.value) == guard.used[1]
    assert int(dut.base_byte_count.value) == packer.byte_count[0]
    assert int(dut.enhancement_byte_count.value) == packer.byte_count[1]
    assert not int(dut.busy.value)

