from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cabac import CABAC_INIT_I, CabacByteEncoder, coefficient_context_init_states
from hevc_reference.chroma_coeff_syntax import coefficient_syntax_bins_8
from hevc_reference.chroma_ctu_syntax import ctu16_yuv_syntax_bins
from hevc_reference.cu_syntax import CABAC_BYPASS, CuSyntaxBin
from hevc_reference.syntax import coefficient_context_address, coefficient_syntax_bins_16


def mapped(events):
    return tuple(CuSyntaxBin(e.value, CABAC_BYPASS if e.bypass else 0,
                             coefficient_context_address(e) or 0) for e in events)


async def reset(dut):
    dut.rst_n.value = 0
    for name in ("cfg_valid", "context_init_valid", "slice_start_valid",
                 "ctu_start_valid", "cu_valid", "y_valid", "cb_valid",
                 "cr_valid", "m_ready"):
        getattr(dut, name).value = 0
    for _ in range(3): await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def initialize(dut, qp):
    dut.context_init_valid.value = 1
    dut.context_init_slice_type.value = CABAC_INIT_I
    dut.context_init_qp.value = qp
    await Timer(1, units="ns")
    assert int(dut.context_init_ready.value)
    await RisingEdge(dut.clk)
    dut.context_init_valid.value = 0
    for _ in range(1200):
        await RisingEdge(dut.clk)
        if int(dut.context_init_done.value): break
    else: raise AssertionError("context init timeout")
    dut.slice_start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.slice_start_ready.value)
    await RisingEdge(dut.clk)
    dut.slice_start_valid.value = 0


async def load_blocks(dut, y, cb, cr):
    specs = (("y", 256, y, 4, 15), ("cb", 64, cb, 3, 7),
             ("cr", 64, cr, 3, 7))
    indices = [0, 0, 0]
    for prefix, size, block, shift, mask in specs:
        getattr(dut, prefix + "_valid").value = 1
        getattr(dut, prefix + "_raster_address").value = 0
        getattr(dut, prefix + "_coefficient").value = block[0][0]
        getattr(dut, prefix + "_block_last").value = 0
    await Timer(1, units="ns")
    for _ in range(3000):
        fires = [int(getattr(dut, p + "_valid").value) and
                 int(getattr(dut, p + "_ready").value)
                 for p, *_ in specs]
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        for plane, (prefix, size, block, shift, mask) in enumerate(specs):
            if fires[plane]:
                indices[plane] += 1
                if indices[plane] == size:
                    getattr(dut, prefix + "_valid").value = 0
                else:
                    address = indices[plane]
                    getattr(dut, prefix + "_raster_address").value = address
                    getattr(dut, prefix + "_coefficient").value = block[address >> shift][address & mask]
                    getattr(dut, prefix + "_block_last").value = int(address == size - 1)
        await Timer(1, units="ns")
        if indices == [256, 64, 64]:
            return
    raise AssertionError(f"coefficient load timeout {indices}")


@cocotb.test()
async def one_yuv_ctu_matches_byte_exact_cabac_reference(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    qp = 34
    await initialize(dut, qp)
    y = [[0] * 16 for _ in range(16)]
    cb = [[0] * 8 for _ in range(8)]
    cr = [[0] * 8 for _ in range(8)]
    for address, value in ((0, -3), (18, 7), (255, -2)):
        y[address >> 4][address & 15] = value
    for address, value in ((0, 2), (21, -5), (63, 9)):
        cb[address >> 3][address & 7] = value
    for address, value in ((0, -1), (14, 4), (48, -7)):
        cr[address >> 3][address & 7] = value
    await load_blocks(dut, y, cb, cr)

    events = ctu16_yuv_syntax_bins(
        1, mapped(coefficient_syntax_bins_16(y)),
        mapped(coefficient_syntax_bins_8(cb)),
        mapped(coefficient_syntax_bins_8(cr)), True,
    )
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for event in events:
        if event.kind == 2: encoder.encode_terminate(event.value)
        elif event.kind == CABAC_BYPASS: encoder.encode_bypass(event.value)
        else: encoder.encode_regular(event.value, event.context_address)
    expected = encoder.bytes()

    dut.ctu_start_valid.value = 1
    dut.ctu_last_in_slice.value = 1
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0
    dut.cu_valid.value = 1
    dut.cu_luma_mode_dc.value = 1
    dut.cu_luma_cbf.value = dut.cu_cb_cbf.value = dut.cu_cr_cbf.value = 1
    rng = random.Random(0xCAB420)
    output, last_flags = [], []
    stalled = None
    for _ in range(50000):
        dut.m_ready.value = int(rng.random() < 0.72)
        await Timer(1, units="ns")
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        valid, ready = int(dut.m_valid.value), int(dut.m_ready.value)
        value = (int(dut.m_byte.value), int(dut.m_last.value)) if valid else None
        if stalled is not None: assert valid and value == stalled
        stalled = value if valid and not ready else None
        if valid and ready:
            output.append(value[0]); last_flags.append(value[1])
        await RisingEdge(dut.clk)
        if cu_fire: dut.cu_valid.value = 0
        if int(dut.protocol_error.value):
            raise AssertionError(
                f"path={int(dut.path_error.value)} cabac={int(dut.cabac_error.value)} "
                f"sched={int(dut.syntax_path.scheduler_error.value)} "
                f"y={int(dut.syntax_path.y_input_error.value)} "
                f"cb={int(dut.syntax_path.cb_input_error.value)} "
                f"cr={int(dut.syntax_path.cr_input_error.value)} "
                f"plane={int(dut.syntax_path.active_coefficient_plane.value)} "
                f"state={int(dut.syntax_path.scheduler.state.value)}")
        if int(dut.slice_done.value): break
    else: raise AssertionError("YUV CABAC timeout")
    assert bytes(output) == expected
    assert last_flags == [0] * (len(output) - 1) + [1]
