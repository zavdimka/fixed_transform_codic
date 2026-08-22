# T20F169 receiver image

This Efinity project is the receiver firmware image for the same board used by
`../t20f169_spi_debug` in transmitter mode. The current milestone provides a
complete 1280x720p60 DVI-compatible TMDS output, an SPI-controlled OSD, and the
flow-controlled compressed-data ingress. It does not contain the video decoder
yet.

## Current video path

- CEA/CTA VIC 4 timing: 1280x720 active, 1650x750 total, 74.4 MHz pixel clock.
- Standard TMDS control symbols and running-disparity video encoding.
- Efinix 5:1 LTX interface: one 10-bit TMDS word is emitted as two 5-bit
  transfers at 148.8 MHz; the hard serializer runs at 372 MHz.
- Until the decoder is connected, the base picture is solid `RGB 128,128,128`.
- Four base-picture modes can be selected over SPI: gray, eight color bars,
  a 64-pixel alignment grid, and independent RGB gradients.
- Loss of a compressed frame will therefore naturally expose gray, without a
  generated `NO SIGNAL` caption.
- OSD is composited after the base-picture selector, so it remains visible
  with no radio/video signal.

This is a DVI-compatible subset carried by the HDMI connector: video and
control periods are implemented, but audio and HDMI data islands are not.

## OSD framebuffer

The OSD is a 640x360, 1-bit transparency mask, expanded to 1280x720 by a 2x2
nearest-neighbour scale. A zero bit is transparent; a one bit selects one
global 24-bit RGB color configured over SPI.

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

The RAM clears automatically after reset in 5760 control-clock cycles, about
96 us at 60 MHz. OSD output is suppressed during a clear, then resumes
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
| `0x12` | none | Clear the complete OSD mask |
| `0x80` | read 9 bytes after command | Signature/version, flags, frame count, address |
| `0x81` | read 7 bytes after command | OSD enable/color, word count and word width |
| `0x82` | read 1 byte after command | Current base-picture mode |
| `0x83` | read 4 bytes after command | Automatic, override, manual and effective LEDs |
| `0x90` | read 12 bytes after command | Link FIFO flags, counters and payload XOR |
| `0x91` | read 8 bytes after command | Parser state and last accepted record |
| `0x92` | read 8 bytes after command | Accepted and rejected record counters |
| `0x93` | read 12 bytes after command | CRC, length and framing error counters |

Status signature is `0xC5`, protocol version is `0x13`. The status flag byte
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
missing (`10`..`13`) and control/resync (`7F`). A complete transaction is
buffered before any payload becomes visible downstream. Bad magic, version,
type, fragment fields, reserved byte, length, CRC or transaction boundary
rejects the whole record; the next start marker resynchronizes the parser.
The 1024x8 validation/replay buffer uses two EBRs. Its conservative synchronous
reader emits one byte every three 60 MHz cycles (20 MB/s), still comfortably
above the 12 MB/s physical maximum of the 24 MHz four-bit input.

## Verified build (Efinity 2026.1, C3 timing model)

The current routed T20F169 build passes placement, routing, bitstream generation
and CDC analysis.

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| Logic elements | 2821 | 19728 | 14.30% |
| Registers | 1240 | 13920 | 8.91% |
| EBR blocks | 60 | 204 | 29.41% |
| Multipliers/DSP | 0 | 36 | 0% |

Worst setup margins are positive: 0.471 ns inside the 148.8 MHz half-pixel
domain, 0.878 ns from the pixel encoder to the 5-bit gearbox, and 1.249 ns in
the 74.4 MHz pixel domain. The 60 MHz control/parser logic is intentionally
checked at 71.4 MHz and has 1.400 ns margin (79.4 MHz analyzed maximum); the
24 MHz link has at least 12.779 ns
between opposite edges. A dedicated register stage separates the
OSD/base-picture compositor from TMDS disparity arithmetic.

Cocotb/Verilator tests cover packet ordering across the 24/60 MHz clock
boundary, packet markers, autonomous FIFO clock stop/resume, CRC/length atomic
reject and recovery, the exact 1024-byte boundary, plus a complete
1650x750 timing frame, all diagnostic
patterns, TMDS symbols and running disparity, 10-to-5-bit ordering, OSD
clear/write/2x2 addressing, and the SPI commands above. Top-level Verilator
lint is clean.

The next integration step is to load the image on a physical board and use the
bars/gradient modes to verify lane order, bit order and polarity on a monitor.
After that, the decoder can replace the diagnostic base-picture source without
changing timing, TMDS, or OSD.

The planned ESP32/FPGA ownership, flow control, FIFO thresholds and decoder
memory budget are documented in `../RECEIVER_DECODER_ARCHITECTURE_PLAN.md`.
