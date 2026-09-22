#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rtl="$repo_root/fpga/rtl/receiver/receiver_full_idct8_32.sv"
tb="$repo_root/fpga/sim/tb_receiver_full_idct8_32_latency.sv"
out="/tmp/receiver_full_idct8_latency.vvp"

iverilog -g2012 -s tb_receiver_full_idct8_32_latency -o "$out" "$rtl" "$tb"
vvp "$out"

if [[ "${COCOTB:-0}" == "1" || "${1:-}" == "--cocotb" ]]; then
    venv="$HOME/.cache/hd-zero-cocotb-venv"
    if [[ ! -x "$venv/bin/cocotb-config" ]]; then
        echo "Missing $venv; install cocotb, pytest, numpy and pillow." >&2
        exit 2
    fi
    cd "$repo_root/fpga/sim"
    PATH="$venv/bin:/usr/local/bin:/usr/bin:/bin" make -s \
        SIM=icarus \
        TOPLEVEL=receiver_full_idct8_32 \
        MODULE=test_receiver_full_idct8_32 \
        VERILOG_SOURCES=../rtl/receiver/receiver_full_idct8_32.sv \
        SIM_BUILD=/tmp/hd-zero-fpga-sim/icarus/receiver_full_idct8_overlap
fi