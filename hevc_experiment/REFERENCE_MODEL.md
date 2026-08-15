# Python/RTL reference model contract

The Python code has two deliberately separate roles.

## Deterministic hardware/transport reference path

Code under `hevc_reference/` is the reusable, deterministic specification for RTL and ESP32 tests. The HEVC datapath belongs in FPGA; radio packet packing remains an ESP32 responsibility:

- `annexb.py` — HEVC NAL/start-code parsing and serialization;
- `parameter_sets.py` — local integer-only Main-profile VPS/SPS/PPS writer;
- `slice_header.py` — parameterized byte-exact IDR I-slice header writer;
- `radio.py` — current radio framing, CRC, XOR, loss and reassembly;
- `fixed_math.py` — explicit two's-complement width, saturation and rounding;
- `debug_interface.py` — 4-bit byte transport and SPI snapshot ABI;
- `intra.py`, `transform.py`, `quant.py` and `scan.py` — bit-exact FPGA
  datapath contracts through normative TU16 coefficient ordering;
- `syntax.py`, `cu_syntax.py` and `cabac.py` — syntax-bin, fixed-CU and
  arithmetic byte-stream contracts.

FPGA-path functions must use integer/byte operations only. Every narrowing, rounding, saturation or wrap must be explicit at the exact pipeline boundary where RTL performs it. NumPy floating point is allowed only for image I/O, quality metrics and the radio channel probability model.

## External oracle path

`external_codec.py` invokes FFmpeg/libx265. It answers two questions:

1. what compression/quality can a mature HEVC encoder achieve;
2. whether the rebuilt Annex-B stream is accepted by a standard decoder.

It is not bit-exact with the planned FPGA and must never be used as the expected coefficient, CABAC or output-byte implementation.

## Block-by-block implementation order

The fixed encoder should be introduced without one large rewrite:

1. native planar I420 camera input contract (implemented with two shared
   16-line/8-line ping-pong banks, automatic Y/Cb/Cr counting and block-raster
   output; physical DVP/CSI clock-domain FIFO remains board-specific);
2. reconstructed top/left sample store (implemented for fixed CU16 Z-order with
   normative availability substitution, two synchronous edge RAMs and
   reconstructed-only feedback);
3. DC/planar and selected directional intra prediction (16x16 luma DC,
   normative filtered planar, DC/planar SAD selection and one-source-EBR
   selected-mode replay implemented; directional modes remain);
4. integer 16x16 forward transform (bit-exact golden model, streaming RTL and
   inferred 4096-bit transpose RAM implemented);
5. quantization and inverse quantization (flat TU16 scaling, selectable
   QP28/34/40 profiles, bit-exact golden model and two-stage streaming RTL
   implemented);
6. inverse transform and reconstruction (bit-exact inverse TU16 model,
   prediction buffer and integrated streaming reconstruction loop implemented;
   its quantized tap now feeds a one-TU staging bridge that derives CBF, suppresses
   all-zero coefficient replay and emits the CU descriptor; multi-slice
   scheduling remains for throughput);
7. coefficient scan and syntax-bin pipeline (TU16 luma last-significant,
   coded-sub-block, significant-coefficient, level, sign, adaptive-Rice bins,
   ordered arbitration and integrated two-bank coefficient replay implemented;
   sign-data-hiding is disabled);
   Fixed CTU64-to-CU16 split, intra 2Nx2N planar/DC mode, derived chroma,
   coded-block flags and CTU prefix/coefficient/termination scheduling are
   implemented as backpressure-safe streams;
8. CABAC arithmetic encoder (regular/bypass/terminate arithmetic, 256-entry
   context RAM, carry buffering, byte output and stop/alignment implemented;
   coefficient context banking, normative B/P/I initialization for
   coefficient and fixed intra-CU contexts from a compile-time ROM, and the
   combined coefficient-to-byte path are integrated;
   the CTU scheduler, coefficient mapping and CABAC encoder are integrated into
   a complete raw-coefficient-to-byte slice top);
9. slice and parameter-set writer (streaming Annex-B and emulation-prevention,
   local bit-exact 1280x768p60 VPS/SPS/PPS generation, compile-time ROM,
   three-NAL streamer, parameterized full-width IDR I-slice headers and streaming
   header/CABAC/NAL multiplexing implemented; the full selected-prediction/residual TU path is now connected
   through integer transform, quantization, reconstruction, CBF/coefficient staging, automatic
   context initialization and CTU counting to a complete Annex-B IDR NAL output.
   One full luma CTU is checked from raw source pixels through reconstructed pixels
   and Annex-B bytes. The camera-raster framer is implemented and preserves Y,
   Cb and Cr. Remaining
   integration is per-CTU pending contexts, chroma coding and the multi-row frame
   controller).

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
