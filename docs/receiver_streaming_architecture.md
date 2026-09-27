# Receiver streaming architecture

## Fixed constraints

- Device: Efinix T20F169, C3 speed grade.
- Decoder clock: 90 MHz; parallel-link clock: 24 MHz.
- Display: 1280x720 at 40 Hz, 45 stripes per frame, 16 active lines per
  stripe. The proven 1980x750 raster runs from a 59.4 MHz pixel clock.
- One active stripe period is 533.333 us, or 48,000 decoder cycles. Vertical
  blanking is additional service time and is not counted in this deadline.
- One stripe contains 80 CTUs and 480 8x8 transform blocks.
- Two decoded stripe banks are retained. A third bank would consume about 60
  additional RAM blocks and is not part of the design.
- The full JPEG-compatible 8x8 IDCT uses all 36 hardware multipliers. There is
  no multiplier budget for a second transform engine.

## Throughput contract

The base layer is mandatory and has bounded work. Enhancement is replayed into
the same local coefficient loader; if it is missing or late, the decoder falls
back to base coefficients rather than stalling the display indefinitely.

For every stripe:

1. Input and entropy parsing may run ahead into compact queues.
2. Base plus enhancement decoding, coefficient loading, full IDCT and
   reconstruction must complete within 48,000 cycles.
3. The measured worst full-enhancement profile is estimated at about 531.6 us,
   roughly 47,842 cycles, leaving about 158 cycles of margin at 40 Hz.
4. A 50 Hz raster provides only 426.667 us per 16 active lines. The measured
   work therefore needs about 112.1 MHz; use roughly 113 MHz as the minimum
   decoder-clock target for a faster speed grade.

## Pipeline

```
parallel link
  -> record ping-pong RAM
  -> base/enhancement entropy decoders
  -> compact block descriptors and narrow coefficient events
  -> banked local coefficient loader in IDCT
  -> one pipelined 36-multiplier full 8x8 IDCT
  -> reconstruction
  -> two stripe pixel banks
  -> HDMI
```

There are no ready paths spanning more than one stage. Every stage boundary is
an elastic register or a small FIFO. Backpressure is based on registered FIFO
occupancy, not on downstream combinational ready signals.

## Coefficient transport

The old interface assembled a 768-bit combinational coefficient vector in the
enhancement combiner and copied it into another 768-bit register in the IDCT.
The replacement interface is deliberately narrow:

- `load_start`: reserve the local IDCT load bank and latch block metadata;
- `load_coeff`: write one signed 12-bit coefficient at a 6-bit physical
  address;
- `load_commit`: mark the block complete and eligible for transform;
- `load_abort`: discard a partial enhancement block and commit base only.

The IDCT owns the coefficient storage. A 64-bit validity bitmap makes unwritten
coefficients zero, so a block does not require a 64-cycle clearing pass. Base
coefficients overwrite the corresponding enhancement positions before commit.

## Queue sizing

Initial implementation targets:

- two complete compressed record slots;
- eight base block descriptors (about 1 KiB total);
- 16 sparse enhancement events;
- the two existing transform result banks;
- the two existing decoded stripe banks.

Queue depths are parameters and must be justified by the full-frame testbench.
They are not increased to hide an unbounded producer/consumer mismatch.

## Resource targets

Final C3 place-and-route usage:

- 19,466 / 19,728 logic elements (98.67%);
- 16,137 LUTs/adders (81.80%) and 9,933 registers (71.36%);
- 193 / 204 memory blocks (94.61%);
- 36 / 36 multipliers (100%);
- decoder-domain analyzed Fmax 93.397 MHz versus the 90.001 MHz clock.

This fits the current receiver for evaluation, but leaves too little placement
headroom for feature growth. A faster and preferably larger receiver FPGA is
the practical route to the 50 Hz target.

## Verification gates

1. Unit-test narrow coefficient loading against the legacy 768-bit command for
   randomized base and enhancement blocks.
2. Run the complete precomputed frame with unbounded display output and collect
   per-stage busy/starved/blocked cycle counters.
3. Run real two-bank display flow control. No bank may remain owned past its
   matching display boundary.
4. Only after the simulations pass, run one complete synthesis and place/route.
