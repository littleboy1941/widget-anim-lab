"""Summarize a private-effect capacity recording (variable-rate timestamps)."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import cv2
import numpy as np

from analyze_cells import describe, inspect_cell
from prepare_capacity import parse_mode


def locate_cell(frame: np.ndarray, side: int) -> tuple[int, int, int, int] | None:
    """Find the white large widget, then its centered animation square."""
    small = cv2.resize(frame, (frame.shape[1] // 4, frame.shape[0] // 4),
                       interpolation=cv2.INTER_AREA)
    white = (small.min(axis=2) > 235).astype(np.uint8)
    count, _, stats, _ = cv2.connectedComponentsWithStats(white, 8)
    candidates = []
    for stat in stats[1:count]:
        x, y, width, height, area = (int(value) for value in stat)
        if (width * 4 >= side + 20 and height * 4 >= side + 20
                and width * 4 < frame.shape[1] * 0.98
                and height * 4 < frame.shape[0] * 0.98):
            candidates.append((area, x * 4, y * 4, width * 4, height * 4))
    if not candidates:
        return None
    _, x, y, width, height = max(candidates)
    return (x + (width - side) // 2, y + (height - side) // 2, side, side)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--scale", type=int, default=3, help="simulator pixels per point")
    parser.add_argument("--crop", type=int, nargs=4, metavar=("X", "Y", "W", "H"),
                        help="override automatic crop detection")
    parser.add_argument("--start", type=float, default=2, help="skip startup transients")
    args = parser.parse_args()
    try:
        mode = parse_mode(args.mode)
    except ValueError as exc:
        parser.error(str(exc))
    capture = cv2.VideoCapture(str(args.video))
    if not capture.isOpened():
        parser.error(f"cannot open {args.video}")
    cell = tuple(args.crop) if args.crop else None
    samples = []
    last_time = -math.inf
    recorded = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        time = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if not math.isfinite(time) or time <= last_time:
            continue
        last_time = time
        if time < args.start:
            continue
        recorded += 1
        if cell is None:
            cell = locate_cell(frame, mode["size"] * args.scale)
            if cell is None:
                continue
            print(f"crop x,y,w,h={cell}; inspect home_widget.png to confirm")
        x, y, width, height = cell
        crop = frame[y:y + height, x:x + width]
        if crop.shape[:2] != (height, width):
            parser.error(f"crop {cell} exceeds video dimensions")
        sample = inspect_cell(crop, "idx3", time)
        if sample.index is not None and sample.index >= mode["count"]:
            # A partial transition can combine digits of adjacent frames.
            sample.index = None
            sample.mixed_marker = True
        samples.append(sample)
    capture.release()
    if cell is None:
        parser.error("could not locate widget; use --crop X Y W H")
    if not samples:
        parser.error("no valid timestamped samples")
    duration = max(0.0, samples[-1].time - samples[0].time)
    print(f"mode={args.mode}, T={mode['count'] / mode['fps']:.3f}s, "
          f"video samples={len(samples)}/{recorded}, "
          f"sampling={len(samples) / duration if duration else 0:.1f}/s")
    describe("capacity", samples, mode["count"], None)
    print("blank and doubled/shutter are image heuristics; an unseen frame "
          "cannot be distinguished from a recorder skip")


if __name__ == "__main__":
    main()
