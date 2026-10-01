#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${HD_ZERO_BUILD_ROOT:-/home/dimka/hd-zero-clone-build}"
venv="${HD_ZERO_COCOTB_VENV:-/home/dimka/.venvs/hd-zero-fpga}"
toplevel="${TOPLEVEL:-custom_pixel_ctu_entropy_writer36}"
test_module="${MODULE:-test_custom_transmitter_throughput}"
sim_build="${SIM_BUILD:-/tmp/hd-zero-fpga-sim/verilator/${toplevel}}"

mkdir -p "${build_root}/fpga"
rsync -a --delete "${repo_root}/fpga/rtl/" "${build_root}/fpga/rtl/"
rsync -a --delete "${repo_root}/fpga/sim/" "${build_root}/fpga/sim/"

source "${venv}/bin/activate"
mapfile -d '' sources < <(
    find "${build_root}/fpga/rtl/custom" -maxdepth 1 -type f -name '*.sv' -print0
)

cd "${build_root}/fpga/sim"
make -s \
    SIM=verilator \
    TOPLEVEL="${toplevel}" \
    MODULE="${test_module}" \
    VERILOG_SOURCES="${sources[*]}" \
    SIM_BUILD="${sim_build}"
