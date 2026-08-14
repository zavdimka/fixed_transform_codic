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
- `hevc_intra_planar16.sv` performs normative luma reference smoothing and
  16x16 planar prediction using recurrence add/subtract operations rather than
  multipliers;
- `hevc_intra_sad_select16.sv` accumulates the absolute DC and planar residuals
  and chooses planar only when its SAD is strictly lower (DC wins ties);
- `hevc_forward_transform16.sv` performs the normative separable HEVC 16x16
  integer forward transform with 8-bit shifts 3/10 and exact rounding;
- `hevc_transform_buffer16.sv` isolates the synchronous 256x16 transpose RAM so
  Efinity can map its 4096 bits into one 5-kbit EBR;
- `hevc_qp_profile.sv` maps the discrete good/medium/poor quality selection to
  configurable QP 28/34/40 defaults;
- `hevc_quant_dequant16.sv` applies flat HEVC TU16 quantization and inverse
  quantization with explicit signed-16 saturation in a two-stage elastic pipe;
- `hevc_inverse_transform16.sv` performs the normative separable HEVC 16x16
  inverse transform with signed-16 clipping after shifts 7 and 12;
- `hevc_prediction_buffer16.sv` retains the 256 prediction bytes until inverse
  residuals return, behind an EBR-friendly synchronous interface;
- `hevc_tu16_reconstruction_loop.sv` connects forward transform, selected QP,
  quant/dequant, inverse transform and clipped reconstruction into one TU16
  controller while exposing a quantized-coefficient write tap;
- `hevc_coefficient_buffer16.sv` provides the EBR-friendly 256x16 synchronous
  coefficient RAM used by `hevc_coefficient_scan16.sv`, which emits the
  normative TU16 diagonal scan and significance metadata for future CABAC;
- `hevc_last_sig_bins16.sv` converts the last nonzero TU16 raster coordinate
  into normative luma `last_sig_coeff_x/y` prefix and suffix bin events;
- `hevc_reconstruct.sv` adds the inverse-path residual to the prediction and
  clips the reconstructed sample to 8 bits.

All blocks use ready/valid flow control and retain a stable output during
backpressure. The DC predictor stores only 32 reference bytes, not a 16x16
source block. After its 16 reference cycles it accepts 256 pixels at one pixel
per cycle.

Planar16 accepts 19 raw top/left reference pairs. Index 0 is the shared top-left
sample, indexes 1..16 border the block, index 17 is the far corner and index 18
is required to filter that corner. It also accepts one source pixel per cycle.
The source stream can be fanned out to DC and planar when both are ready; their
residuals feed the SAD selector in lockstep. The selected mode is known at the
end of the block, so a complete encoder must retain/replay the 16 source rows
for the chosen transform path. This remains within the planned 16-row buffer.
SAD is a deliberately cheap mode heuristic, not full HEVC rate-distortion
optimization; either selected mode still produces standard-compatible syntax.

The forward transform reuses one 16-channel constant-MAC engine for horizontal
and vertical passes. Ping-pong accumulator banks let it accept the first pass
at one residual per cycle while the previous row is written to transpose RAM.
It emits signed 16-bit coefficients in column-major order with explicit `(x,y)`
coordinates. With continuous input and output it takes 561 clock edges from the
first accepted residual through the last accepted coefficient. A worst-case
720p60 frame made entirely of 16x16 TUs therefore needs about 121.2 MHz before
allowing interface or scheduling margin.

The quantizer accepts and emits one coefficient per clock after its two
pipeline stages. It uses the HEVC flat scaling tables, QP quotient/remainder
form, TU16 transform shift and intra rounding bias. QP encodings outside 0..51
are carried through with `m_qp_error` asserted, so control corruption cannot
silently enter the coefficient stream.

The inverse transform consumes the dequantizer's column-major coefficient order
directly and emits row-major residuals with explicit `(x,y)` coordinates. It
uses the same 256x16 synchronous transpose RAM boundary and the same 561-cycle
no-stall block interval as the forward transform. Saturation after each pass is
part of the bit-exact contract.

The integrated reconstruction loop accepts exactly 256 row-major
prediction/residual pairs, latches the quality profile on the first pair and
blocks the next TU until the final reconstructed pixel is accepted. Prediction
RAM reads are aligned with inverse residual coordinates under arbitrary
backpressure. Each accepted quantized coefficient is also emitted as a
non-stalling write pulse with a row-major RAM address; the next scan stage can
therefore attach a coefficient EBR without changing the arithmetic path.

The coefficient scanner accepts those writes in any raster-address order. For
TU16, HEVC always uses the diagonal scan: 4x4 coefficient groups are visited
diagonally and the coefficients inside each group use the same 4x4 order. The
scanner records the last nonzero scan position and all 16 significant-group
flags while loading, with no second search pass. After a two-cycle synchronous
RAM startup it emits one coefficient per accepted clock in the reverse syntax
traversal, from the last nonzero position down to zero, and holds every output
field stable under backpressure. An all-zero TU emits only position zero with
`any_nonzero=0`. A missing or early block marker is reported by
`input_error`. The scan RAM is intentionally standalone for now and connects
directly to the reconstruction loop's coefficient write tap; integration into
the block scheduler belongs with the syntax-bin consumer so stalled entropy
coding cannot let the next TU overwrite it.

The last-significant generator is the first coefficient-syntax stage. It emits
the X prefix, Y prefix, X suffix and Y suffix in HEVC order. Prefix bins carry
the TU16 luma context index and X/Y context-bank selector; suffix bins are
marked bypass and are emitted most-significant bit first. Code length is 2..18
bins depending on the coordinate. The module is started from the first
nonzero scan beat; an all-zero TU must bypass coefficient syntax at the parent
coded-block-flag controller. The next stage will add coded-sub-block flags,
significant-coefficient flags and level/sign coding to the same bin interface.

With no stalls, the current single-context loop takes 870 clock edges from the
first input pair through the last reconstructed pixel. At 1280x720p60 and TU16
throughout, 3600 luma TUs per frame require about 187.9 MHz before chroma and
control margin. The arithmetic blocks are deliberately kept separate: the next
throughput improvement should interleave independent slice contexts so forward
work for one TU overlaps inverse work for another, rather than sharing DSPs.

The matching integer golden models are in
`hevc_experiment/hevc_reference/intra.py`, `transform.py`, `quant.py` and
`scan.py`.
cocotb compares every prediction, signed residual, transformed/quantized/
dequantized coefficient and reconstructed sample against them with random input
gaps and output stalls in both simulators.

Run a portable 4-input-LUT synthesis estimate with:

```bash
make -C fpga synth-estimate
```

With Yosys 0.33 the current estimate is:

| Module | LUT4 | Flip-flops | DSP | EBR |
| --- | ---: | ---: | ---: | ---: |
| `hevc_intra_dc16` | 443 | 309 | 0 | 0 |
| `hevc_intra_planar16` | 1055 | 558 | 0 | 0 |
| `hevc_intra_sad_select16` | 145 | 70 | 0 | 0 |
| `hevc_forward_transform16` | ≤8483* | 867 | ≤15 | 1 |
| `hevc_inverse_transform16` | ≤10483* | 921 | ≤16 | 1 |
| `hevc_quant_dequant16` | ≤1232* | 78 | ≤2 | 0 |
| `hevc_qp_profile` | 5 | 0 | 0 | 0 |
| `hevc_reconstruct` | 35 | 9 | 0 | 0 |
| `hevc_coefficient_scan16` | small control/lookup logic* | small | 0 | 1 |
| `hevc_last_sig_bins16` | 73 | 20 | 0 | 0 |
| Conservative separate-module total | ≤21881* | 2812 | ≤33 | 3 |

This is not an Efinity place-and-route result and LUT4 counts do not map
one-to-one to Efinix logic elements. The reference arrays intentionally become
registers because they need indexed access while pixels are streaming.

`*` The transform LUT4 number is a deliberately pessimistic mapping with all
constant multipliers converted to LUTs and its RAM wrapper black-boxed; the
inverse-transform and quantizer bounds likewise map all multipliers into
LUTs. The operator-level audit finds 15 forward multipliers (the all-64 path
becomes shifts), 16 inverse multipliers, two quantizer multipliers and one
4096-bit synchronous RAM per standalone transform module.

The separate-module total is intentionally pessimistic and exceeds the T20
logic count when every multiplier is forced into LUTs. The integrated
operator-level audit preserves the requested independent arithmetic blocks:
15 forward multipliers, 16 inverse multipliers and two quantizer multipliers,
or 33 of the T20's 36 DSPs. It also contains two 4096-bit transform RAMs and
one 2048-bit prediction RAM, expected to occupy three of 204 EBRs. Connecting
the new 4096-bit coefficient scan RAM raises the datapath estimate to four of
204 EBRs while leaving the 33-DSP estimate unchanged.

Keeping the transform engines separate avoids a large shared-result mux and
allows independent slice contexts to overlap them later. Final DSP inference,
routing, power, T20F169 fit and Fmax must be measured in Efinity.
