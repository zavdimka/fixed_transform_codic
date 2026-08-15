import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


WIDTH = 32
HEIGHT = 32


def make_plane(width: int, height: int, seed: int) -> list[list[int]]:
    return [
        [((x * 17 + y * 29 + seed) ^ (x * y + seed * 3)) & 0xFF
         for x in range(width)]
        for y in range(height)
    ]


def expected_blocks(planes: list[list[list[int]]]) -> list[tuple[int, ...]]:
    result = []
    for plane_index, plane in enumerate(planes):
        block_size = 16 if plane_index == 0 else 8
        block_columns = len(plane[0]) // block_size
        block_rows = len(plane) // block_size
        for block_y in range(block_rows):
            for block_x in range(block_columns):
                for y in range(block_size):
                    for x in range(block_size):
                        block_last = x == block_size - 1 and y == block_size - 1
                        plane_last = (
                            block_last
                            and block_x == block_columns - 1
                            and block_y == block_rows - 1
                        )
                        result.append((
                            plane[block_y * block_size + y]
                                 [block_x * block_size + x],
                            plane_index,
                            block_x,
                            block_y,
                            x,
                            y,
                            int(block_last),
                            int(plane_last),
                            int(plane_last and plane_index == 2),
                        ))
    return result


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_sof.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def planar_frame_is_reordered_into_y_and_chroma_blocks(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    planes = [
        make_plane(WIDTH, HEIGHT, 11),
        make_plane(WIDTH // 2, HEIGHT // 2, 37),
        make_plane(WIDTH // 2, HEIGHT // 2, 73),
    ]
    source = [pixel for plane in planes for row in plane for pixel in row]
    expected = expected_blocks(planes)
    randomizer = random.Random(0x420)
    source_index = 0
    received = []
    stalled = None

    for _cycle in range(20000):
        drive_valid = source_index < len(source) and randomizer.random() < 0.82
        dut.s_valid.value = int(drive_valid)
        dut.s_data.value = source[source_index] if drive_valid else 0
        dut.s_sof.value = int(drive_valid and source_index == 0)
        dut.m_ready.value = int(randomizer.random() < 0.73)

        await RisingEdge(dut.clk)

        output = (
            int(dut.m_data.value),
            int(dut.m_plane.value),
            int(dut.m_block_x.value),
            int(dut.m_block_y.value),
            int(dut.m_x.value),
            int(dut.m_y.value),
            int(dut.m_block_last.value),
            int(dut.m_plane_last.value),
            int(dut.m_frame_last.value),
        )
        if stalled is not None:
            assert int(dut.m_valid.value)
            assert output == stalled

        output_fire = int(dut.m_valid.value) and int(dut.m_ready.value)
        stalled = output if int(dut.m_valid.value) and not int(dut.m_ready.value) else None
        if output_fire:
            received.append(output)

        if drive_valid and int(dut.s_ready.value):
            source_index += 1

        if len(received) == len(expected):
            assert source_index == len(source)
            assert received == expected
            assert int(dut.protocol_error.value) == 0
            assert int(dut.parameter_error.value) == 0
            assert sum(item[6] for item in received) == 12
            assert sum(item[7] for item in received) == 3
            assert sum(item[8] for item in received) == 1
            return

    raise AssertionError(
        f"timeout input={source_index}/{len(source)} "
        f"output={len(received)}/{len(expected)}"
    )
