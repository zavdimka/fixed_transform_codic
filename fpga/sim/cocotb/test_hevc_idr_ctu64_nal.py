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
from hevc_reference.cu_syntax import CABAC_BYPASS, intra_cu16_prefix_bins
from hevc_reference.scan import DIAGONAL_SCAN_16
from hevc_reference.slice_header import idr_slice_header_bytes
from hevc_reference.syntax import (
    coefficient_context_address,
    coefficient_syntax_bins_16,
)


CTU_COLUMNS = 2
CTU_ROWS = 1


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.slice_row.value = 0
    dut.qp.value = 26
    dut.no_output_of_prior_pics.value = 0
    dut.ctu_start_valid.value = 0
    dut.cu_valid.value = 0
    dut.cu_luma_mode_dc.value = 0
    dut.cu_luma_cbf.value = 0
    dut.s_valid.value = 0
    dut.s_raster_address.value = 0
    dut.s_coefficient.value = 0
    dut.s_block_last.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def make_block(entries):
    block = [[0] * 16 for _ in range(16)]
    for scan_position, coefficient in entries:
        address = DIAGONAL_SCAN_16[scan_position]
        block[address >> 4][address & 15] = coefficient
    return block


def coefficient_beats(blocks_by_cu, cbfs):
    beats = []
    for cu_index, cbf in enumerate(cbfs):
        if not cbf:
            continue
        block = blocks_by_cu[cu_index]
        for index in range(256):
            address = ((index & 15) << 4) | (index >> 4)
            beats.append(
                (
                    address,
                    block[address >> 4][address & 15],
                    int(index == 255),
                )
            )
    return beats


def expected_cabac_bytes(qp, ctus) -> bytes:
    contexts = coefficient_context_init_states(CABAC_INIT_I, qp)
    encoder = CabacByteEncoder(contexts)
    for ctu_x, modes, cbfs, blocks_by_cu in ctus:
        for cu_index in range(16):
            for event in intra_cu16_prefix_bins(
                cu_index, ctu_x, modes[cu_index], cbfs[cu_index]
            ):
                if event.kind == CABAC_BYPASS:
                    encoder.encode_bypass(event.value)
                else:
                    encoder.encode_regular(event.value, event.context_address)
            if cbfs[cu_index]:
                for event in coefficient_syntax_bins_16(blocks_by_cu[cu_index]):
                    context_address = coefficient_context_address(event)
                    if context_address is None:
                        encoder.encode_bypass(event.value)
                    else:
                        encoder.encode_regular(event.value, context_address)
        encoder.encode_terminate(int(ctu_x == CTU_COLUMNS - 1))
    return encoder.bytes()


def make_ctus():
    modes0 = tuple(index & 1 for index in range(16))
    cbfs0 = tuple(index in (0, 7) for index in range(16))
    blocks0 = [None] * 16
    blocks0[0] = make_block(((0, -3), (1, 7), (18, -11)))
    blocks0[7] = make_block(((0, 2), (31, -5), (89, 13)))

    modes1 = modes0[::-1]
    cbfs1 = tuple(index in (3, 15) for index in range(16))
    blocks1 = [None] * 16
    blocks1[3] = make_block(((0, 4), (16, -9), (73, 19)))
    blocks1[15] = make_block(((0, -2), (63, 11), (205, -29)))

    return (
        (0, modes0, cbfs0, tuple(blocks0)),
        (1, modes1, cbfs1, tuple(blocks1)),
    )


@cocotb.test()
async def complete_slice_matches_annexb_byte_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    qp = 34
    row = 0
    no_output = True
    ctus = make_ctus()
    cabac_payload = expected_cabac_bytes(qp, ctus)
    expected = build_annexb_nal(
        20,
        idr_slice_header_bytes(
            row,
            qp,
            CTU_COLUMNS,
            CTU_ROWS,
            no_output_of_prior_pics=no_output,
        )
        + cabac_payload,
    )

    dut.slice_row.value = row
    dut.qp.value = qp
    dut.no_output_of_prior_pics.value = int(no_output)
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    rng = random.Random(0x1D2C7A64)
    received = bytearray()
    last_positions = []
    stalled = None
    ctu_index = 0
    ctu_started = False
    cu_index = 0
    coefficient_index = 0
    completed_blocks = 0
    coefficient_streams = [
        coefficient_beats(descriptor[3], descriptor[2]) for descriptor in ctus
    ]

    for _ in range(100000):
        dut.ctu_start_valid.value = int(ctu_index < len(ctus) and not ctu_started)

        if ctu_started and cu_index < 16:
            _, modes, cbfs, _ = ctus[ctu_index]
            dut.cu_valid.value = 1
            dut.cu_luma_mode_dc.value = int(modes[cu_index] == 1)
            dut.cu_luma_cbf.value = int(cbfs[cu_index])
        else:
            dut.cu_valid.value = 0

        beats = coefficient_streams[ctu_index] if ctu_index < len(ctus) else ()
        if ctu_started and coefficient_index < len(beats):
            address, coefficient, block_last = beats[coefficient_index]
            dut.s_valid.value = 1
            dut.s_raster_address.value = address
            dut.s_coefficient.value = coefficient
            dut.s_block_last.value = block_last
        else:
            dut.s_valid.value = 0
            dut.s_block_last.value = 0

        dut.m_ready.value = int(rng.random() < 0.73)
        await Timer(1, units="ns")

        ctu_start_fire = int(dut.ctu_start_valid.value) and int(
            dut.ctu_start_ready.value
        )
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        coefficient_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output = (int(dut.m_byte.value), int(dut.m_last.value))

        if stalled is not None:
            assert output_valid
            assert output == stalled
        stalled = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output[0])
            if output[1]:
                last_positions.append(len(received) - 1)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        assert not int(dut.parameter_error.value)
        assert not int(dut.protocol_error.value)
        if ctu_index < len(ctus):
            assert int(dut.current_ctu_x.value) == ctus[ctu_index][0]
        if ctu_start_fire:
            ctu_started = True
        if cu_fire:
            cu_index += 1
        if coefficient_fire:
            coefficient_index += 1
        if int(dut.block_done.value):
            completed_blocks += 1
        if int(dut.ctu_done.value):
            assert ctu_started
            assert cu_index == 16
            assert coefficient_index == len(beats)
            assert completed_blocks == sum(ctus[ctu_index][2])
            ctu_index += 1
            ctu_started = False
            cu_index = 0
            coefficient_index = 0
            completed_blocks = 0

        if int(dut.done.value):
            assert ctu_index == len(ctus)
            assert last_positions == [len(received) - 1]
            assert bytes(received) == expected
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"complete IDR CTU64 NAL transfer timed out: "
        f"ctu={ctu_index} started={ctu_started} cu={cu_index} "
        f"coefficient={coefficient_index} blocks={completed_blocks} "
        f"x={int(dut.current_ctu_x.value)} busy={int(dut.busy.value)} "
        f"ctu_ready={int(dut.ctu_start_ready.value)} "
        f"cu_ready={int(dut.cu_ready.value)} s_ready={int(dut.s_ready.value)} "
        f"bytes={len(received)}/{len(expected)} "
        f"cabac_busy={int(dut.cabac_busy.value)} "
        f"cabac_valid={int(dut.cabac_m_valid.value)} "
        f"cabac_last={int(dut.cabac_m_last.value)} "
        f"nal_ready={int(dut.nal_s_ready.value)} "
        f"slice_seen={int(dut.cabac_slice_done_seen.value)} "
        f"state={int(dut.state.value)} "
        f"cabac_state={int(dut.cabac_path.cabac.state.value)} "
        f"nal_state={int(dut.nal_path.state.value)} "
        f"writer_state={int(dut.nal_path.nal_writer.state.value)} "
        f"cabac_m_ready={int(dut.cabac_m_ready.value)}"
    )


@cocotb.test()
async def invalid_parameters_emit_no_partial_nal(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    for row, qp in ((CTU_ROWS, 34), (0, 52)):
        dut.slice_row.value = row
        dut.qp.value = qp
        dut.start_valid.value = 1
        await RisingEdge(dut.clk)
        dut.start_valid.value = 0
        await Timer(1, units="ns")
        assert int(dut.parameter_error.value)
        assert not int(dut.busy.value)
        assert not int(dut.m_valid.value)
