# FPGA ↔ ESP32 debug contract (ABI v1)

The production FPGA bitstream is an artifact stored in the ESP32 LittleFS partition. ESP32 configures the FPGA; the development flow does not require a separate user-facing programmer step.

## 4-bit compressed-data bus

The bus transports the encoder byte stream to ESP32. Each byte is sent as:

1. bits `[7:4]`;
2. bits `[3:0]`.

This preserves the MSB-first order used by HEVC/CABAC and makes a captured nibble stream readable as the original byte stream. Electrical clock, strobe and flow-control assignments remain board-level parameters; they do not change the byte ordering. `bytes_to_nibbles()` and `nibbles_to_bytes()` are the Python reference functions.

Framing on this bus is intentionally not frozen in ABI v1 yet. We still need to decide whether the board has dedicated valid/frame sidebands or whether NAL/frame boundaries must be encoded into the nibble stream itself.

ESP32 performs radio packet packing and buffering. Consequently, the FPGA does not infer the radio packet number from the 4-bit stream. ESP32 writes the last transmitted packet count to `REG_HOST_PACKET_COUNT` when that value is useful in a debug snapshot.

## SPI CTU injection transport

The first hardware bring-up top uses a deliberately small command transport
instead of exposing the complete register ABI below. Every command is one
independent SPI mode-0 transaction: assert CS, send the command byte and its
payload, then deassert CS. Multi-byte diagnostic counters are documented per
command; the two-byte CTU CRC is sent most-significant byte first.

| Command | Value | Payload |
|---|---:|---|
| CONFIG | `0x01` | slice row, QP, flags (quality in bits 1:0, no-output flag in bit 7) |
| START_SLICE | `0x02` | none |
| LOAD_CTU | `0x10` | 256 Y + 64 Cb + 64 Cr bytes, then CRC-16/CCITT |
| RUN_CTU | `0x11` | none |
| SOFT_RESET | `0x20` | none |
| CLEAR_ERRORS | `0x21` | none |
| READ_STATUS | `0x80` | dummy bytes clock out status/version/coordinates/count/errors |
| READ_SIGNATURES | `0x81` | dummy bytes clock out byte count and CRC/count signatures |

`spi_load_ctu_command()` and `spi_config_command()` form byte-exact host
transactions. This transport is the minimal path for stopping camera admission,
injecting one known CTU16 and comparing the generated NAL and internal
signatures. The wider register/snapshot ABI remains the planned second-stage
debug monitor and is not implemented by the bring-up top yet.

## SPI register access

All registers are 32-bit little-endian. SPI is used for configuration and low-rate debug only, independently of the 4-bit data bus.

Important registers are defined in `hevc_reference/debug_interface.py`:

| Offset | Register | Direction |
|---:|---|---|
| `0x0000` | debug ID (`HEVC`) | R |
| `0x0004` | ABI version | R |
| `0x0008` | control | R/W |
| `0x000C` | status | R |
| `0x0010` | host/radio packet count | W |
| `0x0014` | snapshot sequence | R |
| `0x0020`–`0x0054` | frozen counters/state | R |
| `0x0060` | memory window selector | R/W |
| `0x0064` | memory window address | R/W |
| `0x0068` | memory window data/autoincrement | R |

Writing `CONTROL_CAPTURE_SNAPSHOT` copies live state into a shadow register bank atomically and raises `STATUS_SNAPSHOT_READY`. ESP32 can therefore:

1. transmit the requested number of radio packets;
2. write that count to `REG_HOST_PACKET_COUNT`;
3. request a snapshot;
4. select the frozen bank;
5. read registers and selected RAM without racing the encoder.

The portable snapshot file is exactly 64 bytes, begins with `HDBG`, and is encoded by `DebugSnapshot.to_bytes()`. ESP32 may save the same blob to LittleFS or forward it to the host for direct comparison with Python.

## Memory windows

The selector is intentionally generic. Initial RTL should expose development windows for:

- reconstructed top samples;
- current prediction block;
- residual/transform coefficients;
- quantized coefficients;
- CABAC contexts;
- byte-packer staging FIFO;
- trace ring buffer.

These windows may be omitted from a release build to recover EBR and logic. The register ABI stays unchanged; an absent window reports an error flag.
