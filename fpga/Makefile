VENV ?= /home/dimka/.venvs/hd-zero-fpga
export PATH := $(VENV)/bin:$(PATH)
export TMPDIR := /tmp
export TMP := /tmp
export TEMP := /tmp

.PHONY: test test-verilator test-icarus lint python-test versions clean

test: lint python-test test-verilator test-icarus

test-verilator:
	$(MAKE) -C sim SIM=verilator
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/byte_to_nibble/results.xml

test-icarus:
	$(MAKE) -C sim SIM=icarus
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/byte_to_nibble/results.xml

lint:
	verilator --lint-only --Wall -Wno-fatal rtl/common/byte_to_nibble.sv

python-test:
	PYTHONPATH=../hevc_experiment $(VENV)/bin/python -m unittest discover \
		-s ../hevc_experiment/tests -v

versions:
	verilator --version
	iverilog -V | head -n 2
	$(VENV)/bin/python -c "import cocotb; print('cocotb', cocotb.__version__)"

clean:
	rm -rf /tmp/hd-zero-fpga-sim
