from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def expected_references(ctu_x, top_available, top_line, left_edge, corner):
    raw = []
    available = []
    for offset in reversed(range(18)):
        valid = ctu_x != 0 and offset < 16
        raw.append(left_edge[offset] if valid else 0)
        available.append(valid)
    valid = top_available and ctu_x != 0
    raw.append(corner if valid else 0)
    available.append(valid)
    for offset in range(18):
        valid = top_available and ctu_x * 16 + offset < len(top_line)
        raw.append(top_line[ctu_x * 16 + offset] if valid else 0)
        available.append(valid)

    current = next((sample for sample, valid in zip(raw, available) if valid), 128)
    filled = []
    for sample, valid in zip(raw, available):
        if valid:
            current = sample
        filled.append(current)
    return [filled[18]] + filled[19:37], [filled[18]] + list(reversed(filled[:18]))


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.m_ready.value = 0
    dut.recon_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def raster_ctu_edges_match_reference(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1EAF16)
    top_line = [0] * 32
    left_edge = [0] * 16
    corner = 128

    for ctu_y in range(2):
        for ctu_x in range(2):
            expected_top, expected_left = expected_references(
                ctu_x, ctu_y != 0, top_line, left_edge, corner
            )
            dut.ctu_x.value = ctu_x
            dut.top_available.value = int(ctu_y != 0)
            dut.start_valid.value = 1
            while True:
                await Timer(1, units="ns")
                if int(dut.start_ready.value):
                    await RisingEdge(dut.clk)
                    break
                await RisingEdge(dut.clk)
            dut.start_valid.value = 0

            references = []
            for _ in range(500):
                dut.m_ready.value = int(rng.random() < 0.73)
                await Timer(1, units="ns")
                fire = int(dut.m_valid.value) and int(dut.m_ready.value)
                beat = (int(dut.m_ref_top.value), int(dut.m_ref_left.value), bool(dut.m_ref_last.value))
                await RisingEdge(dut.clk)
                if fire:
                    references.append(beat)
                if len(references) == 19:
                    break
            assert [v[0] for v in references] == expected_top
            assert [v[1] for v in references] == expected_left
            assert [v[2] for v in references] == [False] * 18 + [True]

            pixels = [
                (ctu_y * 97 + ctu_x * 61 + y * 11 + x * 5) & 255
                for y in range(16) for x in range(16)
            ]
            old_top = list(top_line)
            for address, pixel in enumerate(pixels):
                y, x = divmod(address, 16)
                dut.recon_valid.value = 1
                dut.recon_pixel.value = pixel
                dut.recon_x.value = x
                dut.recon_y.value = y
                dut.recon_block_last.value = int(address == 255)
                await RisingEdge(dut.clk)
            dut.recon_valid.value = 0
            dut.recon_block_last.value = 0
            await Timer(1, units="ns")

            top_line[ctu_x * 16:(ctu_x + 1) * 16] = pixels[-16:]
            left_edge = [pixels[y * 16 + 15] for y in range(16)]
            corner = old_top[ctu_x * 16 + 15]
            assert int(dut.block_committed.value)
            assert not int(dut.protocol_error.value)
            assert not int(dut.parameter_error.value)
