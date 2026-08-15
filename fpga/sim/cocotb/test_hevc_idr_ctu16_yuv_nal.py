from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.cabac import (
    CABAC_INIT_I,
    CabacByteEncoder,
    coefficient_context_init_states,
)
from hevc_reference.chroma_coeff_syntax import coefficient_syntax_bins_8
from hevc_reference.chroma_ctu_syntax import ctu16_yuv_syntax_bins
from hevc_reference.cu_syntax import CABAC_BYPASS, CuSyntaxBin
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import (
    coefficient_context_address,
    coefficient_syntax_bins_16,
)


def mapped(events):
    return tuple(
        CuSyntaxBin(
            event.value,
            CABAC_BYPASS if event.bypass else 0,
            coefficient_context_address(event) or 0,
        )
        for event in events
    )


def expected_nal(qp, y, cb, cr):
    events = ctu16_yuv_syntax_bins(
        1,
        mapped(coefficient_syntax_bins_16(y)),
        mapped(coefficient_syntax_bins_8(cb)),
        mapped(coefficient_syntax_bins_8(cr)),
        True,
    )
    encoder = CabacByteEncoder(coefficient_context_init_states(CABAC_INIT_I, qp))
    for event in events:
        if event.kind == 2:
            encoder.encode_terminate(event.value)
        elif event.kind == CABAC_BYPASS:
            encoder.encode_bypass(event.value)
        else:
            encoder.encode_regular(event.value, event.context_address)
    rbsp = idr_slice_header_bytes(0, qp, 1, 1) + encoder.bytes()
    return build_annexb_nal(20, rbsp)


async def reset(dut):
    dut.rst_n.value = 0
    for name in (
        "start_valid", "ctu_start_valid", "cu_valid", "y_valid",
        "cb_valid", "cr_valid", "m_ready",
    ):
        getattr(dut, name).value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def one_colour_ctu_forms_byte_exact_annexb_idr(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    qp = 34
    y = [[0] * 16 for _ in range(16)]
    cb = [[0] * 8 for _ in range(8)]
    cr = [[0] * 8 for _ in range(8)]
    for address, value in ((0, -3), (18, 7), (119, 2), (255, -2)):
        y[address >> 4][address & 15] = value
    for address, value in ((0, 2), (21, -5), (63, 9)):
        cb[address >> 3][address & 7] = value
    for address, value in ((0, -1), (14, 4), (48, -7)):
        cr[address >> 3][address & 7] = value
    expected = expected_nal(qp, y, cb, cr)

    dut.slice_row.value = 0
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = 0
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    specs = (
        ("y", 256, y, 4, 15),
        ("cb", 64, cb, 3, 7),
        ("cr", 64, cr, 3, 7),
    )
    indices = {prefix: 0 for prefix, *_ in specs}
    dut.ctu_start_valid.value = 1
    dut.cu_valid.value = 1
    dut.cu_luma_mode_dc.value = 1
    dut.cu_luma_cbf.value = 1
    dut.cu_cb_cbf.value = 1
    dut.cu_cr_cbf.value = 1

    rng = random.Random(0x1D420)
    ctu_started = False
    cu_sent = False
    nal = bytearray()
    last_flags = []
    block_done_counts = {"y": 0, "cb": 0, "cr": 0}
    stalled_output = None

    for _ in range(100000):
        for prefix, size, block, shift, mask in specs:
            valid = getattr(dut, prefix + "_valid")
            index = indices[prefix]
            if not int(valid.value) and index < size:
                valid.value = 1
                getattr(dut, prefix + "_raster_address").value = index
                getattr(dut, prefix + "_coefficient").value = (
                    block[index >> shift][index & mask]
                )
                getattr(dut, prefix + "_block_last").value = int(
                    index == size - 1
                )

        dut.m_ready.value = int(rng.random() < 0.72)
        await Timer(1, units="ns")

        ctu_fire = int(dut.ctu_start_valid.value) and int(
            dut.ctu_start_ready.value
        )
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        source_fires = {
            prefix: int(getattr(dut, prefix + "_valid").value) and
            int(getattr(dut, prefix + "_ready").value)
            for prefix, *_ in specs
        }
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output = (
            int(dut.m_byte.value), bool(dut.m_last.value)
        ) if output_valid else None
        if stalled_output is not None:
            assert output_valid and output == stalled_output
        stalled_output = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            nal.append(output[0])
            last_flags.append(output[1])

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if ctu_fire:
            ctu_started = True
            dut.ctu_start_valid.value = 0
        if cu_fire:
            cu_sent = True
            dut.cu_valid.value = 0
        for prefix, fired in source_fires.items():
            if fired:
                indices[prefix] += 1
                getattr(dut, prefix + "_valid").value = 0
        for prefix in block_done_counts:
            block_done_counts[prefix] += int(
                getattr(dut, prefix + "_block_done").value
            )

        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert ctu_started and cu_sent
            assert indices == {"y": 256, "cb": 64, "cr": 64}
            assert block_done_counts == {"y": 1, "cb": 1, "cr": 1}
            assert bytes(nal) == expected
            assert last_flags == [False] * (len(last_flags) - 1) + [True]
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"YUV IDR timeout ctu={ctu_started} cu={cu_sent} "
        f"indices={indices} bytes={len(nal)}"
    )
