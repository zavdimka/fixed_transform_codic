VENV ?= /home/dimka/.venvs/hd-zero-fpga
PARAMETER_SET_WIDTH ?= 1280
PARAMETER_SET_HEIGHT ?= 768
PARAMETER_SET_FPS ?= 60
export PATH := $(VENV)/bin:$(PATH)
export TMPDIR := /tmp
export TMP := /tmp
export TEMP := /tmp

CONTEXT_INIT_SOURCES := ../rtl/hevc/hevc_coefficient_context_init_rom.sv ../rtl/hevc/hevc_coefficient_context_init.sv
CONTEXT_INIT_DEFINE := -DHEVC_COEFFICIENT_CONTEXT_INIT_FILE=\"$(abspath rtl/hevc/hevc_coefficient_context_init.hex)\"
PARAMETER_SET_SOURCES := ../rtl/hevc/hevc_nal_writer.sv ../rtl/hevc/hevc_parameter_set_rom.sv ../rtl/hevc/hevc_parameter_set_streamer.sv
SLICE_NAL_SOURCES := ../rtl/hevc/hevc_nal_writer.sv ../rtl/hevc/hevc_idr_slice_header.sv ../rtl/hevc/hevc_idr_slice_nal.sv
PARAMETER_SET_DEFINE := -DHEVC_PARAMETER_SET_FILE=\"$(abspath rtl/hevc/hevc_parameter_sets.hex)\"
COEFFICIENT_CABAC_SOURCES := $(CONTEXT_INIT_SOURCES) ../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_pingpong16.sv ../rtl/hevc/hevc_last_sig_bins16.sv ../rtl/hevc/hevc_significance_bins16.sv ../rtl/hevc/hevc_coefficient_level_bins16.sv ../rtl/hevc/hevc_coefficient_syntax_arbiter16.sv ../rtl/hevc/hevc_coefficient_syntax16.sv ../rtl/hevc/hevc_coefficient_context_map.sv ../rtl/hevc/hevc_cabac_context_ram.sv ../rtl/hevc/hevc_cabac_bin_step.sv ../rtl/hevc/hevc_cabac_encoder.sv ../rtl/hevc/hevc_coefficient_cabac16.sv
CTU_SYNTAX_SOURCES := ../rtl/hevc/hevc_intra_cu16_prefix.sv ../rtl/hevc/hevc_ctu64_syntax_scheduler.sv
CTU_CABAC_SOURCES := $(CONTEXT_INIT_SOURCES) ../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_pingpong16.sv ../rtl/hevc/hevc_last_sig_bins16.sv ../rtl/hevc/hevc_significance_bins16.sv ../rtl/hevc/hevc_coefficient_level_bins16.sv ../rtl/hevc/hevc_coefficient_syntax_arbiter16.sv ../rtl/hevc/hevc_coefficient_syntax16.sv ../rtl/hevc/hevc_coefficient_context_map.sv $(CTU_SYNTAX_SOURCES) ../rtl/hevc/hevc_cabac_context_ram.sv ../rtl/hevc/hevc_cabac_bin_step.sv ../rtl/hevc/hevc_cabac_encoder.sv ../rtl/hevc/hevc_ctu64_cabac.sv
IDR_CTU_NAL_SOURCES := $(CTU_CABAC_SOURCES) ../rtl/hevc/hevc_nal_writer.sv ../rtl/hevc/hevc_idr_slice_header.sv ../rtl/hevc/hevc_idr_slice_nal.sv ../rtl/hevc/hevc_idr_ctu64_nal.sv
TU_LOOP_SOURCES := ../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_prediction_buffer16.sv ../rtl/hevc/hevc_forward_transform16.sv ../rtl/hevc/hevc_qp_profile.sv ../rtl/hevc/hevc_quant_dequant16.sv ../rtl/hevc/hevc_inverse_transform16.sv ../rtl/hevc/hevc_reconstruct.sv ../rtl/hevc/hevc_tu16_reconstruction_loop.sv
TU_CABAC_BRIDGE_SOURCES := $(TU_LOOP_SOURCES) ../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_tu16_cabac_bridge.sv
LUMA_CTU_NAL_SOURCES := $(IDR_CTU_NAL_SOURCES) $(filter-out ../rtl/hevc/hevc_coefficient_buffer16.sv,$(TU_CABAC_BRIDGE_SOURCES)) ../rtl/hevc/hevc_luma_ctu64_idr_nal.sv
INTRA_FRONTEND_SOURCES := ../rtl/hevc/hevc_prediction_buffer16.sv ../rtl/hevc/hevc_intra_dc16.sv ../rtl/hevc/hevc_intra_planar16.sv ../rtl/hevc/hevc_intra_sad_select16.sv ../rtl/hevc/hevc_intra_frontend16.sv
REFERENCE_LINE_SOURCES := ../rtl/hevc/hevc_luma_reference_line_store.sv
PIXEL_LUMA_CTU_NAL_SOURCES := $(LUMA_CTU_NAL_SOURCES) ../rtl/hevc/hevc_intra_dc16.sv ../rtl/hevc/hevc_intra_planar16.sv ../rtl/hevc/hevc_intra_sad_select16.sv ../rtl/hevc/hevc_intra_frontend16.sv $(REFERENCE_LINE_SOURCES) ../rtl/hevc/hevc_luma_pixel_ctu64_idr_nal.sv
CAMERA_YUV420P_SOURCES := ../rtl/hevc/hevc_camera_yuv420p_ingress.sv

.PHONY: test test-verilator test-icarus lint python-test versions clean \
	synth-estimate synth-intra-estimate synth-planar-estimate \
	synth-sad-estimate synth-transform-estimate synth-inverse-transform-estimate \
	synth-quant-estimate synth-qp-profile-estimate synth-reconstruct-estimate \
	synth-tu-loop-estimate synth-coefficient-scan-estimate synth-last-sig-estimate \
	synth-significance-estimate synth-level-bins-estimate \
	synth-syntax-arbiter-estimate synth-syntax-controller-estimate synth-coefficient-pingpong-estimate synth-context-init-estimate synth-coefficient-cabac-estimate synth-cabac-bin-step-estimate synth-cabac-context-estimate synth-cabac-encoder-estimate \
	test-byte-verilator test-intra-verilator test-planar-verilator \
	test-sad-verilator test-transform-verilator test-inverse-transform-verilator \
	test-quant-verilator test-qp-profile-verilator test-reconstruct-verilator \
	test-tu-loop-verilator test-coefficient-scan-verilator test-last-sig-verilator \
	test-significance-verilator test-level-bins-verilator \
	test-syntax-arbiter-verilator test-syntax-controller-verilator test-coefficient-pingpong-verilator test-context-init-verilator test-coefficient-cabac-verilator test-cabac-bin-step-verilator test-cabac-encoder-verilator \
	test-byte-icarus test-intra-icarus test-planar-icarus \
	test-sad-icarus test-transform-icarus test-inverse-transform-icarus \
	test-quant-icarus test-qp-profile-icarus test-reconstruct-icarus \
	test-tu-loop-icarus test-coefficient-scan-icarus test-last-sig-icarus \
	test-significance-icarus test-level-bins-icarus \
	test-syntax-arbiter-icarus test-syntax-controller-icarus test-coefficient-pingpong-icarus test-context-init-icarus test-cabac-bin-step-icarus test-cabac-encoder-icarus

.PHONY: test-nal-writer-verilator test-nal-writer-icarus synth-nal-writer-estimate test-parameter-sets-verilator test-parameter-sets-icarus synth-parameter-sets-estimate generate-parameter-sets test-slice-header-verilator test-slice-header-fullhd-verilator test-slice-header-icarus synth-slice-header-estimate test-slice-nal-verilator test-slice-nal-fullhd-verilator test-slice-nal-icarus synth-slice-nal-estimate

test: lint python-test test-verilator test-icarus

test-verilator: test-camera-yuv420p-verilator test-luma-pixel-ctu-nal-verilator test-intra-frontend-verilator test-reference-line-verilator test-luma-ctu-nal-verilator test-tu-cabac-bridge-verilator test-idr-ctu-nal-verilator test-ctu-cabac-verilator test-ctu-scheduler-verilator test-cu-prefix-verilator test-byte-verilator test-intra-verilator test-planar-verilator test-sad-verilator test-transform-verilator test-inverse-transform-verilator test-quant-verilator test-qp-profile-verilator test-reconstruct-verilator test-tu-loop-verilator test-coefficient-scan-verilator test-last-sig-verilator test-significance-verilator test-level-bins-verilator test-syntax-arbiter-verilator test-syntax-controller-verilator test-coefficient-pingpong-verilator test-context-init-verilator test-coefficient-cabac-verilator test-cabac-bin-step-verilator test-cabac-encoder-verilator test-nal-writer-verilator test-parameter-sets-verilator test-slice-header-verilator test-slice-header-fullhd-verilator test-slice-nal-verilator test-slice-nal-fullhd-verilator

.PHONY: test-cu-prefix-verilator test-cu-prefix-icarus synth-cu-prefix-estimate generate-context-init test-ctu-scheduler-verilator test-ctu-scheduler-icarus synth-ctu-scheduler-estimate test-ctu-cabac-verilator synth-ctu-cabac-estimate test-idr-ctu-nal-verilator synth-idr-ctu-nal-estimate test-tu-cabac-bridge-verilator synth-tu-cabac-bridge-estimate test-luma-ctu-nal-verilator synth-luma-ctu-nal-estimate
.PHONY: test-intra-frontend-verilator test-reference-line-verilator test-luma-pixel-ctu-nal-verilator synth-intra-frontend-estimate synth-reference-line-estimate synth-luma-pixel-ctu-nal-estimate test-camera-yuv420p-verilator synth-camera-yuv420p-estimate

test-camera-yuv420p-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_camera_yuv420p_ingress \
		MODULE=test_hevc_camera_yuv420p_ingress \
		SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/hevc_camera_yuv420p_ingress_32x32 \
		EXTRA_ARGS="-GFRAME_WIDTH=32 -GFRAME_HEIGHT=32" \
		VERILOG_SOURCES="$(CAMERA_YUV420P_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_camera_yuv420p_ingress_32x32/results.xml

test-intra-frontend-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_intra_frontend16 \
		MODULE=test_hevc_intra_frontend16 \
		VERILOG_SOURCES="$(INTRA_FRONTEND_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_intra_frontend16/results.xml

test-reference-line-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_luma_reference_line_store \
		MODULE=test_hevc_luma_reference_line_store \
		VERILOG_SOURCES="$(REFERENCE_LINE_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_luma_reference_line_store/results.xml

test-luma-pixel-ctu-nal-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_luma_pixel_ctu64_idr_nal \
		MODULE=test_hevc_luma_pixel_ctu64_idr_nal \
		SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/hevc_luma_pixel_ctu64_idr_nal_1x1 \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		HEVC_SLICE_HEADER_PARAMETERS="-GCTU_COLUMNS=1 -GCTU_ROWS=1" \
		VERILOG_SOURCES="$(PIXEL_LUMA_CTU_NAL_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_luma_pixel_ctu64_idr_nal_1x1/results.xml

test-byte-verilator:
	$(MAKE) -C sim SIM=verilator
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/byte_to_nibble/results.xml

test-intra-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_intra_dc16 \
		MODULE=test_hevc_intra_dc16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_dc16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_intra_dc16/results.xml

test-planar-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_intra_planar16 \
		MODULE=test_hevc_intra_planar16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_planar16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_intra_planar16/results.xml

test-sad-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_intra_sad_select16 \
		MODULE=test_hevc_intra_sad_select16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_sad_select16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_intra_sad_select16/results.xml

test-transform-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_forward_transform16 \
		MODULE=test_hevc_forward_transform16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_forward_transform16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_forward_transform16/results.xml

test-inverse-transform-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_inverse_transform16 \
		MODULE=test_hevc_inverse_transform16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_inverse_transform16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_inverse_transform16/results.xml

test-reconstruct-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_reconstruct \
		MODULE=test_hevc_reconstruct \
		VERILOG_SOURCES=../rtl/hevc/hevc_reconstruct.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_reconstruct/results.xml

test-quant-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_quant_dequant16 \
		MODULE=test_hevc_quant_dequant16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_quant_dequant16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_quant_dequant16/results.xml

test-qp-profile-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_qp_profile \
		MODULE=test_hevc_qp_profile \
		VERILOG_SOURCES=../rtl/hevc/hevc_qp_profile.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_qp_profile/results.xml

test-tu-loop-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_tu16_reconstruction_loop \
		MODULE=test_hevc_tu16_reconstruction_loop \
		VERILOG_SOURCES="../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_prediction_buffer16.sv ../rtl/hevc/hevc_forward_transform16.sv ../rtl/hevc/hevc_qp_profile.sv ../rtl/hevc/hevc_quant_dequant16.sv ../rtl/hevc/hevc_inverse_transform16.sv ../rtl/hevc/hevc_reconstruct.sv ../rtl/hevc/hevc_tu16_reconstruction_loop.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_tu16_reconstruction_loop/results.xml

test-coefficient-scan-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_scan16 \
		MODULE=test_hevc_coefficient_scan16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_scan16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_scan16/results.xml

test-level-bins-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_level_bins16 \
		MODULE=test_hevc_coefficient_level_bins16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_coefficient_level_bins16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_level_bins16/results.xml

test-syntax-arbiter-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_syntax_arbiter16 \
		MODULE=test_hevc_coefficient_syntax_arbiter16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_coefficient_syntax_arbiter16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_syntax_arbiter16/results.xml

test-syntax-controller-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_syntax16 \
		MODULE=test_hevc_coefficient_syntax16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_pingpong16.sv ../rtl/hevc/hevc_last_sig_bins16.sv ../rtl/hevc/hevc_significance_bins16.sv ../rtl/hevc/hevc_coefficient_level_bins16.sv ../rtl/hevc/hevc_coefficient_syntax_arbiter16.sv ../rtl/hevc/hevc_coefficient_syntax16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_syntax16/results.xml

test-coefficient-pingpong-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_pingpong16 \
		MODULE=test_hevc_coefficient_pingpong16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_pingpong16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_pingpong16/results.xml

test-context-init-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_context_init \
		MODULE=test_hevc_coefficient_context_init \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		VERILOG_SOURCES="$(CONTEXT_INIT_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_context_init/results.xml

test-coefficient-cabac-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_coefficient_cabac16 \
		MODULE=test_hevc_coefficient_cabac16 \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		VERILOG_SOURCES="$(COEFFICIENT_CABAC_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_coefficient_cabac16/results.xml

test-cabac-bin-step-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_cabac_bin_step \
		MODULE=test_hevc_cabac_bin_step \
		VERILOG_SOURCES=../rtl/hevc/hevc_cabac_bin_step.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_cabac_bin_step/results.xml

test-cabac-encoder-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_cabac_encoder \
		MODULE=test_hevc_cabac_encoder \
		VERILOG_SOURCES="../rtl/hevc/hevc_cabac_context_ram.sv ../rtl/hevc/hevc_cabac_bin_step.sv ../rtl/hevc/hevc_cabac_encoder.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_cabac_encoder/results.xml

test-significance-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_significance_bins16 \
		MODULE=test_hevc_significance_bins16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_significance_bins16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_significance_bins16/results.xml

test-last-sig-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_last_sig_bins16 \
		MODULE=test_hevc_last_sig_bins16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_last_sig_bins16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_last_sig_bins16/results.xml

test-icarus: test-ctu-scheduler-icarus test-cu-prefix-icarus test-byte-icarus test-intra-icarus test-planar-icarus test-sad-icarus test-transform-icarus test-inverse-transform-icarus test-quant-icarus test-qp-profile-icarus test-reconstruct-icarus test-tu-loop-icarus test-coefficient-scan-icarus test-last-sig-icarus test-significance-icarus test-level-bins-icarus test-syntax-arbiter-icarus test-syntax-controller-icarus test-coefficient-pingpong-icarus test-context-init-icarus test-cabac-bin-step-icarus test-cabac-encoder-icarus test-nal-writer-icarus test-parameter-sets-icarus test-slice-header-icarus test-slice-nal-icarus

test-byte-icarus:
	$(MAKE) -C sim SIM=icarus
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/byte_to_nibble/results.xml

test-intra-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_intra_dc16 \
		MODULE=test_hevc_intra_dc16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_dc16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_intra_dc16/results.xml

test-planar-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_intra_planar16 \
		MODULE=test_hevc_intra_planar16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_planar16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_intra_planar16/results.xml

test-sad-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_intra_sad_select16 \
		MODULE=test_hevc_intra_sad_select16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_sad_select16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_intra_sad_select16/results.xml

test-transform-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_forward_transform16 \
		MODULE=test_hevc_forward_transform16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_forward_transform16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_forward_transform16/results.xml

test-inverse-transform-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_inverse_transform16 \
		MODULE=test_hevc_inverse_transform16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_inverse_transform16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_inverse_transform16/results.xml

test-reconstruct-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_reconstruct \
		MODULE=test_hevc_reconstruct \
		VERILOG_SOURCES=../rtl/hevc/hevc_reconstruct.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_reconstruct/results.xml

test-quant-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_quant_dequant16 \
		MODULE=test_hevc_quant_dequant16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_quant_dequant16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_quant_dequant16/results.xml

test-qp-profile-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_qp_profile \
		MODULE=test_hevc_qp_profile \
		VERILOG_SOURCES=../rtl/hevc/hevc_qp_profile.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_qp_profile/results.xml

test-tu-loop-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_tu16_reconstruction_loop \
		MODULE=test_hevc_tu16_reconstruction_loop \
		VERILOG_SOURCES="../rtl/hevc/hevc_transform_buffer16.sv ../rtl/hevc/hevc_prediction_buffer16.sv ../rtl/hevc/hevc_forward_transform16.sv ../rtl/hevc/hevc_qp_profile.sv ../rtl/hevc/hevc_quant_dequant16.sv ../rtl/hevc/hevc_inverse_transform16.sv ../rtl/hevc/hevc_reconstruct.sv ../rtl/hevc/hevc_tu16_reconstruction_loop.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_tu16_reconstruction_loop/results.xml

test-coefficient-scan-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_coefficient_scan16 \
		MODULE=test_hevc_coefficient_scan16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_scan16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_coefficient_scan16/results.xml

test-level-bins-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_coefficient_level_bins16 \
		MODULE=test_hevc_coefficient_level_bins16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_coefficient_level_bins16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_coefficient_level_bins16/results.xml

test-syntax-arbiter-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_coefficient_syntax_arbiter16 \
		MODULE=test_hevc_coefficient_syntax_arbiter16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_coefficient_syntax_arbiter16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_coefficient_syntax_arbiter16/results.xml

test-syntax-controller-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_coefficient_syntax16 \
		MODULE=test_hevc_coefficient_syntax16 \
		TESTCASE="dc_only_replays_into_levels_without_significance_bins,all_zero_block_bypasses_coefficient_syntax,missing_final_marker_is_reported" \
		VERILOG_SOURCES="../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_pingpong16.sv ../rtl/hevc/hevc_last_sig_bins16.sv ../rtl/hevc/hevc_significance_bins16.sv ../rtl/hevc/hevc_coefficient_level_bins16.sv ../rtl/hevc/hevc_coefficient_syntax_arbiter16.sv ../rtl/hevc/hevc_coefficient_syntax16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_coefficient_syntax16/results.xml

test-coefficient-pingpong-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_coefficient_pingpong16 \
		MODULE=test_hevc_coefficient_pingpong16 \
		VERILOG_SOURCES="../rtl/hevc/hevc_coefficient_buffer16.sv ../rtl/hevc/hevc_coefficient_pingpong16.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_coefficient_pingpong16/results.xml

test-context-init-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_coefficient_context_init \
		MODULE=test_hevc_coefficient_context_init \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		VERILOG_SOURCES="$(CONTEXT_INIT_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_coefficient_context_init/results.xml

test-cabac-bin-step-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_cabac_bin_step \
		MODULE=test_hevc_cabac_bin_step \
		VERILOG_SOURCES=../rtl/hevc/hevc_cabac_bin_step.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_cabac_bin_step/results.xml

test-cabac-encoder-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_cabac_encoder \
		MODULE=test_hevc_cabac_encoder \
		VERILOG_SOURCES="../rtl/hevc/hevc_cabac_context_ram.sv ../rtl/hevc/hevc_cabac_bin_step.sv ../rtl/hevc/hevc_cabac_encoder.sv"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_cabac_encoder/results.xml

test-significance-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_significance_bins16 \
		MODULE=test_hevc_significance_bins16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_significance_bins16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_significance_bins16/results.xml

test-last-sig-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_last_sig_bins16 \
		MODULE=test_hevc_last_sig_bins16 \
		VERILOG_SOURCES=../rtl/hevc/hevc_last_sig_bins16.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_last_sig_bins16/results.xml

lint:
	verilator --lint-only --Wall --top-module hevc_camera_yuv420p_ingress $(CAMERA_YUV420P_SOURCES:../%=%)
	verilator --lint-only --Wall rtl/common/byte_to_nibble.sv
	verilator --lint-only --Wall rtl/hevc/hevc_intra_dc16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_intra_planar16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_intra_sad_select16.sv
	verilator --lint-only --Wall --top-module hevc_intra_frontend16 $(INTRA_FRONTEND_SOURCES:../%=%)
	verilator --lint-only --Wall --top-module hevc_luma_reference_line_store $(REFERENCE_LINE_SOURCES:../%=%)
	verilator --lint-only --Wall --top-module hevc_luma_pixel_ctu64_idr_nal $(PIXEL_LUMA_CTU_NAL_SOURCES:../%=%)
	verilator --lint-only --Wall rtl/hevc/hevc_intra_cu16_prefix.sv
	verilator --lint-only --Wall --top-module hevc_ctu64_syntax_scheduler $(CTU_SYNTAX_SOURCES:../%=%)
	verilator --lint-only --Wall --top-module hevc_ctu64_cabac $(CTU_CABAC_SOURCES:../%=%)
	verilator --lint-only --Wall --top-module hevc_idr_ctu64_nal $(IDR_CTU_NAL_SOURCES:../%=%)
	verilator --lint-only --Wall --top-module hevc_tu16_cabac_bridge $(TU_CABAC_BRIDGE_SOURCES:../%=%)
	verilator --lint-only --Wall --top-module hevc_luma_ctu64_idr_nal $(LUMA_CTU_NAL_SOURCES:../%=%)
	verilator --lint-only --Wall rtl/hevc/hevc_transform_buffer16.sv rtl/hevc/hevc_forward_transform16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_transform_buffer16.sv rtl/hevc/hevc_inverse_transform16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_quant_dequant16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_qp_profile.sv
	verilator --lint-only --Wall rtl/hevc/hevc_reconstruct.sv
	verilator --lint-only --Wall rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_scan16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_last_sig_bins16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_significance_bins16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_coefficient_level_bins16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_coefficient_syntax_arbiter16.sv
	verilator --lint-only --Wall rtl/hevc/hevc_cabac_bin_step.sv
	verilator --lint-only --Wall --top-module hevc_cabac_encoder rtl/hevc/hevc_cabac_context_ram.sv rtl/hevc/hevc_cabac_bin_step.sv rtl/hevc/hevc_cabac_encoder.sv
	verilator --lint-only --Wall --top-module hevc_coefficient_syntax16 rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_pingpong16.sv rtl/hevc/hevc_last_sig_bins16.sv rtl/hevc/hevc_significance_bins16.sv rtl/hevc/hevc_coefficient_level_bins16.sv rtl/hevc/hevc_coefficient_syntax_arbiter16.sv rtl/hevc/hevc_coefficient_syntax16.sv
	verilator --lint-only --Wall --top-module hevc_coefficient_pingpong16 rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_pingpong16.sv
	verilator --lint-only --Wall --top-module hevc_coefficient_context_map rtl/hevc/hevc_coefficient_context_map.sv
	verilator --lint-only --Wall --top-module hevc_coefficient_context_init rtl/hevc/hevc_coefficient_context_init_rom.sv rtl/hevc/hevc_coefficient_context_init.sv
	verilator --lint-only --Wall --top-module hevc_coefficient_cabac16 rtl/hevc/hevc_coefficient_context_init_rom.sv rtl/hevc/hevc_coefficient_context_init.sv rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_pingpong16.sv rtl/hevc/hevc_last_sig_bins16.sv rtl/hevc/hevc_significance_bins16.sv rtl/hevc/hevc_coefficient_level_bins16.sv rtl/hevc/hevc_coefficient_syntax_arbiter16.sv rtl/hevc/hevc_coefficient_syntax16.sv rtl/hevc/hevc_coefficient_context_map.sv rtl/hevc/hevc_cabac_context_ram.sv rtl/hevc/hevc_cabac_bin_step.sv rtl/hevc/hevc_cabac_encoder.sv rtl/hevc/hevc_coefficient_cabac16.sv
	verilator --lint-only --Wall --top-module hevc_tu16_reconstruction_loop rtl/hevc/hevc_transform_buffer16.sv rtl/hevc/hevc_prediction_buffer16.sv rtl/hevc/hevc_forward_transform16.sv rtl/hevc/hevc_qp_profile.sv rtl/hevc/hevc_quant_dequant16.sv rtl/hevc/hevc_inverse_transform16.sv rtl/hevc/hevc_reconstruct.sv rtl/hevc/hevc_tu16_reconstruction_loop.sv
	verilator --lint-only --Wall rtl/hevc/hevc_nal_writer.sv
	verilator --lint-only --Wall --top-module hevc_parameter_set_streamer rtl/hevc/hevc_nal_writer.sv rtl/hevc/hevc_parameter_set_rom.sv rtl/hevc/hevc_parameter_set_streamer.sv
	verilator --lint-only --Wall rtl/hevc/hevc_idr_slice_header.sv
	verilator --lint-only --Wall -GCTU_COLUMNS=30 -GCTU_ROWS=16 rtl/hevc/hevc_idr_slice_header.sv
	verilator --lint-only --Wall --top-module hevc_idr_slice_nal rtl/hevc/hevc_nal_writer.sv rtl/hevc/hevc_idr_slice_header.sv rtl/hevc/hevc_idr_slice_nal.sv
	verilator --lint-only --Wall --top-module hevc_idr_slice_nal -GCTU_COLUMNS=30 -GCTU_ROWS=16 rtl/hevc/hevc_nal_writer.sv rtl/hevc/hevc_idr_slice_header.sv rtl/hevc/hevc_idr_slice_nal.sv

test-cu-prefix-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_intra_cu16_prefix \
		MODULE=test_hevc_intra_cu16_prefix \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_cu16_prefix.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_intra_cu16_prefix/results.xml

test-cu-prefix-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_intra_cu16_prefix \
		MODULE=test_hevc_intra_cu16_prefix \
		VERILOG_SOURCES=../rtl/hevc/hevc_intra_cu16_prefix.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_intra_cu16_prefix/results.xml

synth-cu-prefix-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_intra_cu16_prefix.sv; hierarchy -top hevc_intra_cu16_prefix; synth -top hevc_intra_cu16_prefix -noabc; abc -lut 4; clean; stat'

test-ctu-scheduler-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_ctu64_syntax_scheduler \
		MODULE=test_hevc_ctu64_syntax_scheduler \
		VERILOG_SOURCES="$(CTU_SYNTAX_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_ctu64_syntax_scheduler/results.xml

test-ctu-scheduler-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_ctu64_syntax_scheduler \
		MODULE=test_hevc_ctu64_syntax_scheduler \
		VERILOG_SOURCES="$(CTU_SYNTAX_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_ctu64_syntax_scheduler/results.xml

synth-ctu-scheduler-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_intra_cu16_prefix.sv rtl/hevc/hevc_ctu64_syntax_scheduler.sv; hierarchy -top hevc_ctu64_syntax_scheduler; blackbox hevc_intra_cu16_prefix; synth -top hevc_ctu64_syntax_scheduler -noabc; abc -lut 4; clean; stat'

test-ctu-cabac-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_ctu64_cabac \
		MODULE=test_hevc_ctu64_cabac \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		VERILOG_SOURCES="$(CTU_CABAC_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_ctu64_cabac/results.xml

synth-ctu-cabac-estimate:
	yosys -Q -p 'read_verilog -sv $(CTU_CABAC_SOURCES:../%=%); hierarchy -top hevc_ctu64_cabac; blackbox hevc_coefficient_context_init hevc_coefficient_syntax16 hevc_ctu64_syntax_scheduler hevc_cabac_encoder; synth -top hevc_ctu64_cabac -noabc; abc -lut 4; clean; stat'

test-tu-cabac-bridge-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_tu16_cabac_bridge \
		MODULE=test_hevc_tu16_cabac_bridge \
		VERILOG_SOURCES="$(TU_CABAC_BRIDGE_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_tu16_cabac_bridge/results.xml

synth-tu-cabac-bridge-estimate:
	yosys -Q -p 'read_verilog -sv $(TU_CABAC_BRIDGE_SOURCES:../%=%); blackbox hevc_tu16_reconstruction_loop hevc_coefficient_buffer16; hierarchy -top hevc_tu16_cabac_bridge; synth -top hevc_tu16_cabac_bridge -noabc; abc -lut 4; clean; stat'

test-luma-ctu-nal-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_luma_ctu64_idr_nal \
		MODULE=test_hevc_luma_ctu64_idr_nal \
		SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/hevc_luma_ctu64_idr_nal_1x1 \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		HEVC_SLICE_HEADER_PARAMETERS="-GCTU_COLUMNS=1 -GCTU_ROWS=1" \
		VERILOG_SOURCES="$(LUMA_CTU_NAL_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_luma_ctu64_idr_nal_1x1/results.xml

synth-luma-ctu-nal-estimate:
	yosys -Q -p 'read_verilog -sv $(LUMA_CTU_NAL_SOURCES:../%=%); blackbox hevc_tu16_cabac_bridge hevc_idr_ctu64_nal; hierarchy -top hevc_luma_ctu64_idr_nal; synth -top hevc_luma_ctu64_idr_nal -noabc; abc -lut 4; clean; stat'

test-idr-ctu-nal-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_idr_ctu64_nal \
		MODULE=test_hevc_idr_ctu64_nal \
		SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/hevc_idr_ctu64_nal_2x1 \
		HEVC_CONTEXT_INIT_DEFINE='$(CONTEXT_INIT_DEFINE)' \
		HEVC_SLICE_HEADER_PARAMETERS="-GCTU_COLUMNS=2 -GCTU_ROWS=1" \
		VERILOG_SOURCES="$(IDR_CTU_NAL_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_idr_ctu64_nal_2x1/results.xml

synth-idr-ctu-nal-estimate:
	yosys -Q -p 'read_verilog -sv $(IDR_CTU_NAL_SOURCES:../%=%); blackbox hevc_ctu64_cabac hevc_idr_slice_nal; hierarchy -top hevc_idr_ctu64_nal; synth -top hevc_idr_ctu64_nal -noabc; abc -lut 4; clean; stat'

generate-context-init:
	PYTHONPATH=../hevc_experiment $(VENV)/bin/python scripts/generate_hevc_context_init.py \
		--output rtl/hevc/hevc_coefficient_context_init.hex

python-test:
	PYTHONPATH=../hevc_experiment $(VENV)/bin/python -m unittest discover \
		-s ../hevc_experiment/tests -v

versions:
	verilator --version
	iverilog -V | head -n 2
	yosys --version
	$(VENV)/bin/python -c "import cocotb; print('cocotb', cocotb.__version__)"

synth-estimate: synth-camera-yuv420p-estimate synth-luma-pixel-ctu-nal-estimate synth-intra-frontend-estimate synth-reference-line-estimate synth-luma-ctu-nal-estimate synth-tu-cabac-bridge-estimate synth-idr-ctu-nal-estimate synth-ctu-cabac-estimate synth-ctu-scheduler-estimate synth-cu-prefix-estimate synth-intra-estimate synth-planar-estimate synth-sad-estimate synth-transform-estimate synth-inverse-transform-estimate synth-quant-estimate synth-qp-profile-estimate synth-reconstruct-estimate synth-tu-loop-estimate synth-coefficient-scan-estimate synth-last-sig-estimate synth-significance-estimate synth-level-bins-estimate synth-syntax-arbiter-estimate synth-syntax-controller-estimate synth-coefficient-pingpong-estimate synth-context-init-estimate synth-coefficient-cabac-estimate synth-cabac-bin-step-estimate synth-cabac-context-estimate synth-cabac-encoder-estimate synth-nal-writer-estimate synth-parameter-sets-estimate synth-slice-header-estimate synth-slice-nal-estimate

synth-cabac-bin-step-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_cabac_bin_step.sv; hierarchy -top hevc_cabac_bin_step; synth -top hevc_cabac_bin_step -noabc; abc -lut 4; clean; stat'

synth-cabac-context-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_cabac_context_ram.sv; hierarchy -top hevc_cabac_context_ram; proc; memory -nomap; opt; stat'

synth-cabac-encoder-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_cabac_context_ram.sv rtl/hevc/hevc_cabac_bin_step.sv rtl/hevc/hevc_cabac_encoder.sv; hierarchy -top hevc_cabac_encoder; blackbox hevc_cabac_context_ram hevc_cabac_bin_step; synth -top hevc_cabac_encoder -noabc; abc -lut 4; clean; stat'

synth-camera-yuv420p-estimate:
	yosys -Q -p 'read_verilog -sv $(CAMERA_YUV420P_SOURCES:../%=%); hierarchy -top hevc_camera_yuv420p_ingress; proc; memory -nomap; opt; stat'

synth-intra-frontend-estimate:
	yosys -Q -p 'read_verilog -sv $(INTRA_FRONTEND_SOURCES:../%=%); hierarchy -top hevc_intra_frontend16; blackbox hevc_intra_dc16 hevc_intra_planar16 hevc_intra_sad_select16 hevc_prediction_buffer16; synth -top hevc_intra_frontend16 -noabc; abc -lut 4; clean; stat'

synth-reference-line-estimate:
	yosys -Q -p 'read_verilog -sv $(REFERENCE_LINE_SOURCES:../%=%); hierarchy -top hevc_luma_reference_line_store; proc; memory -nomap; opt; stat'

synth-luma-pixel-ctu-nal-estimate:
	yosys -Q -p 'read_verilog -sv $(PIXEL_LUMA_CTU_NAL_SOURCES:../%=%); blackbox hevc_luma_ctu64_idr_nal hevc_intra_frontend16 hevc_luma_reference_line_store; hierarchy -top hevc_luma_pixel_ctu64_idr_nal; synth -top hevc_luma_pixel_ctu64_idr_nal -noabc; abc -lut 4; clean; stat'

synth-intra-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_intra_dc16.sv; hierarchy -top hevc_intra_dc16; synth -top hevc_intra_dc16 -noabc; abc -lut 4; clean; stat'

synth-planar-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_intra_planar16.sv; hierarchy -top hevc_intra_planar16; synth -top hevc_intra_planar16 -noabc; abc -lut 4; clean; stat'

synth-sad-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_intra_sad_select16.sv; hierarchy -top hevc_intra_sad_select16; synth -top hevc_intra_sad_select16 -noabc; abc -lut 4; clean; stat'

synth-transform-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_transform_buffer16.sv rtl/hevc/hevc_forward_transform16.sv; hierarchy -top hevc_forward_transform16; proc; memory -nomap; opt; stat'

synth-inverse-transform-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_transform_buffer16.sv rtl/hevc/hevc_inverse_transform16.sv; hierarchy -top hevc_inverse_transform16; proc; memory -nomap; opt; stat'

synth-quant-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_quant_dequant16.sv; hierarchy -top hevc_quant_dequant16; proc; memory -nomap; opt; stat'

synth-qp-profile-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_qp_profile.sv; hierarchy -top hevc_qp_profile; synth -top hevc_qp_profile -noabc; abc -lut 4; clean; stat'

synth-reconstruct-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_reconstruct.sv; hierarchy -top hevc_reconstruct; synth -top hevc_reconstruct -noabc; abc -lut 4; clean; stat'

synth-tu-loop-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_transform_buffer16.sv rtl/hevc/hevc_prediction_buffer16.sv rtl/hevc/hevc_forward_transform16.sv rtl/hevc/hevc_qp_profile.sv rtl/hevc/hevc_quant_dequant16.sv rtl/hevc/hevc_inverse_transform16.sv rtl/hevc/hevc_reconstruct.sv rtl/hevc/hevc_tu16_reconstruction_loop.sv; hierarchy -top hevc_tu16_reconstruction_loop; proc; memory -nomap; opt; stat'

synth-coefficient-scan-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_scan16.sv; hierarchy -top hevc_coefficient_scan16; proc; memory -nomap; opt; stat'

synth-last-sig-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_last_sig_bins16.sv; hierarchy -top hevc_last_sig_bins16; synth -top hevc_last_sig_bins16 -noabc; abc -lut 4; clean; stat'

synth-significance-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_significance_bins16.sv; hierarchy -top hevc_significance_bins16; synth -top hevc_significance_bins16 -noabc; abc -lut 4; clean; stat'

synth-level-bins-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_level_bins16.sv; hierarchy -top hevc_coefficient_level_bins16; synth -top hevc_coefficient_level_bins16 -noabc; abc -lut 4; clean; stat'

synth-syntax-arbiter-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_syntax_arbiter16.sv; hierarchy -top hevc_coefficient_syntax_arbiter16; synth -top hevc_coefficient_syntax_arbiter16 -noabc; abc -lut 4; clean; stat'

synth-syntax-controller-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_pingpong16.sv rtl/hevc/hevc_last_sig_bins16.sv rtl/hevc/hevc_significance_bins16.sv rtl/hevc/hevc_coefficient_level_bins16.sv rtl/hevc/hevc_coefficient_syntax_arbiter16.sv rtl/hevc/hevc_coefficient_syntax16.sv; hierarchy -top hevc_coefficient_syntax16; blackbox hevc_coefficient_pingpong16 hevc_last_sig_bins16 hevc_significance_bins16 hevc_coefficient_level_bins16 hevc_coefficient_syntax_arbiter16; synth -top hevc_coefficient_syntax16 -noabc; abc -lut 4; clean; stat'

synth-coefficient-pingpong-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_pingpong16.sv; hierarchy -top hevc_coefficient_pingpong16; blackbox hevc_coefficient_buffer16; synth -top hevc_coefficient_pingpong16 -noabc; abc -lut 4; clean; stat'

synth-context-init-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_context_init_rom.sv rtl/hevc/hevc_coefficient_context_init.sv; hierarchy -top hevc_coefficient_context_init; blackbox hevc_coefficient_context_init_rom; synth -top hevc_coefficient_context_init -noabc; abc -lut 4; clean; stat'
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_context_init_rom.sv; hierarchy -top hevc_coefficient_context_init_rom; proc; memory -nomap; opt; stat'

synth-coefficient-cabac-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_coefficient_context_init_rom.sv rtl/hevc/hevc_coefficient_context_init.sv rtl/hevc/hevc_coefficient_buffer16.sv rtl/hevc/hevc_coefficient_pingpong16.sv rtl/hevc/hevc_last_sig_bins16.sv rtl/hevc/hevc_significance_bins16.sv rtl/hevc/hevc_coefficient_level_bins16.sv rtl/hevc/hevc_coefficient_syntax_arbiter16.sv rtl/hevc/hevc_coefficient_syntax16.sv rtl/hevc/hevc_coefficient_context_map.sv rtl/hevc/hevc_cabac_context_ram.sv rtl/hevc/hevc_cabac_bin_step.sv rtl/hevc/hevc_cabac_encoder.sv rtl/hevc/hevc_coefficient_cabac16.sv; hierarchy -top hevc_coefficient_cabac16; blackbox hevc_coefficient_context_init hevc_coefficient_syntax16 hevc_cabac_encoder; synth -top hevc_coefficient_cabac16 -noabc; abc -lut 4; clean; stat'

clean:
	rm -rf /tmp/hd-zero-fpga-sim

test-nal-writer-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_nal_writer \
		MODULE=test_hevc_nal_writer \
		VERILOG_SOURCES=../rtl/hevc/hevc_nal_writer.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_nal_writer/results.xml

test-nal-writer-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_nal_writer \
		MODULE=test_hevc_nal_writer \
		VERILOG_SOURCES=../rtl/hevc/hevc_nal_writer.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_nal_writer/results.xml

synth-nal-writer-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_nal_writer.sv; hierarchy -top hevc_nal_writer; synth -top hevc_nal_writer -noabc; abc -lut 4; clean; stat'

test-parameter-sets-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_parameter_set_streamer \
		MODULE=test_hevc_parameter_set_streamer \
		HEVC_PARAMETER_SET_DEFINE='$(PARAMETER_SET_DEFINE)' \
		VERILOG_SOURCES="$(PARAMETER_SET_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_parameter_set_streamer/results.xml

test-parameter-sets-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_parameter_set_streamer \
		MODULE=test_hevc_parameter_set_streamer \
		HEVC_PARAMETER_SET_DEFINE='$(PARAMETER_SET_DEFINE)' \
		VERILOG_SOURCES="$(PARAMETER_SET_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_parameter_set_streamer/results.xml

synth-parameter-sets-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_nal_writer.sv rtl/hevc/hevc_parameter_set_rom.sv rtl/hevc/hevc_parameter_set_streamer.sv; hierarchy -top hevc_parameter_set_streamer; blackbox hevc_parameter_set_rom; synth -top hevc_parameter_set_streamer -noabc; abc -lut 4; clean; stat'
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_parameter_set_rom.sv; hierarchy -top hevc_parameter_set_rom; proc; memory -nomap; opt; stat'

generate-parameter-sets:
	PYTHONPATH=../hevc_experiment $(VENV)/bin/python scripts/generate_hevc_parameter_sets.py \
		--output rtl/hevc/hevc_parameter_sets.hex \
		--width $(PARAMETER_SET_WIDTH) --height $(PARAMETER_SET_HEIGHT) \
		--fps $(PARAMETER_SET_FPS)

test-slice-header-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_idr_slice_header \
		MODULE=test_hevc_idr_slice_header \
		VERILOG_SOURCES=../rtl/hevc/hevc_idr_slice_header.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_idr_slice_header/results.xml

test-slice-header-fullhd-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_idr_slice_header \
		MODULE=test_hevc_idr_slice_header \
		CTU_COLUMNS=30 CTU_ROWS=16 \
		SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/hevc_idr_slice_header_fullhd \
		HEVC_SLICE_HEADER_PARAMETERS="-GCTU_COLUMNS=30 -GCTU_ROWS=16" \
		VERILOG_SOURCES=../rtl/hevc/hevc_idr_slice_header.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_idr_slice_header_fullhd/results.xml

test-slice-header-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_idr_slice_header \
		MODULE=test_hevc_idr_slice_header \
		VERILOG_SOURCES=../rtl/hevc/hevc_idr_slice_header.sv
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_idr_slice_header/results.xml

synth-slice-header-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_idr_slice_header.sv; hierarchy -top hevc_idr_slice_header; synth -top hevc_idr_slice_header -noabc; abc -lut 4; clean; stat'

test-slice-nal-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_idr_slice_nal \
		MODULE=test_hevc_idr_slice_nal \
		VERILOG_SOURCES="$(SLICE_NAL_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_idr_slice_nal/results.xml

test-slice-nal-fullhd-verilator:
	$(MAKE) -C sim SIM=verilator TOPLEVEL=hevc_idr_slice_nal \
		MODULE=test_hevc_idr_slice_nal \
		CTU_COLUMNS=30 CTU_ROWS=16 \
		SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/hevc_idr_slice_nal_fullhd \
		HEVC_SLICE_HEADER_PARAMETERS="-GCTU_COLUMNS=30 -GCTU_ROWS=16" \
		VERILOG_SOURCES="$(SLICE_NAL_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/verilator/hevc_idr_slice_nal_fullhd/results.xml

test-slice-nal-icarus:
	$(MAKE) -C sim SIM=icarus TOPLEVEL=hevc_idr_slice_nal \
		MODULE=test_hevc_idr_slice_nal \
		VERILOG_SOURCES="$(SLICE_NAL_SOURCES)"
	$(VENV)/bin/python scripts/check_cocotb_results.py \
		/tmp/hd-zero-fpga-sim/icarus/hevc_idr_slice_nal/results.xml

synth-slice-nal-estimate:
	yosys -Q -p 'read_verilog -sv rtl/hevc/hevc_nal_writer.sv rtl/hevc/hevc_idr_slice_header.sv rtl/hevc/hevc_idr_slice_nal.sv; blackbox hevc_nal_writer hevc_idr_slice_header; hierarchy -top hevc_idr_slice_nal; synth -top hevc_idr_slice_nal -noabc; abc -lut 4; clean; stat'
