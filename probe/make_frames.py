"""Generate transparent, numbered frames for a long widget animation."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw


# Chosen from saturated HSV candidates by farthest-point sampling in Lab.
# Minimum pairwise OpenCV Lab distance is 52 (versus 11 for 16 uniform hues).
PALETTE: tuple[tuple[int, int, int], ...] = (
    (255, 0, 0),
    (8, 255, 0),
    (8, 0, 255),
    (0, 183, 255),
    (255, 64, 225),
    (255, 191, 0),
    (41, 166, 84),
    (41, 84, 166),
    (64, 255, 219),
    (166, 0, 62),
    (166, 111, 41),
    (166, 0, 155),
    (223, 255, 0),
    (255, 64, 118),
    (0, 26, 166),
    (64, 129, 255),
)


def make_frame(index: int, count: int, size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    marker = size // 5
    draw.rectangle((0, 0, marker - 1, marker - 1), fill=PALETTE[index // 16] + (255,))
    draw.rectangle((size - marker, 0, size - 1, marker - 1), fill=PALETTE[index % 16] + (255,))

    angle = 2 * math.pi * index / count
    radius = size * 0.19
    cx = size * 0.5 + radius * math.cos(angle)
    cy = size * 0.69 + radius * math.sin(angle)
    ball_radius = size / 12
    draw.ellipse(
        (round(cx - ball_radius), round(cy - ball_radius),
         round(cx + ball_radius), round(cy + ball_radius)),
        fill=(40, 40, 40, 255),
    )
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, required=True, help="number of frames, 1..240")
    parser.add_argument("--size", type=int, default=150)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.count <= 240:
        parser.error("--count must be between 1 and 240")
    if args.size < 32:
        parser.error("--size must be at least 32")

    args.out.mkdir(parents=True, exist_ok=True)
    for index in range(args.count):
        make_frame(index, args.count, args.size).save(args.out / f"frame_{index}.png")
    print(f"Wrote {args.count} RGBA frames to {args.out}")


if __name__ == "__main__":
    main()
