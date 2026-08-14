"""FFmpeg/libx265 adapter used only as a quality and syntax oracle."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess

def run(command: list[str], *, quiet: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.PIPE,
    )


def require_tools() -> None:
    missing = [name for name in ("ffmpeg", "ffprobe") if shutil.which(name) is None]
    if missing:
        raise SystemExit("missing executable(s): " + ", ".join(missing))


def encode_hevc(
    input_path: Path,
    output_path: Path,
    qp: int,
    slices: int,
    preset: str,
    ctu: int,
    loss_oriented: bool,
    fpga_lite: bool,
) -> None:
    # All pictures are IDR/I pictures: no temporal references, no lookahead and
    # no B pictures. Multiple x265 slices require WPP in this implementation.
    params = {
        # keyint=1 makes x265 signal the less universally accelerated
        # Main-Intra/RExt profile. This one-picture invocation still emits an
        # IDR, while keyint=2 allows an ordinary Main-profile SPS. A persistent
        # implementation must explicitly force every input picture to IDR.
        "keyint": 2,
        "min-keyint": 1,
        "bframes": 0,
        "rc-lookahead": 0,
        "scenecut": 0,
        "repeat-headers": 1,
        "annexb": 1,
        "info": 0,
        "pools": 1,
        "frame-threads": 1,
        "wpp": 1,
        "slices": slices,
        "qp": qp,
        "ipratio": 1.0,
        "ctu": ctu,
        "ref": 1,
        "weightp": 0,
        "temporal-mvp": 0,
    }
    if loss_oriented:
        # Removing in-loop filtering makes slice boundaries independent at the
        # reconstructed-pixel level and reduces FPGA line-buffer complexity.
        params.update({"sao": 0, "no-deblock": 1})
    if fpga_lite:
        params.update({
            "min-cu-size": 16,
            "max-tu-size": 16,
            "tu-intra-depth": 1,
            "rd": 2,
            "rdoq-level": 0,
            "psy-rd": 0,
            "psy-rdoq": 0,
            "aq-mode": 0,
            "no-signhide": 1,
            "no-strong-intra-smoothing": 1,
            "limit-modes": 1,
        })
    encoded_params = ":".join(f"{key}={value}" for key, value in params.items())
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(input_path), "-frames:v", "1", "-pix_fmt", "yuv420p",
        "-c:v", "libx265", "-profile:v", "main", "-preset", preset,
        "-x265-params", encoded_params,
        "-f", "hevc", str(output_path),
    ], quiet=True)


def decode_hevc(input_path: Path, output_path: Path) -> bool:
    try:
        run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-err_detect", "ignore_err", "-i", str(input_path),
            "-frames:v", "1", str(output_path),
        ], quiet=True)
    except subprocess.CalledProcessError:
        return False
    return output_path.exists()
