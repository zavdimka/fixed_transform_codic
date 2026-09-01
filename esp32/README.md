# ESP32-C5 link controller

This is one ESP-IDF application for both physical board roles. The selected
role is stored in NVS and controls the direction of the four-bit FPGA link:

- `tx`: FPGA encoder to ESP32-C5, followed by raw Wi-Fi transmission;
- `rx`: raw Wi-Fi reception, followed by ESP32-C5 to FPGA decoder;
- `service`: radio is disabled and FPGA-facing data pins remain inputs.

The initial radio implementation is deliberately one-way. It uses one fixed
maximum-throughput profile (HE20 MCS9), has no reverse reports and performs no
rate adaptation. The FPGA TX and RX projects remain in the same Git branch as
this application. FPGA image manifests and run-time FPGA image selection are
not part of this first version.

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

The current code only establishes safe GPIO directions and raw-radio framing.
PARLIO DMA, FPGA SPI configuration, UART OSD input, packet buffering and FPGA
bitstream loading will be added as separate components.
