# ESP32-C5 link controller

This is one ESP-IDF application for both physical board roles. The selected
role is stored in NVS and controls the direction of the four-bit FPGA link:

- `tx`: FPGA encoder to ESP32-C5, followed by raw Wi-Fi transmission;
- `rx`: raw Wi-Fi reception, followed by ESP32-C5 to FPGA decoder;
- `service`: radio is disabled and FPGA-facing data pins remain inputs.

The board uses an ESP32-C5R8 with 8 MiB quad PSRAM plus a separate 16 MiB QSPI
flash. Large frame, packet and capture buffers should be allocated explicitly
from PSRAM. DMA descriptors, task stacks and small latency-critical buffers
remain in internal SRAM. PSRAM runs at its normal 80 MHz setting and is tested
during boot.

The initial radio implementation is deliberately one-way. It uses one fixed
maximum-throughput profile (HE20 MCS9), has no reverse reports and performs no
rate adaptation. The FPGA TX and RX projects remain in the same Git branch as
this application.

## FPGA images and LittleFS

The 16 MiB flash contains a 3 MiB application partition and a 12 MiB LittleFS
partition named `storage`. Its image is rebuilt from `esp32/fs` and is included
automatically by `idf.py flash`. FPGA images therefore have the same Git/build
version as the ESP32 application.

Build both Efinity projects in passive SPI x1 mode and copy their raw binary
outputs (not the textual `.hex` or `.bit` files) to:

```text
esp32/fs/fpga/tx/default.hex.bin
esp32/fs/fpga/rx/default.hex.bin
```

The transmitter project is already configured to generate `.hex.bin`; the
receiver project had that option enabled already. Additional image versions
can coexist in those directories. At the USB console use:

```text
fpga list
fpga tx-file /fs/fpga/tx/alternative.hex.bin
fpga rx-file /fs/fpga/rx/alternative.hex.bin
save
reboot
```

At boot, `tx` and `rx` roles stream the selected file directly from LittleFS to
the FPGA over passive SPI mode 3 at 8 MHz. SPI chip-select remains asserted for
the complete image, 128 trailing clocks are generated, and `CDONE` must become
high before Wi-Fi starts. The complete FPGA image is never buffered in RAM.
The filesystem is deliberately not auto-formatted on mount failure, because
that could erase all stored FPGA versions.

## Receiver OSD

After loading the receiver FPGA image, ESP32 opens the FPGA user SPI interface
in mode 0 at 1 MHz and verifies protocol signature `0xC5`, version `0x14`.
The upper four 80-column OSD rows show live receiver diagnostics:

- Wi-Fi RSSI, received packets per second and sequence-derived packet loss;
- FPGA link FIFO level, received bytes and parser record counters;
- decoder completions, rejected records, CRC, length and syntax errors;
- HDMI frame counter.

The statistics refresh once per second. A built-in 7x10 ASCII display font is
rendered into the existing 640x360 FPGA bitmap; lowercase input is mapped to
uppercase for readability. Every glyph occupies columns `0..6` and rows
`1..10` of its 8x12 logical-pixel attribute cell. Column 7 and rows 0/11 remain
blank as character spacing. After the FPGA's 2x HDMI scale this becomes a
14x20 glyph inside a 16x24 output cell, so foreground/background color changes
stay aligned to character boundaries. Text cells use the existing attribute
RAM, keeping statistics visible over both live video and the gray no-signal
picture.

Rows `0..3` are reserved for system statistics. The public
`receiver_osd_write_line()` interface exposes rows `4..29` for the future
flight-controller OSD parser, without coupling UART/MAVLink/MSP handling to the
FPGA bitmap layout. The OSD remains generated and composited in the FPGA; only
compact text/graphics updates cross SPI.

## Toolchain

The project is pinned and tested with ESP-IDF v6.0.2 in WSL:

```sh
get_idf
cd ~/fixed_transform_codic/esp32
idf.py set-target esp32c5
idf.py build
```

GPIO13/GPIO14 are the primary USB Serial/JTAG console, so no external USB-UART
adapter is required. After flashing, configure a board with:

```text
role tx
band 5g
channel 36
bandwidth 20
save
reboot
```

Use `role rx` on the receiver. Both boards must use the same band, channel and
bandwidth.

## Board pins

| Net | ESP32-C5 GPIO | TX role | RX role |
|---|---:|---|---|
| PAR_D0..D3 | 0..3 | input | output |
| PAR_CLK | 4 | input | input |
| PAR_CS | 5 | input | output |
| SPI_CS | 6 | output | output |
| FPGA_CDONE | 7 | input | input |
| SPI_CLK | 8 | output | output |
| FPGA_CRESET | 9 | output | output |
| SPI_MOSI | 10 | output | output |
| FC UART TX/RX | 11/12 | reserved | reserved |
| USB D-/D+ | 13/14 | USB console | USB console |
| TWI SDA/SCK | 23/24 | reserved | reserved |
| CLK48 | 25 | input | input |
| SBUS | 26 | input | input |
| FPGA INT | 27 | input | input |
| SPI_MISO | 28 | input | input |

The current code establishes safe GPIO directions, FPGA configuration,
raw-radio framing and receiver statistics OSD. PARLIO DMA, flight-controller
UART OSD parsing and packet buffering remain to be added as separate
components.
## Updating without the BOOT jumper

The partition table has two 3 MiB application slots (`ota_0` and `ota_1`).
After the first complete flash, later application images can be uploaded over
the USB Serial/JTAG console without entering ROM download mode:

```powershell
python tools/ota_upload.py COM84 esp32/build/fixed_transform_link.bin
```

The uploader computes CRC32, sends one flow-controlled 1024-byte chunk at a
time and waits while the firmware writes the inactive slot. The boot slot is
changed only after CRC32 and ESP-IDF image validation both pass. Send `reboot`
after `OTA COMPLETE`. Bootloader rollback is enabled; the application confirms
the new slot after NVS, filesystem and board GPIO initialization succeed.

Console commands:

```text
update status
update receive <size> <crc32-hex>
reboot bootloader CONFIRM
```

The last command asks the ESP32-C5 LP_AON block to reboot into ROM download
boot0 (UART/USB). It is an emergency path; normal updates should use A/B OTA.
The LP_AON force-download bit survives a normal reset. After servicing from ROM,
either power-cycle the board, or clear bits 30:29 at `0x600b1034` with an
esptool `write-mem` command before resetting. Do not leave the physical BOOT
jumper asserted after the initial complete flash, or every reset will return to
the ROM `waiting for download` prompt.

## Receiver HDMI bring-up

The RX FPGA image starts in diagnostic pattern 1 (eight 160-pixel color bars)
immediately after configuration. It does not depend on Wi-Fi, packet parsing or
the video decoder. Once receiver OSD SPI is active, select a source with:

```text
hdmi pattern 0   # decoded video / neutral gray when no stripes arrive
hdmi pattern 1   # color bars (power-on default)
hdmi pattern 2   # 64-pixel grid/checkerboard
hdmi pattern 3   # RGB gradients
```

The receiver OSD is initialized even if radio startup fails, so HDMI and SPI
can be debugged independently from the wireless link.

## Receiver file-decoder test

If `/fs/test/decoder_base.rxt` is present, receiver firmware automatically
switches HDMI to decoded-video mode and repeatedly sends the file to the FPGA
over the 4-bit PARLIO link. The bundled vector contains one precomputed
1280x720 frame split into 45 independently decoded base-layer stripes. Generate
it and its reference PNGs with:

```text
python3 tools/generate_decoder_test_stream.py
```

Runtime control and counters are available on the USB console:

```text
decoder status
decoder stop
decoder play [/fs/test/decoder_base.rxt]
```

`decoder status` prints both file/DMA progress and FPGA parser/decoder counts.
A healthy repeating test keeps CRC, length, framing, rejected-record and syntax
counts at zero while accepted and decoded counts increase continuously.
