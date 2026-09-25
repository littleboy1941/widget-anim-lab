"""Measure numbered animation frames in cropped simulator screen recordings."""

from __future__ import annotations

import argparse
import colorsys
import math
import statistics
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from make_frames import PALETTE as IDX_PALETTE


M12_PALETTE = tuple(
    tuple(round(channel * 255) for channel in colorsys.hsv_to_rgb(k / 12, 1, 1))
    for k in range(12)
)


@dataclass(frozen=True)
class Cell:
    name: str
    x: int
    y: int
    width: int
    height: int
    mode: str


@dataclass
class Sample:
    time: float
    index: int | None
    blank: bool
    ball_area: int
    mixed_marker: bool
    doubled: bool = False


def parse_cell(spec: str) -> Cell:
    try:
        name, geometry, *mode = spec.split(":")
        x, y, width, height = (int(v) for v in geometry.split(","))
        selected = mode[0] if mode else "m12"
        if not name or len(mode) > 1 or selected not in ("m12", "idx", "idx3"):
            raise ValueError
        if min(x, y) < 0 or min(width, height) <= 0:
            raise ValueError
        return Cell(name, x, y, width, height, selected)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "cell must be NAME:x,y,w,h[:m12|idx|idx3] with positive dimensions"
        ) from exc


def palette_lab(palette: tuple[tuple[int, int, int], ...]) -> np.ndarray:
    rgb = np.asarray(palette, dtype=np.uint8)[None, :, :]
    return cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)[0].astype(np.float32)


LAB_PALETTES = {"m12": palette_lab(M12_PALETTE),
                "idx": palette_lab(IDX_PALETTE), "idx3": palette_lab(IDX_PALETTE)}


def marker(
    bgr: np.ndarray, bounds: tuple[float, float, float, float], mode: str
) -> tuple[int | None, bool, bool]:
    """Return palette entry, whether ink is present, and whether colors mix."""
    height, width = bgr.shape[:2]
    x0, y0, x1, y1 = bounds
    patch = bgr[
        max(0, round(y0 * height)):min(height, round(y1 * height)),
        max(0, round(x0 * width)):min(width, round(x1 * width)),
    ]
    if patch.size == 0:
        return None, False, False

    hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
    colored = (hsv[:, :, 1] >= 60) & (hsv[:, :, 2] >= 65)
    present = float(np.mean(colored)) >= 0.55
    if not present:
        return None, False, False

    lab = cv2.cvtColor(patch, cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(np.float32)
    palette = LAB_PALETTES[mode]
    distance = np.linalg.norm(lab[:, None, :] - palette[None, :, :], axis=2)
    nearest = np.argmin(distance, axis=1)
    best = int(np.bincount(nearest, minlength=len(palette)).argmax())
    best_pixels = np.count_nonzero(nearest == best)
    runner_pixels = max(
        (np.count_nonzero(nearest == k) for k in range(len(palette)) if k != best),
        default=0,
    )
    # A second solid color in the interior of a marker is useful evidence of
    # overlap. Codec noise at its edges is excluded by sampling only its core.
    mixed = mode in ("idx", "idx3") and runner_pixels > 0.16 * len(nearest) and best_pixels < 0.80 * len(nearest)
    return best, True, mixed


def inspect_cell(bgr: np.ndarray, mode: str, time: float) -> Sample:
    if mode == "m12":
        major, present, _ = marker(bgr, (0.08, 0.08, 0.24, 0.24), mode)
        index = major
        blank = not present
        mixed = False
    elif mode == "idx":
        major, left, mixed_left = marker(bgr, (0.04, 0.04, 0.16, 0.16), mode)
        minor, right, mixed_right = marker(bgr, (0.84, 0.04, 0.96, 0.16), mode)
        index = 16 * major + minor if left and right and major is not None and minor is not None else None
        blank = not left and not right
        mixed = mixed_left or mixed_right
    else:
        readings = [marker(bgr, (center - 0.035, 0.025, center + 0.035, 0.115), mode)
                    for center in (0.25, 0.50, 0.75)]
        digits = [reading[0] for reading in readings]
        index = (256 * digits[0] + 16 * digits[1] + digits[2]
                 if all(digit is not None for digit in digits) else None)
        blank = not any(reading[1] for reading in readings)
        mixed = any(reading[2] for reading in readings)

    # The moving ball is near neutral gray. Limit this search to the area below
    # the markers so dark palette entries never contribute to its area.
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    background = float(np.median(gray))
    dark = (gray < min(130, background - 55)) & (hsv[:, :, 1] < 85)
    dark[:round(bgr.shape[0] * 0.29), :] = False
    area = int(np.count_nonzero(dark))
    return Sample(time, index, blank, area, mixed)


def finalize_doubles(samples: list[Sample]) -> tuple[float, float]:
    single_areas = [s.ball_area for s in samples if s.index is not None and s.ball_area > 0]
    if not single_areas:
        return 0, 0
    # The lower half limits the influence of overlap frames. Completely hidden
    # overlapping images cannot be detected from a rendered video.
    baseline = float(np.median(np.partition(single_areas, len(single_areas) // 2)[:len(single_areas) // 2 + 1]))
    threshold = baseline * 1.18
    for sample in samples:
        sample.doubled = sample.mixed_marker or (
            sample.index is not None and sample.ball_area > threshold
        )
    return baseline, threshold


def sample_weights(samples: list[Sample], end: float | None) -> list[float]:
    gaps = [b.time - a.time for a, b in zip(samples, samples[1:]) if b.time > a.time]
    last_gap = statistics.median(gaps) if gaps else 0.0
    times = [sample.time for sample in samples]
    weights = [max(0.0, b - a) for a, b in zip(times, times[1:])]
    weights.append(max(0.0, min(times[-1] + last_gap, end) - times[-1]) if end is not None else last_gap)
    return weights


def describe(name: str, samples: list[Sample], frame_count: int, end: float | None) -> None:
    if not samples:
        print(f"{name}: нет кадров видео в заданном интервале")
        return
    finalize_doubles(samples)
    weights = sample_weights(samples, end)
    duration = sum(weights)
    blank_time = sum(weight for sample, weight in zip(samples, weights) if sample.blank)
    doubled_time = sum(weight for sample, weight in zip(samples, weights) if sample.doubled)
    double_episodes = sum(
        sample.doubled and (i == 0 or not samples[i - 1].doubled)
        for i, sample in enumerate(samples)
    )
    unknown_time = sum(
        weight for sample, weight in zip(samples, weights)
        if sample.index is None and not sample.blank
    )

    changes: list[tuple[float, int]] = []
    previous: int | None = None
    for sample in samples:
        if sample.index is None:
            continue
        if previous is not None and sample.index != previous:
            changes.append((sample.time, (sample.index - previous) % frame_count))
        previous = sample.index
    good = sum(step == 1 for _, step in changes)
    skips = sum(1 < step <= frame_count // 2 for _, step in changes)
    backwards = sum(step > frame_count // 2 for _, step in changes)
    gaps = [b[0] - a[0] for a, b in zip(changes, changes[1:])]
    distinct = len({s.index for s in samples if s.index is not None})
    print(
        f"{name}: {duration:.3f} с, смен {len(changes)} "
        f"({len(changes) / duration if duration else 0:.2f}/с), "
        f"+1 {good}/{len(changes)} ({100 * good / len(changes) if changes else 0:.1f}%), "
        f"пропусков {skips}, назад {backwards}, живых кадров {distinct}/{frame_count}"
    )
    print(
        f"  интервалы: медиана {statistics.median(gaps) if gaps else 0:.3f} с, "
        f"максимум {max(gaps, default=0):.3f} с; "
        f"пусто {blank_time:.3f} с, двоение {doubled_time:.3f} с "
        f"({double_episodes} эп.), неопределённо {unknown_time:.3f} с"
    )


def dump_frame(video: Path, seconds: float, output: Path) -> None:
    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        raise RuntimeError(f"cannot open video: {video}")
    capture.set(cv2.CAP_PROP_POS_MSEC, seconds * 1000)
    ok, frame = capture.read()
    time = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
    capture.release()
    if not ok or not cv2.imwrite(str(output), frame):
        raise RuntimeError(f"cannot save video frame to {output}")
    print(f"Сохранён кадр {time:.3f} с: {output} ({frame.shape[1]}x{frame.shape[0]})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--cell", nargs="+", action="extend", type=parse_cell, default=[])
    parser.add_argument("--dump-frame", nargs=2, metavar=("SEC", "OUT.png"))
    parser.add_argument("--start", type=float, default=0)
    parser.add_argument("--end", type=float)
    parser.add_argument("--frames", type=int, help="idx cycle length; otherwise infer max observed index + 1")
    args = parser.parse_args()
    if args.start < 0 or args.end is not None and args.end <= args.start:
        parser.error("time range must satisfy 0 <= --start < --end")
    if args.frames is not None and not 1 <= args.frames <= 4096:
        parser.error("--frames must be between 1 and 4096")
    if not args.cell and not args.dump_frame:
        parser.error("specify at least one --cell or --dump-frame")

    if args.dump_frame:
        seconds, output = args.dump_frame
        dump_frame(args.video, float(seconds), Path(output))
    if not args.cell:
        return

    capture = cv2.VideoCapture(str(args.video))
    if not capture.isOpened():
        parser.error(f"cannot open video: {args.video}")
    video_width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    video_height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    for cell in args.cell:
        if cell.x + cell.width > video_width or cell.y + cell.height > video_height:
            parser.error(f"{cell.name}: rectangle exceeds {video_width}x{video_height} video")
    results: dict[Cell, list[Sample]] = {cell: [] for cell in args.cell}
    last_time = -math.inf
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        time = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if not math.isfinite(time):
            parser.error("CAP_PROP_POS_MSEC is not finite")
        if time <= last_time:
            # запись симулятора изредка даёт повтор метки времени — кадр пропускаем
            continue
        last_time = time
        if time < args.start:
            continue
        if args.end is not None and time >= args.end:
            break
        for cell, samples in results.items():
            crop = frame[cell.y:cell.y + cell.height, cell.x:cell.x + cell.width]
            samples.append(inspect_cell(crop, cell.mode, time))
    capture.release()

    for cell, samples in results.items():
        if cell.mode == "m12":
            frame_count = 12
        elif args.frames is not None:
            frame_count = args.frames
            if any(s.index is not None and s.index >= frame_count for s in samples):
                parser.error(f"{cell.name}: detected an index outside --frames {frame_count}")
        else:
            frame_count = max((s.index for s in samples if s.index is not None), default=-1) + 1
            print(f"{cell.name}: --frames не задан, длина цикла определена как {frame_count}")
        if frame_count:
            describe(cell.name, samples, frame_count, args.end)
        else:
            print(f"{cell.name}: меток не обнаружено")


if __name__ == "__main__":
    main()
