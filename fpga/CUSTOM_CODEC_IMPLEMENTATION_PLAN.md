# T20 custom stripe codec implementation plan

This document freezes the first production-oriented FPGA scope for the custom
1280×16 stripe codec. The Python reference remains the bitstream and quality
oracle. Radio packet buffering, reordering and LF duplication are ESP32 jobs.

## 1. Frozen production profile

Input and independence:

- 1280×720 at 30 frames/s;
- 8-bit YUV420 camera stream;
- one independently decodable 1280×16 luma stripe and matching 640×8 Cb/Cr;
- 80 CTU16 units per stripe and 45 stripes per frame;
- prediction, entropy and DC state reset at every stripe;
- loss of a stripe never changes the decoder state of the next stripe.

Coding tools:

- four luma 8×8 transforms plus one Cb and one Cr 8×8 transform per CTU;
- signed integer Q14 DCT8 already used by the Python model;
- fixed quantization profile for a stripe;
- one CTU16 intra mode selected by the existing bounded SATD path;
- base layer: first six diagonal-zigzag luma coefficients and first three
  chroma coefficients;
- enhancement layer: all remaining coefficients;
- diagonal zigzag and the current fixed JPEG-compatible VLC tables;
- base-only reconstruction is the only encoder prediction reference;
- 2-byte coarse LF summary per CTU: two Y averages and one Cb/Cr average.

Explicitly excluded from the first RTL version:

- mode-dependent coefficient scan;
- local deterministic or signalled 8×8 intra modes;
- activity/fullness adaptive quantization;
- gradient prediction;
- CABAC, learned VLC tables, trellis/RDO and temporal prediction;
- YUV422 and RGB camera input.

The excluded Python experiments stay useful as regression evidence, but they
are not part of the hardware datapath. Their measured rate/distortion was worse
than fixed-Q diagonal scan.

## 2. FPGA/ESP32 boundary

The FPGA emits a tagged elementary stream; it does not assemble radio packets:

```text
STRIPE_START(stripe_id, quality)
BASE_BITS(...)
ENHANCEMENT_BITS(...)
LF_SUMMARY(160 bytes at width 1280)
STRIPE_END(base_bit_count, enhancement_bit_count, flags)
```

The 4-bit FPGA-to-ESP32 bridge serializes the tagged records. The ESP32 stores
and rearranges them as:

```text
radio A_N = base(N) + LF(N+1)
radio B_N = enhancement(N)
```

Measured Q20 averages on the current 1280×720 test frame are 884 bytes for A
and 521 bytes for B. A and B may each be fragmented into multiple physical
radio packets without changing the FPGA format.

The FPGA needs only a small asynchronous output FIFO. It must never hold a
complete compressed stripe or the neighboring LF copy.

## 3. Hard output limits

Fixed Q alone cannot guarantee a finite practical packet size on noise or an
adversarial image. The RTL therefore needs a hard syntactically valid limiter,
not an adaptive quality controller.

Initial configurable limits:

```text
BASE_MAX_BYTES        = 2048
ENHANCEMENT_MAX_BYTES = 1536
LF_BYTES              = 160
MAX_CODEC_BYTES       = 3584
MAX_ESP_PAYLOAD       = 3744 bytes before transport headers
```

The limits are compile-time defaults and writable debug registers. ESP32
allocates buffers from the announced limits rather than observed averages.

Limiter rules, in priority order:

1. Mode, DC and an EOB/empty marker for every remaining block are mandatory.
2. Base AC tokens are admitted only while the writer can still reserve the
   worst-case mandatory tail for all unencoded blocks.
3. When the base budget is exhausted, the current base segment terminates with
   EOB and all later base AC values become zero. Encoder reconstruction uses
   exactly those transmitted zeros.
4. Enhancement AC tokens are admitted while its independent budget remains.
   Once full, every remaining enhancement segment is emitted as empty.
5. No partially written VLC token is legal.
6. Overflow, impossible mandatory reserve or output backpressure timeout sets
   a sticky error flag and terminates the stripe with a valid marker where
   possible. It must not corrupt the next stripe.

The Python model must implement the same limiter before RTL starts. Random,
checkerboard and maximum-amplitude residual tests must prove that encoded size
never exceeds either bound and encoder/decoder references remain bit-exact.

At the proposed maximum, 45 stripes × 30 frames/s require at most about
40.4 Mbit/s before transport headers. A 4-bit output bus therefore needs at
least 10.1 MHz of sustained payload clock. The implementation target is at
least 24 MHz plus a dual-clock FIFO, giving more than 2× margin.

## 4. T20 memory plan

The camera cannot be stalled. Encoding one stripe while receiving the next
requires ping-pong 16-line storage.

One 1280×16 YUV420 band contains:

| Plane | Bytes |
|---|---:|
| Y, 1280×16 | 20,480 |
| Cb, 640×8 | 5,120 |
| Cr, 640×8 | 5,120 |
| Total | 30,720 |

With straightforward byte-wide mapping to 5-kbit EBRs, one bank is about 60
RAM blocks and ping-pong storage is about 120 blocks. The first implementation
uses this simple mapping because it has predictable addressing and timing.

Provisional additional RAM allocation:

| Function | 5-kbit blocks |
|---|---:|
| Ping-pong camera bands | 120 |
| Coefficient ping-pong buffers | 4 |
| DCT/quant/VLC constant ROMs | 2–4 |
| FPGA-to-ESP32 asynchronous FIFO | 1–2 |
| Debug/snapshot storage | 1–2 |
| Expected total | 128–132 of 142 |

Small transform intermediates, left references, LF accumulators and bit-writer
state should use registers/LUT RAM to protect the remaining EBR margin.

If place-and-route needs more RAM margin, a later optimization may pack five
8-bit pixels into four 10-bit EBR words. It can reduce the camera store toward
98 blocks, but it is deliberately deferred because it complicates addressing
and cross-word reads.

## 5. DSP and cycle plan

There are 108,000 CTU16 units/s at 720p30. At 70 MHz the absolute budget is
about 648 cycles/CTU. The production target is no more than 520 cycles/CTU,
leaving about 20% scheduling and blanking margin.

Provisional datapath:

- 32 DSP blocks assigned to a registered DCT/inverse-DCT MAC fabric;
- four DSP blocks reserved for quantization/dequantization or routing relief;
- forward DCT for six blocks: approximately 192 multiply cycles at 32 lanes;
- sparse base inverse reconstruction: target 60–100 cycles/CTU;
- prediction/SATD, scan, VLC and control overlap through ping-pong buffers;
- target sustained total: 400–520 cycles/CTU.

Only the sparse base layer is inverse transformed in the encoder. Enhancement
does not participate in later prediction and therefore needs no encoder-side
inverse transform.

The clock target is 70–80 MHz, not 150–200 MHz. Every DSP MAC stage, quantizer,
scan lookup and bit-packer boundary must be registered. Extra latency is
acceptable; sustained CTU interval and absence of long combinational paths are
the timing criteria.

## 6. RTL module split

Suggested modules and contracts:

1. `custom_yuv420_stripe_pingpong`
   - camera write port, codec read port and bank ownership;
   - exact 16/8/8 line geometry;
   - no overwrite before codec release.
2. `custom_stripe_scheduler`
   - frame/stripe/CTU/block coordinates;
   - fixed six-block CTU order;
   - stripe state resets.
3. `custom_intra16_frontend`
   - DC/horizontal predictor availability;
   - bounded sequential SATD mode selection;
   - base-reconstructed left references only.
4. `custom_dct8_service`
   - registered shared MAC lanes;
   - forward and sparse inverse requests;
   - explicit width, rounding and saturation semantics.
5. `custom_quant8`
   - fixed ROM table, reciprocal multiply and shift;
   - separate luma/chroma tables and finer base entries.
6. `custom_layer_split_scan8`
   - fixed diagonal zigzag;
   - tagged base/enhancement coefficients.
7. `custom_vlc_encoder`
   - fixed canonical tables;
   - one complete token at a time, bounded token width.
8. `custom_dual_budget_writer`
   - independent base/enhancement bit reservoirs;
   - mandatory-tail reservation and clean EOB truncation;
   - exact bit counts and overflow flags.
9. `custom_lf_summary`
   - four 4-bit averages per CTU and 160-byte stripe stream.
10. `custom_codec_stream_mux`
    - elementary record tags and asynchronous FIFO to the 4-bit bridge.
11. `custom_codec_top_720p`
    - camera ingress, codec pipeline, debug registers and performance counters.

No module should infer a tri-state internal signal. All combinational outputs
must have defaults, and every ready/valid dependency crossing more than one
functional stage must be registered or pass through a FIFO/skid buffer.

## 7. Verification and implementation stages

### Stage 0 — freeze Python bounded stream

- implement independent base/enhancement byte limits;
- serialize exact elementary record headers and flags;
- add truncation, random, checkerboard and burst-loss tests;
- freeze golden bitstreams for at least Q18, Q20 and Q24.

Exit: exact size bounds, deterministic decode and no reference drift.

### Stage 1 — arithmetic primitives

- DCT8 forward;
- sparse base inverse;
- quant/dequant;
- zigzag/layer splitter;
- LF accumulator.

Exit: Cocotb bit-exact against Python for directed and random vectors, with
explicit maximum internal widths and zero unexpected saturation.

### Stage 2 — bounded entropy writer

- fixed VLC lookup;
- base/enhancement reservoirs;
- mandatory-tail accounting;
- tag stream and output backpressure.

Exit: byte- and bit-length-exact block/CTU tests including every truncation
boundary and maximum VLC token.

### Stage 3 — CTU reconstruction loop

- prediction and mode selection;
- six forward transforms;
- base-only inverse reconstruction;
- left-reference update.

Exit: one CTU and one complete 1280×16 stripe match Python pixels and bits.

### Stage 4 — real camera streaming

- ping-pong stripe RAM;
- simultaneous camera fill and codec drain;
- Y/Cb/Cr scheduling and frame-edge handling.

Exit: no overwrite/underflow in a continuous synthetic 720p30 camera stream.

### Stage 5 — ESP32/debug integration

- tagged 4-bit output bridge;
- SPI control/status and deterministic injected camera data;
- counters for cycles/CTU, FIFO high-water, base/enh bytes and truncations.

Exit: captured ESP32 elementary stream decodes byte-exactly in Python.

### Stage 6 — T20 synthesis and closure

- Efinity synthesis/place-and-route only after module-level simulation passes;
- batch critical-path fixes by registered boundary, not one net at a time;
- continuous 720p30 hardware stress stream.

Exit targets:

| Metric | Target |
|---|---:|
| Fmax | at least 70 MHz |
| Sustained interval | at most 520 cycles/CTU |
| DSP | at most 36, preferred 32–35 |
| 5-kbit RAM | at most 135 of 142 |
| LE | preferred below 16,000 |
| Base bytes/stripe | never above 2048 |
| Enhancement bytes/stripe | never above 1536 |
| 720p30 dropped camera samples | zero |

## 8. First implementation task

The first vertical slice is now implemented as `custom_budget_writer.py` and
`custom_dual_budget_writer.sv`. It freezes atomic token admission, independent
layer counters, mandatory-tail release and sticky fatal-error behavior. Cocotb
compares the RTL directly with the Python state machine under backpressure.

The guard output is a stream of complete admitted VLC tokens on
`m_bits/m_length`. The serializer described in section 9 now consumes this
interface. Actual JPEG-table VLC generation and EOB-tail reservation are still
to be integrated into `custom_codec_experiment.py`.

The budget guard treats `m_bits` as opaque. At the packer boundary, the first
bit is left-aligned in `m_bits[31]` and the remaining meaningful bits follow
toward the LSB. This lets `custom_token_byte_packer` use one fixed left shift
per cycle instead of a variable barrel shifter. `left_align_token()` in the
Python model defines the exact wire conversion.

Current regression commands:

```bash
/home/dimka/.venvs/hd-zero-fpga/bin/python -m pytest -q \
  -p no:cacheprovider tests/test_custom_budget_writer.py

cd fpga/sim
PATH=/home/dimka/.venvs/hd-zero-fpga/bin:$PATH make -f Makefile \
  SIM=verilator TOPLEVEL=custom_dual_budget_writer \
  MODULE=test_custom_dual_budget_writer \
  VERILOG_SOURCES=../rtl/custom/custom_dual_budget_writer.sv \
  SIM_BUILD=/tmp/hd-zero-fpga-sim/verilator/custom_dual_budget_writer
```

The budget guard result is 5/5 Python tests and 3/3 Cocotb tests. Generic Yosys
synthesis reports 145 flip-flops, 1,081 primitive cells and no inferred RAM;
this is a sanity estimate, not an Efinity/T20 placement result.

## 9. Token-to-byte serializer

`custom_token_byte_packer.sv` and its Python model maintain independent partial
bytes for base and enhancement while accepting an interleaved tagged token
stream. Full bytes are emitted immediately. Stripe finish emits at most one
zero-padded byte per layer; exact byte-aligned streams receive no extra byte.
The exact bit counts from the budget guard remain authoritative, so padding is
never interpreted as entropy data.

The serializer consumes one payload bit per clock. This avoids a wide dynamic
shift and a long combinational reservoir path. At the hard 3,584-byte codec
limit the payload itself averages 358.4 bits/CTU. Even a pessimistic stream of
two-bit VLC tokens adds at most about 179 token-load cycles/CTU, staying below
the absolute 648-cycle budget at 70 MHz. Normal image streams and longer VLC
tokens have substantially more margin. First-bit-on-load bypass remains a
possible later optimization if hardware counters show it is useful.

`custom_bounded_byte_writer.sv` connects the dual budget guard and serializer,
including ordered finish/drain handling. Verification now covers:

- 9/9 Python guard/packer tests;
- 3/3 budget-guard Cocotb tests;
- 3/3 standalone packer Cocotb tests;
- 1/1 composed limiter-to-byte Cocotb test with random backpressure;
- 4/4 existing custom image-codec regression checks.

Generic synthesis of the composed writer reports 249 flip-flops, 1,598
primitive cells and no RAM. The next implementation boundary is the fixed VLC
encoder: canonical ROM lookup plus combined Huffman/amplitude tokens, followed
by exact EOB-tail reservation in the real Python stripe encoder.

## 10. Fixed VLC encoder

`custom_vlc_encoder.sv` now accepts a JPEG entropy descriptor consisting of
DC/AC class, luma/chroma table, symbol and right-aligned amplitude. It validates
the category/size relationship and emits one atomic, left-aligned token. The
budget guard therefore sees the complete Huffman+amplitude length and can never
truncate a coefficient between its prefix and magnitude bits.

The lookup files are generated by `tools/generate_custom_vlc_rom.py` directly
from `jpeg_radio_codec.HUFFMAN_ENCODE`:

- `custom_vlc_dc_table.hex`: 32 × 22 bits;
- `custom_vlc_ac_table.hex`: 512 × 22 bits;
- total initialized contents: 11,968 bits;
- conservative Efinity allocation: four 5-kbit EBRs because DC and AC are
  separate synchronous memories. The small DC ROM may later share a physical
  block with another constant table if Efinity packing permits it.

ROM lookup, Huffman/amplitude concatenation and final left alignment are split
across registered stages. There is no combinational ROM-to-barrel-shifter path.
`custom_fixed_entropy_writer.sv` connects the descriptor encoder to the budget
guard and byte serializer while retaining the layer, mandatory and reserve
metadata alongside the in-flight token.

Verification covers all 348 valid standard-table symbols, randomized amplitude
bits, ignored high amplitude bits, invalid descriptor handling, output stalls
and a complete descriptor-to-bounded-byte stream. Generic synthesis with the
ROM black-boxed reports about 373 flip-flops and 2,174 primitive cells for the
whole entropy writer. This remains a generic sanity estimate; Efinity decides
the real LE and EBR mapping.

The next boundary is exact mandatory-tail accounting in the real stripe model:
mode/DC/EOB descriptors for every remaining block, base reconstruction from
only admitted coefficients, and bounded image-quality regression at the hard
2,048/1,536-byte limits.

## 11. Bounded Python stripe integration

The real `encode_stripe()` path now uses the same atomic-token budget model as
RTL. For the fixed 1280×16 production profile the initial mandatory reserve is:

| Layer | Reserved bits | Reserved bytes |
|---|---:|---:|
| Base | 12,000 | 1,500 |
| Enhancement | 1,920 | 240 |

The base reserve covers 80 signalled modes, worst-case DC tokens for 320 luma
and 160 chroma blocks, and a valid AC terminator for every block. Enhancement
reserves only its empty/EOB markers. Each shorter real DC immediately returns
unused headroom. A zero-length accounting token releases a reserved EOB when a
segment naturally ends at its final coefficient; it never reaches the byte
packer.

When a base AC token is rejected, that coefficient and the remaining segment
are zero in both encoder reconstruction and decoder output. Every record stores
a model-only CRC of the encoder base reference; decoding checks it and raises
on any prediction drift. The production defaults are exposed as
`--base-max-bytes 2048` and `--enhancement-max-bytes 1536`.

Regression results:

- Q20 on `1.png`: byte-identical to the pre-limiter stream, 29.590115 dB and
  0.439754 bpp; observed maxima 787/777 bytes, no truncation;
- Q24 on `1.png`: byte-identical, 30.099000 dB and 0.498025 bpp; observed
  maxima 830/950 bytes, no truncation;
- random 1280×16 noise at Q20: 1,288/1,536 bytes; enhancement truncates cleanly
  in 365 blocks;
- checkerboard 1280×16 at Q20: 660/1,536 bytes; enhancement truncates cleanly
  in 347 blocks;
- impossible mandatory limits are rejected before the first transform.

Stage 0 size bounding and reconstruction-drift requirements are therefore
complete. The next FPGA-facing block is the coefficient run/category scanner
and scheduler that produces the tested entropy descriptors and exact reserve
release events.

## 12. Quantized-coefficient scanner

`custom_coefficient_scanner8.sv` now accepts one raster-order signed 12-bit
8x8 block and emits the exact syntax-operation stream for the entropy frontend.
VLC operations can feed the fixed VLC encoder directly; RAW and SEGMENT_END
operations tell the following dispatcher whether to write a presence bit, an
EOB token or only release an unused EOB reserve. It implements the Python
`custom_coefficient_scanner.py` contract:

- separate base and enhancement zig-zag ranges;
- luma presence bits and chroma empty-segment EOB handling;
- JPEG run/category symbols, including repeated ZRL descriptors;
- atomic DC/EOB reserve-release events for the hard layer budgets;
- DC clamp to +/-2047 and AC clamp to +/-1023 with a sticky saturation flag.

The 64x12 coefficient store has a synchronous registered read port and block
RAM attributes. Its payload is only 768 bits, so the conservative T20 estimate
is one 5-kbit EBR. The forward and inverse zig-zag maps are constant 64x6 ROMs;
generic Yosys preserves all three memories instead of expanding the
coefficient store into flip-flops. Efinity remains authoritative for physical
packing of the two small constant maps.

There is no separate 64-cycle metadata prepass. While raster coefficients are
written, the inverse zig-zag map tracks the greatest nonzero base and
enhancement positions. With continuous input and an unstalled descriptor sink,
a fully dense luma block completes in exactly 258 cycles and a fully dense
chroma block in 256 cycles, including the 64 load cycles. Empty blocks are much
shorter. This single-buffer reference implementation is deliberately simple;
six worst-case blocks must not be scheduled serially on the final 520-cycle
CTU path.

Verification covers all-zero and long-run directed cases, exact dense-block
cycle bounds, invalid split rejection, saturation and 30 randomized blocks
under independent input/output stalls. The RTL descriptor sequence is compared
field-for-field with Python; Cocotb is 4/4 and the focused Python suite is
14/14.

The next boundary is the syntax dispatcher and a small descriptor FIFO. It
will convert RAW/SEGMENT_END operations into budget-writer tokens and decouple
coefficient scanning from the slower bit serializer. A following two-bank
block scheduler will let transform/quantization fill one 8x8 bank while the
scanner drains the other. Before integration into the stripe top, that wrapper
must prove the aggregate six-block CTU interval against the 520-cycle target
rather than only the latency of one isolated block.

## 13. Syntax dispatcher and bounded block writer

The scanner is now connected to the hard-budget byte path by three small RTL
blocks:

- `custom_syntax_dispatcher.sv` maps VLC operations through the existing
  registered table encoder, maps luma presence to one left-aligned raw bit,
  and maps SEGMENT_END either to an AC EOB or to a zero-length accounting
  token;
- `custom_budget_token_fifo.sv` provides four entries of ordered elastic
  buffering without a combinational ready/valid loop;
- `custom_block_entropy_writer8.sv` composes the coefficient scanner,
  dispatcher/FIFO, dual hard-budget guard and byte serializer behind one
  stripe lifecycle and one 8x8 block input.

A natural segment end is important: it releases the complete reserved EOB
allowance while contributing zero payload bits. A required EOB is encoded by
the selected luma/chroma AC table and releases the same reserve atomically.
Thus the writer can neither omit a required terminator nor charge a terminator
that the decoder does not need.

The dual budget guard now also latches an optional drop independently for each
layer until the next mandatory segment tail. All later optional AC tokens in
that segment are dropped even if a short one would fit. Accepting one would be
incorrect because its run is relative to the previously transmitted
coefficient. The mandatory EOB/accounting token clears the latch for the next
segment. This rule also handles tokens that were already queued when the first
budget rejection became visible.

The FIFO stores 4 x 46 bits in registers. Generic four-input-LUT synthesis of
the dispatcher and FIFO, with the already-counted VLC encoder black-boxed,
reports 205 LUTs and 248 flip-flops. This is intentionally small enough to keep
as local registers; spending a 5-kbit EBR on 184 payload bits is not justified
unless Efinity placement later shows register pressure in this area.

The complete block-to-byte hierarchy retains five inferred memories: the
768-bit coefficient RAM, two 64x6 zig-zag constant maps and the two fixed VLC
ROMs. The conservative physical allowance remains one EBR for coefficients
and four for the VLC tables; Efinity may implement or pack the two tiny maps
differently. Generic hierarchy statistics are 949 RTL cells and are not an LE
estimate.

End-to-end Cocotb feeds four luma and two chroma blocks (one complete YUV422
16x16 CTU), applies independent coefficient and radio-byte stalls, forces the
four-entry FIFO above one entry, and uses tight budgets that reject optional
coefficients. Every output byte, drop count, bit count and mandatory reserve is
checked against the composed Python model. A second test proves that malformed
block metadata remains fatal until the next stripe start. Both tests pass
without an unconsumed reserve.

This wrapper still schedules the six coefficient blocks serially. The next
stage is the two-bank coefficient scheduler: one bank is filled by the
transform/quantizer while the other is scanned. Its performance test must use
representative Q20/Q24 coefficient traces and report both average and
worst-observed CTU intervals; an artificial fully dense block is not a useful
0.5-bpp throughput proxy.

## 14. Two-bank coefficient scheduler

`custom_coefficient_pingpong8.sv` alternates complete raster-order blocks
between two independent synchronous coefficient banks. Only the oldest bank
can drive the syntax stream, so a later block may load and wait at its first
descriptor but can never overtake an earlier block. The scheduler accepts the
next block immediately after the previous 64th coefficient, routes
backpressure to the active input bank, and keeps saturation and metadata errors
sticky for the stripe.

The bounded block writer now uses this scheduler in place of its single
scanner. Its byte-exact six-block YUV422 regression is unchanged, including
tight-budget truncation and random input/output stalls.

With continuous coefficient input and an unstalled syntax sink, two fully
dense luma blocks complete in 456 cycles. Two independent single-bank runs
would require 516 cycles, so 60 of the available 64 load cycles are hidden.
The remaining four cycles are bank handoff/control latency. This dense case is
only a deterministic upper-stress comparison; the radio-rate decision still
needs traces produced by the real Q20/Q24 Python transform and quantizer.

The implementation intentionally duplicates the small scanner controller as
well as the 768-bit coefficient RAM. Generic RTL statistics are:

| Hierarchy | RTL cells | Memory cells |
|---|---:|---:|
| Single scanner | 294 | 3 |
| Two-bank scheduler | 690 | 6 |
| Complete block-to-byte path | 1,345 | 8 |

The physical conservative allowance is now two 5-kbit EBRs for coefficient
banks plus four EBRs for the fixed VLC tables. The duplicated tiny zig-zag maps
may become logic or be packed separately by Efinity. With the scanner treated
as a black box, the bank arbiter itself is about 89 four-input LUTs and 15
flip-flops; most of the 396-cell increase is the second scanner. This remains a
small fraction of T20, but a shared scan engine with external dual banks is a
valid later optimization if Efinity shows LE pressure.

The next measurement step is to export quantized 8x8 block traces from Q20 and
Q24 runs on `1.png`, replay them through the scheduler, and record average,
95th-percentile and worst CTU intervals. That will tell us whether the current
one-coefficient-per-two-cycle scan engine is sufficient or needs a pipelined
read/descriptor queue before implementing the transform-to-bank bridge.

## 15. Representative 720p coefficient replay

`tools/export_custom_scheduler_trace.py` center-crops/scales `1.png` to the
target 1280x720 geometry and exports every quantized 8x8 block immediately
after the integer DCT/quantizer and before budget admission. It runs the real
bounded stripe encoder, including base reconstruction used by later intra
prediction. The fixed diagonal-scan production profile is required; the
discarded mode-dependent scan experiment is deliberately not part of this
hardware trace.

The export contains 45 stripes x 80 CTUs x six blocks for both Q20 and Q24.
Independent 16-line stripes are generated in parallel to keep this exact model
practical without changing its arithmetic or prediction state. The compressed
NPZ is a temporary generated test input rather than a repository artifact.
Generate and replay both qualities with:

```bash
make test-custom-coefficient-trace-verilator
```

For a shorter repeat of one already generated trace, append
`CUSTOM_TRACE_QUALITIES=20` or `CUSTOM_TRACE_QUALITIES=24`.

Full-frame trace statistics and RTL replay with a continuously ready descriptor
sink are:

| Quality | Non-zero coefficients | Average cycles/CTU | P95 | Worst |
|---|---:|---:|---:|---:|
| Q20 | 5.08% | 390.28 | 393 | 440 |
| Q24 | 5.92% | 390.66 | 395 | 444 |

The intervals include the first CTU startup after every stripe-local clear, not
only steady-state differences. At 70 MHz the 720p30 allowance is about 648
cycles/CTU. The observed Q24 worst case therefore retains 204 cycles, or 31.5%
margin. Repeating that worst interval for every CTU would require about 48 MHz;
the average interval corresponds to about 49.8 fps at 70 MHz. Even 60 MHz
retains roughly 20% against the observed worst case.

This closes the question for the coefficient scheduler itself: a wider or
pipelined scan engine is not justified by the representative coefficient
density. It does not yet prove the same interval for the complete entropy path,
because this replay holds `m_ready` continuously high. The next throughput
measurement should feed the same traces through `custom_block_entropy_writer8`
with real VLC lookup, token FIFO, budget guard, byte packer and an unstalled byte
sink. Only if that path pushes P95 toward 648 cycles should its local queue or
VLC issue rate be widened before connecting the transform/quantizer producer.

## 16. Complete block entropy replay

`test_custom_block_entropy_trace8.py` replays the same full Q20/Q24 coefficient
sets through `custom_block_entropy_writer8`, including the synchronous VLC ROM,
dispatcher, four-token FIFO, dual budget guard and byte packer. The byte sink is
continuously ready. Every 16-line stripe is separately started, drained,
finished and restarted, so the effective interval includes both partial-byte
flush and restart overhead.

The current wrapper accepts transform blocks but not the two-bit CTU intra-mode
prefix. Its test reservation is therefore 148 base bits/CTU, or 11840 bits per
stripe, instead of the complete Python stream's 12000 bits. Enhancement keeps
the complete 1920-bit reservation. The missing 160 base bits/stripe equal 900
bytes per 720p frame and must be added by the next syntax-prefix integration;
they are not silently counted as block payload.

Measured results are:

| Quality | Average | P95 | Worst CTU | Effective incl. flush | Worst stripe/CTU | Output bytes | Drops |
|---|---:|---:|---:|---:|---:|---:|---:|
| Q20 | 394.39 | 419 | 551 | 394.55 | 399.65 | 55,311 | 0 |
| Q24 | 398.55 | 440 | 575 | 398.71 | 410.50 | 62,427 | 0 |

The complete block entropy path adds only about eight average cycles/CTU over
the Q24 scanner-only result. The worst individual CTU leaves 73 of the 648
available cycles at 70 MHz, an 11.3% instantaneous margin, and corresponds to
about 62.1 MHz if every CTU were equally difficult. The more relevant worst
complete stripe averages 410.5 cycles/CTU and would need only about 44.3 MHz
for 720p30. The two coefficient banks and stripe buffering therefore absorb
the isolated VLC/packer peaks without requiring a wider scan or VLC issue path.

No coefficient saturated, neither production byte limit was exceeded, and no
optional token was dropped on this frame. The next RTL boundary is an ordered
CTU-prefix input for the two mode bits, followed by the transform/quantizer to
coefficient-bank bridge. Prefix admission must share the same base budget and
must complete before the first luma DC token of its CTU.

## 17. Ordered CTU intra-mode prefix

`custom_block_entropy_writer8.sv` now accepts one two-bit intra mode before
each group of six YUV422 blocks. The two bits are emitted MSB first as mandatory
base-layer RAW operations. Each operation atomically releases one reserved bit,
so the prefix participates in exactly the same hard budget and accounting path
as the coefficient syntax.

The wrapper enforces the stream order rather than relying on the producer:

- stripe start requires a prefix;
- no block is accepted until both prefix bits have entered the syntax FIFO;
- exactly six blocks can be accepted for that CTU;
- the next prefix is not accepted until all six blocks have completed, and a
  seventh block cannot cross the boundary first.

This strict boundary costs a few idle cycles but needs only mode, bit-position
and three-bit block counters. It avoids another queue or CTU metadata RAM and
makes the decoder-visible ordering independent of transform-side stalls.

The Python trace exporter now records the actual selected mode for all 80 CTUs
in every stripe. Full-frame replay uses the complete 12000-bit base reservation
and verifies that all 3600 prefixes and 21600 blocks are accepted in order.
Measured results, including the previously omitted 900 mode bytes per frame,
are:

| Quality | Average | P95 | Worst CTU | Effective incl. flush | Worst stripe/CTU | Output bytes | Bits/pixel | Drops |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Q20 | 408.34 | 433 | 565 | 408.50 | 413.59 | 56,211 | 0.488 | 0 |
| Q24 | 412.57 | 454 | 589 | 412.73 | 424.44 | 63,327 | 0.550 | 0 |

The prefix adds about 14 cycles/CTU in both modes and exactly 900 output bytes,
with no coefficient drops. At 70 MHz the observed Q24 worst CTU retains 59 of
the approximately 648 available cycles and would require 63.6 MHz if repeated
continuously. The worst complete stripe requires 45.8 MHz for 720p30, while the
full-frame average corresponds to about 47.1 fps at 70 MHz. The ordered prefix
therefore does not justify a wider syntax path.

Generic Yosys hierarchy statistics rise from 1,345 to 1,411 RTL cells, while
the inferred memory count remains eight. These counts are comparison metrics,
not Efinity LE estimates; the prefix itself adds no RAM or DSP requirement.

The next boundary is the streaming transform/quantizer-to-bank bridge. It must
produce the six raster-order 8x8 blocks and their base split counts directly
from one 16x16 YUV422 CTU, preserve the measured entropy overlap, and prove the
same complete-frame interval without Python-prepared coefficients.

## 18. Paired Q14 forward DCT8 service

`custom_dct8_pair32.sv` implements the Python model's separable signed Q14
forward residual transform for two 8x8 blocks at once. Eight row-wide input
transfers load both blocks. The MAC fabric then evaluates two frequencies for
both blocks per issue cycle, using exactly 32 registered signed multipliers.
The first stage clips to signed 13 bits and the final stage clips to signed 16
bits with the same round-to-nearest, away-from-zero rule as Python.

The first pass is performed in place. Before processing one input column, its
16 samples are copied to a 256-bit pair register; the four frequency pairs can
then overwrite that consumed column. This removes separate input and
intermediate arrays. The second-pass results enter a two-stage elastic output
pipeline directly, so there is no 2048-bit coefficient output buffer either.
Only two 64x16 work arrays remain.

The datapath is registered at the multiplier output and again after the
balanced adder tree. The longest intended arithmetic regions are therefore:

```text
DSP register -> three-level balanced 32-bit adder tree -> sum register
sum register -> signed Q14 rounding/clip -> work/output register
```

The output supplies adjacent raster coefficients for both blocks every cycle
and remains stable under arbitrary backpressure. A pair takes 99 cycles with
continuous input/output, including load and drain. Three pairs therefore need
about 297 cycles for all six forward transforms of one CTU before overlap with
entropy coding, below both the 520-cycle production target and the measured
approximately 413-cycle Q24 entropy interval.

Cocotb compares every coefficient for a constant block, checkerboard, an
out-of-range saturation case, 12 random physical residual pairs and a separate
random-backpressure run. Both tests pass bit-exactly. Generic Yosys statistics
are 414 RTL cells, two memory cells and exactly 32 `$mul` cells. The two work
arrays have the parallel access pattern of registers rather than simple EBRs;
their physical cost must be checked in Efinity and is not hidden in the generic
cell count.

The next block is a four-coefficient quantizer attached to this paired output.
It may use the four DSPs reserved by the original 36-DSP plan, keeping the
forward transform active at full rate. The quantizer must reproduce signed
`round_div` exactly for fixed Q20/Q24 luma and chroma tables before the pair
output is adapted into the two coefficient banks.
