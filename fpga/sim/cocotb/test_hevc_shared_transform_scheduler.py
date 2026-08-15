from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


PLANES = (("y", 0, 256, 0), ("cb", 1, 64, 1), ("cr", 2, 64, 0))


async def reset(dut):
    dut.rst_n.value = 0
    for name, _, _, _ in PLANES:
        getattr(dut, f"{name}_request_valid").value = 0
        getattr(dut, f"{name}_s_valid").value = 0
        getattr(dut, f"{name}_m_ready").value = 0
    dut.service_command_ready.value = 0
    dut.service_s_ready.value = 0
    dut.service_m_valid.value = 0
    dut.service_m_data.value = 0
    dut.service_m_x.value = 0
    dut.service_m_y.value = 0
    dut.service_m_block_last.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def complete_blocks_are_serialized_y_cb_cr(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x5A4ED)

    sources = {
        name: [((plane + 1) * 1000 + index * 7) & 0x7FFF
               for index in range(length)]
        for name, plane, length, _ in PLANES
    }
    for name, _, _, inverse in PLANES:
        getattr(dut, f"{name}_request_valid").value = 1
        getattr(dut, f"{name}_inverse").value = inverse

    source_index = {name: 0 for name, _, _, _ in PLANES}
    received = {name: [] for name, _, _, _ in PLANES}
    command_order = []
    done_order = []
    service_owner = None
    service_input = []
    service_output_index = 0

    for _ in range(10000):
        dut.service_command_ready.value = int(rng.random() < 0.82)
        dut.service_s_ready.value = int(rng.random() < 0.77)
        for name, _, length, _ in PLANES:
            ready = int(rng.random() < 0.71)
            getattr(dut, f"{name}_m_ready").value = ready
            if (source_index[name] < length and not int(
                    getattr(dut, f"{name}_s_valid").value)):
                getattr(dut, f"{name}_s_data").value = sources[name][source_index[name]]
                getattr(dut, f"{name}_s_valid").value = int(rng.random() < 0.88)

        if service_owner is not None and len(service_input) == len(sources[service_owner]):
            if not int(dut.service_m_valid.value) and rng.random() < 0.86:
                length = len(service_input)
                size = 16 if service_owner == "y" else 8
                index = service_output_index
                dut.service_m_data.value = service_input[index]
                dut.service_m_x.value = index % size
                dut.service_m_y.value = index // size
                dut.service_m_block_last.value = int(index == length - 1)
                dut.service_m_valid.value = 1

        await Timer(1, units="ns")
        command_fire = int(dut.service_command_valid.value) and int(
            dut.service_command_ready.value)
        service_input_fire = int(dut.service_s_valid.value) and int(
            dut.service_s_ready.value)
        service_output_fire = int(dut.service_m_valid.value) and int(
            dut.service_m_ready.value)
        request_fires = {
            name: int(getattr(dut, f"{name}_request_valid").value) and
                  int(getattr(dut, f"{name}_request_ready").value)
            for name, _, _, _ in PLANES
        }
        source_fires = {
            name: int(getattr(dut, f"{name}_s_valid").value) and
                  int(getattr(dut, f"{name}_s_ready").value)
            for name, _, _, _ in PLANES
        }
        output_fires = {
            name: int(getattr(dut, f"{name}_m_valid").value) and
                  int(getattr(dut, f"{name}_m_ready").value)
            for name, _, _, _ in PLANES
        }

        if command_fire:
            plane = int(dut.service_plane.value)
            name, _, length, inverse = PLANES[plane]
            assert service_owner is None
            assert bool(dut.service_size8.value) == (name != "y")
            assert int(dut.service_inverse.value) == inverse
            service_owner = name
            service_input = []
            service_output_index = 0
            command_order.append(name)
        if service_input_fire:
            assert service_owner is not None
            service_input.append(dut.service_s_data.value.signed_integer)
        for name, fire in output_fires.items():
            if fire:
                assert name == service_owner
                received[name].append((
                    getattr(dut, f"{name}_m_data").value.signed_integer,
                    int(getattr(dut, f"{name}_m_x").value),
                    int(getattr(dut, f"{name}_m_y").value),
                    bool(getattr(dut, f"{name}_m_block_last").value),
                ))

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        for name, fire in request_fires.items():
            if fire:
                getattr(dut, f"{name}_request_valid").value = 0
        for name, fire in source_fires.items():
            if fire:
                source_index[name] += 1
                getattr(dut, f"{name}_s_valid").value = 0
        if service_output_fire:
            service_output_index += 1
            dut.service_m_valid.value = 0
            if service_output_index == len(service_input):
                done_order.append(service_owner)
                service_owner = None

        assert not int(dut.protocol_error.value)
        if len(done_order) == 3:
            break
    else:
        raise AssertionError("shared transform scheduler timed out")

    assert command_order == ["y", "cb", "cr"]
    assert done_order == command_order
    assert source_index == {"y": 256, "cb": 64, "cr": 64}
    for name, _, length, _ in PLANES:
        size = 16 if name == "y" else 8
        expected = [(sources[name][index], index % size, index // size,
                     index == length - 1) for index in range(length)]
        assert received[name] == expected
    assert not int(dut.busy.value)


@cocotb.test()
async def early_block_last_sets_protocol_error(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.cb_request_valid.value = 1
    dut.cb_inverse.value = 0
    dut.service_command_ready.value = 1
    await RisingEdge(dut.clk)
    dut.cb_request_valid.value = 0

    dut.cb_s_valid.value = 1
    dut.cb_s_data.value = 17
    dut.service_s_ready.value = 1
    await RisingEdge(dut.clk)
    dut.cb_s_valid.value = 0
    dut.service_s_ready.value = 0

    dut.service_m_valid.value = 1
    dut.service_m_data.value = 17
    dut.service_m_x.value = 0
    dut.service_m_y.value = 0
    dut.service_m_block_last.value = 1
    dut.cb_m_ready.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.protocol_error.value)
    assert int(dut.block_done.value)
    assert int(dut.completed_plane.value) == 1
