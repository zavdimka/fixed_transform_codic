#!/usr/bin/env python3
"""Compatible CLI for the modular HEVC/radio reference experiment.

The actual HEVC encoder is still the external x265 oracle. Deterministic
Annex-B and radio logic lives in :mod:`hevc_reference` so it can be reused by
future bit-exact RTL tests without invoking this CLI.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

from hevc_reference.annexb import NalUnit, START_CODE, VCL_TYPES, annexb_nals
from hevc_reference.external_codec import decode_hevc, encode_hevc, require_tools
from hevc_reference.metrics import psnr
from hevc_reference.radio import PACKET_HEADER, packetize, reassemble, simulate_loss

def execute(args: argparse.Namespace, qp: int, slices: int, run_dir: Path) -> dict:
    run_dir.mkdir(parents=True, exist_ok=True)
    encoded_path = run_dir / "encoded.hevc"
    decoded_path = run_dir / "decoded.png"
    recovered_path = run_dir / "recovered.hevc"
    recovered_image_path = run_dir / "recovered.png"
    gray_input_path = run_dir / "gray_template.png"
    gray_hevc_path = run_dir / "gray_template.hevc"

    encode_hevc(
        args.input, encoded_path, qp, slices, args.preset, args.ctu,
        args.loss_oriented, args.fpga_lite,
    )
    if not decode_hevc(encoded_path, decoded_path):
        raise RuntimeError("FFmpeg could not decode its own HEVC stream")

    source = np.asarray(Image.open(args.input).convert("RGB"), dtype=np.uint8)
    decoded = np.asarray(Image.open(decoded_path).convert("RGB"), dtype=np.uint8)
    nals = annexb_nals(encoded_path.read_bytes())
    concealment_nals: list[NalUnit | None] | None = None
    gray_template_bytes = 0
    if args.loss_concealment == "gray-slices":
        height, width = source.shape[:2]
        Image.new("RGB", (width, height), (128, 128, 128)).save(gray_input_path)
        encode_hevc(
            gray_input_path, gray_hevc_path, qp, slices, args.preset, args.ctu,
            args.loss_oriented, args.fpga_lite,
        )
        gray_vcl = [
            nal for nal in annexb_nals(gray_hevc_path.read_bytes())
            if nal.nal_type in VCL_TYPES
        ]
        expected_vcl_count = sum(nal.nal_type in VCL_TYPES for nal in nals)
        if len(gray_vcl) != expected_vcl_count:
            raise RuntimeError(
                "gray template slice layout differs from the source stream"
            )
        gray_iter = iter(gray_vcl)
        concealment_nals = [
            next(gray_iter) if nal.nal_type in VCL_TYPES else None
            for nal in nals
        ]
        gray_template_bytes = sum(len(nal.data) + len(START_CODE) for nal in gray_vcl)

    packets, cached = packetize(
        nals, args.packet_bytes, args.frame_id,
        args.parameter_sets == "cached", args.copies, args.xor_groups,
        args.packet_order,
    )
    received, dropped, effective_drop = simulate_loss(
        packets, args.packet_bytes, args.packet_drop_rate,
        args.reference_packet_bytes, args.packet_drop_seed, args.loss_model,
        args.burst_min_packets, args.burst_max_packets,
    )
    (
        recovered, complete_vcl, incomplete_vcl, repaired_vcl, concealed_vcl
    ) = reassemble(
        received, cached, nals, args.packet_bytes, concealment_nals
    )
    recovered_path.write_bytes(recovered)
    recovered_decoded = decode_hevc(recovered_path, recovered_image_path)
    recovered_psnr = None
    if recovered_decoded:
        recovered_rgb = np.asarray(
            Image.open(recovered_image_path).convert("RGB"), dtype=np.uint8
        )
        recovered_psnr = psnr(source, recovered_rgb)

    pixels = source.shape[0] * source.shape[1]
    vcl_sizes = [len(nal.data) for nal in nals if nal.nal_type in VCL_TYPES]
    report = {
        "qp": qp,
        "slices_requested": slices,
        "vcl_nal_count": len(vcl_sizes),
        "vcl_nal_bytes": vcl_sizes,
        "largest_vcl_nal": max(vcl_sizes, default=0),
        "hevc_bytes": encoded_path.stat().st_size,
        "hevc_bpp": encoded_path.stat().st_size * 8 / pixels,
        "loss_free_psnr": psnr(source, decoded),
        "radio_packets": len(packets),
        "copies": args.copies,
        "radio_bytes": sum(len(packet.raw) for packet in packets),
        "radio_bpp": sum(len(packet.raw) for packet in packets) * 8 / pixels,
        "minimum_packet_bytes": min((len(packet.raw) for packet in packets), default=0),
        "maximum_packet_bytes": max((len(packet.raw) for packet in packets), default=0),
        "average_packet_bytes": (
            sum(len(packet.raw) for packet in packets) / len(packets)
            if packets else 0.0
        ),
        "dropped_packets": dropped,
        "effective_drop_rate": effective_drop,
        "loss_model": args.loss_model,
        "burst_packets": [args.burst_min_packets, args.burst_max_packets],
        "packet_order": args.packet_order,
        "complete_vcl_nals": complete_vcl,
        "incomplete_vcl_nals": incomplete_vcl,
        "repaired_vcl_nals": repaired_vcl,
        "concealed_vcl_nals": concealed_vcl,
        "loss_concealment": args.loss_concealment,
        "gray_template_bytes": gray_template_bytes,
        "recovered_decoded": recovered_decoded,
        "recovered_psnr": recovered_psnr,
        "cached_parameter_bytes": sum(len(nal.data) + 4 for nal in cached),
    }
    (run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def print_report(report: dict) -> None:
    recovered = (
        f"{report['recovered_psnr']:.3f} dB"
        if report["recovered_psnr"] is not None else "decode failed"
    )
    print(
        f"QP {report['qp']:2d}, slices {report['vcl_nal_count']:2d}: "
        f"HEVC {report['hevc_bpp']:.4f} bpp, "
        f"radio {report['radio_bpp']:.4f} bpp, "
        f"PSNR {report['loss_free_psnr']:.3f} dB"
    )
    print(
        f"  VCL max={report['largest_vcl_nal']} B; packets="
        f"{report['radio_packets']} "
        f"({report['minimum_packet_bytes']}/"
        f"{report['average_packet_bytes']:.1f}/"
        f"{report['maximum_packet_bytes']} B), "
        f"dropped={report['dropped_packets']}"
    )
    print(
        f"  complete/incomplete/repaired/concealed slices="
        f"{report['complete_vcl_nals']}/{report['incomplete_vcl_nals']}/"
        f"{report['repaired_vcl_nals']}/{report['concealed_vcl_nals']}; "
        f"recovered={recovered}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Standard HEVC All-Intra + custom radio fragmentation experiment"
    )
    parser.add_argument("input", type=Path)
    parser.add_argument("--qp", type=int, default=35)
    parser.add_argument("--slices", type=int, default=12)
    parser.add_argument("--ctu", type=int, choices=(16, 32, 64), default=64)
    parser.add_argument("--preset", default="medium")
    parser.add_argument("--packet-bytes", type=int, default=890)
    parser.add_argument("--packet-drop-rate", type=float, default=0.0)
    parser.add_argument("--packet-drop-seed", type=int, default=1234)
    parser.add_argument(
        "--copies", type=int, default=1,
        help="transmit complete time-separated passes of every radio fragment",
    )
    parser.add_argument("--reference-packet-bytes", type=int, default=890)
    parser.add_argument(
        "--xor-groups", type=int, default=0,
        help="number of interleaved XOR repair groups per fragmented NAL",
    )
    parser.add_argument(
        "--loss-model", choices=("airtime", "fixed", "burst"),
        default="airtime",
    )
    parser.add_argument("--burst-min-packets", type=int, default=2)
    parser.add_argument("--burst-max-packets", type=int, default=10)
    parser.add_argument(
        "--packet-order", choices=("nal", "round-robin"), default="nal",
    )
    parser.add_argument(
        "--parameter-sets", choices=("cached", "in-band"), default="cached"
    )
    parser.add_argument(
        "--loss-oriented", action=argparse.BooleanOptionalAction, default=True,
        help="disable SAO/deblock to remove reconstructed slice-boundary filtering",
    )
    parser.add_argument(
        "--loss-concealment", choices=("decoder", "gray-slices"),
        default="gray-slices",
        help="replace missing VCL NALs with standard pre-encoded gray slices",
    )
    parser.add_argument(
        "--fpga-lite", action="store_true",
        help="restrict encoder-only HEVC search/tree tools for an FPGA-like profile",
    )
    parser.add_argument("--frame-id", type=int, default=0)
    parser.add_argument("--output-dir", type=Path, default=Path("hevc_results"))
    parser.add_argument(
        "--sweep-qp", nargs="*", type=int,
        help="run several QPs instead of only --qp",
    )
    parser.add_argument(
        "--sweep-slices", nargs="*", type=int,
        help="run several slice counts instead of only --slices",
    )
    args = parser.parse_args()

    require_tools()
    if not args.input.exists():
        raise SystemExit(f"input image not found: {args.input}")
    if not 0 <= args.qp <= 51:
        raise SystemExit("--qp must be in [0, 51]")
    if args.slices < 1:
        raise SystemExit("--slices must be positive")
    if args.packet_bytes <= PACKET_HEADER.size:
        raise SystemExit(
            f"--packet-bytes must exceed {PACKET_HEADER.size}-byte radio header"
        )
    if args.copies < 1:
        raise SystemExit("--copies must be positive")
    if not 0 <= args.xor_groups <= 15:
        raise SystemExit("--xor-groups must be in [0, 15]")
    if not 0.0 <= args.packet_drop_rate <= 1.0:
        raise SystemExit("--packet-drop-rate must be in [0, 1]")
    if not 1 <= args.burst_min_packets <= args.burst_max_packets:
        raise SystemExit("invalid burst packet range")

    qps = args.sweep_qp if args.sweep_qp else [args.qp]
    slice_counts = args.sweep_slices if args.sweep_slices else [args.slices]
    reports: list[dict] = []
    for slices in slice_counts:
        for qp in qps:
            run_dir = args.output_dir / f"slices{slices}_qp{qp}"
            report = execute(args, qp, slices, run_dir)
            reports.append(report)
            print_report(report)
    (args.output_dir / "summary.json").write_text(
        json.dumps(reports, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
