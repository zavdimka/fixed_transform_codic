from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cabac import CabacByteEncoder

KIND_REGULAR = 0
KIND_BYPASS = 1
KIND_TERMINATE = 2


async def reset(dut):
    dut.rst_n.value = 0
    dut.cfg_valid.value = 0
    dut.start_valid.value = 0
    dut.s_valid.value = 0
    dut.s_kind.value = 0
    dut.s_bin.value = 0
    dut.s_context_address.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def configure_and_start(dut, contexts):
    for address, (state, mps) in enumerate(contexts):
        dut.cfg_valid.value = 1
        dut.cfg_context_address.value = address
        dut.cfg_state_index.value = state
        dut.cfg_mps.value = mps
        await Timer(1, units="ns")
        assert int(dut.cfg_ready.value)
        await RisingEdge(dut.clk)
    dut.cfg_valid.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0


def make_reference(contexts, commands):
    encoder = CabacByteEncoder(contexts)
    updates = []
    for kind, bin_value, address in commands:
        if kind == KIND_REGULAR:
            context = encoder.encode_regular(bin_value, address)
            updates.append((
                address, context.state_index, context.mps,
            ))
        elif kind == KIND_BYPASS:
            encoder.encode_bypass(bin_value)
        else:
            encoder.encode_terminate(bin_value)
    return encoder.bytes(), updates


async def run_commands(dut, commands, rng):
    command_index = 0
    presenting = False
    received = []
    updates = []
    last_flags = []
    stalled_output = None

    for _ in range(300000):
        if not presenting and command_index < len(commands):
            presenting = rng.random() < 0.78
        if presenting:
            kind, bin_value, address = commands[command_index]
            dut.s_valid.value = 1
            dut.s_kind.value = kind
            dut.s_bin.value = bin_value
            dut.s_context_address.value = address
        else:
            dut.s_valid.value = 0

        dut.m_ready.value = int(rng.random() < 0.63)
        await Timer(1, units="ns")

        output = (int(dut.m_byte.value), int(dut.m_last.value))
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert output_valid
            assert output == stalled_output
        stalled_output = (
            output if output_valid and not output_ready else None
        )
        if output_valid and output_ready:
            received.append(output[0])
            last_flags.append(output[1])

        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if input_fire:
            command_index += 1
            presenting = False
        if int(dut.context_update_valid.value):
            updates.append((
                int(dut.context_update_address.value),
                int(dut.context_update_state_index.value),
                int(dut.context_update_mps.value),
            ))
        assert not int(dut.protocol_error.value)

        if int(dut.slice_done.value):
            assert command_index == len(commands)
            return bytes(received), last_flags, updates
    raise AssertionError("CABAC encoder timed out")


async def run_continuous_commands(dut, commands):
    command_index = 0
    received = []
    updates = []
    last_flags = []
    fire_cycles = []

    for cycle in range(300000):
        if command_index < len(commands):
            kind, bin_value, address = commands[command_index]
            dut.s_valid.value = 1
            dut.s_kind.value = kind
            dut.s_bin.value = bin_value
            dut.s_context_address.value = address
        else:
            dut.s_valid.value = 0
        dut.m_ready.value = 1
        await Timer(1, units="ns")

        if int(dut.m_valid.value):
            received.append(int(dut.m_byte.value))
            last_flags.append(int(dut.m_last.value))
        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if input_fire:
            fire_cycles.append(cycle)
            command_index += 1
        if int(dut.context_update_valid.value):
            updates.append((
                int(dut.context_update_address.value),
                int(dut.context_update_state_index.value),
                int(dut.context_update_mps.value),
            ))
        assert not int(dut.protocol_error.value)
        if int(dut.slice_done.value):
            assert command_index == len(commands)
            return bytes(received), last_flags, updates, fire_cycles
    raise AssertionError("continuous CABAC encoder test timed out")


@cocotb.test()
async def random_context_bins_match_hm_byte_model_under_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x265CABAC)

    contexts = [
        (rng.randrange(64), rng.randrange(2)) for _ in range(256)
    ]
    commands = []
    for _ in range(900):
        if rng.random() < 0.42:
            commands.append((KIND_BYPASS, rng.randrange(2), 0))
        else:
            commands.append((
                KIND_REGULAR, rng.randrange(2), rng.randrange(96),
            ))
        if rng.random() < 0.015:
            commands.append((KIND_TERMINATE, 0, 0))
    commands.append((KIND_TERMINATE, 1, 0))

    expected_bytes, expected_updates = make_reference(contexts, commands)
    await configure_and_start(dut, contexts)
    received, last_flags, updates = await run_commands(dut, commands, rng)

    assert received == expected_bytes
    assert updates == expected_updates
    assert last_flags == [0] * (len(received) - 1) + [1]


@cocotb.test()
async def repeated_context_updates_cross_synchronous_context_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    contexts = [(0, 0)] * 256
    commands = [(KIND_REGULAR, 0, 23)] * 12
    commands.append((KIND_TERMINATE, 1, 0))
    expected_bytes, expected_updates = make_reference(contexts, commands)
    await configure_and_start(dut, contexts)
    received, last_flags, updates, fire_cycles = await run_continuous_commands(
        dut, commands)

    assert received == expected_bytes
    assert updates == expected_updates
    assert last_flags == [0] * (len(received) - 1) + [1]
    assert fire_cycles[:12] == [
        fire_cycles[0] + index for index in range(12)
    ]


@cocotb.test()
async def minimal_and_carry_heavy_slices_restart_cleanly(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xFF00)

    contexts = [(0, 0)] * 256
    await configure_and_start(dut, contexts)
    received, last_flags, _ = await run_commands(
        dut, [(KIND_TERMINATE, 1, 0)], rng
    )
    assert received == bytes.fromhex("fe80")
    assert last_flags == [0, 1]

    await configure_and_start(dut, contexts)
    commands = [(KIND_BYPASS, 1, 0)] * 256
    commands += [(KIND_BYPASS, 0, 0)] * 64
    commands.append((KIND_TERMINATE, 1, 0))
    expected, _ = make_reference(contexts, commands)
    received, last_flags, _ = await run_commands(dut, commands, rng)
    assert received == expected
    assert last_flags[-1] == 1
