from __future__ import annotations

import json
import os
import struct
import zlib
from collections import Counter
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Edge, FallingEdge, ReadOnly, RisingEdge, Timer


ROOT = Path(__file__).resolve().parents[3]
STREAM = Path(os.environ.get(
    "RECEIVER_E2E_STREAM", "esp32/fs/test/decoder_base.rxt"
))
if not STREAM.is_absolute():
    STREAM = ROOT / STREAM
REPORT = Path(os.environ.get("RECEIVER_E2E_REPORT", "/tmp/receiver_e2e_report.json"))
CAPTURE_DIR_TEXT = os.environ.get("RECEIVER_E2E_CAPTURE_DIR", "").strip()
CAPTURE_DIR = Path(CAPTURE_DIR_TEXT) if CAPTURE_DIR_TEXT else None
HDMI_PIXEL_HZ = 59_400_000
HDMI_H_TOTAL = 1980
HDMI_V_TOTAL = 750
ACTIVE_STRIPE_LINES = 16
VERTICAL_BLANK_LINES = 30
ACTIVE_STRIPE_PERIOD_PS = round(
    1e12 * HDMI_H_TOTAL * ACTIVE_STRIPE_LINES / HDMI_PIXEL_HZ
)
VERTICAL_BLANK_PERIOD_PS = round(
    1e12 * HDMI_H_TOTAL * VERTICAL_BLANK_LINES / HDMI_PIXEL_HZ
)
HDMI_FRAME_RATE = HDMI_PIXEL_HZ / HDMI_H_TOTAL / HDMI_V_TOTAL
DECODER_CLOCK_HZ = 88_000_000
REQUIRED_CYCLES_PER_STRIPE = round(
    ACTIVE_STRIPE_PERIOD_PS * DECODER_CLOCK_HZ / 1e12
)


def load_records(path: Path) -> list[bytes]:
    data = path.read_bytes()
    assert data[:8] == b"HDZRXT1\0"
    count, maximum = struct.unpack_from("<HH", data, 8)
    offset = 16
    records: list[bytes] = []
    for _ in range(count):
        length = struct.unpack_from("<H", data, offset)[0]
        offset += 2
        assert 20 <= length <= maximum
        records.append(data[offset:offset + length])
        offset += length
    assert offset == len(data)
    return records


def completed_base_stripes(records: list[bytes], *, require_complete: bool) -> int:
    completed: list[int] = []
    active_stripe: int | None = None
    active_count = 0
    next_fragment = 0
    for record in records:
        if record[3] != 0x10:
            continue
        stripe = record[10]
        fragment_index = record[12]
        fragment_count = record[13]
        assert fragment_count > 0
        if fragment_index == 0:
            assert active_stripe is None
            active_stripe = stripe
            active_count = fragment_count
            next_fragment = 0
        assert active_stripe == stripe
        assert active_count == fragment_count
        assert fragment_index == next_fragment
        next_fragment += 1
        if next_fragment == active_count:
            completed.append(stripe)
            active_stripe = None
    if require_complete:
        assert active_stripe is None
    return len(completed)


async def reset_dut(dut) -> None:
    dut.pll_lock.value = 0
    dut.pll2_lock.value = 0
    dut.PAR_CS.value = 0
    dut.PAR_D.value = 0
    dut.SPI_CLK.value = 0
    dut.SPI_CS.value = 1
    dut.SPI_MOSI.value = 0
    dut.CSI_PCLK.value = 0
    dut.CSI_VSYNC.value = 0
    dut.CSI_HSYNC.value = 0
    dut.CSI_D.value = 0
    await ClockCycles(dut.pll_60Mhz, 8)
    dut.pll_lock.value = 1
    dut.pll2_lock.value = 1
    await ClockCycles(dut.hdmi_pixel_clk, 5)
    assert int(dut.reset_60_n.value)
    assert int(dut.reset_24_n.value)
    assert int(dut.reset_pixel_n.value)


async def wait_link_enabled(dut) -> None:
    wait_start = cocotb.utils.get_sim_time(units="ns")
    while True:
        await FallingEdge(dut.pll_24Mhz)
        await ReadOnly()
        if int(dut.link_clock_enabled_24.value):
            await Timer(1, units="ps")
            return
        if cocotb.utils.get_sim_time(units="ns") - wait_start > 50_000_000:
            raise AssertionError("PAR_CLK remained gated for 50 ms")


async def drive_accelerated_video_clock(dut) -> None:
    """Drive real 16-line deadlines and the separate vertical blank gap."""
    dut.hdmi_pixel_clk.value = 0
    period_ps = ACTIVE_STRIPE_PERIOD_PS
    while True:
        await Timer(period_ps, units="ps")
        dut.hdmi_pixel_clk.value = 1
        await Timer(1, units="ns")
        dut.hdmi_pixel_clk.value = 0
        period_ps = (
            VERTICAL_BLANK_PERIOD_PS
            if int(dut.reset_pixel_n.value) and int(dut.video_y.value) == 749
            else ACTIVE_STRIPE_PERIOD_PS
        )


async def send_record(dut, record: bytes, stats: dict[str, int]) -> None:
    for value in record:
        for nibble in (value >> 4, value & 0x0F):
            await wait_link_enabled(dut)
            dut.PAR_CS.value = 1
            dut.PAR_D.value = nibble
            await RisingEdge(dut.pll_24Mhz)
            stats["nibbles"] += 1
    await wait_link_enabled(dut)
    dut.PAR_CS.value = 0
    dut.PAR_D.value = 0
    await RisingEdge(dut.pll_24Mhz)
    stats["records"] += 1
    stats["bytes"] += len(record)


async def monitor_completions(
    dut,
    origin_ns: float,
    events: list[dict[str, float]],
    output_stats: dict[str, object],
    capture: dict[str, object] | None,
) -> None:
    """Timestamp the last reconstructed sample accepted for each stripe."""
    completed = 0
    while True:
        await RisingEdge(dut.pll_60Mhz)
        await ReadOnly()
        if (int(dut.base_write_valid.value)
                and int(dut.base_write_ready.value)):
            plane = int(dut.base_write_plane.value)
            value = int(dut.base_write_data.value)
            expected_neutral = 126 if plane == 0 else 128
            output_stats["samples"][plane] += 1
            output_stats["minimum"][plane] = min(
                output_stats["minimum"][plane], value
            )
            output_stats["maximum"][plane] = max(
                output_stats["maximum"][plane], value
            )
            output_stats["xor"][plane] ^= value
            output_stats["nonneutral"][plane] += value != expected_neutral
            if capture is not None:
                stripe = int(dut.base_write_stripe_id.value)
                address = int(dut.base_write_address.value)
                plane_size = 20_480 if plane == 0 else 5_120
                assert 0 <= stripe < 45
                assert 0 <= address < plane_size
                offset = stripe * plane_size + address
                capture["planes"][plane][offset] = value
                if not capture["seen"][plane][offset]:
                    capture["seen"][plane][offset] = 1
                    capture["unique_samples"][plane] += 1
        if (int(dut.base_write_valid.value)
                and int(dut.base_write_ready.value)
                and int(dut.base_write_last.value)):
            completed += 1
            events.append({
                "index": completed,
                "time_us": (
                    cocotb.utils.get_sim_time(units="ns") - origin_ns
                ) / 1e3,
            })


async def monitor_pipeline_profile(dut, profile: dict[str, object]) -> None:
    """Count decoder-domain occupancy and completed-block spacing."""
    states: Counter[str] = Counter()
    block_intervals: list[int] = []
    decoder = dut.base_decoder
    block_counter = getattr(decoder, "bounded_completed_block_count", None)
    previous_block = int(block_counter.value) if block_counter is not None else 0
    previous_block_cycle = 0
    cycle = 0
    while True:
        await RisingEdge(dut.pll_60Mhz)
        cycle += 1
        entropy = decoder.entropy
        states[f"entropy_{int(entropy.state.value)}"] += 1
        states[f"fifo_{int(decoder.write_fifo_level.value)}"] += 1
        states["entropy_output_valid"] += int(entropy.block_valid.value)
        states["entropy_output_stalled"] += int(
            entropy.block_valid.value and not entropy.block_ready.value
        )
        states["transform_busy"] += int(dut.transform_busy.value)
        states["reconstruction_stalled"] += int(
            decoder.reconstruction_write_valid.value
            and not decoder.reconstruction_write_ready.value
        )
        states["stripe_output_stalled"] += int(
            dut.decoded_write_valid.value and not dut.decoded_write_ready.value
        )
        if block_counter is not None:
            current_block = int(block_counter.value)
            if current_block != previous_block:
                block_intervals.append(cycle - previous_block_cycle)
                previous_block_cycle = cycle
                previous_block = current_block
        profile["cycles"] = cycle
        profile["states"] = dict(states)
        profile["block_intervals_cycles"] = block_intervals


def snapshot(dut) -> dict[str, int]:
    names = (
        "link_byte_count", "link_transaction_count", "link_read_level",
        "base_completed_count", "stripe_displayed_count",
        "stripe_missing_count", "enhancement_stored_count",
        "enhancement_store_rejected_count", "enhancement_replayed_count",
        "enhancement_request_miss_count", "transform_fifo_level",
    )
    return {name: int(getattr(dut, name).value) for name in names}


@cocotb.test()
async def full_rxt_stream_reaches_hdmi_at_realtime_rate(dut) -> None:
    # Production clock ratios. Fast HDMI is unused by the RTL top but is
    # driven to keep this test interchangeable with future serializer logic.
    cocotb.start_soon(Clock(dut.CLK_48Mhz, 20_834, units="ps").start())
    cocotb.start_soon(Clock(dut.pll_60Mhz, 11_364, units="ps").start())
    cocotb.start_soon(Clock(dut.pll_24Mhz, 41_666, units="ps").start())
    cocotb.start_soon(drive_accelerated_video_clock(dut))
    # The 2x/5x clocks only serialize an already-produced TMDS word. Holding
    # them low preserves the complete decoder/display behaviour while avoiding
    # tens of millions of irrelevant simulator events per input frame.
    dut.hdmi_half_pixel_clk.value = 0
    dut.hdmi_fast_clk.value = 0

    await reset_dut(dut)
    records = load_records(STREAM)
    type_counts = Counter(record[3] for record in records)
    assert 0x10 in type_counts
    assert set(type_counts).issubset({0x10, 0x11})
    assert completed_base_stripes(records, require_complete=True) == 45
    selected_stripes_text = os.environ.get("RECEIVER_E2E_STRIPES", "").strip()
    if selected_stripes_text:
        selected_stripes = {
            int(value, 0) for value in selected_stripes_text.split(",")
        }
        if not selected_stripes or any(not 0 <= value < 45
                                       for value in selected_stripes):
            raise ValueError("RECEIVER_E2E_STRIPES must contain IDs in [0, 44]")
        records = [record for record in records if record[10] in selected_stripes]
    maximum_records = int(os.environ.get("RECEIVER_E2E_MAX_RECORDS", "0"))
    if maximum_records:
        records = records[:maximum_records]
    selected_type_counts = Counter(record[3] for record in records)
    selected_base_stripes = completed_base_stripes(
        records, require_complete=False
    )

    unbounded_output = bool(int(os.environ.get(
        "RECEIVER_E2E_UNBOUNDED_OUTPUT", "0"
    )))
    start_ns = cocotb.utils.get_sim_time(units="ns")
    start = snapshot(dut)
    tx = {"records": 0, "bytes": 0, "nibbles": 0}
    passes = int(os.environ.get("RECEIVER_E2E_PASSES", "2"))
    pass_times: list[float] = []
    completion_events: list[dict[str, float]] = []
    output_stats: dict[str, object] = {
        "samples": [0, 0, 0],
        "minimum": [255, 255, 255],
        "maximum": [0, 0, 0],
        "xor": [0, 0, 0],
        "nonneutral": [0, 0, 0],
    }
    capture = None
    if CAPTURE_DIR is not None:
        capture = {
            "planes": [bytearray(1280 * 720),
                       bytearray(640 * 360), bytearray(640 * 360)],
            "seen": [bytearray(1280 * 720),
                     bytearray(640 * 360), bytearray(640 * 360)],
            "unique_samples": [0, 0, 0],
        }
    completion_monitor = cocotb.start_soon(
        monitor_completions(
            dut, start_ns, completion_events, output_stats, capture
        )
    )
    pipeline_profile: dict[str, object] = {}
    profile_monitor = None
    if bool(int(os.environ.get("RECEIVER_E2E_PROFILE", "0"))):
        profile_monitor = cocotb.start_soon(
            monitor_pipeline_profile(dut, pipeline_profile)
        )

    for _ in range(passes):
        for record in records:
            await send_record(dut, record, tx)
        pass_times.append(cocotb.utils.get_sim_time(units="ns") - start_ns)

    # Let the final parser transaction and decoder drain. A complete stripe
    # must fit inside the active-line budget to sustain the selected raster.
    expected = selected_base_stripes * passes
    timeout_ns = 10_000_000
    deadline = cocotb.utils.get_sim_time(units="ns") + timeout_ns
    while len(completion_events) < expected:
        if cocotb.utils.get_sim_time(units="ns") >= deadline:
            break
        await Timer(100, units="us")

    # With real bank ownership the first disposable frame establishes phase.
    # Wait for HDMI to consume every produced stripe before taking the final
    # snapshot; this is the end-to-end guarantee omitted by unbounded mode.
    if not unbounded_output:
        display_deadline = cocotb.utils.get_sim_time(units="ns") + 30_000_000
        while (int(dut.stripe_displayed_count.value)
               - start["stripe_displayed_count"] < expected):
            if cocotb.utils.get_sim_time(units="ns") >= display_deadline:
                break
            await Timer(100, units="us")

    end_ns = cocotb.utils.get_sim_time(units="ns")
    end = snapshot(dut)
    delta = {name: end[name] - start[name] for name in end}
    elapsed_s = (end_ns - start_ns) / 1e9
    completed = len(completion_events)
    completion_monitor.kill()
    if profile_monitor is not None:
        profile_monitor.kill()
    completion_intervals_us = [
        event["time_us"] - (
            completion_events[index - 1]["time_us"] if index else 0.0
        )
        for index, event in enumerate(completion_events)
    ]
    stripe_budget_us = ACTIVE_STRIPE_PERIOD_PS / 1e6
    # Unbounded mode has no display startup. With real bank ownership the
    # entire first frame is the allowed phase-acquisition frame, so enforce
    # continuous deadlines starting at the second frame.
    steady_start = 1 if unbounded_output else selected_base_stripes
    steady_completion_intervals_us = completion_intervals_us[steady_start:]
    steady_over_budget_indices = [
        index + steady_start
        for index, interval in enumerate(steady_completion_intervals_us)
        if interval > stripe_budget_us
    ]
    maximum_steady_interval_us = max(
        steady_completion_intervals_us, default=0.0
    )
    steady_equivalent_frames_per_second = (
        1e6 / maximum_steady_interval_us / 45.0
        if maximum_steady_interval_us else 0.0
    )
    capture_report = None
    if capture is not None:
        CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
        plane_names = ("y", "cb", "cr")
        for name, plane in zip(plane_names, capture["planes"]):
            (CAPTURE_DIR / f"rtl_{name}.raw").write_bytes(plane)
        capture_crc = 0
        for plane in capture["planes"]:
            capture_crc = zlib.crc32(plane, capture_crc)
        expected_crc = struct.unpack_from("<I", STREAM.read_bytes(), 12)[0]
        capture_report = {
            "directory": str(CAPTURE_DIR),
            "unique_samples": capture["unique_samples"],
            "crc32": f"{capture_crc:08x}",
            "expected_crc32": f"{expected_crc:08x}",
            "crc_match": capture_crc == expected_crc,
        }
        (CAPTURE_DIR / "capture.json").write_text(
            json.dumps(capture_report, indent=2) + "\n"
        )
    report = {
        "stream": str(STREAM),
        "unbounded_output": unbounded_output,
        "passes": passes,
        "records_per_pass": len(records),
        "base_records_per_pass": selected_type_counts[0x10],
        "base_stripes_per_pass": selected_base_stripes,
        "enhancement_records_per_pass": selected_type_counts[0x11],
        "tx": tx,
        "pass_times_ms": [value / 1e6 for value in pass_times],
        "elapsed_ms": elapsed_s * 1e3,
        "delta": delta,
        "decoded_stripes_per_second": completed / elapsed_s,
        "equivalent_frames_per_second": completed / elapsed_s / 45.0,
        "required_active_stripes_per_second": 1e12 / ACTIVE_STRIPE_PERIOD_PS,
        "hdmi_frame_rate": HDMI_FRAME_RATE,
        "required_cycles_per_stripe": REQUIRED_CYCLES_PER_STRIPE,
        "completion_events": completion_events,
        "completion_intervals_us": completion_intervals_us,
        "maximum_completion_interval_us": max(completion_intervals_us, default=0.0),
        "maximum_steady_completion_interval_us": maximum_steady_interval_us,
        "steady_equivalent_frames_per_second": (
            steady_equivalent_frames_per_second
        ),
        "over_budget_completion_indices": [
            index for index, interval in enumerate(completion_intervals_us)
            if interval > stripe_budget_us
        ],
        "steady_over_budget_completion_indices": steady_over_budget_indices,
        "output_stats": output_stats,
        "capture": capture_report,
        "pipeline_profile": pipeline_profile,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n")
    dut._log.info("RECEIVER_E2E_REPORT %s", json.dumps(report, sort_keys=True))

    assert int(dut.link_overflow_24.value) == 0
    assert int(dut.link_framing_24.value) == 0
    assert delta["link_transaction_count"] == len(records) * passes
    assert delta["base_completed_count"] == expected, (
        f"entropy completed only {delta['base_completed_count']}/{expected} "
        f"stripes; report written to {REPORT}"
    )
    assert completed == expected, (
        f"reconstruction emitted only {completed}/{expected} stripes; "
        f"report written to {REPORT}"
    )
    assert delta["enhancement_store_rejected_count"] == 0
    if capture is not None:
        assert capture["unique_samples"] == [1280 * 720, 640 * 360, 640 * 360]
        assert capture_report["crc_match"], (
            "RTL reconstructed frame CRC differs from the software reference; "
            f"capture written to {CAPTURE_DIR}"
        )
    if unbounded_output:
        assert steady_equivalent_frames_per_second >= HDMI_FRAME_RATE, (
            "pipeline steady state sustains only "
            f"{steady_equivalent_frames_per_second:.2f} fps"
        )
    else:
        assert delta["stripe_displayed_count"] == expected, (
            f"HDMI displayed only {delta['stripe_displayed_count']}/{expected} "
            f"decoded stripes; report written to {REPORT}"
        )
    if unbounded_output:
        assert not steady_over_budget_indices, (
            "continuous stripe deadlines missed at completion indices "
            f"{steady_over_budget_indices}; report written to {REPORT}"
        )
    else:
        # The bounded decoder is intentionally paced by HDMI bank releases.
        # Vertical blanking can stretch completion intervals without losing
        # output; the end-to-end invariant is that every decoded stripe is
        # eventually selected by the display after the disposable first frame.
        assert delta["stripe_missing_count"] == selected_base_stripes, (
            "unexpected missing stripes after phase acquisition: "
            f"{delta['stripe_missing_count']}; report written to {REPORT}"
        )