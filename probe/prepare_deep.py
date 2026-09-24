"""Generate deep-series PNGs for both app and widget before XcodeGen runs."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from make_frames import make_frame

ROOT = Path(__file__).resolve().parent


def main() -> None:
    spec = (ROOT / "project.yml").read_text(encoding="utf-8")
    for name in ("WABlink30.ttf", "WABlink60.ttf"):
        if spec.count(f"- {name}") != 2:
            raise SystemExit(f"project.yml must list {name} in both UIAppFonts arrays")

    frames = ROOT / "DeepFrames"
    frames.mkdir(exist_ok=True)
    for i in range(240):
        small = frames / f"deep240s_{i}.png"
        make_frame(i, 240, 48).save(small, optimize=True)
        make_frame(i, 240, 150).save(frames / f"deep240_{i}.png", optimize=True)
        shutil.copyfile(small, frames / f"deep480s_{i}.png")
        # Distinct resource name and image layer, same idx picture as i.
        shutil.copyfile(small, frames / f"deep480s_{i + 240}.png")

    subprocess.run(
        [sys.executable, str(ROOT / "fontgen.py"), "--blink-only", "--blink", "30", "60",
         "--out", str(ROOT / "Fonts")],
        check=True,
    )
    print(f"Deep frames: {len(list(frames.glob('*.png')))} PNGs")


if __name__ == "__main__":
    main()
