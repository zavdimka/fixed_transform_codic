import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def quality_profiles_select_expected_qp(dut) -> None:
    expected = {
        0: (28, 4, 4, 1),
        1: (34, 5, 4, 1),
        2: (40, 6, 4, 1),
        3: (34, 5, 4, 0),
    }
    for quality, values in expected.items():
        dut.quality.value = quality
        await Timer(1, units="ns")
        actual = (
            int(dut.qp.value), int(dut.qp_per.value), int(dut.qp_rem.value),
            int(dut.profile_valid.value),
        )
        assert actual == values
