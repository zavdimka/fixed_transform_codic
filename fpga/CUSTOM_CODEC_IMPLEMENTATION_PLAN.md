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

The next code change should be the Python `custom_dual_budget_writer` model.
It is the last bitstream-level decision that must be frozen before any new RTL
is written. After its image-quality and worst-case tests pass, RTL work starts
with the DCT8 service and bounded entropy writer in parallel-compatible module
boundaries.
