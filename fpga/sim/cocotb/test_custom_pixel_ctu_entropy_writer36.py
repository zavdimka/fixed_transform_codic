from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from test_custom_ctu_entropy_writer36 import expected_stripe
from test_custom_intra_residual_frontend import expected_ctu, pack_bytes


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.stripe_start_valid.value = 0
    dut.stripe_finish_valid.value = 0
    dut.quality24.value = 0
    dut.base_limit_bits.value = 16384
    dut.enhancement_limit_bits.value = 12288
    dut.base_reserved_bits.value = 300
    dut.enhancement_reserved_bits.value = 48
    dut.ctu_start_valid.value = 0
    dut.ctu_has_left.value = 0
    dut.ctu_left_y.value = 0
    dut.ctu_left_cb.value = 0
    dut.ctu_left_cr.value = 0
    dut.s_valid.value = 0
    dut.s_row.value = 0
    dut.m_ready.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def two_pixel_ctus_match_python_entropy_bytes(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    sample_rng = np.random.default_rng(0xC7E2E)

    sources = []
    references = []
    # First CTU has the stripe-edge DC=128 rule.
    sources.append((
        sample_rng.integers(24, 232, (16, 16), dtype=np.uint8),
        sample_rng.integers(48, 208, (8, 8), dtype=np.uint8),
        sample_rng.integers(48, 208, (8, 8), dtype=np.uint8),
    ))
    references.append((None, None, None))
    # Second CTU is close to its supplied reconstructed left edge and normally
    # chooses horizontal; the oracle still decides rather than assuming it.
    left_y = sample_rng.integers(32, 224, 16, dtype=np.uint8)
    left_cb = sample_rng.integers(48, 208, 8, dtype=np.uint8)
    left_cr = sample_rng.integers(48, 208, 8, dtype=np.uint8)
    sources.append((
        np.clip(np.repeat(left_y[:, None], 16, axis=1)
                + sample_rng.integers(-3, 4, (16, 16)), 0, 255).astype(np.uint8),
        np.clip(np.repeat(left_cb[:, None], 8, axis=1)
                + sample_rng.integers(-3, 4, (8, 8)), 0, 255).astype(np.uint8),
        np.clip(np.repeat(left_cr[:, None], 8, axis=1)
                + sample_rng.integers(-3, 4, (8, 8)), 0, 255).astype(np.uint8),
    ))
    references.append((left_y, left_cb, left_cr))

    modes = []
    ctus = []
    for (y, cb, cr), (ref_y, ref_cb, ref_cr) in zip(
        sources, references, strict=True
    ):
        mode, _dc, _horizontal, pairs = expected_ctu(
            y, cb, cr, ref_y, ref_cb, ref_cr
        )
        modes.append(mode)
        ctus.append(pairs)
    expected, expected_drops, guard, packer = expected_stripe(
        tuple(ctus), tuple(modes), (16384, 12288), (300, 48), (0, 0)
    )
    assert expected_drops == 0

    dut.stripe_start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.stripe_start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.stripe_start_valid.value = 0

    input_ctu = 0
    start_active = False
    row_index = 0
    rows = []
    frontend_count = 0
    ctu_done_count = 0
    finish_active = False
    finish_accepted = False
    observed = []

    for _cycle in range(5000):
        if input_ctu < len(sources) and not start_active and not rows:
            y, cb, cr = sources[input_ctu]
            ref_y, ref_cb, ref_cr = references[input_ctu]
            rows = [pack_bytes(row) for row in y]
            rows += [pack_bytes(row) for row in cb]
            rows += [pack_bytes(row) for row in cr]
            row_index = 0
            dut.ctu_has_left.value = int(ref_y is not None)
            dut.ctu_left_y.value = pack_bytes(
                ref_y if ref_y is not None else np.zeros(16, dtype=np.uint8)
            )
            dut.ctu_left_cb.value = pack_bytes(
                ref_cb if ref_cb is not None else np.zeros(8, dtype=np.uint8)
            )
            dut.ctu_left_cr.value = pack_bytes(
                ref_cr if ref_cr is not None else np.zeros(8, dtype=np.uint8)
            )
            dut.ctu_start_valid.value = 1
            start_active = True

        if rows and not start_active and row_index < 32:
            dut.s_valid.value = 1
            dut.s_row.value = rows[row_index]
        else:
            dut.s_valid.value = 0

        if ctu_done_count == len(sources) and not finish_active:
            dut.stripe_finish_valid.value = 1
            finish_active = True

        await Timer(1, units="ns")
        start_fire = start_active and int(dut.ctu_start_ready.value)
        row_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        finish_fire = finish_active and int(dut.stripe_finish_ready.value)
        if int(dut.m_valid.value):
            observed.append((int(dut.m_layer.value), int(dut.m_byte.value)))

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
        frontend_count += int(dut.frontend_done.value)
        ctu_done_count += int(dut.ctu_done.value)
        if finish_fire:
            finish_active = False
            finish_accepted = True
            dut.stripe_finish_valid.value = 0
        if finish_accepted and int(dut.stripe_finish_done.value):
            break
    else:
        raise AssertionError("pixel-to-byte integration timed out")

    assert frontend_count == 2
    assert ctu_done_count == 2
    assert observed == expected
    assert not int(dut.fatal_error.value)
    assert not int(dut.coefficient_saturated.value)
    assert int(dut.base_used_bits.value) == guard.used[0]
    assert int(dut.enhancement_used_bits.value) == guard.used[1]
    assert int(dut.base_byte_count.value) == packer.byte_count[0]
    assert int(dut.enhancement_byte_count.value) == packer.byte_count[1]
    assert not int(dut.busy.value)
