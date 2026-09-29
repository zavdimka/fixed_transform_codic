from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CTUS_PER_STRIPE = 80
STRIPES_PER_FRAME = 45


def pack_bytes(values: list[int]) -> int:
    packed = 0
    for index, value in enumerate(values):
        packed |= value << (8 * index)
    return packed


def make_rows(ctu_index: int, pattern: str) -> list[int]:
    rows: list[int] = []
    state = 0x720000 ^ (ctu_index * 0x9E3779B1)

    def sample(row: int, column: int, plane: int) -> int:
        nonlocal state
        if pattern == "checker":
            return 255 if ((row ^ column ^ ctu_index ^ plane) & 1) else 0
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        return (state >> 24) & 0xFF

    for row in range(16):
        rows.append(pack_bytes([sample(row, column, 0)
                                for column in range(16)]))
    for plane in (1, 2):
        for row in range(8):
            rows.append(pack_bytes([sample(row, column, plane)
                                    for column in range(8)]))
    return rows


async def reset(dut, quality24: bool) -> None:
    dut.rst_n.value = 0
    dut.configured_quality24.value = int(quality24)
    dut.stripe_valid.value = 0
    dut.stripe_frame_id.value = 0
    dut.stripe_index.value = 0
    dut.row_valid.value = 0
    dut.row_index.value = 0
    dut.row_data.value = 0
    dut.m_ready.value = 1
    dut.packet_commit_ready.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_stripe(dut, quality24: bool, pattern: str) -> dict[str, float | int]:
    await reset(dut, quality24)
    dut.stripe_frame_id.value = 0x1234
    dut.stripe_index.value = 17
    dut.stripe_valid.value = 1

    active_rows: list[int] = []
    active_row = 0
    started_ctus = 0
    output_bytes = 0
    stripe_taken = False
    measured_cycles = 0

    for _ in range(80000):
        await Timer(1, units="ns")
        take_fire = int(dut.stripe_valid.value) and int(dut.stripe_take.value)
        start_fire = int(dut.read_ctu_start.value)
        row_fire = int(dut.row_valid.value) and int(dut.row_ready.value)
        commit_fire = int(dut.packet_commit.value) and int(
            dut.packet_commit_ready.value
        )
        output_bytes += int(dut.m_valid.value) and int(dut.m_ready.value)

        await RisingEdge(dut.clk)

        if stripe_taken:
            measured_cycles += 1
        if take_fire:
            stripe_taken = True
            dut.stripe_valid.value = 0

        if row_fire:
            active_row += 1
            if active_row == len(active_rows):
                active_rows = []
                dut.row_valid.value = 0
            else:
                dut.row_index.value = active_row
                dut.row_data.value = active_rows[active_row]

        if start_fire:
            assert not active_rows
            assert int(dut.read_ctu.value) == started_ctus
            active_rows = make_rows(started_ctus, pattern)
            active_row = 0
            dut.row_valid.value = 1
            dut.row_index.value = 0
            dut.row_data.value = active_rows[0]
            started_ctus += 1

        if commit_fire:
            break
    else:
        raise AssertionError("camera codec pipeline did not commit the stripe")

    assert started_ctus == CTUS_PER_STRIPE
    assert not active_rows
    assert int(dut.packet_frame_id.value) == 0x1234
    assert int(dut.packet_stripe_index.value) == 17
    assert int(dut.packet_quality.value) == (24 if quality24 else 20)
    assert not int(dut.fatal_error.value)

    return {
        "quality": 24 if quality24 else 20,
        "cycles": measured_cycles,
        "fps_64mhz": 64_000_000 / (measured_cycles * STRIPES_PER_FRAME),
        "fps_66mhz": 66_000_000 / (measured_cycles * STRIPES_PER_FRAME),
        "output_bytes": output_bytes,
    }


@cocotb.test()
async def camera_scheduler_overlaps_frontend_and_entropy(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    results = [
        await run_stripe(dut, False, "checker"),
        await run_stripe(dut, True, "noise"),
    ]
    for result in results:
        cocotb.log.info(
            "CAMERA_PIPELINE_THROUGHPUT quality=%d cycles=%d "
            "fps_64mhz=%.3f fps_66mhz=%.3f output_bytes=%d",
            result["quality"],
            result["cycles"],
            result["fps_64mhz"],
            result["fps_66mhz"],
            result["output_bytes"],
        )

    assert max(int(result["cycles"]) for result in results) < 52000
