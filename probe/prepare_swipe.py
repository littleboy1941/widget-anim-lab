"""Кадры опыта со свайпом (SwipeWidget.swift): 16 кадров 150 px с idx-метками в RateFrames."""

from __future__ import annotations

from pathlib import Path

from make_frames import make_frame

ROOT = Path(__file__).resolve().parent


def main() -> None:
    frames = ROOT / "RateFrames"
    frames.mkdir(exist_ok=True)
    for i in range(16):
        make_frame(i, 16, 150).save(frames / f"fps16_{i}.png", optimize=True)
    print(f"Swipe frames: {len(list(frames.glob('fps16_*.png')))} PNGs")


if __name__ == "__main__":
    main()
