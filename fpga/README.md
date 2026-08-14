# FPGA development environment

The portable codec RTL is tested in WSL before Efinix-specific wrappers are
added. Daily tests use Verilator and Icarus; Efinity/ModelSim remain the
integration path for generated or encrypted Efinix IP.

## Installed WSL tools

- Verilator 5.020
- Icarus Verilog 12.0
- GTKWave 3.3.116
- Yosys 0.33
- Python 3.12 virtual environment at
  `/home/dimka/.venvs/hd-zero-fpga`
- cocotb 1.9.2, pytest 9.1.1 and NumPy 2.5.2

cocotb is intentionally pinned to 1.9.2 because Ubuntu 24.04 ships Verilator
5.020; cocotb 2.x requires a newer Verilator.

To recreate the Python environment:

```bash
python3 -m venv /home/dimka/.venvs/hd-zero-fpga
/home/dimka/.venvs/hd-zero-fpga/bin/python -m pip install \
  -r fpga/requirements-dev.txt
```

Run every current regression from the repository root:

```bash
make -C fpga test
```

Run only one simulator:

```bash
make -C fpga test-verilator
make -C fpga test-icarus
```

Simulation build products are deliberately placed under `/tmp` because WSL
creates thousands of Verilator files much faster there than on `/mnt/c`.

## RTL boundary

`rtl/common/byte_to_nibble.sv` is the first production-oriented block. It
converts the encoder byte stream to the FPGA-to-ESP32 4-bit bus in high-nibble,
low-nibble order. Its ready/valid interface tolerates arbitrary downstream
stalls and transfers consecutive bytes without an idle cycle.

Efinix IP must later be isolated under `rtl/vendor/efinix/`. Portable codec
modules must not instantiate Efinix primitives directly.

## HEVC streaming datapath

The first standard-compatible HEVC building blocks are under `rtl/hevc/`:

- `hevc_intra_dc16.sv` loads 16 top/left reference pairs, calculates the
  normative 16x16 luma DC value, applies HEVC boundary filtering and emits one
  prediction/residual pair per accepted source pixel;
- `hevc_reconstruct.sv` adds the inverse-path residual to the prediction and
  clips the reconstructed sample to 8 bits.

Both blocks use ready/valid flow control and retain a stable output during
backpressure. The predictor stores only 32 reference bytes, not a 16x16 source
block. After its 16 reference cycles it accepts 256 pixels at one pixel per
cycle. Source pixels can therefore arrive directly from a line-window or CTU
stream.

The matching integer golden model is in
`hevc_experiment/hevc_reference/intra.py`. cocotb compares every prediction,
signed residual and reconstructed sample against it with random input gaps and
output stalls in both simulators.

Run a portable 4-input-LUT synthesis estimate with:

```bash
make -C fpga synth-estimate
```

With Yosys 0.33 the current estimate is:

| Module | LUT4 | Flip-flops | DSP | EBR |
| --- | ---: | ---: | ---: | ---: |
| `hevc_intra_dc16` | 443 | 309 | 0 | 0 |
| `hevc_reconstruct` | 35 | 9 | 0 | 0 |

This is not an Efinity place-and-route result and LUT4 counts do not map
one-to-one to Efinix logic elements. The reference arrays intentionally become
registers: they total only 256 bits and need indexed access while pixels are
streaming. The estimate is useful for regression and architecture comparisons;
final T20F169 fit and Fmax must be measured in Efinity.
