"""Create both rate-series asset sets before XcodeGen runs in CI."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from make_frames import make_frame
from PIL import Image

ROOT = Path(__file__).resolve().parent
FONT_SETS = (("WAFrame24_", 24, 240, True),
             ("WAFrame30_", 30, 120, True),
             ("WAFrame8SVG_", 8, 80, False))


def manifest() -> list[str]:
    return [f"{prefix}{i}.ttf" for prefix, fps, _, _ in FONT_SETS
            for i in range(2 * fps)]


def check_manifest() -> None:
    spec = (ROOT / "project.yml").read_text(encoding="utf-8")
    for name in manifest():
        if spec.count(f"- {name}") != 2:
            raise SystemExit(f"project.yml must list {name} in both UIAppFonts arrays")


def main() -> None:
    check_manifest()
    rate_dir = ROOT / "RateFrames"
    rate_dir.mkdir(exist_ok=True)
    for fps in (8, 12, 16, 24, 30):
        for i in range(fps):
            make_frame(i, fps, 150).save(rate_dir / f"fps{fps}_{i}.png", optimize=True)

    for prefix, fps, count, sbix in FONT_SETS:
        frame_dir = ROOT / "_tmp" / prefix
        frame_dir.mkdir(parents=True, exist_ok=True)
        for i in range(count):
            path = frame_dir / f"frame_{i}.png"
            # Bryce's later glyph must cover all earlier glyphs in its stack.
            # Transparent source frames would leave previous balls visible.
            opaque = Image.new("RGBA", (96, 96), "white")
            opaque.alpha_composite(make_frame(i, count, 96))
            opaque.save(path, optimize=True)
        cmd = [sys.executable, str(ROOT / "fontgen.py"), "--blink",
               "--fps", str(fps), "--out", str(ROOT / "Fonts"),
               "--prefix", prefix, "--input-dir", str(frame_dir)]
        if sbix:
            cmd.append("--sbix")
        subprocess.run(cmd, check=True)
        total = sum((ROOT / "Fonts" / f"{prefix}{i}.ttf").stat().st_size
                    for i in range(2 * fps))
        print(f"{prefix}: {count} frames, {2 * fps} fonts, {total / 1048576:.2f} MiB")


if __name__ == "__main__":
    main()
