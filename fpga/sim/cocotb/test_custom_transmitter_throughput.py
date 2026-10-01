from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from test_custom_intra_residual_frontend import pack_bytes


CTUS_PER_STRIPE = 80
STRIPES_PER_FRAME = 45
BASE_LIMIT_BITS = 2048 * 8
ENHANCEMENT_LIMIT_BITS = 1536 * 8
BASE_RESERVED_BITS = 12000
ENHANCEMENT_RESERVED_BITS = 1920


async def reset(dut, quality24: bool) -> None:
    dut.rst_n.value = 0
    dut.stripe_start_valid.value = 0
    dut.stripe_finish_valid.value = 0
    dut.quality24.value = int(quality24)
    dut.base_limit_bits.value = BASE_LIMIT_BITS
    dut.enhancement_limit_bits.value = ENHANCEMENT_LIMIT_BITS
    dut.base_reserved_bits.value = BASE_RESERVED_BITS
    dut.enhancement_reserved_bits.value = ENHANCEMENT_RESERVED_BITS
    dut.ctu_start_valid.value = 0
    dut.ctu_has_left.value = 0
    dut.ctu_left_y.value = 0
    dut.ctu_left_cb.value = 0
    dut.ctu_left_cr.value = 0
    dut.s_valid.value = 0
    dut.s_row.value = 0
    dut.m_ready.value = 1
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def make_ctu(pattern: str, index: int, rng: np.random.Generator):
    if pattern == "flat":
        y = np.full((16, 16), 128, dtype=np.uint8)
        cb = np.full((8, 8), 128, dtype=np.uint8)
        cr = np.full((8, 8), 128, dtype=np.uint8)
    elif pattern == "gradient":
        x16 = np.arange(16, dtype=np.int32)
        y16 = np.arange(16, dtype=np.int32)[:, None]
        x8 = np.arange(8, dtype=np.int32)
        y8 = np.arange(8, dtype=np.int32)[:, None]
        y = ((index * 13 + x16 * 5 + y16 * 3) & 0xFF).astype(np.uint8)
        cb = ((96 + index * 7 + x8 * 3 + y8 * 2) & 0xFF).astype(np.uint8)
        cr = ((160 - index * 5 + x8 * 2 - y8 * 3) & 0xFF).astype(np.uint8)
    elif pattern == "checker":
        yy, xx = np.indices((16, 16))
        cy, cx = np.indices((8, 8))
        y = np.where((xx ^ yy ^ index) & 1, 255, 0).astype(np.uint8)
        cb = np.where((cx ^ cy ^ index) & 1, 240, 16).astype(np.uint8)
        cr = np.where((cx ^ cy ^ index) & 1, 16, 240).astype(np.uint8)
    elif pattern == "noise":
        y = rng.integers(0, 256, (16, 16), dtype=np.uint8)
        cb = rng.integers(0, 256, (8, 8), dtype=np.uint8)
        cr = rng.integers(0, 256, (8, 8), dtype=np.uint8)
    else:
        raise ValueError(pattern)
    return y, cb, cr


async def run_stripe(
    dut, pattern: str, quality24: bool
) -> dict[str, float | int | str]:
    await reset(dut, quality24)
    rng = np.random.default_rng(0x720000 + len(pattern))
    sources = [make_ctu(pattern, index, rng)
               for index in range(CTUS_PER_STRIPE)]

    dut.stripe_start_valid.value = 1
    while True:
        await Timer(1, units="ns")
        if int(dut.stripe_start_ready.value):
            await RisingEdge(dut.clk)
            break
        await RisingEdge(dut.clk)
    dut.stripe_start_valid.value = 0

    input_ctu = 0
    completed_ctus = 0
    start_active = False
    rows: list[int] = []
    row_index = 0
    finish_active = False
    finish_accepted = False
    output_bytes = 0
    cycles = 0
    bridge_stall_cycles = 0
    descriptor_stall_cycles = 0
    pair_done_cycles: list[int] = []

    for _ in range(250000):
        cycles += 1
        if input_ctu < CTUS_PER_STRIPE and not start_active and not rows:
            y, cb, cr = sources[input_ctu]
            rows = [pack_bytes(row) for row in y]
            rows += [pack_bytes(row) for row in cb]
            rows += [pack_bytes(row) for row in cr]
            row_index = 0
            if input_ctu:
                prev_y, prev_cb, prev_cr = sources[input_ctu - 1]
                dut.ctu_has_left.value = 1
                dut.ctu_left_y.value = pack_bytes(prev_y[:, -1])
                dut.ctu_left_cb.value = pack_bytes(prev_cb[:, -1])
                dut.ctu_left_cr.value = pack_bytes(prev_cr[:, -1])
            else:
                dut.ctu_has_left.value = 0
                dut.ctu_left_y.value = 0
                dut.ctu_left_cb.value = 0
                dut.ctu_left_cr.value = 0
            dut.ctu_start_valid.value = 1
            start_active = True

        if rows and not start_active and row_index < 32:
            dut.s_valid.value = 1
            dut.s_row.value = rows[row_index]
        else:
            dut.s_valid.value = 0

        if completed_ctus == CTUS_PER_STRIPE and not finish_active:
            dut.stripe_finish_valid.value = 1
            finish_active = True

        await Timer(1, units="ns")
        start_fire = start_active and int(dut.ctu_start_ready.value)
        row_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        finish_fire = finish_active and int(dut.stripe_finish_ready.value)
        output_bytes += int(dut.m_valid.value) and int(dut.m_ready.value)
        bridge_stall_cycles += (
            int(dut.entropy.bridge_m_valid.value)
            and not int(dut.entropy.bridge_m_ready.value)
        )
        descriptor_stall_cycles += (
            int(dut.entropy.descriptor_valid.value)
            and not int(dut.entropy.entropy_s_ready.value)
        )
        if int(dut.entropy.pair_done.value):
            pair_done_cycles.append(cycles)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if start_fire:
            start_active = False
            dut.ctu_start_valid.value = 0
        if row_fire:
            row_index += 1
            if row_index == 32:
                rows = []
                input_ctu += 1
                dut.s_valid.value = 0
        completed_ctus += int(dut.ctu_done.value)
        if finish_fire:
            finish_active = False
            finish_accepted = True
            dut.stripe_finish_valid.value = 0
        if finish_accepted and int(dut.stripe_finish_done.value):
            break
    else:
        raise AssertionError(
            f"{pattern}: full-width stripe timed out after {cycles} cycles"
        )

    assert completed_ctus == CTUS_PER_STRIPE
    assert not int(dut.fatal_error.value)
    base_bytes = int(dut.base_byte_count.value)
    enhancement_bytes = int(dut.enhancement_byte_count.value)
    assert output_bytes == base_bytes + enhancement_bytes
    return {
        "pattern": pattern,
        "quality": 24 if quality24 else 20,
        "cycles": cycles,
        "cycles_per_ctu": cycles / CTUS_PER_STRIPE,
        "fps_60mhz": 60_000_000 / (cycles * STRIPES_PER_FRAME),
        "fps_64mhz": 64_000_000 / (cycles * STRIPES_PER_FRAME),
        "fps_72mhz": 72_000_000 / (cycles * STRIPES_PER_FRAME),
        "required_mhz_30fps": cycles * STRIPES_PER_FRAME * 30 / 1_000_000,
        "base_bytes": base_bytes,
        "enhancement_bytes": enhancement_bytes,
        "saturated": int(dut.coefficient_saturated.value),
        "bridge_stall_cycles": bridge_stall_cycles,
        "descriptor_stall_cycles": descriptor_stall_cycles,
        "max_pair_interval": max(
            (b - a for a, b in zip(pair_done_cycles, pair_done_cycles[1:])),
            default=0,
        ),
    }


@cocotb.test()
async def full_width_stripe_throughput(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    results = []
    for quality24 in (False, True):
        for pattern in ("flat", "gradient", "checker", "noise"):
            result = await run_stripe(dut, pattern, quality24)
            results.append(result)
            cocotb.log.info(
                "TRANSMITTER_THROUGHPUT "
                "quality=%d pattern=%s cycles=%d cycles_per_ctu=%.3f "
            "fps_60mhz=%.3f fps_64mhz=%.3f fps_72mhz=%.3f required_mhz_30fps=%.3f "
                "base_bytes=%d enhancement_bytes=%d saturated=%d",
                result["quality"],
                result["pattern"],
                result["cycles"],
                result["cycles_per_ctu"],
                result["fps_60mhz"],
                result["fps_64mhz"],
                result["fps_72mhz"],
                result["required_mhz_30fps"],
                result["base_bytes"],
                result["enhancement_bytes"],
                result["saturated"],
            )
            cocotb.log.info(
                "TRANSMITTER_STALLS quality=%d pattern=%s bridge=%d "
                "descriptor=%d max_pair_interval=%d",
                result["quality"],
                result["pattern"],
                result["bridge_stall_cycles"],
                result["descriptor_stall_cycles"],
                result["max_pair_interval"],
            )

    worst = max(results, key=lambda item: int(item["cycles"]))
    cocotb.log.info(
        "TRANSMITTER_WORST quality=%d pattern=%s cycles=%d fps_60mhz=%.3f fps_64mhz=%.3f fps_72mhz=%.3f required_mhz_30fps=%.3f",
        worst["quality"],
        worst["pattern"],
        worst["cycles"],
        worst["fps_60mhz"],
        worst["fps_64mhz"],
        worst["fps_72mhz"],
        worst["required_mhz_30fps"],
    )
