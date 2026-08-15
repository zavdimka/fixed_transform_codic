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
- `hevc_intra_cu16_prefix.sv` emits the fixed CTU64-to-CU16 split tree,
  intra 2Nx2N planar/DC mode, derived chroma mode and luma/chroma CBF bins;
- `hevc_ctu64_syntax_scheduler.sv` serializes 16 CU prefixes, each optional
  mapped coefficient-bin stream and the CTU terminate-zero/terminate-one bin;
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
- `hevc_tu16_cabac_bridge.sv` captures that tap in one 256x16 staging EBR,
  derives `cbf_luma`, emits the CU descriptor and replays coefficients only for
  a nonzero TU, while reconstructed pixels continue on their independent stream;
- `hevc_luma_ctu64_idr_nal.sv` joins that pixel-domain TU path to the
  complete CTU-CABAC/Annex-B path, counts 16 TU16 blocks per CTU and delays
  `ctu_done`/`done` until both the NAL and reconstructed-pixel streams finish;
- `hevc_coefficient_buffer16.sv` provides the EBR-friendly 256x16 synchronous
  coefficient RAM used by `hevc_coefficient_scan16.sv`, which emits the
  normative TU16 diagonal scan and significance metadata for CABAC;
- `hevc_coefficient_pingpong16.sv` wraps two coefficient EBRs with ordered
  bank ownership, load-time scan metadata and independent read/release
  handshakes so the next TU can load while CABAC consumes the current TU;
- `hevc_last_sig_bins16.sv` converts the last nonzero TU16 raster coordinate
  into normative luma `last_sig_coeff_x/y` prefix and suffix bin events;
- `hevc_significance_bins16.sv` consumes the reverse coefficient scan and
  emits normative `coded_sub_block_flag` and `significant_coeff_flag`
  events with their derived luma context indexes;
- `hevc_coefficient_level_bins16.sv` collects at most 16 nonzero values from
  one 4x4 group and emits greater-than-one/two, sign and adaptive-Rice
  coefficient-level bins;
- `hevc_coefficient_syntax_arbiter16.sv` serializes last-position, significance
  and level events into one ordered, backpressure-safe pre-CABAC bin stream;
- `hevc_coefficient_syntax16.sv` acquires completed TUs from the two-bank store,
  schedules the significance and level replay passes and adds a two-bin output
  FIFO at the arithmetic-CABAC boundary;
- `hevc_cabac_bin_step.sv` performs one regular or bypass CABAC bin,
  including the normative LPS range table, probability-state transition and
  fixed-width range/low renormalization in a one-entry elastic pipeline;
- `hevc_cabac_context_ram.sv` stores 256 seven-bit probability contexts in
  one synchronous, EBR-friendly memory;
- `hevc_cabac_encoder.sv` combines that RAM and bin step with terminate-bin
  handling, HM-compatible bits-left/carry/0xFF buffering, byte alignment and a
  backpressure-safe byte output marked at the end of each slice;
- `hevc_coefficient_context_map.sv` maps local coefficient syntax contexts into
  non-overlapping X/Y, significance and level banks in the CABAC RAM;
- `hevc_coefficient_context_init_rom.sv` infers a synchronous 576x8 ROM from
  `hevc_coefficient_context_init.hex`, holding HM B/P/I coefficient and fixed
  intra-CU `initValue` rows in one T20 5-kbit EBR;
- `hevc_coefficient_context_init.sv` converts the selected ROM row and clipped
  slice QP into the normative state/MPS pair and writes 192 compact contexts;
- `hevc_nal_writer.sv` wraps an RBSP byte stream in a four-byte Annex-B start
  code and layer-zero HEVC NAL header, inserting emulation-prevention bytes;
- `hevc_parameter_set_rom.sv` and `hevc_parameter_set_streamer.sv` read a
  compile-time 59-byte VPS/SPS/PPS RBSP image and emit three complete NALs;
- `hevc_idr_slice_header.sv` emits a minimal byte-aligned IDR I-slice header
  for one full-width CTU row, with compile-time frame geometry and run-time
  row/QP selection;
- `hevc_idr_slice_nal.sv` streams that header followed by CABAC bytes through
  the shared NAL writer, producing one complete type-20 Annex-B IDR NAL without
  buffering the slice payload;
- `hevc_coefficient_cabac16.sv` joins the ping-pong syntax controller, context
  map and arithmetic encoder into one coefficient-to-byte slice path, while
  retaining the external context-configuration interface;
- `hevc_ctu64_cabac.sv` adds fixed CU descriptors, CTU scheduling and
  terminate-zero/one around that coefficient path while retaining compile-time
  context initialization;
- `hevc_idr_ctu64_nal.sv` is the current complete slice-output top: it
  initializes I-slice contexts for the selected QP, counts adjacent CTUs,
  generates the final-CTU termination and streams the CABAC bytes directly into
  the IDR header/NAL path without a compressed-slice buffer;
- `hevc_reconstruct.sv` adds the inverse-path residual to the prediction and
  clips the reconstructed sample to 8 bits.

The fixed parameter-set image advertises Main-profile 1280x768p60 8-bit 4:2:0,
CTU64, minimum CU16 and maximum TU16. SAO, deblocking, sign-data-hiding,
strong intra smoothing and WPP are disabled. This is exactly 20x12 complete
CTUs, so the 12 full-width slices need neither partial bottom CTUs nor WPP
entry points. The same slice-header RTL can be compiled for a 1920x1024 coded
frame as 30x16 CTUs; a conventional 1080-line source must be cropped or scaled
to 1024 lines before encoding.
The three RBSPs occupy 59 initialized bytes and produce 85 Annex-B bytes after
start codes, NAL headers and emulation prevention. Regenerate the image with
`make -C fpga generate-parameter-sets`; add `hevc_parameter_sets.hex` to the
Efinity project as a memory-initialization file. For the 30x16 variant, use
`make -C fpga generate-parameter-sets PARAMETER_SET_WIDTH=1920` with
`PARAMETER_SET_HEIGHT=1024`. The receiver can cache these
85 bytes and they do not need to be sent on every frame.

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
`input_error`.

The standalone ping-pong store preserves completion order across both banks and
attaches the last-position, significant-group and framing metadata to each TU.
Once a bank is acquired, synchronous reads may run in parallel with loading the
other bank; explicit release is the only operation that makes it writable again.
The store is tested both independently and inside the syntax controller. While
one acquired bank is replayed into syntax bins, the reconstruction-side input can
fill the other bank; a third TU is backpressured until the active bank is released.

The standalone scanner remains a unit-test boundary. The integrated syntax
controller connects the raster-addressed ping-pong store to the reconstruction-loop
write tap. It preserves FIFO order and releases each active bank only after the
last pre-CABAC bin has left its output FIFO.

The last-significant generator is the first coefficient-syntax stage. It emits
the X prefix, Y prefix, X suffix and Y suffix in HEVC order. Prefix bins carry
the TU16 luma context index and X/Y context-bank selector; suffix bins are
marked bypass and are emitted most-significant bit first. Code length is 2..18
bins depending on the coordinate. The module is started from the first
nonzero scan beat; an all-zero TU must bypass coefficient syntax at the parent
coded-block-flag controller. The significance generator adds coded-sub-block and
significant-coefficient flags to the same bin interface. It retains only the
16-bit significant-group map and per-group counters. Right/lower group
neighbours select the normative context pattern; the last coefficient and the
inferred position-zero coefficient do not produce redundant bins. A DC-only TU
therefore completes this stage without a significance bin.

The level generator retains only the current 4x4 group's nonzero magnitudes and
signs. It emits up to eight context-coded greater-than-one flags, the first
greater-than-two flag, all signs as bypass bins, then the normative adaptive
Golomb-Rice remainder including the escape form. The carried C1 state is
preserved between groups. Sign-data-hiding is deliberately disabled in the PPS
contract for this first implementation, which remains standard-compatible.
The syntax arbiter enforces the required `last -> significance -> level` order
and never acknowledges an inactive producer. A separate done handshake handles
the DC-only case, where the significance stage emits no bin. The integrated
controller acquires one completed bank and its load-time last-position/group metadata, reads that bank in reverse order for significance,
rewinds the address generator and replays it group-by-group for levels. The second 4096-bit bank remains independently writable during both replay
passes. A two-entry FIFO decouples this pipeline from the
arithmetic CABAC ready path while sustaining one bin per clock when the
consumer runs continuously. All-zero TUs bypass coefficient syntax, and
`block_done` waits until the FIFO is empty.

With no stalls, the current single-context loop takes 870 clock edges from the
first input pair through the last reconstructed pixel. At 1280x720p60 and TU16
throughout, 3600 luma TUs per frame require about 187.9 MHz before chroma and
control margin. The arithmetic blocks are deliberately kept separate: the next
throughput improvement should interleave independent slice contexts so forward
work for one TU overlaps inverse work for another, rather than sharing DSPs.

The CABAC encoder accepts regular, bypass and terminate commands. Contexts are
loaded through a configuration port before `start`; regular bins update the
selected entry, bypass bins leave RAM untouched, and a terminate-one command
emits the final stop/alignment bit and asserts `m_last`. Carry propagation and
runs of deferred `0xFF` bytes follow [HM-16.18 `TEncBinCABAC`](https://hevc.hhi.fraunhofer.de/HM-doc/_t_enc_bin_coder_c_a_b_a_c_8cpp_source.html). The current
synchronous context read plus registered arithmetic boundary takes four clocks
per ordinary bin; this is functionally complete but should be overlapped or
collapsed if measured slice-bin rate exceeds the available clock budget.
A luma-only QP34 estimate on `1.png` produced about 354930 bins per frame,
or 21.3 Mbin/s at 60 FPS; four clocks per bin therefore require about
85.2 MHz before chroma and remaining slice syntax. This supports keeping the
simple engine and overlapping it with the next TU through ping-pong coefficient
buffers instead of immediately duplicating or deeply pipelining CABAC.

The integrated coefficient-to-CABAC path uses this compact context-RAM map:

| Addresses | HEVC coefficient context bank |
| --- | --- |
| 0..14 | `last_sig_coeff_x_prefix` |
| 16..30 | `last_sig_coeff_y_prefix` |
| 32..33 | `coded_sub_block_flag` |
| 64..91 | luma `significant_coeff_flag` |
| 96..111 | luma `coeff_abs_level_greater1_flag` |
| 112..115 | luma `coeff_abs_level_greater2_flag` |
| 128..130 | `split_cu_flag` |
| 132..135 | `part_mode` |
| 136 | `prev_intra_luma_pred_flag` |
| 137..138 | `intra_chroma_pred_mode` |
| 144..148 | luma `cbf_luma` |
| 152..156 | chroma `cbf_cb` / `cbf_cr` |
| 160..162 | reserved `transform_subdiv_flag` bank |

The bank sizes follow the
[HM-16.18 context model counts](https://hevc.hhi.fraunhofer.de/HM-doc/_context_tables_8h.html);
the numeric RAM addresses are an internal FPGA layout. Bypass bins do not read a
context. Before a slice, the integrated loader accepts B=0, P=1 or I=2 plus QP,
clips QP to 0..51 as HM does, reads the selected 192-byte ROM row and writes the
probability RAM in 384 clocks. The original external configuration port remains
available for diagnostics and future non-coefficient syntax contexts.
`rtl/hevc/hevc_coefficient_context_init.hex` must be added to the Efinity
project as a memory-initialization file. If the synthesis working directory
differs from the FPGA project root, override
`HEVC_COEFFICIENT_CONTEXT_INIT_FILE` with the path passed to `$readmemh`.
`make -C fpga generate-context-init` regenerates the table from the Python HM
model. The fixed CU prefix, CTU scheduler and integrated CABAC top are
backpressure-safe. The scheduler accepts 16 CU descriptors and gates the already
mapped coefficient stream only for CUs with `cbf_luma=1`. It emits terminate-zero for a non-final CTU or
terminate-one for the final CTU. It contains no pixel or coefficient RAM.
The integrated top accepts raw raster-addressed TU16 coefficients into the same
two EBR banks, serializes mapped coefficient bins only after a CU with
`cbf_luma=1`, and forwards the final CTU terminate-one through CABAC to the
aligned byte marked `m_last`. The older coefficient-only wrapper and its
`slice_finish` port remain as a unit-test boundary.

The matching integer golden models are in
`hevc_experiment/hevc_reference/intra.py`, `transform.py`, `quant.py`,
`scan.py`, `syntax.py`, `cu_syntax.py` and `cabac.py`.
cocotb compares every prediction, signed residual, transformed/quantized/
dequantized coefficient and reconstructed sample against them with random input
gaps and output stalls. The complete integrated syntax replay uses Verilator;
Icarus checks its DC/all-zero/framing paths and continues to run the full
multigroup significance, level and arbiter modules separately.

The complete pixel/residual-to-reconstructed-pixel-and-Annex-B one-CTU oracle,
the TU-reconstruction-to-CABAC bridge, coefficient-only, complete
two-CTU-to-CABAC and full two-CTU-to-Annex-B byte oracles run under
Verilator. The pixel-domain oracle checks all 4096 reconstructed luma samples
and the complete NAL byte-for-byte under independent randomized stalls. The full oracle checks automatic context
initialization, CTU X/last scheduling, the slice header, CABAC payload,
emulation prevention, randomized output stalls and the single final `m_last`.
Their syntax and arithmetic children remain independently covered by both
simulators because Icarus is impractically slow for the combined event-heavy
hierarchy.

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
| `hevc_intra_cu16_prefix` | 34 | 15 | 0 | 0 |
| `hevc_ctu64_syntax_scheduler` glue [8] | 49 | 18 | 0 | 0 |
| `hevc_forward_transform16` | ≤8483* | 867 | ≤15 | 1 |
| `hevc_inverse_transform16` | ≤10483* | 921 | ≤16 | 1 |
| `hevc_quant_dequant16` | ≤1232* | 78 | ≤2 | 0 |
| `hevc_qp_profile` | 5 | 0 | 0 | 0 |
| `hevc_reconstruct` | 33 | 9 | 0 | 0 |
| `hevc_coefficient_scan16` | small control/lookup logic* | small | 0 | 1 |
| `hevc_last_sig_bins16` | 73 | 20 | 0 | 0 |
| `hevc_significance_bins16` | 114 | 33 | 0 | 0 |
| `hevc_coefficient_level_bins16` | 1549 | 353 | 0 | 0 |
| `hevc_coefficient_syntax_arbiter16` | 48 | 3 | 0 | 0 |
| `hevc_coefficient_syntax16` glue/FIFO only** | 209 | 174 | 0 | 0 |
| `hevc_coefficient_pingpong16` control and RAMs [4] | 248 | 73 | 0 | 2 |
| `hevc_cabac_bin_step` | 570 | 52 | 0 | 0 |
| `hevc_cabac_context_ram` | small port mux | 7 output bits | 0 | 1 |
| `hevc_cabac_encoder` glue only*** | 916 | 165 | 0 | 0 |
| `hevc_coefficient_context_init` [5] | ≤176 | 20 | ≤1 | 1 |
| `hevc_ctu64_cabac` glue/map only [6] | 89 | 12 | 0 | 0 |
| `hevc_nal_writer` | 38 | 15 | 0 | 0 |
| `hevc_parameter_set_streamer` control | 37 | 16 | 0 | 0 |
| `hevc_parameter_set_rom` | small port mux | 8 output bits | 0 | 1 |
| `hevc_idr_slice_header` | 133 | 38 | 0 | 0 |
| `hevc_idr_slice_nal` glue only [7] | 29 | 4 | 0 | 0 |
| `hevc_idr_ctu64_nal` glue only [9] | 50 | 26 | 0 | 0 |
| `hevc_tu16_cabac_bridge` glue/staging [10] | 57 | 36 | 0 | 1 |
| `hevc_luma_ctu64_idr_nal` integration glue [11] | 24 | 10 | 0 | 0 |
| Known mapped subtotal including pixel-to-NAL wrapper | ≤26322* | 3902 | ≤34 | 9 |

This is not an Efinity place-and-route result and LUT4 counts do not map
one-to-one to Efinix logic elements. The reference arrays intentionally become
registers because they need indexed access while pixels are streaming.

`*` The transform LUT4 number is a deliberately pessimistic mapping with all
constant multipliers converted to LUTs and its RAM wrapper black-boxed; the
inverse-transform and quantizer bounds likewise map all multipliers into
LUTs. The operator-level audit finds 15 forward multipliers (the all-64 path
becomes shifts), 16 inverse multipliers, two quantizer multipliers and one
4096-bit synchronous RAM per standalone transform module.

`**` The syntax-controller row black-boxes the ping-pong store and four syntax
children, and counts only replay control plus the two-entry output FIFO. The
complete integrated coefficient-syntax hierarchy is approximately 2241 LUT4,
656 FF, zero DSPs and two EBRs before Efinity-specific mapping.
The standalone CABAC bin step adds 570 LUT4 and 52 FF in the same portable
mapping; its 2.4-kbit constant tables may instead be mapped into one of the
abundant 5-kbit EBRs after adding a synchronous lookup stage.

`***` The byte-encoder row black-boxes the bin-step and context-RAM children.
The complete CABAC hierarchy is therefore approximately 1486 LUT4, 224 FF,
zero DSPs and one EBR in the portable estimate.

[4] The ping-pong row black-boxes both 4096-bit RAM instances when mapping its
control, so 248 LUT4 and 73 FF cover bank ownership, the two-entry completion
queue and load-time metadata. The two RAM instances use two EBRs.

[5] The initializer LUT4 number is a conservative portable mapping of the
loader, clipping logic and its 7x7 signed QP product. Efinity may place that one
product in a DSP, reducing LUT use. The separately black-boxed 576x8 synchronous
ROM is 4608 bits and fits one 5-kbit EBR; the table file is loaded at compile time.

The NAL writer has no payload RAM: it adds six fixed bytes per NAL (four-byte
start code and two-byte header), plus one `0x03` only where emulation prevention
is required. It otherwise transfers one RBSP byte per accepted clock.
The parameter-set controller adds 37 LUT4 and 16 FF around that shared NAL
writer. Its 59x8 synchronous initialized ROM is deliberately marked for block
RAM and consumes at most one otherwise-abundant 5-kbit EBR.
The slice-header writer stores at most four output bytes in registers. Its
compile-time CTU-column multiply maps to shifts/adds and consumes no DSP or EBR.
The IDR-NAL wrapper backpressures CABAC until those header bytes have entered the
NAL writer, then connects CABAC directly; it does not retain the slice payload.

[6] The CTU-to-CABAC row black-boxes the initializer, coefficient-syntax, CTU
scheduler and arithmetic children. Its 89 LUT4 include context mapping, slice
lifecycle, configuration arbitration, outstanding-block tracking and protocol
checks; the 12 FF retain only wrapper state.

[7] The IDR-NAL row black-boxes the existing slice-header and NAL-writer
children. Its 29 LUT4 and four FF cover source selection, parameter validation
and the three-state slice lifecycle.

[8] The CTU scheduler row black-boxes the 34-LUT4/15-FF CU-prefix child. The
complete scheduler hierarchy is about 83 LUT4 and 33 FF, with no DSP or EBR.

[9] The complete slice-output row black-boxes the existing CTU-CABAC and
IDR-NAL children. Its 50 LUT4 and 26 FF cover automatic context/slice startup,
CTU X/last tracking, completion/error checks and a one-clock inter-CTU guard
that keeps the next descriptor aligned with the updated X coordinate. It adds
no payload RAM, DSP or EBR.

[10] The TU-to-CABAC bridge row black-boxes the reconstruction loop and the
256x16 coefficient RAM. Its 60 LUT4 and 36 FF implement block ownership,
nonzero/CBF reduction, descriptor holding and a one-coefficient-per-clock synchronous
RAM replay under backpressure. The staging RAM costs one 5-kbit EBR and avoids
queuing an all-zero TU in the downstream coefficient banks.

[11] The pixel-to-NAL integration row black-boxes the existing TU bridge and
IDR-NAL hierarchy. Its 24 LUT4 and ten FF implement CTU ownership, the 16-TU
index and a completion barrier between the independently backpressured
reconstruction and NAL branches. It adds no RAM or arithmetic.

The separate-module total is intentionally pessimistic and exceeds the T20
logic count when every multiplier is forced into LUTs. The integrated
operator-level audit preserves the requested independent arithmetic blocks:
15 forward multipliers, 16 inverse multipliers and two quantizer multipliers,
or 34 of the T20's 36 DSPs after the context initializer. It also
contains two 4096-bit transform RAMs and one 2048-bit prediction RAM,
expected to occupy three of 204 EBRs.
Connecting the first 4096-bit coefficient RAM raises the datapath estimate
to four EBRs; the second ping-pong bank raises it to five, the 1792-bit
CABAC context RAM raises it to six, and the 4608-bit initialized context ROM
raises it to seven of 204; the parameter-set ROM raises it to eight, and
the TU-to-CABAC staging buffer raises the connected datapath estimate to nine.
The pixel-to-NAL wrapper adds no EBR. The QP initialization product raises the
conservative DSP count to 34.

Keeping the transform engines separate avoids a large shared-result mux and
allows independent slice contexts to overlap them later. Final DSP inference,
routing, power, T20F169 fit and Fmax must be measured in Efinity.
