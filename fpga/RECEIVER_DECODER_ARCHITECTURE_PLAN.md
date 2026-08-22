# Receiver decoder and ESP32/FPGA boundary plan

This document freezes the first receiver architecture for the custom 1280x16
stripe codec. The HDMI/OSD pipeline already runs at 1280x720p60. The radio
source is nominally 30 FPS, so the ESP32 must retain compressed frames and feed
each selected frame to the FPGA twice unless a 60 FPS transmitter profile is
used later.

## 1. Ownership boundary

### ESP32-C5 owns

- radio DMA and radio packet CRC validation;
- burst-loss detection, packet sequence tracking and bounded reordering;
- selection of primary base/enhancement data or the preceding packet's LF
  backup;
- compressed frame/stripe storage;
- whole-frame repeat/drop policy that converts the transmitter cadence to the
  fixed HDMI cadence;
- fragmentation into FPGA-link transactions no larger than 1024 bytes;
- prioritization: LF/base first, enhancement only after the near display
  deadline is protected;
- PARLIO/GDMA descriptor preparation and SPI control/telemetry.

The ESP32 must not perform entropy decoding, inverse transforms, prediction or
YUV-to-RGB conversion. It may rearrange transport records because it has ample
RAM and this avoids packet/reorder RAM in the FPGA.

### FPGA owns

- the flow-controlled 4-bit physical link and its asynchronous ingress FIFO;
- link framing, length/version checks and a link CRC;
- stripe/layer scheduling and display deadlines;
- base, enhancement and LF-only entropy syntax;
- inverse quantization, inverse DCT and intra reconstruction;
- base-only prediction references;
- late-enhancement discard and missing-stripe gray concealment;
- two decoded YUV420 stripe buffers;
- raster-paced YUV420-to-RGB, HDMI timing/TMDS and always-on OSD.

The FPGA never waits for software while generating HDMI. At every 16-line
boundary it swaps to a correctly tagged ready stripe or emits gray for that
stripe. OSD is composited afterward in both cases.

## 2. Physical link and hard backpressure

Receiver-role pin directions should be:

```text
PAR_D[3:0]  ESP32 -> FPGA
PAR_CS      ESP32 -> FPGA, active transaction/valid
PAR_CLK     FPGA  -> ESP32, nominally 24 MHz
SPI         unchanged, concurrent control and telemetry
```

ESP32-C5 PARLIO TX supports an external input clock. Using the FPGA as the
clock source gives real hardware backpressure without another pin: the FPGA
stops `PAR_CLK` only after the current bounded link transaction, and PARLIO/GDMA
holds the queued data until the clock resumes. FreeRTOS or ESP-IDF latency is
therefore not in the overflow-safety loop.

The initial FPGA FIFO is 4096 byte entries. Each entry contains eight payload
bits plus start/end metadata. On T20 the synthesized 4096x10 memory maps as ten
4096x1 EBR lanes, so it costs ten 5-kbit EBRs.

Initial hardware thresholds are:

| Level | Used bytes | Action |
|---|---:|---|
| empty/critical | 0 | decoder underflow counter; gray if deadline expires |
| low | 1024 or less | request aggressive ESP32 refill; base/LF first |
| target | 2048 | normal operating point |
| stop pending | 2816 or more | finish current transaction, then stop `PAR_CLK` |
| resume | 2048 or less | restart `PAR_CLK` |
| overflow guard | 3584 or more | sticky warning; only malformed traffic should reach it |
| full | 4096 | sticky fatal link error; discard until resynchronization |

The maximum link transaction, including header and CRC, is 1024 bytes. Thus a
stop decision at 2816 bytes leaves 1280 bytes: one complete transaction plus a
256-byte allowance for CDC/decision latency. The 2816/2048 hysteresis also
prevents rapid clock gating.

Clock gating must be glitch-free. The internal 24 MHz clock remains running;
the input state machine advances only while the output clock enable is active,
and that enable changes only during the low clock phase. The exact Efinix
clock-output implementation must be checked in place-and-route and later on a
scope.

If external-clock PARLIO proves unsuitable on hardware, the fallback is an
ESP32-owned 24 MHz `PAR_CLK` plus conservative SPI credits. After reading free
space, ESP32 subtracts every byte already queued to DMA and never starts a
transaction larger than the remaining credit. Because FPGA consumption only
increases free space, this remains safe with stale SPI reads, but it provides
less elasticity than hardware clock stopping.

## 3. FPGA link record

Radio packets are not passed through unchanged. ESP32 emits a small internal
record with a fixed header, bounded payload and CRC16:

```text
magic, protocol version, record type, sequence
display frame id, source frame id, stripe id, quality
fragment index/count, payload length, flags
payload
CRC16(header + payload)
```

Required record types are:

- display-frame start/end;
- stripe base fragment;
- stripe enhancement fragment;
- LF-only recovered stripe;
- explicit missing stripe;
- optional control/resynchronization record.

The declared transaction length lets the FPGA commit the final byte on a clock
edge even if `PAR_CLK` stops while `PAR_CS` is low. Early `PAR_CS`, excess data,
bad magic/version/CRC, duplicate fragments or out-of-range frame/stripe IDs
reject the complete transaction and increment separate counters.

## 4. ESP32 real-time organization

Use four responsibilities rather than one frame task:

1. Radio ISR/callback only returns packet descriptors to a lock-free/ring queue.
2. A high-priority assembler validates sequence/CRC and resolves LF recovery.
3. A high-priority FPGA feeder builds bounded link records and keeps the PARLIO
   transaction queue populated.
4. A lower-priority control task owns SPI and reads status snapshots.

PARLIO callbacks run in ISR context and must only recycle a DMA staging buffer
and notify the feeder. All PARLIO descriptors and active payloads reside in
DMA-capable internal SRAM. Recommended initial allocation:

| ESP32 memory | Initial allocation |
|---|---:|
| PARLIO staging pool | 32 x 1024 bytes |
| radio RX descriptors/ring | 8-16 KiB |
| metadata and reorder tables | 4-8 KiB |
| compressed frame slots | external 8 MiB QSPI RAM |

The external RAM is useful here even though it is not needed for the radio
packet ring. A complete compressed frame must be retained to repeat 30 FPS
input at 60 Hz HDMI, and the adversarial hard bound exceeds the approximately
100 KiB internal buffer budget. PARLIO should not transmit directly from PSRAM;
copy the next 1024-byte records into the internal staging pool ahead of DMA.

The feeder queues non-blocking PARLIO transactions. A 1024-byte record takes
about 85 us at 24 MHz on a 4-bit bus. Thirty-two prepared descriptors therefore
cover about 2.7 ms even when the link runs continuously at its maximum rate.
FPGA clock stopping protects the FIFO if the prepared queue gets ahead.

The raw link capacity is 96 Mbit/s. Replaying the absolute codec hard bound of
3744 bytes x 45 stripes at 60 display frames/s is about 80.9 Mbit/s before link
headers, so the pathological case has limited margin but still fits with short
packet gaps. Normal approximately 0.5 bpp material is far below this limit.

## 5. FIFO levels read over SPI

SPI polling is predictive control and telemetry, not hard backpressure. Read
one atomic snapshot containing:

```text
link_epoch
fifo_used_bytes, fifo_free_bytes, fifo_high_water
complete_record_count
decoded_stripes_ready (0..2)
expected_display_frame, expected_stripe
current_decoder_state
underflow_count, overflow_count, crc_error_count, sequence_error_count
late_enhancement_count, lf_recovery_count, gray_stripe_count
```

ESP32 policy:

- `used <= 1024`: keep all available DMA staging descriptors queued and send
  LF/base records before enhancement;
- `1024 < used < 2816`: normal refill toward 1536-2560 bytes;
- `used >= 2816`: stop preparing enhancement and let hardware clock gating
  drain the FIFO;
- `decoded_stripes_ready == 0`: urgent base/LF service;
- `decoded_stripes_ready == 2`: no urgency; use available link time for
  enhancement;
- never infer a free slot from a DMA completion callback: completion means the
  link accepted bytes, not that the decoder consumed them.

A 0.5-1 ms SPI status period is useful during tuning, but correctness must hold
with 2 ms or longer scheduling gaps. Polling SPI transactions are preferable
for these short snapshots; an interrupt/DMA SPI queue is unnecessary unless
other traffic later shares the bus.

## 6. Decoder and display buffering

One decoded 1280x16 YUV420 stripe is 30,720 bytes. The first build uses simple
byte-oriented EBR mapping for timing predictability:

| FPGA storage | EBR estimate |
|---|---:|
| existing 640x360 OSD | 48 |
| two decoded YUV420 stripes | 120 |
| 4096-entry ingress FIFO | 10 |
| entropy reservoirs/scratch | 4-8 |
| references/tables/metadata | 4-8 |
| total estimate | 186-194 of 204 |

This is tight but plausible. If synthesis needs margin, the first memory
optimization is five 8-bit samples packed into four native 10-bit words for the
two decoded stripes. It saves about 24 EBRs. It is deliberately deferred until
the simple dual-clock stripe RAM closes timing.

The two stripe buffers use explicit ownership states: FREE, DECODING, READY and
DISPLAYING. The decoder can be at most one stripe ahead. Base reconstruction
writes a valid displayable stripe first; enhancement refines it only before its
deadline. Enhancement never changes prediction references.

## 7. Frame-rate and clock mismatch

Do not tune radio FPS or HDMI clocks to FIFO fullness. The ESP32 builds a
continuous ordered display sequence:

- nominal 30 FPS source: enqueue each selected compressed frame twice;
- source faster than display demand: discard the oldest complete frame before
  it enters the FPGA link;
- source slower or temporarily absent: enqueue the last complete compressed
  frame again;
- no complete retained frame: emit explicit missing stripes, producing gray
  while OSD remains visible.

The FIFO's actual consumption rate is the feedback for this sequence; no
per-VSYNC software interrupt is required. Dropping or repeating occurs only at
whole-frame boundaries. Packet/stripe loss decisions remain local to a frame.

With a 30 FPS camera and 60 Hz HDMI, retaining a complete compressed frame is
unavoidable unless the FPGA gains a full raw frame buffer or HDMI changes to a
30 Hz mode. This introduces approximately one source-frame of buffering, but
keeps raw-frame RAM out of both the T20 and ESP32.

## 8. Implementation checkpoints

1. **Complete:** reverse receiver-role `PAR_CLK` to an FPGA output and verify
   packet-boundary clock stop/resume in the link model.
2. **Complete for the transport FIFO:** implement the 4096x10 asynchronous byte
   FIFO, thresholds, sticky link errors, consumed-byte/transaction counters and
   SPI snapshot. Length enforcement moves to the record parser in checkpoint 3.
3. Implement link header/CRC and record reassembly without decoder logic.
4. Add two simple byte-wide YUV420 stripe buffers and a raw-stripe debug record;
   display injected YUV through HDMI with OSD.
5. Add base/LF entropy decoding, inverse quantization/IDCT and base-only intra
   reconstruction.
6. Add enhancement decoding with a hard display deadline and late discard.
7. Add frame repeat/drop sequencing and burst-loss regressions matching the
   Python radio model.
8. Run the first complete T20 synthesis; only then decide whether packed stripe
   RAM is required.
