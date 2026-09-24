#!/usr/bin/env python3
"""Find the numbered widget animation in a simulator recording and gate its playback."""

from __future__ import annotations

import argparse
import math
import statistics
import sys
from pathlib import Path

import cv2
import numpy as np

PROBE = Path(__file__).resolve().parents[2] / "probe"
sys.path.insert(0, str(PROBE))
from analyze_cells import inspect_cell, sample_weights  # noqa: E402


def red_squares(frame: np.ndarray) -> list[tuple[int, int, int]]:
    """Locate the red high-nibble marker, whose side is one fifth of the source."""
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    red = (((hsv[:, :, 0] <= 11) | (hsv[:, :, 0] >= 170))
           & (hsv[:, :, 1] >= 110) & (hsv[:, :, 2] >= 100)).astype(np.uint8)
    red = cv2.morphologyEx(red, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    contours, _ = cv2.findContours(red, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    height, width = frame.shape[:2]
    candidates = []
    for contour in contours:
        x, y, w, h = cv2.boundingRect(contour)
        side = round((w + h) / 2)
        if (side < 8 or side > min(width, height) / 5
                or abs(w - h) > side * 0.18
                or cv2.contourArea(contour) < side * side * 0.72
                or x + 5 * side > width or y + 5 * side > height):
            continue
        candidates.append((x, y, side))
    return candidates


def crop(frame: np.ndarray, box: tuple[int, int, int]) -> np.ndarray:
    x, y, marker_side = box
    side = marker_side * 5
    return frame[y:y + side, x:x + side]


def find_animation(frames: list[np.ndarray]) -> tuple[int, int, int]:
    candidates: list[tuple[int, int, int]] = []
    for frame in frames:
        for box in red_squares(frame):
            if not any(max(abs(a - b) for a, b in zip(box, other)) <= 4
                       for other in candidates):
                candidates.append(box)

    ranked = []
    for box in candidates:
        indices = [inspect_cell(crop(frame, box), "idx", 0).index for frame in frames]
        valid = [index for index in indices if index is not None and 0 <= index < 12]
        ranked.append((len(set(valid)), len(valid), box))
    if not ranked:
        raise RuntimeError("colored animation markers were not found")
    distinct, valid_count, best = max(ranked)
    if distinct < 3 or valid_count < max(3, len(frames) // 2):
        raise RuntimeError(f"animation marker pair is unconfirmed (distinct={distinct}, valid={valid_count})")
    return best


def read_discovery_frames(video: Path) -> tuple[list[np.ndarray], float]:
    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        raise RuntimeError(f"cannot open video: {video}")
    fps = capture.get(cv2.CAP_PROP_FPS)
    if not math.isfinite(fps) or fps <= 0:
        capture.release()
        raise RuntimeError("video has no usable frame rate")
    total = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    if total <= 0:
        capture.release()
        raise RuntimeError("video contains no frames")
    # Spread discovery across the recording so the right marker changes color.
    positions = set(np.linspace(0, total - 1, min(16, total), dtype=int).tolist())
    frames = []
    for position in sorted(positions):
        capture.set(cv2.CAP_PROP_POS_FRAMES, position)
        ok, frame = capture.read()
        if ok:
            frames.append(frame)
    capture.release()
    if len(frames) < 3:
        raise RuntimeError("too few frames available for marker discovery")
    return frames, fps


def check(video: Path) -> tuple[bool, str]:
    discovery, fps = read_discovery_frames(video)
    box = find_animation(discovery)
    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        raise RuntimeError(f"cannot reopen video: {video}")
    samples = []
    frame_number = 0
    last_time = -math.inf
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        time = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if not math.isfinite(time) or time <= last_time:
            time = (frame_number / fps if frame_number == 0 else last_time + 1 / fps)
        samples.append(inspect_cell(crop(frame, box), "idx", time))
        last_time = time
        frame_number += 1
    capture.release()
    if len(samples) < 2:
        raise RuntimeError("too few video samples")

    weights = sample_weights(samples, None)
    duration = sum(weights)
    blank = sum(weight for sample, weight in zip(samples, weights) if sample.blank)
    changes = []
    previous = None
    for sample in samples:
        if sample.index is None or not 0 <= sample.index < 12:
            continue
        if previous is not None and sample.index != previous:
            changes.append((sample.index - previous) % 12)
        previous = sample.index
    distinct = len({sample.index for sample in samples if sample.index is not None and 0 <= sample.index < 12})
    rate = len(changes) / duration if duration > 0 else 0
    plus_one = sum(step == 1 for step in changes) / len(changes) if changes else 0
    passed = rate >= 7 and plus_one >= 0.95 and distinct == 12 and blank <= 1.0
    x, y, marker_side = box
    message = (f"changes_per_s={rate:.2f} plus_one={plus_one * 100:.1f}% "
               f"frames={distinct}/12 blank_s={blank:.3f} "
               f"changes={len(changes)} duration_s={duration:.3f} "
               f"crop={x},{y},{marker_side * 5},{marker_side * 5}")
    return passed, message


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    args = parser.parse_args()
    try:
        passed, metrics = check(args.video)
    except Exception as exc:
        print(f"RESULT FAIL error={exc}")
        return 1
    print(f"RESULT {'PASS' if passed else 'FAIL'} {metrics}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
