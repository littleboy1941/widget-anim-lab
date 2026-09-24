#!/usr/bin/env python3
"""Build deterministic animated-image fixtures for WidgetLab's simulator tests."""

from __future__ import annotations

import argparse
from io import BytesIO
from pathlib import Path
import random
import struct

from PIL import Image, ImageDraw


def artwork(size: tuple[int, int], index: int, rgba: bool = False) -> Image.Image:
    mode = "RGBA" if rgba else "RGB"
    background = (25, 38, 64, 255) if rgba else (25, 38, 64)
    image = Image.new(mode, size, background)
    draw = ImageDraw.Draw(image)
    width, height = size
    for band in range(0, height, 24):
        color = ((band * 3 + index * 7) % 200 + 30,
                 (band * 5 + index * 11) % 180 + 35,
                 (band * 7 + index * 3) % 180 + 35)
        draw.rectangle((0, band, width, min(height, band + 11)),
                       fill=(*color, 255) if rgba else color)
    x = (index * 17) % max(1, width - 45)
    y = (index * 11) % max(1, height - 45)
    draw.ellipse((x, y, x + 44, y + 44),
                 fill=(245, 190, 45, 255) if rgba else (245, 190, 45))
    return image


def gif_image_block(image: Image.Image) -> bytes:
    """Encode one frame with its own local palette, suitable for a GIF subrect."""
    stream = BytesIO()
    image.convert("P", palette=Image.Palette.ADAPTIVE, colors=64).save(stream, format="GIF")
    data = stream.getvalue()
    packed = data[10]
    table_size = 3 * (1 << ((packed & 7) + 1)) if packed & 0x80 else 0
    table = data[13:13 + table_size]
    position = data.index(b"\x2c", 13 + table_size)
    descriptor = bytearray(data[position:position + 10])
    assert descriptor[0] == 0x2C and table
    descriptor[9] = 0x80 | (packed & 7)
    return bytes(descriptor) + table + data[position + 10:-1]


def partial_gif(path: Path, canvas: tuple[int, int], frames: list[tuple[Image.Image, int, int, int, int]]) -> None:
    """Write full logical canvas plus true offset image descriptors."""
    width, height = canvas
    output = bytearray(b"GIF89a" + struct.pack("<HHBBB", width, height, 0x70, 0, 0))
    for image, x, y, milliseconds, disposal in frames:
        block = bytearray(gif_image_block(image))
        block[1:5] = struct.pack("<HH", x, y)
        assert 0 <= x <= width - image.width and 0 <= y <= height - image.height
        delay = max(0, milliseconds // 10)
        output += b"\x21\xf9\x04" + bytes([(disposal & 7) << 2])
        output += struct.pack("<H", delay) + b"\x00\x00"
        output += block
    output.append(0x3B)
    path.write_bytes(output)


def make_4k(root: Path) -> None:
    canvas = (3840, 2160)
    noise = random.Random(0x51A7).randbytes(canvas[0] * canvas[1])
    base = Image.frombytes("L", canvas, noise).convert("RGB")
    draw = ImageDraw.Draw(base)
    for index in range(0, 30):
        x = index * 128
        draw.rectangle((x, 0, x + 28, canvas[1]), fill=(30, 55, 90))
    frames = [(base, 0, 0, 1000, 1)]
    for index in range(1, 30):
        tile = artwork((192, 128), index)
        x = (index * 127) % (canvas[0] - tile.width)
        y = (index * 83) % (canvas[1] - tile.height)
        frames.append((tile, x, y, 1000, 1))
    partial_gif(root / "4k_partial.gif", canvas, frames)


def make_many_gif(root: Path) -> None:
    delays = (0, 10, 20, 50, 500)
    frames = [(artwork((320, 240), index), 0, 0, delays[index % len(delays)], 1)
              for index in range(500)]
    partial_gif(root / "many_delays.gif", (320, 240), frames)


def make_disposal(root: Path) -> None:
    size = (320, 240)
    frames = []
    for index in range(12):
        tile = Image.new("RGB", (80, 70), (18, 35, 62))
        draw = ImageDraw.Draw(tile)
        draw.ellipse((5, 5, 65, 65), fill=(240, 50 + index * 12, 60))
        frames.append((tile, (index * 23) % 240, (index * 13) % 170,
                       100, 2 if index % 2 == 0 else 3))
    # Pillow's transparent GIF writer supplies a genuine transparency index and
    # per-frame disposal metadata; ImageIO must handle both disposal methods.
    images = []
    for tile, x, y, _, _ in frames:
        image = Image.new("RGBA", size, (0, 0, 0, 0))
        image.paste(tile, (x, y))
        images.append(image)
    images[0].save(root / "transparent_disposal.gif", save_all=True,
                   append_images=images[1:], duration=100, loop=0,
                   disposal=[frame[4] for frame in frames], transparency=0,
                   optimize=False)


def make_oversize(root: Path) -> None:
    frames = [(artwork((64, 64), index), index * 64, index * 64, 100, 1)
              for index in range(2)]
    partial_gif(root / "oversize_canvas.gif", (12000, 8000), frames)


def make_truncated(root: Path) -> None:
    # Two distinct frames; truncate halfway through the second image's payload.
    source = root / "truncated.gif"
    first = artwork((320, 240), 1)
    second = artwork((320, 240), 17)
    partial_gif(source, (320, 240), [(first, 0, 0, 100, 1),
                                     (second, 0, 0, 100, 1)])
    data = source.read_bytes()
    source.write_bytes(data[:len(data) // 2])


def make_apng_webp(root: Path) -> None:
    frames = [artwork((256, 192), index, rgba=True) for index in range(200)]
    frames[0].save(root / "many.apng", format="PNG", save_all=True,
                   append_images=frames[1:], duration=50, loop=0,
                   disposal=0, blend=0, optimize=False)
    frames[0].save(root / "many.webp", format="WEBP", save_all=True,
                   append_images=frames[1:], duration=50, loop=0,
                   quality=75, method=3)


def make_single(root: Path) -> None:
    artwork((320, 240), 3).save(root / "single.gif", format="GIF")


def make_long(root: Path) -> None:
    frames = [(artwork((320, 240), index), 0, 0, 1000, 1)
              for index in range(120)]
    partial_gif(root / "long_120s.gif", (320, 240), frames)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[1] / "StressFixtures")
    args = parser.parse_args()
    root = args.output
    root.mkdir(parents=True, exist_ok=True)
    make_4k(root)
    make_many_gif(root)
    make_disposal(root)
    make_oversize(root)
    make_truncated(root)
    make_apng_webp(root)
    make_single(root)
    make_long(root)
    for path in sorted(root.iterdir()):
        print(f"{path.name}: {path.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
