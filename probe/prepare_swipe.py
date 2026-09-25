"""Кадры опытов со свайпом (SwipeWidget.swift, PrivateWidget.swift): 16 и 30 кадров 150 px
с idx-метками в RateFrames."""

from __future__ import annotations

from pathlib import Path

from make_frames import make_frame

ROOT = Path(__file__).resolve().parent


def main() -> None:
    frames = ROOT / "RateFrames"
    frames.mkdir(exist_ok=True)
    for fps in (16, 30):
        for i in range(fps):
            make_frame(i, fps, 150).save(frames / f"fps{fps}_{i}.png", optimize=True)
    print(f"Swipe frames: {len(list(frames.glob('fps*_*.png')))} PNGs")


if __name__ == "__main__":
    main()
