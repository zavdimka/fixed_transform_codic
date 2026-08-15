from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def z_to_xy(cu_index: int) -> tuple[int, int]:
    return (((cu_index >> 2) & 1) << 1 | (cu_index & 1),
            ((cu_index >> 3) & 1) << 1 | ((cu_index >> 1) & 1))


def substitute_references(
    ctu_x: int,
    cu_index: int,
    completed: set[int],
    bottom: dict[int, list[int]],
    right: dict[int, list[int]],
    previous_right: list[int],
) -> tuple[list[int], list[int]]:
    bx, by = z_to_xy(cu_index)
    raw: list[int] = []
    available: list[bool] = []

    for offset in reversed(range(18)):
        sample_by = by + offset // 16
        local_y = offset & 15
        if bx == 0:
            valid = ctu_x != 0 and sample_by < 4
            raw.append(previous_right[sample_by * 16 + local_y] if valid else 0)
        else:
            neighbour = sample_by * 4 + bx - 1
            valid = sample_by < 4 and neighbour in completed
            raw.append(right[neighbour][local_y] if valid else 0)
        available.append(valid)

    if by == 0:
        raw.append(0)
        available.append(False)
    elif bx == 0:
        valid = ctu_x != 0
        raw.append(previous_right[by * 16 - 1] if valid else 0)
        available.append(valid)
    else:
        neighbour = (by - 1) * 4 + bx - 1
        valid = neighbour in completed
        raw.append(bottom[neighbour][15] if valid else 0)
        available.append(valid)

    for offset in range(18):
        sample_bx = bx + offset // 16
        local_x = offset & 15
        neighbour = (by - 1) * 4 + sample_bx
        valid = by != 0 and sample_bx < 4 and neighbour in completed
        raw.append(bottom[neighbour][local_x] if valid else 0)
        available.append(valid)

    first = next((sample for sample, valid in zip(raw, available) if valid), 128)
    filled = []
    current = first
    for sample, valid in zip(raw, available):
        if valid:
            current = sample
        filled.append(current)

    top = [filled[18]] + filled[19:37]
    left = [filled[18]] + list(reversed(filled[0:18]))
    return top, left


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.m_ready.value = 0
    dut.recon_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def z_order_edges_and_left_ctu_boundary_match_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1EAF_265)

    completed: set[int] = set()
    bottom: dict[int, list[int]] = {}
    right: dict[int, list[int]] = {}
    previous_right = [128] * 64

    for ctu_x, indices in ((0, range(16)), (1, range(1))):
        if ctu_x == 1:
            completed.clear()
            bottom.clear()
            right.clear()
        for cu_index in indices:
            bx, by = z_to_xy(cu_index)
            expected_top, expected_left = substitute_references(
                ctu_x, cu_index, completed, bottom, right, previous_right
            )

            dut.ctu_x.value = ctu_x
            dut.cu_index.value = cu_index
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
                beat = (
                    int(dut.m_ref_top.value),
                    int(dut.m_ref_left.value),
                    bool(dut.m_ref_last.value),
                )
                await RisingEdge(dut.clk)
                if fire:
                    references.append(beat)
                if len(references) == 19:
                    break
            else:
                raise AssertionError("reference output timed out")

            assert [item[0] for item in references] == expected_top
            assert [item[1] for item in references] == expected_left
            assert [item[2] for item in references] == [False] * 18 + [True]

            pixels = [
                (ctu_x * 61 + bx * 37 + by * 23 + y * 11 + x * 5) & 255
                for y in range(16)
                for x in range(16)
            ]
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

            raster = by * 4 + bx
            bottom[raster] = pixels[15 * 16:16 * 16]
            right[raster] = [pixels[y * 16 + 15] for y in range(16)]
            completed.add(raster)
            if bx == 3:
                for y in range(16):
                    previous_right[by * 16 + y] = right[raster][y]

            assert int(dut.block_committed.value)
            assert not int(dut.protocol_error.value)
            assert not int(dut.busy.value)
