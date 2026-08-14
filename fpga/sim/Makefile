SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := byte_to_nibble
MODULE := test_byte_to_nibble

REPO_ROOT := $(abspath ../..)
VERILOG_SOURCES := ../rtl/common/byte_to_nibble.sv
export PYTHONPATH := $(REPO_ROOT)/hevc_experiment:$(CURDIR)/cocotb:$(PYTHONPATH)
export TMPDIR := /tmp
export TMP := /tmp
export TEMP := /tmp

# Building under /tmp avoids the severe small-file penalty of WSL on /mnt/c.
SIM_BUILD ?= /tmp/hd-zero-fpga-sim/$(SIM)/$(TOPLEVEL)
COCOTB_RESULTS_FILE ?= $(SIM_BUILD)/results.xml

ifeq ($(SIM),verilator)
COMPILE_ARGS += --Wall -Wno-fatal
endif

ifneq ($(HEVC_CONTEXT_INIT_DEFINE),)
COMPILE_ARGS += $(HEVC_CONTEXT_INIT_DEFINE)
endif

ifneq ($(HEVC_PARAMETER_SET_DEFINE),)
COMPILE_ARGS += $(HEVC_PARAMETER_SET_DEFINE)
endif

ifneq ($(HEVC_SLICE_HEADER_PARAMETERS),)
COMPILE_ARGS += $(HEVC_SLICE_HEADER_PARAMETERS)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
