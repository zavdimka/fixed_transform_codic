# T20F169 receiver image

This Efinity project is the receiver firmware image for the same board used by
`../t20f169_spi_debug` in transmitter mode. The current milestone provides a
complete 1280x720p60 DVI-compatible TMDS output, an SPI-controlled OSD, and the
flow-controlled compressed-data ingress. It contains the final pair of
decoded-stripe memories, the raw YUV420 injection path, the complete base
decoder, and LF-only recovery for packet-loss concealment. Enhancement-layer
AC entropy decoding is present and observable over SPI. Its compressed layer is
now retained in three EBRs and replayed when the matching base stripe starts;
its coefficient events are not yet applied to the picture. The one-block
coefficient combiner and shared full-IDCT connection are next.

`receiver_full_idct8_32.sv` is now the verified full-frequency transform
candidate for that connection. It reuses 32 registered multiplier lanes across
dequantization and both separable IDCT passes, then produces one residual sample
per clock. Its standalone regression is bit-exact for Q20/Q24 and completes an
unstalled block within the 720p30 budget at 60 MHz. It is intentionally not
instantiated in `top.v` until the compressed enhancement replay buffer and
one-block coefficient combiner are in place, so current routed utilization
still describes the base-only display path.

## Current video path

- CEA/CTA VIC 4 timing: 1280x720 active, 1650x750 total, 74.4 MHz pixel clock.
- Standard TMDS control symbols and running-disparity video encoding.
- Efinix 5:1 LTX interface: one 10-bit TMDS word is emitted as two 5-bit
  transfers at 148.8 MHz; the hard serializer runs at 372 MHz.
- Mode zero displays validated raw/debug or later decoded YUV420 stripes and
  substitutes `RGB 128,128,128` at a missing stripe deadline.
- Modes 1..3 select eight color bars, a 64-pixel alignment grid, and
  independent RGB gradients for board diagnostics.
- Loss of a compressed frame will therefore naturally expose gray, without a
  generated `NO SIGNAL` caption.
- OSD is composited after the base-picture selector, so it remains visible
  with no radio/video signal.

This is a DVI-compatible subset carried by the HDMI connector: video and
control periods are implemented, but audio and HDMI data islands are not.

## OSD framebuffer

The OSD is a 640x360, 1-bit shape mask, expanded to 1280x720 by a 2x2
nearest-neighbour scale. A separate 80x30 attribute map assigns foreground
and optional background colors to each 8x12 logical-pixel (16x24 HDMI-pixel)
cell. This keeps the bitmap useful for arbitrary graphics while matching the
usual text rendering granularity.

The logical image is arranged as 16 words per row. Each word contains 40
adjacent pixels, so:

```text
word_address = y * 16 + floor(x / 40)
bit_index    = x % 40
```

Bulk data is little-endian: the first byte supplies bits 7:0 and the fifth
byte supplies bits 39:32. Within a byte, bit 0 is the leftmost pixel.

The framebuffer contains 230400 bits (28.8 KiB). It is deliberately mapped as
12 banks x 4 lanes x 512 x 10 bits and therefore consumes exactly 48 of the
T20's 5-kbit EBR blocks. It is a single buffer; an SPI update can become
visible during the current frame. A later decoder can use the remaining EBR
for line stores and packet/reconstruction buffers.

Attribute address and bit layout are:

```text
attribute_address = floor(hdmi_y / 24) * 80 + floor(hdmi_x / 16)

bits 3:0  foreground color index
bits 7:4  background color index
bit  8    background opaque (zero keeps the video transparent)
bit  9    reserved, write as zero
```

Indices `0..14` select the fixed VGA-style palette: black, dark blue, dark
green, dark cyan, dark red, dark magenta, brown, light gray, dark gray, bright
blue, bright green, bright cyan, bright red, bright magenta and yellow. Index
`15` selects the programmable global RGB value from command `0x01`. The reset
attribute is `0x00f`: programmable foreground and transparent background, so
legacy bitmap-only software remains compatible.

The 2400 x 10-bit attribute map is implemented as five additional 512 x
10-bit dual-clock EBRs. Together the bitmap and attributes consume 53 EBRs.

Both RAMs clear automatically after reset in 5760 control-clock cycles, about
96 us at 60 MHz. Attribute clearing runs in parallel with bitmap clearing and
restores `0x00f`. OSD output is suppressed during a clear, then resumes
automatically.

## SPI protocol

SPI uses the existing `SPI_CLK`, active-low `SPI_CS`, `SPI_MOSI`, and
`SPI_MISO` signals. Each transaction starts with one command byte.

| Command | Payload / returned bytes | Purpose |
|---|---|---|
| `0x01` | enable, R, G, B | Enable OSD and set its global color |
| `0x02` | override mask, manual value | Control the six active-low LEDs |
| `0x03` | mode[1:0] | Select gray/bars/grid/RGB-gradient base picture |
| `0x04` | drain enable | Enable the temporary FIFO debug sink |
| `0x10` | address low, address high[4:0] | Set the 13-bit OSD word pointer |
| `0x11` | groups of five bytes | Write 40-bit words and auto-increment |
| `0x12` | none | Clear the OSD mask and restore default attributes |
| `0x13` | address low, address high[3:0] | Set the 12-bit attribute pointer |
| `0x14` | groups of two bytes | Write 10-bit attributes little-endian and auto-increment; upper six bits of byte 2 must be zero |
| `0x80` | read 11 bytes after command | Signature/version, flags, frame count, bitmap and attribute pointers |
| `0x81` | read 10 bytes after command | OSD enable/color, bitmap layout, then attribute columns, rows and bit width |
| `0x82` | read 1 byte after command | Current base-picture mode |
| `0x83` | read 4 bytes after command | Automatic, override, manual and effective LEDs |
| `0x90` | read 12 bytes after command | Link FIFO flags, counters and payload XOR |
| `0x91` | read 8 bytes after command | Parser state and last accepted record |
| `0x92` | read 8 bytes after command | Accepted and rejected record counters |
| `0x93` | read 12 bytes after command | CRC, length and framing error counters |
| `0x94` | read 16 bytes after command | Base decoder state, residual XOR and completed/rejected/syntax counters |
| `0x95` | read 16 bytes after command | Enhancement event state, coefficient XOR and completed/rejected/syntax counters |

Status signature is `0xC5`, protocol version is `0x14`. The status flag byte
contains, from bit 0 upward: PLL2 lock, clear busy, clear done pulse, write
ready, and sticky command error.

## Clocks and constraints

- PLL1: 60 MHz control/SPI/OSD-write clock and the existing 24 MHz output.
- PLL2: 372 MHz serializer clock, 148.8 MHz 5-bit interface clock, and 74.4 MHz
  pixel clock.
- The SDC constrains the 60 MHz fabric domain to a 14 ns period (71.4 MHz) to
  preserve implementation margin.
- HDMI SDC periods are written as exactly harmonic values at Efinity's 1 ps
  timing resolution. This prevents a false 1 ps pixel-to-half-pixel setup
  relationship caused by decimal rounding.

The hard periphery and pin names intentionally match the transmitter project.
In this receiver image `PAR_CS` and `PAR_D` are ESP32-to-FPGA inputs, while
`PAR_CLK` is a nominal 24 MHz FPGA-to-ESP32 output. SPI operates concurrently
as the control interface.

The 4-bit ingress converts pairs of high-nibble-first transfers to byte
entries in a 4096x10 dual-clock FIFO. The extra bits distinguish the first data
byte and an explicit end marker. The FIFO consumes 10 EBRs, one 4096x1 lane for
each entry bit. At 2816 occupied entries the clock is stopped
after `PAR_CS` falls; it restarts at 2048. A 4088-entry emergency threshold can
pause a malformed overlong transaction in place before RAM overflow. The
internal 24 MHz clock continues running, and the external enable changes only
while it is low, so stop/resume does not create a shortened high pulse.

## ESP32-to-FPGA link record

Each PAR transaction contains exactly one version-1 link record. The fixed
18-byte header is followed by 0..1004 payload bytes and a little-endian
CRC16-CCITT-FALSE over header plus payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 2 | magic `C5 3A` |
| 2 | 1 | version `01` |
| 3 | 1 | record type |
| 4 | 2 | sequence, little-endian |
| 6 | 2 | display frame ID |
| 8 | 2 | source frame ID |
| 10 | 1 | stripe ID |
| 11 | 1 | quality |
| 12 | 1 | fragment index |
| 13 | 1 | fragment count, nonzero |
| 14 | 1 | flags |
| 15 | 1 | reserved, zero |
| 16 | 2 | payload length, little-endian |

Supported types are frame start/end (`01`/`02`), stripe base/enhancement/LF/
missing (`10`..`13`), raw YUV420 debug (`20`) and control/resync (`7F`). A complete transaction is
buffered before any payload becomes visible downstream. Bad magic, version,
type, fragment fields, reserved byte, length, CRC or transaction boundary
rejects the whole record; the next start marker resynchronizes the parser.
The 1024x8 validation/replay buffer uses two EBRs. Its conservative synchronous
reader emits one byte every three 60 MHz cycles (20 MB/s), still comfortably
above the 12 MB/s physical maximum of the 24 MHz four-bit input.

### Raw YUV420 stripe debug record

Record type `0x20` injects one planar 1280x16 YUV420 stripe without invoking
the future entropy decoder. The aggregate stripe is exactly 30720 bytes:

```text
Y   16 x 1280 = 20480 bytes
Cb   8 x  640 =  5120 bytes
Cr   8 x  640 =  5120 bytes
```

ESP32 splits this byte stream into ordered records of at most 1004 payload
bytes. Fragment zero starts or replaces an incomplete assembly; subsequent
fragments must keep the same display-frame ID, stripe ID and fragment count.
The stripe becomes READY only when the last declared fragment brings the
aggregate size to exactly 30720 bytes. Bad order, missing fragments and wrong
length can never expose partially written pixels.

The two display banks use toggle handshakes in both directions. The 60 MHz
writer does not reuse a bank until the pixel domain has completed all 16
lines. At the blanking interval before a stripe, HDMI selects a correctly
tagged READY bank or neutral gray. The pipelined limited-range BT.601
YUV-to-RGB conversion uses four DSP blocks and remains aligned with the OSD.

This raw format is intentionally only a board/debug path: its bandwidth is
too high for continuous 720p. The compressed decoder will write the same bank
interface, so timing, OSD and HDMI do not change in later checkpoints.

## Verified build (Efinity 2026.1, C3 timing model)

The current routed T20F169 build passes placement, routing, bitstream generation
and CDC analysis.

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| Logic elements | 17926 | 19728 | 90.87% |
| Registers | 9015 | 13920 | 64.76% |
| EBR blocks | 190 | 204 | 93.14% |
| Multipliers/DSP | 36 | 36 | 100.00% |

The pixel domain analyzes to 83.25 MHz and has 1.428 ns setup margin at the
74.4 MHz HDMI pixel clock. The 148.8 MHz half-pixel domain retains at least
0.358 ns setup margin. The codec/control domain analyzes to 65.915 MHz; the
71.4 MHz over-constraint reports -1.171 ns, while the real 60 MHz operating
period has approximately 1.496 ns margin. The 24 MHz link analyzes to
47.833 MHz.

Cocotb/Verilator tests cover packet ordering across the 24/60 MHz clock
boundary, packet markers, autonomous FIFO clock stop/resume, CRC/length atomic
reject and recovery, the exact 1024-byte boundary, raw fragment assembly,
bank swapping, YUV-to-RGB vectors and gray concealment, plus a complete
1650x750 timing frame and all diagnostic
patterns, TMDS symbols and running disparity, 10-to-5-bit ordering, OSD
clear/write/2x2 addressing, 80x30 attribute boundaries and the SPI commands
above. The routed design includes the base/enhancement decoder and full IDCT;
1802 LE and 14 EBR remain free. Physical HDMI, diagnostic-pattern, OSD and raw
stripe injection tests can proceed when the boards arrive.

The planned ESP32/FPGA ownership, flow control, FIFO thresholds and decoder
memory budget are documented in `../RECEIVER_DECODER_ARCHITECTURE_PLAN.md`.
