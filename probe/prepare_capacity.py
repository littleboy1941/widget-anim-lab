"""Generate one matrix variant's numbered PNGs into optional CapacityFrames."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from make_frames import make_capacity_frame

MODE = re.compile(r"p(?P<fps>\d+)n(?P<count>\d+)s(?P<size>\d+)k(?P<radius>\d+)(?:g(?P<group>\d+))?")
ROOT = Path(__file__).resolve().parent


def parse_mode(raw: str) -> dict[str, int]:
    match = MODE.fullmatch(raw)
    if match is None:
        raise ValueError("mode must be p{fps}n{count}s{size}k{radius}[g{group}]")
    values = {key: int(value) for key, value in match.groupdict(default="0").items()}
    if not (1 <= values["fps"] <= 120 and 1 <= values["count"] <= 4096
            and 32 <= values["size"] <= 320 and values["radius"] > 0
            and values["group"] >= 0):
        raise ValueError("mode values out of range")
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode")
    args = parser.parse_args()
    try:
        mode = parse_mode(args.mode)
    except ValueError as exc:
        parser.error(str(exc))
    output = ROOT / "CapacityFrames"
    output.mkdir(exist_ok=True)
    for index in range(mode["count"]):
        make_capacity_frame(index, mode["count"], mode["size"]).save(
            output / f"cap_{index}.png", optimize=True
        )
    print(f"{args.mode}: wrote {mode['count']} frames to {output}")


if __name__ == "__main__":
    main()
