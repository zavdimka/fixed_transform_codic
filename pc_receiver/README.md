# HDZero clone PC receiver

This directory contains the compiled reference decoder and is the foundation
for the live USB/Wi-Fi PC receiver. Python remains the golden encoder/model;
C++ must match its decoded YUV bytes and the CRC stored in every `.rxt` file.

The default `jpeg-dct` profile is the layered integer-DCT stream used by the
current transmitter and receiver. The experimental `bounded-iht` profile is
also supported explicitly. Every 16-line stripe is independent, so the
decoder distributes stripes across a fixed worker group without inter-frame
state.

Build and test under WSL:

```bash
cmake -S pc_receiver -B pc_receiver/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build pc_receiver/build
ctest --test-dir pc_receiver/build --output-on-failure
```

Decode a captured/reference frame:

```bash
pc_receiver/build/hdzero_decode \
  esp32/fs/test/decoder_enhancement.rxt \
  --profile jpeg-dct --output-yuv frame.yuv --output-ppm frame.ppm

# Experimental bounded transform:
pc_receiver/build/hdzero_decode capture.rxt \
  --profile bounded-iht --output-yuv frame.yuv
```

The `.yuv` output is planar 8-bit YUV420 (`Y`, then `Cb`, then `Cr`).  PPM is
intentionally used for the dependency-free preview path; image/video output
libraries belong in the later application layer, not in `codec_core`.

The ESP32 capture helper writes an `HDZCAP1` container with the exact boundaries
of raw FPGA transactions:

```powershell
python tools/capture_download.py COM84 tmp/camera.hcap --packets 200
```

At this stage the TX FPGA harness still emits bare entropy payloads, so `.hcap`
is intended for transport inspection. Once the FPGA packetizer adds frame and
stripe metadata, the same codec library will consume captured frames directly.

## Live UDP and raw monitor input

Normal Wi-Fi/UDP operation remains the default:

```bash
pc_receiver/build/hdzero_live --bind 0.0.0.0 --port 5600
```

For direct ESP32-C5 packet injection, create a monitor interface on a Linux
adapter that supports monitor mode and tune it to the transmitter channel.
For example, replace `phy1` and channel 36 with the values for the actual
adapter and transmitter:

```bash
sudo iw phy phy1 interface add hdzmon type monitor
sudo ip link set hdzmon up
sudo iw dev hdzmon set channel 36 HT20
sudo setcap cap_net_raw=eip pc_receiver/build/hdzero_live
pc_receiver/build/hdzero_live --monitor hdzmon
```

The monitor backend uses Linux `AF_PACKET` and expects radiotap frames. It
filters for the project BSSID `02:46:50:56:00:01` and protocol bytes
`88:B5`, strips an optional captured FCS, and passes either a bare link record
or an aggregated HZU payload to the same decoder used by UDP. No association,
IP address, or Wi-Fi password is used in this mode. Rebuilding the executable
can remove its file capability; rerun `setcap` when necessary. The adapter
path is covered by an offline radiotap parser test, but still requires
hardware validation with a compatible monitor-mode adapter.
