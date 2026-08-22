import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.write_ready.value = 0
    for prefix in ("base", "lf"):
        getattr(dut, f"{prefix}_valid").value = 0
        getattr(dut, f"{prefix}_start").value = 0
        getattr(dut, f"{prefix}_last").value = 0
        getattr(dut, f"{prefix}_frame_id").value = 0
        getattr(dut, f"{prefix}_stripe_id").value = 0
        getattr(dut, f"{prefix}_plane").value = 0
        getattr(dut, f"{prefix}_address").value = 0
        getattr(dut, f"{prefix}_data").value = 0
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def selected_stripe_owns_sink_until_last_sample(dut):
    await reset_dut(dut)
    dut.write_ready.value = 1
    dut.lf_valid.value = 1
    dut.lf_start.value = 1
    dut.lf_frame_id.value = 3
    dut.lf_stripe_id.value = 4
    dut.lf_data.value = 0x44
    await RisingEdge(dut.clk)
    assert int(dut.lf_ready.value) == 1
    await FallingEdge(dut.clk)
    dut.lf_start.value = 0
    dut.base_valid.value = 1
    dut.base_start.value = 1
    dut.base_data.value = 0xBA
    dut.lf_data.value = 0x45
    await RisingEdge(dut.clk)
    assert int(dut.owner.value) == 2
    assert int(dut.base_ready.value) == 0
    assert int(dut.lf_ready.value) == 1
    assert int(dut.write_data.value) == 0x45
    await FallingEdge(dut.clk)
    dut.lf_last.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.lf_valid.value = 0
    dut.lf_last.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.base_ready.value) == 1
    assert int(dut.write_data.value) == 0xBA
