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

## SPI-injected CTU bring-up top

`hevc_720p_spi_debug_top.sv` is the first board-oriented debug top. It bypasses
the camera input without changing the codec: SPI loads exactly one planar CTU16
into a 512x8 synchronous block RAM, the loader replays Y/Cb/Cr through the normal
ready/valid pixel ports, and the actual Annex-B NAL exits on the 4-bit stream.
The normal encoder context is retained between CTUs. Only the 384-byte injected
CTU is buffered; no frame or 16-line debug framebuffer is added.

The SPI slave is mode 0 and is synchronously oversampled by `clk`. For initial
bring-up keep SCK at or below one eighth of the encoder clock. Each command has
its own CS-low transaction:

| Command | Bytes after command | Result |
|---|---:|---|
| `01` CONFIG | 3 | slice row, QP, quality/flags |
| `02` START_SLICE | 0 | starts one independently decodable slice |
| `10` LOAD_CTU | 386 | Y[256], Cb[64], Cr[64], big-endian CRC-16/CCITT |
| `11` RUN_CTU | 0 | admits the loaded CTU when the codec is ready |
| `20` SOFT_RESET | 0 | resets codec/loader state |
| `21` CLEAR_ERRORS | 0 | clears transport command/length/CRC errors |
| `80` READ_STATUS | 7 dummy bytes | state, version, CTU coordinates and errors |
| `81` READ_SIGNATURES | 16 dummy bytes | NAL/reconstruction counts and CRCs |

A normal injected slice sequence is CONFIG, START_SLICE, then LOAD_CTU and
RUN_CTU for each raster-order CTU. LOAD_CTU is rejected while the loader is
busy, truncated or overlong transfers set a sticky error, and a CTU becomes
runnable only after its length and CRC both pass. Python command builders live
in `hevc_reference.debug_interface`.

The logical 4-bit output has `nibble_valid`, `nibble_ready` and
`nibble_last` sidebands. The board wrapper still has to map these onto the
actual FPGA-to-ESP32 pins or encode framing if only four physical conductors
are available; that decision does not affect the codec or SPI injection path.

For Efinity, select `hevc_720p_spi_debug_top` as the top module. The complete
portable source list is printed with:

```bash
make -C fpga list-spi-debug-sources
```

Also add `rtl/hevc/hevc_coefficient_context_init.hex` to the project and define
`HEVC_COEFFICIENT_CONTEXT_INIT_FILE` to its absolute build path. The top
defaults are already 1280x720, CTU16 and five CTU rows per slice. Clock/PLL,
reset polarity and package pin constraints intentionally remain in the
board-specific Efinity wrapper because the oscillator and pin assignment are
not recorded in this repository.

Portable Yosys mapping of only the new debug shell, with the codec black-boxed,
reports about 649 LUT4 and 314 flip-flops, plus one 4096-bit EBR and no DSP.
Added to the current codec projection this is about 16050 LUT4 (roughly 81.6% of
T20), 35/36 DSP and approximately 151--155/204 EBR. This still fits on paper,
but the margin must be confirmed by the first Efinity place-and-route build.

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
- `hevc_intra_frontend16.sv` stores one raw 16x16 source block in a synchronous
  2048-bit RAM, evaluates DC and planar in lockstep, then reloads the saved
  references and replays only the selected prediction/residual stream;
- `hevc_chroma_intra8.sv` applies the luma-selected derived planar/DC mode
  to one 8x8 chroma TU, using unfiltered HEVC chroma references and recurrence
  add/subtract datapaths with no multiplier or source-block replay RAM;
- `hevc_chroma_reference_line_store8.sv` performs normative unavailable-sample
  substitution in raster CTU16 order and retains one half-width reconstructed
  top line plus the eight-byte right edge for one Cb or Cr plane;
- `hevc_luma_reference_line_store16.sv` consumes CTU16 in raster order, applies
  normative unavailable-sample substitution and retains one reconstructed full-width
  top line plus the 16-byte right edge; the older Z-order store remains as a CTU64 regression boundary;
- `hevc_ctu16_intra_prefix.sv` emits one unsplit CTU16/CU16 intra 2Nx2N
  planar/DC prefix, derived chroma mode and luma/chroma CBF bins;
- `hevc_ctu16_syntax_scheduler.sv` serializes that one CU prefix, optional Y,
  Cb and Cr mapped coefficient-bin streams in normative order, and the CTU
  terminate-zero/terminate-one bin;
  the CTU64 prefix and scheduler remain as regression boundaries;
- `hevc_forward_transform16.sv` performs the normative separable HEVC 16x16
  integer forward transform with 8-bit shifts 3/10 and exact rounding;
- `hevc_transform_buffer16.sv` isolates the synchronous 256x16 transpose RAM so
  Efinity can map its 4096 bits into one 5-kbit EBR;
- `hevc_qp_profile.sv` maps the discrete good/medium/poor quality selection to
  configurable QP 28/34/40 defaults;
- `hevc_quant_dequant16.sv` applies flat HEVC TU16 quantization and inverse
  quantization with explicit signed-16 saturation in a two-stage elastic pipe;
- `hevc_transform8_core.sv`, its forward/inverse wrappers, `hevc_chroma_qp.sv`
  and `hevc_quant_dequant8.sv` implement bit-exact 8x8 chroma transform, the
  normative 4:2:0 QP mapping and TU8 quantization shifts;
- `hevc_chroma_tu8_reconstruction_loop.sv` is the independently verified Cb/Cr
  sample-to-coefficient-to-reconstructed-sample path. It accepts one 8x8 block,
  tolerates arbitrary ready/valid stalls and exposes 64 raster-addressed levels;
- `hevc_chroma_tu8_cabac_bridge.sv` captures those 64 levels in one synchronous
  1024-bit staging RAM, derives the plane CBF, suppresses all-zero replay and
  independently handshakes the descriptor, coefficient and reconstruction streams;
- `hevc_chroma_ctu16_controller.sv` owns independent Cb/Cr reference lines,
  serializes both planes through one predictor and one TU8 bridge, tags reconstructed
  samples and coefficient replay by plane, and publishes the combined CBF descriptor
  only after both reconstructed blocks have been committed;
- `hevc_last_sig_bins8.sv`, `hevc_significance_bins8.sv` and the chroma mode of
  `hevc_coefficient_level_bins16.sv` emit normative TU8 last-position,
  significance and level bins while reusing the existing compact CABAC context
  banks;
- `hevc_coefficient_syntax8.sv` stores one 8x8 quantized block in a synchronous
  1024-bit RAM, replays it for significance and levels, and produces one ordered,
  backpressure-safe pre-CABAC stream;
- `hevc_ctu16_yuv_syntax_path.sv` selects only the scheduler-requested Y, Cb or
  Cr producer, maps its contexts and forms the normative prefix-Y-Cb-Cr-terminate
  stream without a combinational ready/valid loop;
- `hevc_ctu16_yuv_cabac.sv` feeds that stream through one shared context RAM and
  arithmetic CABAC encoder; its byte output is checked exactly against the Python
  reference under backpressure;
- `hevc_idr_ctu16_yuv_nal.sv` wraps that colour CABAC stream with the standard
  IDR slice header and Annex-B NAL writer while tracking raster CTU coordinates;
- `hevc_yuv_ctu16_idr_nal.sv` joins one prepared luma TU with raw Cb/Cr blocks,
  starts chroma after the selected luma mode is known, routes all three coefficient
  streams to the shared colour CABAC path and joins reconstruction/NAL completion;
- `hevc_yuv_pixel_ctu16_idr_nal.sv` is the raw-colour integration top: it
  builds luma references, selects planar/DC from raw Y, forwards raw Cb/Cr to
  the derived-mode chroma path and emits one reconstructed, byte-exact IDR CTU;
- `hevc_shared_transform_scheduler.sv` arbitrates complete Y, Cb and Cr
  transform transactions onto one external service, locks ownership through
  `block_last` and checks the exact 256/64-sample block lengths;
- `hevc_transform_mac16.sv` is the explicit 16-lane signed multiplier boundary
  intended to infer exactly 16 DSPs;
- `hevc_transform_mac8x2.sv`, `hevc_stream_transform_lane8.sv` and
  `hevc_paired_transform8_core.sv` split the same 16-multiplier budget into two
  independent eight-lane TU8 paths; Cb PASS2 overlaps Cr load/PASS1 and both
  coefficient blocks leave as one ordered, backpressure-safe 128-sample stream;
- `hevc_transform_bank16.sv` and `hevc_shared_transform_core.sv` implement one
  banked, backpressure-safe transform engine shared by TU8/TU16 and forward/inverse
  operation, with the exact HEVC integer matrices, shifts, rounding and clipping;
  its elastic synchronous-RAM output pipeline sustains one PASS2 coefficient per
  clock; the dual-core forward instance also starts PASS1 as soon as each complete
  raster row arrives, overlapping all but the final row with input loading;
- `hevc_shared_transform_service.sv` closes that core behind the Y/Cb/Cr
  scheduler, so all planes demonstrably use the same physical transform engine;
- `hevc_shared_quant_mac.sv` and `hevc_shared_quant_dequant.sv` implement one
  two-DSP, elastic TU8/TU16 quant/dequant path with selectable HEVC shifts;
- `hevc_shared_reconstruction_core.sv` surrounds the shared arithmetic with
  prediction and dequantized-coefficient EBRs plus one block FSM, exposing
  independent backpressure-safe quantized-coefficient and reconstructed-pixel
  streams;
  its elastic dequantized-coefficient replay sustains one coefficient per clock,
  while prediction read and reconstruction sustain one pixel per clock;
- `hevc_dual_reconstruction_core.sv` separates forward and inverse transforms,
  shares one two-DSP quantizer and rotates four ordered prediction/dequant context
  banks so one Y command and one paired Cb/Cr command overlap inverse reconstruction
  of the preceding CTU without changing coefficient or pixel order; forward
  quantization overlaps paired-chroma loading, while column-major inverse replay
  overlaps reconstruction and inverse PASS1;
- `hevc_coefficient_replay_store.sv` separates coefficient capture from CABAC
  consumption with one synchronous, backpressure-safe EBR-friendly store;
- `hevc_yuv_dual_reconstruction_bridge.sv` is the live YUV arithmetic bridge: it
  sends one TU16 Y command and one paired Cb/Cr TU8 command to the dual core,
  forms chroma prediction from the two reference-line stores, routes reconstructed
  samples back to the correct line store, derives all three CBF flags and replays
  Y/Cb/Cr coefficients independently to the standard syntax path;
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
- `hevc_luma_ctu16_idr_nal.sv` joins one TU16 pixel-domain path to the
  complete CTU-CABAC/Annex-B path and delays `ctu_done`/`done` until both the
  NAL and reconstructed-pixel streams finish;
- `hevc_luma_pixel_ctu16_idr_nal.sv` is the active raw-luma integration top: it
  starts one reference/mode-decision transaction per raster CTU16, feeds the
  selected stream to transform/CABAC and commits only accepted reconstructed
  pixels; CTU64 tops remain available for regression;
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
  for one full-width group of CTU rows, with compile-time frame geometry,
  configurable rows per slice and run-time slice/QP selection;
- `hevc_idr_slice_nal.sv` streams that header followed by CABAC bytes through
  the shared NAL writer, producing one complete type-20 Annex-B IDR NAL without
  buffering the slice payload;
- `hevc_coefficient_cabac16.sv` joins the ping-pong syntax controller, context
  map and arithmetic encoder into one coefficient-to-byte slice path, while
  retaining the external context-configuration interface;
- `hevc_ctu16_cabac.sv` adds the single-CU CTU16 descriptor, coefficient
  scheduling and terminate-zero/one around that path while retaining compile-time
  context initialization;
- `hevc_idr_ctu16_nal.sv` is the active complete slice-output top: it
  initializes I-slice contexts for the selected QP, counts raster CTU16 blocks,
  generates the final-CTU termination and streams the CABAC bytes directly into
  the IDR header/NAL path without a compressed-slice buffer;
- `hevc_camera_yuv420p_ingress.sv` accepts an 8-bit planar I420 frame in
  camera raster order, ping-pongs two 16-line banks and emits 16x16 Y plus
  matching 8x8 Cb/Cr blocks with explicit plane, coordinate and end markers;
- `hevc_reconstruct.sv` adds the inverse-path residual to the prediction and
  clips the reconstructed sample to 8 bits.

The fixed parameter-set image advertises Main-profile 1280x768p60 8-bit 4:2:0,
CTU16, CU16 and TU16. SAO, deblocking, sign-data-hiding, strong intra smoothing
and WPP are disabled. This is exactly 80x48 CTUs. Four adjacent CTU rows form
one 64-pixel-high slice, preserving 12 independently decodable full-width slices
without any 64x64 pixel reorder buffer. The same slice-header RTL can be compiled for a 1920x1024 coded
frame as 120x64 CTU16 blocks; a conventional 1080-line source must be cropped or scaled
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
`hevc_intra_frontend16` now performs that fan-out and SAD decision. It keeps one
256-byte source block, then runs a second predictor pass and replays only the
selected prediction/residual stream. This spends cycles instead of adding two
full prediction/residual memories. SAD is a deliberately cheap mode heuristic,
not full HEVC rate-distortion optimization; either selected mode still produces
standard-compatible syntax.

The active reference store follows raster CTU16 order. It retains only the reconstructed
bottom row as the next CTU-row top line, the current 16-byte right edge and one
carried top-left sample. At 1280 pixels the full-width top line is 10,240 bits
(two 5-kbit EBRs); at 1920 pixels it is 15,360 bits (three EBRs). Prediction is
reset at the top of every four-CTU-row, 64-pixel-high slice. No CTU-sized pixel
reorder or 16-line reference buffer is required.

`hevc_camera_yuv420p_ingress` defines the camera-side contract as planar 8-bit
I420: the complete Y plane in raster order, then Cb and Cr at half width and
height. `s_sof` marks the first Y byte; all following coordinates and plane
boundaries are counted internally. Two 16-line luma banks are shared with the
smaller eight-line chroma stripes. The block output sustains one sample per
clock, preserves Cb/Cr instead of silently discarding colour, and remains stable
under arbitrary backpressure. A small asynchronous FIFO is still required
between a non-stallable sensor clock and this ready/valid clock domain.

The CTU16 luma pixel-to-NAL top and camera ingress now use the same spatial
raster block order, so no Z-order reorder RAM is needed. A small frame controller
still has to route Y blocks into the luma core and associate the matching 8x8 Cb/Cr
blocks. The CTU16 prefix and scheduler carry real `cbf_cb`/`cbf_cr` values and serialize
residual syntax as Y, Cb, Cr. The isolated YUV CABAC top now accepts one TU16 and
two TU8 coefficient blocks and produces a byte-exact shared CABAC stream. Existing
luma-only NAL wrappers still tie chroma low. The chroma predictor, per-plane
reference stores and shared Cb-then-Cr controller are now independently and
jointly verified.
The controller derives both plane CBF values and exposes plane-tagged, backpressure-safe
coefficient and reconstruction streams. The CTU-level Y/Cb/Cr arbiter, colour
IDR wrapper and raw-colour frontend are now
byte-exact end to end from raw Y/Cb/Cr samples. Luma reference collection and
planar/DC mode selection are part of the active top and require no frame-sized
buffer. The remaining camera-side stage is CTU association: planar camera Y, Cb
and Cr stripes must be scheduled into matching CTUs before this top.

The current integration is deliberately serialized for correctness: reference
collection, the first DC/planar pass, selected-mode replay and the existing TU
loop do not overlap across blocks. It is therefore not yet a 720p60 throughput
top. The 16-line ping-pong/pending-context stage must overlap capture, mode
decision and transform work; simply increasing the clock is not the intended
solution.

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
arithmetic CABAC ready path. Bypass bins can still be consumed every clock;
regular context-coded bins are accepted every two clocks by the registered
arithmetic path. All-zero TUs bypass coefficient syntax, and
`block_done` waits until the FIFO is empty.

With no stalls, the current single-context loop takes 870 clock edges from the
first input pair through the last reconstructed pixel. At 1280x720p60 and TU16
throughout, 3600 luma TUs per frame require about 187.9 MHz before chroma and
control margin. The arithmetic blocks remain available as the reference path. The verified dual-core
controller described below now overlaps forward work for one TU with inverse work
for an earlier TU while preserving block order.

The CABAC encoder accepts regular, bypass and terminate commands. Contexts are
loaded through a configuration port before `start`; regular bins update the
selected entry, bypass bins leave RAM untouched, and a terminate-one command
emits the final stop/alignment bit and asserts `m_last`. Carry propagation and
runs of deferred `0xFF` bytes follow [HM-16.18 `TEncBinCABAC`](https://hevc.hhi.fraunhofer.de/HM-doc/_t_enc_bin_coder_c_a_b_a_c_8cpp_source.html). The encoder
uses a split bin-step and combines arithmetic commit with the byte-output check.
Regular context-coded bins are registered between range/table/state work and the
32-bit low update/renormalization shift, so a continuous regular run accepts one
bin every two clocks. The registered result can retire while the encoder captures
the next command; bypass bins retain their short chained path. A forwarding
register supplies the updated state when consecutive regular bins address the same
RAM entry.
The chain pauses only for terminate processing or when deferred bytes must be
emitted. The standalone registered bin-step interface remains unchanged for use
where an elastic timing boundary is preferable.
A luma-only QP34 estimate on `1.png` produced about 354930 bins per frame,
or 21.3 Mbin/s at 60 FPS. The raw chained bin rate therefore requires at least
21.3 MHz before chroma, byte-emission bubbles and remaining slice syntax; the
measured complete YUV path below is the conservative current system limit.

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
model. The active CTU16 prefix, scheduler and integrated CABAC top are
backpressure-safe. The scheduler accepts one CU descriptor per CTU and gates the
mapped coefficient stream only when `cbf_luma=1`; the CTU64 scheduler remains
as a regression boundary. It emits terminate-zero for a non-final CTU or
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

The raw-source-pixel and prepared-prediction/residual one-CTU oracles, the
TU-reconstruction-to-CABAC bridge, coefficient-only, complete two-CTU-to-CABAC
and full two-CTU-to-Annex-B byte oracles run under Verilator. The raw-pixel
oracle independently rebuilds raster CTU16 references, unavailable-sample
substitution, DC/planar SAD choice, quantized reconstruction and CABAC, then
checks all 256 reconstructed luma samples and the complete NAL byte-for-byte
under independent randomized stalls. The four-row multi-CTU oracle additionally checks raster X/Y progression and one
64-pixel-high slice. The full oracle checks automatic context
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
| `hevc_intra_frontend16` control/references [12] | 363 | 372 | 0 | 1 |
| `hevc_chroma_intra8` | 469 | 314 | 0 | 0 |
| `hevc_chroma_reference_line_store8` | control/substitution logic | small + 233-bit capture | 0 | 1 / 2 per plane |
| `hevc_chroma_tu8_cabac_bridge` glue/staging | 51 | 29 | 0 | 1 |
| `hevc_chroma_ctu16_controller` glue | 74 | 20 | 0 | 0 |
| `hevc_idr_ctu16_yuv_nal` glue | 70 | 33 | 0 | 0 |
| `hevc_yuv_ctu16_idr_nal` arbiter glue | 32 | 22 | 0 | 0 |
| `hevc_yuv_pixel_ctu16_idr_nal` raw-Y glue [15] | 11 | 4 | 0 | 0 |
| `hevc_shared_transform_scheduler` [16] | 116 | 25 | 0 | 0 |
| `hevc_shared_transform_core` control/selection [17] | 1423 | 139 | 16 | <=32 |
| `hevc_paired_transform8_core` control/datapath [22] | 1317 | 207 | 16 | <=32 |
| `hevc_shared_transform_service` wrapper [18] | 2 | 0 | 0 | 0 |
| `hevc_shared_quant_dequant` control [19] | 493 | 79 | 2 | 0 |
| `hevc_shared_reconstruction_core` FSM/buffers [20] | 114 | 62 | 0 | 2 |
| `hevc_dual_reconstruction_core` control/ring [21] | 233 | 93 | 34 | <=72 |
| `hevc_luma_reference_line_store16` | control/substitution logic | small + 425-bit capture | 0 | 2 / 3 |
| `hevc_ctu16_intra_prefix` | 20 | 7 | 0 | 0 |
| `hevc_ctu16_syntax_scheduler` glue [8] | 40 | 8 | 0 | 0 |
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
| `hevc_cabac_bin_step` active split specialization | 592 | 62 | 0 | 0 |
| `hevc_cabac_context_ram` | small port mux | 7 output bits | 0 | 1 |
| `hevc_cabac_encoder` accelerated hierarchy*** | 1721 | 234 | 0 | 0 |
| `hevc_coefficient_context_init` [5] | ≤176 | 20 | ≤1 | 1 |
| `hevc_ctu16_cabac` glue/map only [6] | 89 | 12 | 0 | 0 |
| `hevc_nal_writer` | 38 | 15 | 0 | 0 |
| `hevc_parameter_set_streamer` control | 37 | 16 | 0 | 0 |
| `hevc_parameter_set_rom` | small port mux | 8 output bits | 0 | 1 |
| `hevc_idr_slice_header` | 133 | 38 | 0 | 0 |
| `hevc_idr_slice_nal` glue only [7] | 29 | 4 | 0 | 0 |
| `hevc_idr_ctu16_nal` glue only [9] | 50 | 26 | 0 | 0 |
| `hevc_tu16_cabac_bridge` glue/staging [10] | 57 | 36 | 0 | 1 |
| `hevc_luma_ctu16_idr_nal` integration glue [11] | 24 | 10 | 0 | 0 |
| `hevc_luma_pixel_ctu16_idr_nal` integration glue [13] | 10 | 3 | 0 | 0 |
| `hevc_camera_yuv420p_ingress` control + stripe RAMs [14] | control | small | 0 | 64 / 96 |
| Known separate-module luma/shared-control subtotal | <=28841* | 4586 | <=52 | <=46 |

This is not an Efinity place-and-route result and LUT4 counts do not map
one-to-one to Efinix logic elements. The small predictor reference arrays
intentionally become registers because
they need indexed access while pixels are streaming. The source replay and
large reconstructed-edge stores keep synchronous one-address-per-cycle ports
so Efinity can infer hard RAM instead of LUT memory.

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
The active split CABAC bin-step specialization maps to 592 LUT4 and 62 FF in
the same portable flow; its 2.4-kbit constant tables may instead be mapped into
one of the abundant 5-kbit EBRs after adding a synchronous lookup stage.

`***` The byte-encoder row includes its active registered split bin-step and
black-boxes only the context RAM. The accelerated CABAC hierarchy is therefore approximately
1721 LUT4, 234 FF, zero DSPs and one EBR in the portable estimate. The registered
regular-bin boundary lowers portable LUT depth while leaving the measured CTU
admission interval unchanged. Exact delay and packing still require an Efinity
timing result before the 180-MHz system target can be considered proven.

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

[8] The CTU16 scheduler row black-boxes the 20-LUT4/7-FF prefix child. The
complete scheduler hierarchy is about 60 LUT4 and 15 FF, with no DSP or EBR.

[9] The complete slice-output row black-boxes the existing CTU-CABAC and
IDR-NAL children. Its 50 LUT4 and 26 FF cover automatic context/slice startup,
CTU X/last tracking, completion/error checks and a one-clock inter-CTU guard
that keeps the next descriptor aligned with the updated X coordinate. It adds
no payload RAM, DSP or EBR.

[10] The TU-to-CABAC bridge row black-boxes the reconstruction loop and the
256x16 coefficient RAM. Its 57 LUT4 and 36 FF implement block ownership,
nonzero/CBF reduction, descriptor holding and a one-coefficient-per-clock synchronous
RAM replay under backpressure. The staging RAM costs one 5-kbit EBR and avoids
queuing an all-zero TU in the downstream coefficient banks.

[11] The pixel-to-NAL integration row black-boxes the existing TU bridge and
IDR-NAL hierarchy. Its control implements ownership of the single TU16 and a completion barrier between the independently backpressured
reconstruction and NAL branches. It adds no RAM or arithmetic.

[12] The frontend row black-boxes both predictors, the SAD unit and the 256-byte
source RAM. Its estimate covers mode/replay control plus 38 saved reference
bytes; the source buffer consumes one EBR.

[13] The raw-pixel top row black-boxes the reference store, frontend and previous
pixel-to-NAL core. Its ten LUT4 and three FF cover block launching and CTU-level
quality retention.

[15] The raw-colour top black-boxes the luma frontend, luma reference store and
prepared-YUV core. Its 11 LUT4 and four FF cover joint start qualification,
accepted-reconstruction feedback and the slice-row availability boundary. It
adds no arithmetic or storage RAM.

[16] The shared-transform scheduler contains no arithmetic or RAM. Its 116 LUT4
and 25 FF implement three-client command arbitration, full-block ownership,
ready/valid routing and independent 64/256-sample protocol counters.

[17] The shared core estimate black-boxes the 16-lane MAC and all 32 RAM banks,
so 1423 LUT4 and 139 FF cover state, addressing, rounding/clipping, the elastic
PASS2 output pipeline and the exact TU8/TU16 coefficient selection. A separate
operator audit of the full hierarchy
finds exactly 16 signed multipliers. The two 4096-bit scratch planes contain only
8192 data bits, but their 256-bit-per-cycle read bandwidth is expressed as sixteen
16x16 banks per plane; the conservative bound is therefore 32 EBRs until Efinity
reports its actual packing. Enabling streaming forward PASS1 gives a portable
control estimate of 1444 LUT4 and 145 FF; the column-major streaming inverse mode
uses 1450 LUT4 and 145 FF. DSP and RAM counts are unchanged.

[18] With the transform core black-boxed, the service wrapper adds two LUT4 and
no registers around the already counted 116-LUT4/25-FF scheduler. Its integrated
operator audit still finds exactly 16 multipliers and the same 32 RAM banks.

[19] The shared quant/dequant estimate black-boxes its explicit two-multiplier MAC.
The remaining selectable TU8/TU16 shifts, rounding, saturation and two-stage
ready/valid pipeline use 493 LUT4 and 79 FF in the portable LUT4 mapping.

[20] With the transform, quantizer, QP mapping, reconstruction arithmetic and
two RAM children black-boxed, the full-block controller uses 114 LUT4 and 62 FF.
Its 256x8 prediction RAM and 256x16 dequantized-coefficient RAM add two EBRs.
The complete operator audit remains at 18 multipliers and adds no third arithmetic
copy.

[21] This estimate black-boxes both transform cores, the shared quantizer, QP
mapping, reconstruction arithmetic and eight RAM children. The 233 LUT4 and 93 FF
cover the two controllers, four-entry ordered context ring and stream routing. A
full-hierarchy operator audit finds exactly 34 multipliers: 16 forward, 16 inverse
and two shared quant/dequant multipliers. Each of the four contexts has one 256x8
prediction and one 256x16 dequantized-coefficient RAM. Together with the two
conservatively unpacked transform cores, the core bound is 72 EBRs.

[22] A full operator audit finds exactly 16 multipliers in the explicit 8+8 MAC.
Each streaming lane uses eight input and eight intermediate synchronous banks;
the complete pair therefore has the same conservative 32-bank EBR bound as one
shared TU16 core. With those banks and the MAC black-boxed, the two lane controls
use about 1264 LUT4 and 198 FF; ordered input/output routing adds 53 LUT4 and nine
FF. This is a verified replacement datapath for the shared core's chroma mode,
not an additional 16-DSP block in the final T20 design.

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
The prepared-pixel wrapper adds no EBR. The raw-pixel frontend adds one EBR for
source replay, while the 1280-pixel top-line reference store adds two, taking the
connected estimate from nine to twelve of 204 EBRs. The QP initialization
product raises the conservative DSP count to 34.

[14] The I420 ingress uses two `FRAME_WIDTH x 16 x 8` banks: 64 T20 EBRs at
1280 pixels or 96 EBRs at 1920 pixels. Cb and Cr reuse the same banks.
Including the complete colour encoder gives approximately 80 to 84 EBRs
for 1280-wide video or 117 to 121 EBRs for 1920-wide video. The range depends
on whether Efinity packs the 4608 chroma scratch bits into one EBR or maps the
five logical arrays separately. Both bounds remain below the T20 total of 204
5-kbit EBRs; small control memories may add implementation-dependent packing
overhead.

At 1280 pixels each chroma reference-store top line is 640x8 bits and fits one
5-kbit EBR; Cb and Cr therefore add two EBRs. The shared CTU16 controller adds no
RAM of its own; it selects those two stores around one predictor and one TU8
bridge. At 1920 pixels each 960x8 line
uses two EBRs, for four total. The predictor itself uses registers only.

Each TU8 syntax controller adds one 1024-bit synchronous coefficient store. The
YUV top uses two of them, so the conservative cost is two 5-kbit EBRs, though
Efinity may pack them with other small memories. It does not add a CABAC
context bank or DSP because chroma uses the existing last, significance and level
context address ranges.

The legacy colour hierarchy still exposes up to 51 multiplier operators because
its luma and chroma transform/quant paths remain physically parallel. The verified
replacement core performs TU8/TU16 forward and inverse transforms with exactly 16
multiplier operators shared across every mode. The shared quant/dequant block adds
exactly two more, so the replacement arithmetic is 18 DSPs, or 19 including QP
context initialization, comfortably below the T20 total of 36.

Excluding the three legacy transform/quant LUT models, the known logic subtotal
with the dual forward/inverse controls is about 10149 LUT4, versus 19728 T20
logic elements. The dual reconstruction core uses at most 72 conservatively
unpacked EBRs. Replacing the single core raises the system estimate to roughly
148 to 152 EBRs at 1280-pixel width and 185 to 189 at 1920-pixel width. Both
remain below the T20 total of 204, but the 1920-pixel configuration leaves only
15 to 19 EBRs for implementation-dependent packing overhead. The exact bank
packing, routing cost and Fmax require Efinity synthesis.

The selectable transform, quant/dequant and full reconstruction sequence is now
bit-exact, but the single-core controller is a functional integration point rather
than the final real-time architecture. With transform PASS2, coefficient replay
and reconstruction all pipelined, measured no-stall latency is 1549 cycles for
TU16 and 397 for TU8, or 2343 serial cycles for one Y+Cb+Cr CTU16. At 3840 CTUs
per 1280x768 frame this would still require about 540 MHz for 60 fps and is
therefore not viable as-is.

The dual-core stage is bit-exact and verified across twelve consecutive Y/Cb/Cr
CTUs. A CTU is accepted as one 256-sample Y command followed by one 128-sample
paired-chroma command (64 Cb samples, then 64 Cr samples). Four ordered contexts
absorb the small forward/inverse skew. Earlier reported 1554- and 1202-cycle
dual-core intervals are superseded: the cocotb source inserted
an unintended idle cycle after every accepted sample. The corrected no-stall source
holds `s_valid` continuously and demonstrates the intended one-sample-per-clock
camera interface; a separate test still injects deliberate input and output stalls.

The live forward and inverse paths now each use one shared transform fabric. Streaming
TU16 PASS1 overlaps every completed raster row with loading of the next row. During
the paired-chroma command, Cb PASS2 and quantization overlap Cr load/PASS1. Command
acceptance intervals therefore alternate between 535 clocks for Y and 207 clocks for
the Cb/Cr pair, giving a measured forward CTU interval of 742 clocks. Column-major
replay overlaps inverse PASS1 with coefficient loading; Cb reconstruction also
overlaps replay of Cr. Reconstructed CTUs have a 744-clock steady interval. At 3840
CTUs per 1280x768 frame and 60 fps this requires 171.42 MHz, 9.7% less than the old
824-clock/189.85-MHz path. Coefficients and pixels remain bit-exact with input stalls
and independent coefficient/pixel backpressure.

`hevc_shared_transform_fabric16` now implements the next transform integration
stage. One physical datapath serves either one luma TU16 or a simultaneous Cb/Cr
TU8 pair. It contains exactly one 8+8 MAC boundary (16 multiplier operators), 16
input banks and 16 intermediate banks. TU16 uses both MAC halves as one 16-term
dot product; paired TU8 uses them as independent eight-term products. Therefore a
forward/inverse dual-transform reconstruction pipeline needs two fabric instances,
not four separate luma/chroma datapaths: 32 transform DSPs and at most 64
conservatively unpacked transform EBRs, matching the present dual-core resource
class rather than adding another 32 banks for chroma.

The fabric is bit-exact in all four modes and under independent input/output
backpressure. Measured no-stall command latency is 532 clocks for TU16 and 203
clocks for the Cb/Cr pair; output spans are continuous 256 and 128 clocks. Packed
controller/datapath ports are used deliberately so both Verilator and the current
Yosys frontend accept the RTL. With RAM and MAC treated as physical black boxes,
the conservative standalone control/routing estimate is 3943 LUT4 and 353 FF per
fabric, plus exactly 32 bank instances and 16 DSP multipliers. Compared with the
1452-LUT luma controller portion, two fabrics may add roughly 4982 LUT4 to the
known 10149-LUT system subtotal, for about 15131 LUT4 (77% of T20) before Efinity
packing and routing. This is still plausible, but the margin is no longer large.

Both fabric instances are now integrated into the live dual reconstruction core.
Structural synthesis reports exactly 64 transform-bank instances and 32 transform
multipliers; shared quant/dequant raises this to 34 multipliers, or 35 of the T20's
36 DSPs after context initialization. With bank RAMs, DSP boundaries and the existing
storage/quant blocks treated as physical black boxes, Yosys reports 8130 LUT4 and
815 flip-flop cells for the complete dual controller and fabric routing. This keeps
the projected full-system subtotal near 15131 LUT4 (about 77% of T20) and the earlier
148--152 EBR estimate at 1280-pixel width. The implementation therefore still looks
plausible in T20, but only one DSP and a moderate LUT/routing margin remain. Final
routable Fmax, EBR packing and power must be measured in Efinity.

The shared arithmetic is now connected to the complete colour camera-to-NAL path.
`hevc_yuv_ctu16_idr_nal` no longer instantiates the legacy luma TU16 bridge and
chroma TU8 reconstruction controller; both planes pass through the dual fabric while
the existing HEVC CABAC and Annex-B writer remain unchanged. Separate replay stores
decouple the variable-rate syntax engine from transform output. Prepared-Y/raw-chroma
and raw-YUV420 top-level tests both match the Python reference reconstructed pixels
and Annex-B byte stream exactly under randomized pixel, coefficient and NAL
backpressure.

The three replay memories contain 4096 + 1024 + 1024 bits. Conservatively they use
three 5-kbit EBRs, one more than the old sequential luma/chroma bridges, so the
1280-pixel full-system projection becomes roughly 149--153 of 204 EBRs. The bridge
adds no multipliers: structural Yosys still reports 34 arithmetic multipliers, or
35 of 36 T20 DSPs including context initialization.

The complete raw-YUV420 camera path is also verified across two horizontally
adjacent CTU16 blocks. The second block uses the reconstructed right edges of the
first block as its Y, Cb and Cr reference samples. With randomized camera, pixel
and NAL backpressure, both reconstructed planes and the complete Annex-B stream
remain bit-exact against the Python model. This test is available as
`make test-yuv-pixel-ctu16-multictu-verilator`.

This end-to-end test exposed and then removed the entropy-coding serialization
limit. With no stalls, luma and chroma reconstruction originally finished 1699 and 1908 clocks
after each CTU enters the arithmetic core. The original four-clock CABAC loop
admitted the next CTU at clock 4428. A combinational bin boundary, same-address
context forwarding and elastic single-byte emission reduced the serialized
camera-to-NAL interval first to 3275, then 2821 and finally 2726 clocks.

The NAL/CABAC transaction is now decoupled from reconstruction completion. In
addition, the raw-luma reference and mode-decision front end can accept the next
CTU while Cb/Cr reconstruction of the preceding CTU finishes. This reuses the
existing 256-byte intra source RAM as a one-entry elasticity buffer; it adds no
full-CTU frame buffer or DSP. The front end now also stores both prediction
candidates in one 256x16 RAM, so the selected prediction can be replayed without
reloading 19 references and rerunning both predictors. Finally, the 37-sample
reference-store scan issues one RAM read per clock instead of alternating issue
and capture states. These changes reduce luma/chroma completion to 1643/1852
clocks and the measured no-stall input interval to exactly 1642 clocks: 41.8%
below the previous 2821-clock result and 62.9% below the original 4428-clock loop.
Reconstructed Y/Cb/Cr pixels and all 189 Annex-B bytes
remain bit-exact under randomized camera, reconstruction and NAL backpressure. The
selected dense two-CTU vector generates 651 and 905 CABAC bin events. A dedicated
regression also verifies twelve consecutive updates of one context address at the
intentional one-bin-per-two-clocks cadence.

A 1280x720 frame contains 80 x 45 = 3600 CTU16 blocks. At 1642 clocks/CTU the
steady-state requirement is 177.336 MHz for 30 FPS. A 180 MHz encoder clock gives
30.45 FPS before the small slice-boundary overhead; 185 and 200 MHz give 31.30
and 33.83 FPS. The cocotb performance regression explicitly checks that the
measured interval satisfies 720p30 at 180 MHz. Use `SLICE_CTU_ROWS=5` for 720
lines, because the 45 CTU rows must be divided into an integer number of
independent slices.

The updated portable T20 projection remains close to 15400 LUT4 (approximately
78.3%), 35 of 36 DSPs and roughly 150--154 of 204 EBRs. The extra 4096-bit
prediction-pair RAM conservatively costs one EBR; the pipelined reference scan
adds no memory. Both 256-deep prediction memories carry explicit block-RAM
inference attributes. The complete raw-YUV admission shell is 52 LUT4 and 31 FF.
After registering both MPS and LPS regular paths, the elastic CABAC hierarchy is
1721 LUT4 and 234 FF, with no added DSP or EBR. This is 6 LUT4 fewer and two FF
more than the preceding LPS-only split, so the full-system projection remains
close to 15400 LUT4. Final routable timing and the exact packed resource count
still require an Efinity build.

The CABAC encoder now registers every regular context-coded bin between the
range-table/state stage and the final 32-bit low update/renormalization stage.
Bypass bins retain their one-cycle path; consecutive same-context regular updates
are accepted every two clocks. Portable Yosys LUT4 mapping of the specialized bin
step reduces the longest register-to-register combinational depth from the
original 18 levels, through 16 with the LPS-only split, to 15 LUT levels. This is
not an Efinity delay estimate and ignores dedicated carry mapping, but it removes
the remaining unregistered MPS range/state-to-low chain.

The extra regular-bin cycle does not change measured system throughput: the dense
two-CTU camera-to-NAL regression still admits CTUs exactly 1642 clocks apart and
reports 30.45 FPS at 180 MHz. Reconstructed Y/Cb/Cr data, the 189-byte Annex-B
stream and randomized-backpressure behavior remain bit-exact. The eight-CTU
multi-row regression also passes; the added CABAC service latency stays hidden
behind the existing reconstruction/replay elasticity for the tested dense stream.

Widening the internal sample or coefficient buses is not the next useful timing
trade. Camera ingest, reference reconstruction and coefficient replay already
stream at one sample per clock, while reconstructed-neighbor and CABAC-context
updates are inherently sequential. A two-sample datapath would duplicate RAM
ports, arithmetic and routing without shortening the remaining 16-level CABAC
dependency. A separate lower-frequency NAL/radio clock domain with an asynchronous
FIFO can still be added at the ESP32 boundary later; it is a clean CDC/isolation
choice, not a way to reduce the encoder clock required for 720p30.

## T20 packet output and camera snapshot debug

The `t20f169_spi_debug` board build now buffers each custom-codec stripe in a
dual-clock, two-slot packet RAM. Base and enhancement bytes may arrive
interleaved from the entropy writer but are emitted as separate transactions.
The codec/control PLL output is named `pll_60Mhz` and physically runs at
60 MHz; its 14 ns (71.43 MHz) SDC constraint is intentionally retained as
timing margin.
`PAR_CS` is high from the high nibble of the first byte through the low nibble
of the final byte; it is then low for a programmable gap (32 `PAR_CLK` cycles by
default). Each layer payload is limited to 2048 bytes. `PAR_CLK` remains a
continuous 24 MHz clock and bytes are sent high nibble first.

The camera probe captures the first 32 active 1280-pixel YUV422 lines following
the armed VSYNC edge: 81,920 raw bytes. Five bytes are exposed as one 40-bit
debug word. The RAM is written in the `CSI_PCLK` domain and read synchronously
through the SPI/control clock domain; no camera signal is sampled directly by
the codec clock. For the T20 build, the byte stream is stored as 16,384
byte-oriented 40-bit words. Efinity maps the simple inferred memories into 160
5-kbit EBRs, effectively using eight bits of each native ten-bit location.
Compared with the explicit five-byte-to-four-word packing, this spends 32 more
EBRs but removes the large 128-bank fabric read mux. In the complete board
build it reduces mapped LUTs from 11928 to 10818 and flip-flops from 7144 to
6851. The placed design uses 16167/19728 logic elements, 197/204 EBRs and all
36 DSPs. The 60 MHz domain closes the 14 ns constraint with +0.613 ns slack
(74.70 MHz analyzed Fmax).

The custom-codec datapath does not reset payload registers whose contents are
qualified by a reset control/valid bit. State machines, valid flags, counters,
errors and externally visible control state still have explicit reset values.
This is safe in a four-state simulation: an uninitialized payload may be `X`
only while its valid flag is low, and no accepted transaction observes it.
At the preceding 128-EBR checkpoint this change reduced flip-flops driven by reset from
3592 to 1920 and the main 60 MHz reset fanout from 3197 to 1525. The mapped LUT
count fell from 14539 to 11873, while use stayed at 165 EBR and 36 DSP. The
post-route codec-clock estimate is 74.62 MHz; with the board project's current
14 ns timing constraint, WNS is +0.599 ns. The new critical path is coefficient
queue ownership/control rather than the DCT datapath.

The codec test source is selectable without rebuilding the bitstream. Mode 0
keeps the pseudo-random stress source, mode 1 generates a deterministic luma
gradient with fixed chroma, and mode 2 generates high-contrast luma/chroma
bars. Modes 1 and 2 make the compressed output repeatable and are intended for
initial FPGA-to-ESP32 packet-path verification before connecting live camera
pixels to the encoder.

SPI uses mode 0 and active-low chip select. Keep SCK at or below one eighth of
the codec/control clock. The debug commands are:

| Command | Payload / response |
|---|---|
| `01` | Write gap low, gap high, polarity flags (`bit0=VSYNC high`, `bit1=HREF high`), then source mode (`0..2`) |
| `02` | Write LED override mask, then manual LED value; bits 5:0 use logical `1=on` |
| `20` | Arm a new 32-line capture at the next VSYNC |
| `22` | Select snapshot word address, little endian (14 bits) |
| `80` | Read ID/version, status, gap, current packet length and packet count |
| `81` | Read captured line count, last line byte count, word count and cache-valid |
| `82` | Read cached 40-bit word as five little-endian bytes plus valid; address auto-increments |
| `83` | Read auto LED state, override mask, manual state and effective state |

Set an address with `22`, wait for the synchronous read to complete, then issue
repeated `82` transactions to walk through the snapshot. Packet overflow,
camera framing error and SPI command error are visible in status and on LED 2.
All six board LEDs are active low only at the top-level pins. Internally and on
SPI, one always means illuminated. After reset the override mask is zero, so
LEDs show heartbeat, PLL lock, combined sticky errors, codec busy, Q24 quality
and camera capture busy. Setting a mask bit transfers only that LED to ESP32;
writing mask `0x3f` gives ESP32 complete control, while writing zero restores
all automatic diagnostics.

The dedicated regressions are:

```bash
make -C fpga test-layer-packet-pingpong-verilator
make -C fpga test-camera-yuv422-snapshot-verilator
make -C fpga test-custom-spi-debug-control-verilator
```
