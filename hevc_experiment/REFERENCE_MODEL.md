# Python/RTL reference model contract

The Python code has two deliberately separate roles.

## Deterministic hardware/transport reference path

Code under `hevc_reference/` is the reusable, deterministic specification for RTL and ESP32 tests. The HEVC datapath belongs in FPGA; radio packet packing remains an ESP32 responsibility:

- `annexb.py` — HEVC NAL/start-code parsing and serialization;
- `radio.py` — current radio framing, CRC, XOR, loss and reassembly;
- `fixed_math.py` — explicit two's-complement width, saturation and rounding;
- `debug_interface.py` — 4-bit byte transport and SPI snapshot ABI;
- future prediction, transform, quantization and CABAC modules.

FPGA-path functions must use integer/byte operations only. Every narrowing, rounding, saturation or wrap must be explicit at the exact pipeline boundary where RTL performs it. NumPy floating point is allowed only for image I/O, quality metrics and the radio channel probability model.

## External oracle path

`external_codec.py` invokes FFmpeg/libx265. It answers two questions:

1. what compression/quality can a mature HEVC encoder achieve;
2. whether the rebuilt Annex-B stream is accepted by a standard decoder.

It is not bit-exact with the planned FPGA and must never be used as the expected coefficient, CABAC or output-byte implementation.

## Block-by-block implementation order

The fixed encoder should be introduced without one large rewrite:

1. fixed RGB/YUV420 conversion or native camera YUV input contract;
2. reconstructed top/left sample store;
3. DC/planar and selected directional intra prediction (16x16 luma DC golden
   model and streaming RTL implemented; planar/directional remain);
4. integer 16x16 forward transform;
5. quantization and inverse quantization;
6. inverse transform and reconstruction;
7. coefficient scan and syntax bin generation;
8. CABAC arithmetic encoder;
9. slice and parameter-set writer.

Each step needs small synthetic vectors, a Python intermediate dump and a cocotb comparison before the next step is added.

## Regression command

From the repository root:

```bash
PYTHONPATH=hevc_experiment python3 -m unittest discover -s hevc_experiment/tests -v
```

The legacy command remains compatible:

```bash
python3 hevc_experiment/hevc_radio_experiment.py 1.png --qp 35 --slices 12 --ctu 32
```
