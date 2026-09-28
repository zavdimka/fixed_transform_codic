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
