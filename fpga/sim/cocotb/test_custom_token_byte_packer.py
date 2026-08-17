from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_budget_writer import Layer
from custom_token_byte_packer import TokenBytePacker, left_align_token


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.s_valid.value = 0
    dut.s_layer.value = 0
    dut.s_bits.value = 0
    dut.s_length.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start(dut) -> None:
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0


async def run_stream(
    dut,
    tokens: list[tuple[Layer, int, int]],
    seed: int,
) -> tuple[list[tuple[int, int]], tuple[int, int]]:
    rng = random.Random(seed)
    source_index = 0
    source_active = False
    finish_active = False
    observed: list[tuple[int, int]] = []
    stalled_output: tuple[int, int] | None = None

    for _ in range(20000):
        if not source_active and source_index < len(tokens) and rng.random() < 0.8:
            layer, bits, length = tokens[source_index]
            dut.s_layer.value = int(layer)
            dut.s_bits.value = bits
            dut.s_length.value = length
            dut.s_valid.value = 1
            source_active = True

        if source_index == len(tokens) and not source_active and not finish_active:
            dut.finish_valid.value = 1
            finish_active = True

        dut.m_ready.value = int(rng.random() < 0.65)
        await Timer(1, units="ns")

        current_output = None
        if int(dut.m_valid.value):
            current_output = (int(dut.m_layer.value), int(dut.m_byte.value))
        if stalled_output is not None:
            assert current_output == stalled_output

        source_fire = source_active and bool(int(dut.s_ready.value))
        finish_fire = finish_active and bool(int(dut.finish_ready.value))
        output_fire = current_output is not None and bool(int(dut.m_ready.value))
        stalled_output = current_output if current_output is not None and not output_fire else None
        if output_fire:
            observed.append(current_output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if source_fire:
            source_index += 1
            source_active = False
            dut.s_valid.value = 0
        if finish_fire:
            finish_active = False
            dut.finish_valid.value = 0
        if int(dut.finish_done.value):
            assert source_index == len(tokens)
            assert not int(dut.busy.value)
            return observed, (
                int(dut.base_byte_count.value),
                int(dut.enhancement_byte_count.value),
            )

    raise AssertionError("token byte packer timed out")


@cocotb.test()
async def directed_interleaved_layers_and_flush(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await start(dut)

    tokens = [
        (Layer.BASE, left_align_token(0b101, 3), 3),
        (Layer.ENHANCEMENT, left_align_token(0x3, 2), 2),
        (Layer.BASE, left_align_token(0x1AB, 9), 9),
        (Layer.ENHANCEMENT, left_align_token(0x2A, 6), 6),
    ]
    model = TokenBytePacker()
    for token in tokens:
        model.submit(*token)
    model.finish()

    observed, counts = await run_stream(dut, tokens, 0xD1EC7ED)
    assert observed == [(int(item.layer), item.value) for item in model.output]
    assert counts == tuple(model.byte_count)


@cocotb.test()
async def randomized_tokens_match_python_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await start(dut)

    rng = random.Random(0x5041434B)
    tokens = []
    model = TokenBytePacker()
    for _ in range(180):
        layer = Layer(rng.randrange(2))
        length = rng.randrange(1, 33)
        bits = left_align_token(rng.getrandbits(length), length)
        token = (layer, bits, length)
        tokens.append(token)
        model.submit(*token)
    model.finish()

    observed, counts = await run_stream(dut, tokens, 0xBACC0FFE)
    assert observed == [(int(item.layer), item.value) for item in model.output]
    assert counts == tuple(model.byte_count)


@cocotb.test()
async def zero_length_token_sets_sticky_error(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await start(dut)

    dut.s_valid.value = 1
    dut.s_length.value = 0
    await Timer(1, units="ns")
    assert int(dut.s_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.s_valid.value = 0
    assert int(dut.input_error.value)

    observed, counts = await run_stream(dut, [], 123)
    assert observed == []
    assert counts == (0, 0)
    assert int(dut.input_error.value)

