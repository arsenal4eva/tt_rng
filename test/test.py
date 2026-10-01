import cocotb

from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge


@cocotb.test()
async def test_project(dut):

    dut._log.info("Starting TRNG test")

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    await Timer(100, unit="ns")

    dut.rst_n.value = 1

    await Timer(100, unit="ns")


    dut._log.info("Testing disabled state")

    dut.ui_in.value = 0

    await Timer(200, unit="ns")

    assert int(dut.uo_out.value) == 0


    dut._log.info("Enabling TRNG test mode")

    dut.ui_in.value = 0b00000011

    await Timer(100, unit="ns")


    dut._log.info("Waiting for entropy bytes")

    values = []

    for _ in range(100):

        await RisingEdge(dut.clk)

        value = int(dut.uo_out.value)

        if value not in values:
            values.append(value)


    dut._log.info("Observed values: %s", values)

    assert len(values) > 1


    dut._log.info("Checking output width")

    assert 0 <= int(dut.uo_out.value) <= 255


    dut._log.info("Testing normal mode")

    dut.ui_in.value = 0b00000001

    await Timer(100, unit="ns")

    assert 0 <= int(dut.uo_out.value) <= 255


    dut._log.info("TRNG test successful")
