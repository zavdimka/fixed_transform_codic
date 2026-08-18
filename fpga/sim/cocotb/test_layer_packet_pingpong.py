from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly


async def reset(dut) -> None:
    dut.write_rst_n.value = 0
    dut.read_rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_layer.value = 0
    dut.s_commit.value = 0
    dut.gap_cycles.value = 7
    for _ in range(5):
        await RisingEdge(dut.write_clk)
    dut.write_rst_n.value = 1
    dut.read_rst_n.value = 1


async def push_byte(dut, value: int, layer: int) -> None:
    dut.s_data.value = value
    dut.s_layer.value = layer
    dut.s_valid.value = 1
    while True:
        await RisingEdge(dut.write_clk)
        if int(dut.s_ready.value):
            break
    dut.s_valid.value = 0


async def commit(dut) -> None:
    dut.s_commit.value = 1
    while True:
        await RisingEdge(dut.write_clk)
        if int(dut.s_commit_ready.value):
            break
    dut.s_commit.value = 0


@cocotb.test()
async def emits_layer_packets_with_exact_cs_gaps(dut) -> None:
    cocotb.start_soon(Clock(dut.write_clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.read_clk, 20, units="ns").start())
    await reset(dut)

    base0 = bytes([0x12, 0xAB, 0x00, 0xF7])
    enhancement0 = bytes([0x45, 0x67, 0x89])
    base1 = bytes([0xDE, 0xAD])

    # Deliberately interleave layers as the entropy writer does.
    for index in range(max(len(base0), len(enhancement0))):
        if index < len(base0):
            await push_byte(dut, base0[index], 0)
        if index < len(enhancement0):
            await push_byte(dut, enhancement0[index], 1)
    await commit(dut)
    for value in base1:
        await push_byte(dut, value, 0)
    await commit(dut)

    packets: list[tuple[int, bytes]] = []
    active_nibbles: list[int] = []
    active_layer = 0
    previous_active = 0
    gap_lengths: list[int] = []
    inactive_run = 0

    for _ in range(5000):
        await RisingEdge(dut.read_clk)
        await ReadOnly()
        active = int(dut.packet_active.value)
        if active:
            if not previous_active:
                if packets:
                    gap_lengths.append(inactive_run)
                inactive_run = 0
                active_layer = int(dut.packet_layer.value)
                assert int(dut.packet_start.value)
            else:
                assert int(dut.packet_layer.value) == active_layer
            active_nibbles.append(int(dut.packet_data.value))
            if int(dut.packet_end.value):
                assert len(active_nibbles) % 2 == 0
        else:
            inactive_run += 1
            if previous_active:
                assert len(active_nibbles) % 2 == 0
                payload = bytes(
                    (active_nibbles[i] << 4) | active_nibbles[i + 1]
                    for i in range(0, len(active_nibbles), 2)
                )
                packets.append((active_layer, payload))
                active_nibbles = []

        previous_active = active
        if len(packets) == 3:
            break

    assert packets == [(0, base0), (1, enhancement0), (0, base1)]
    assert all(gap >= 7 for gap in gap_lengths)
    assert int(dut.packet_count.value) == 3
    assert not int(dut.write_overflow.value)


@cocotb.test()
async def empty_layer_is_not_emitted(dut) -> None:
    cocotb.start_soon(Clock(dut.write_clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.read_clk, 20, units="ns").start())
    await reset(dut)

    enhancement = bytes([0xA5, 0x5A])
    for value in enhancement:
        await push_byte(dut, value, 1)
    await commit(dut)

    nibbles: list[int] = []
    for _ in range(1000):
        await RisingEdge(dut.read_clk)
        await ReadOnly()
        if int(dut.packet_active.value):
            assert int(dut.packet_layer.value) == 1
            nibbles.append(int(dut.packet_data.value))
        elif nibbles:
            break

    assert nibbles == [0xA, 0x5, 0x5, 0xA]

