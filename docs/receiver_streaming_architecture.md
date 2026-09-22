# Receiver streaming architecture

## Fixed constraints

- Device: Efinix T20F169.
- Decoder clock: 103.2 MHz.
- Display: 1280x720 at 50 Hz, 45 stripes per frame, 16 lines per stripe.
- One stripe period is 444.444 us, or 45,867 decoder cycles.
- One stripe contains 80 CTUs and 480 8x8 transform blocks.
- Two decoded stripe banks are retained. A third bank would consume about 60
  additional RAM blocks and is not part of the design.
- The existing 32-multiplier IDCT is retained. There is no multiplier budget
  for a second transform engine.

## Throughput contract

The base layer is mandatory and must have bounded work. Enhancement is
best-effort and may never stall base decoding beyond a configurable per-stripe
budget.

For every stripe:

1. Input and entropy parsing may run ahead into compact queues.
2. The transform must accept all 480 blocks within 45,867 cycles.
3. The preferred transform initiation interval is at most 64 cycles. This
   accounts for 30,720 cycles and leaves 14,080 cycles for entropy variation,
   queue bubbles and stripe bookkeeping.
4. If enhancement exceeds its event budget or arrives late, remaining blocks
   use base coefficients. The decoder does not wait indefinitely.

## Pipeline

```
parallel link
  -> record ping-pong RAM
  -> base/enhancement entropy decoders
  -> compact block descriptors and sparse coefficient events
  -> local coefficient loader in IDCT
  -> one 32-multiplier IDCT
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

- no additional multipliers;
- at most 12 additional RAM blocks for record and job queues;
- remove the old wide combiner (about 1,065 LUT and 1,078 FF in the current
  build);
- keep total logic-element use below 90 percent before optional diagnostics;
- keep at least 10 percent positive routing headroom at 100.8 MHz.

## Verification gates

1. Unit-test narrow coefficient loading against the legacy 768-bit command for
   randomized base and enhancement blocks.
2. Run the complete precomputed frame with unbounded display output and collect
   per-stage busy/starved/blocked cycle counters.
3. Run real two-bank display flow control. No bank may remain owned past its
   matching display boundary.
4. Only after the simulations pass, run one complete synthesis and place/route.
