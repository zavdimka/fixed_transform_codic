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
in mode 0 at 5 MHz and verifies protocol signature `0xC5`, version `0x14`.
The upper four 80-column OSD rows show live receiver diagnostics:

- Wi-Fi RSSI, received packets per second and sequence-derived packet loss;
- FPGA link FIFO level, received bytes and parser record counters;
- decoder completions, rejected records, CRC, length and syntax errors;
- HDMI frame counter.

The statistics refresh once per second. A built-in 5x7 ASCII display font is
rendered into the existing 640x360 FPGA bitmap; lowercase input is mapped to
uppercase for readability. Text cells use the existing foreground/background
attribute RAM, so statistics remain visible over both live video and the gray
no-signal picture.

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
