from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cabac import (
    CABAC_INIT_I,
    CabacByteEncoder,
    coefficient_context_init_states,
)
from hevc_reference.cu_syntax import (
    CABAC_BYPASS,
    intra_cu16_prefix_bins,
)
from hevc_reference.scan import DIAGONAL_SCAN_16
from hevc_reference.syntax import (
    coefficient_context_address,
    coefficient_syntax_bins_16,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.cfg_valid.value = 0
    dut.context_init_valid.value = 0
    dut.context_init_slice_type.value = CABAC_INIT_I
    dut.context_init_qp.value = 0
    dut.slice_start_valid.value = 0
    dut.ctu_start_valid.value = 0
    dut.ctu_x.value = 0
    dut.ctu_last_in_slice.value = 0
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


async def initialize_and_start(dut, qp: int) -> None:
    dut.context_init_valid.value = 1
    dut.context_init_slice_type.value = CABAC_INIT_I
    dut.context_init_qp.value = qp
    await Timer(1, units="ns")
    assert int(dut.context_init_ready.value)
    await RisingEdge(dut.clk)
    dut.context_init_valid.value = 0

    for _ in range(1200):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert not int(dut.context_init_error.value)
        if int(dut.context_init_done.value):
            break
    else:
        raise AssertionError("context initialization timed out")

    dut.slice_start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.slice_start_ready.value)
    await RisingEdge(dut.clk)
    dut.slice_start_valid.value = 0


def make_block(entries):
    block = [[0] * 16 for _ in range(16)]
    for scan_position, coefficient in entries:
        address = DIAGONAL_SCAN_16[scan_position]
        block[address >> 4][address & 15] = coefficient
    return block


def expected_slice_bytes(contexts, ctus) -> bytes:
    encoder = CabacByteEncoder(contexts)
    for ctu_x, last_ctu, modes, cbfs, blocks_by_cu in ctus:
        for cu_index in range(16):
            for event in intra_cu16_prefix_bins(
                cu_index, ctu_x, modes[cu_index], cbfs[cu_index]
            ):
                if event.kind == CABAC_BYPASS:
                    encoder.encode_bypass(event.value)
                else:
                    encoder.encode_regular(event.value, event.context_address)
            if cbfs[cu_index]:
                for event in coefficient_syntax_bins_16(
                    blocks_by_cu[cu_index]
                ):
                    address = coefficient_context_address(event)
                    if address is None:
                        encoder.encode_bypass(event.value)
                    else:
                        encoder.encode_regular(event.value, address)
        encoder.encode_terminate(int(last_ctu))
    return encoder.bytes()


def coefficient_beats(blocks_by_cu, cbfs):
    beats = []
    for cu_index, cbf in enumerate(cbfs):
        if not cbf:
            continue
        block = blocks_by_cu[cu_index]
        for index in range(256):
            address = ((index & 15) << 4) | (index >> 4)
            beats.append((
                address,
                block[address >> 4][address & 15],
                int(index == 255),
            ))
    return beats


async def run_ctu(dut, descriptor, rng, output, last_flags, stall):
    ctu_x, last_ctu, modes, cbfs, blocks_by_cu = descriptor
    beats = coefficient_beats(blocks_by_cu, cbfs)

    dut.ctu_start_valid.value = 1
    dut.ctu_x.value = ctu_x
    dut.ctu_last_in_slice.value = int(last_ctu)
    await Timer(1, units="ns")
    assert int(dut.ctu_start_ready.value)
    await RisingEdge(dut.clk)
    dut.ctu_start_valid.value = 0

    cu_index = 0
    beat_index = 0
    cu_presenting = False
    beat_presenting = False
    completed_blocks = 0

    for _ in range(400000):
        if not cu_presenting and cu_index < 16:
            cu_presenting = True
        if cu_presenting:
            dut.cu_valid.value = 1
            dut.cu_luma_mode_dc.value = int(modes[cu_index] == 1)
            dut.cu_luma_cbf.value = int(cbfs[cu_index])
        else:
            dut.cu_valid.value = 0

        if not beat_presenting and beat_index < len(beats):
            beat_presenting = True
        if beat_presenting:
            address, coefficient, block_last = beats[beat_index]
            dut.s_valid.value = 1
            dut.s_raster_address.value = address
            dut.s_coefficient.value = coefficient
            dut.s_block_last.value = block_last
        else:
            dut.s_valid.value = 0
            dut.s_block_last.value = 0

        dut.m_ready.value = int(rng.random() < 0.73)
        await Timer(1, units="ns")
        cu_fire = int(dut.cu_valid.value) and int(dut.cu_ready.value)
        coefficient_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        byte_valid = int(dut.m_valid.value)
        byte_ready = int(dut.m_ready.value)
        byte_value = (int(dut.m_byte.value), int(dut.m_last.value))
        if stall[0] is not None:
            assert byte_valid
            assert byte_value == stall[0]
        stall[0] = byte_value if byte_valid and not byte_ready else None
        if byte_valid and byte_ready:
            output.append(byte_value[0])
            last_flags.append(byte_value[1])

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if cu_fire:
            cu_index += 1
            cu_presenting = False
        if coefficient_fire:
            beat_index += 1
            beat_presenting = False
        if int(dut.block_done.value):
            completed_blocks += 1
        assert not int(dut.protocol_error.value)
        if int(dut.ctu_done.value):
            break
    else:
        raise AssertionError("integrated CTU scheduling timed out")

    assert cu_index == 16
    assert beat_index == len(beats)
    assert completed_blocks == sum(cbfs)


@cocotb.test()
async def two_complete_ctus_match_cabac_byte_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    qp = 34
    contexts = coefficient_context_init_states(CABAC_INIT_I, qp)
    await initialize_and_start(dut, qp)
    rng = random.Random(0xC7A64CAB)

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

    ctus = (
        (0, False, modes0, cbfs0, tuple(blocks0)),
        (1, True, modes1, cbfs1, tuple(blocks1)),
    )
    output = []
    last_flags = []
    stall = [None]
    for descriptor in ctus:
        await run_ctu(dut, descriptor, rng, output, last_flags, stall)

    dut.cu_valid.value = 0
    dut.s_valid.value = 0
    for _ in range(2000):
        dut.m_ready.value = int(rng.random() < 0.73)
        await Timer(1, units="ns")
        byte_valid = int(dut.m_valid.value)
        byte_ready = int(dut.m_ready.value)
        byte_value = (int(dut.m_byte.value), int(dut.m_last.value))
        if stall[0] is not None:
            assert byte_valid
            assert byte_value == stall[0]
        stall[0] = byte_value if byte_valid and not byte_ready else None
        if byte_valid and byte_ready:
            output.append(byte_value[0])
            last_flags.append(byte_value[1])
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert not int(dut.protocol_error.value)
        if int(dut.slice_done.value):
            break
    else:
        raise AssertionError("CABAC slice finish timed out")

    assert bytes(output) == expected_slice_bytes(contexts, ctus)
    assert last_flags == [0] * (len(output) - 1) + [1]
    assert not int(dut.busy.value)
