"""Generate tiny, deterministic animation fixtures and inspect their encoded frames."""

import json
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent / "Fixtures"
SIZE = (20, 20)
DURATIONS = [50, 100, 200, 10]
POINTS = [(0.1, 0.1), (0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7)]


def opaque_frames():
    colors = [(240, 40, 40), (40, 210, 60), (50, 80, 240), (230, 190, 30)]
    boxes = [(4, 4, 7, 7), (12, 4, 15, 7), (4, 12, 7, 15), (12, 12, 15, 15)]
    image = Image.new("RGB", SIZE, (24, 32, 48))
    result = []
    for color, box in zip(colors, boxes):
        image = image.copy()
        ImageDraw.Draw(image).rectangle(box, fill=color)
        result.append(image)
    return result


def transparent_frames():
    result = []
    for box in [(4, 4, 7, 7), (12, 4, 15, 7), (4, 12, 7, 15), (12, 12, 15, 15)]:
        image = Image.new("RGBA", SIZE, (0, 0, 0, 0))
        ImageDraw.Draw(image).ellipse(box, fill=(240, 40, 40, 255))
        result.append(image)
    return result


def inspect_partial_gif(path):
    # Pillow's tile is populated from GIF image descriptors, including offsets.
    with Image.open(path) as image:
        boxes = []
        for index in range(image.n_frames):
            image.seek(index)
            tile = image.tile[0]
            boxes.append(tuple(tile[1]))
            print(f"{path.name} frame {index}: GIF block {boxes[-1]}, disposal={image.disposal_method}")
    assert boxes[0] == (0, 0, *SIZE), boxes
    assert all((r - l) < SIZE[0] and (b - t) < SIZE[1]
               for l, t, r, b in boxes[1:]), boxes


def read_composited(path):
    webp_durations = webp_frame_durations(path) if path.suffix == ".webp" else None
    with Image.open(path) as image:
        frames = []
        durations = []
        for index in range(image.n_frames):
            image.seek(index)
            durations.append(webp_durations[index] if webp_durations is not None
                             else image.info["duration"])
            frames.append(image.convert("RGBA").copy())
    return frames, durations


def webp_frame_durations(path):
    # Pillow decodes animated WebP frames but does not expose ANMF durations.
    data = path.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    result = []
    offset = 12
    while offset + 8 <= len(data):
        kind = data[offset:offset + 4]
        length = int.from_bytes(data[offset + 4:offset + 8], "little")
        if kind == b"ANMF":
            assert length >= 16
            result.append(int.from_bytes(data[offset + 20:offset + 23], "little"))
        offset += 8 + length + (length & 1)
    return result


def expected_entry(path, original):
    frames, durations = read_composited(path)
    assert len(frames) == len(original) == 4, path
    assert durations == DURATIONS, (path, durations)
    for index, (actual, source) in enumerate(zip(frames, original)):
        assert actual.tobytes() == source.convert("RGBA").tobytes(), (path, index)
    return {
        "frameCount": len(frames),
        "durations": [max(ms / 1000, 0.1) if ms < 20 else ms / 1000
                      for ms in durations],
        "points": [
            [{"x": x, "y": y,
              "rgba": list(frame.getpixel((round(x * (SIZE[0] - 1)),
                                           round(y * (SIZE[1] - 1)))))}
             for x, y in POINTS]
            for frame in frames
        ],
    }


def main():
    ROOT.mkdir(exist_ok=True)
    opaque = opaque_frames()
    transparent = transparent_frames()

    # A shared palette makes optimize=True encode actual changed rectangles.
    palette = [0, 0, 0, 24, 32, 48, 240, 40, 40, 40, 210, 60,
               50, 80, 240, 230, 190, 30] + [0, 0, 0] * 250
    indexed = []
    for frame in opaque:
        image = Image.new("P", SIZE)
        image.putpalette(palette)
        lookup = {(24, 32, 48): 1, (240, 40, 40): 2,
                  (40, 210, 60): 3, (50, 80, 240): 4,
                  (230, 190, 30): 5}
        pixels = frame.load()
        image.putdata([lookup[pixels[x, y]] for y in range(SIZE[1])
                       for x in range(SIZE[0])])
        indexed.append(image)
    partial = ROOT / "partial.gif"
    indexed[0].save(partial, save_all=True, append_images=indexed[1:],
                    duration=DURATIONS, loop=0, disposal=1, optimize=True)
    inspect_partial_gif(partial)

    disposal = ROOT / "disposal2.gif"
    transparent[0].save(disposal, save_all=True,
                        append_images=transparent[1:], duration=DURATIONS,
                        loop=0, disposal=2, optimize=True, transparency=0)
    with Image.open(disposal) as image:
        for index in range(image.n_frames):
            image.seek(index)
            assert image.disposal_method == 2, (disposal, index, image.disposal_method)

    apng = ROOT / "anim.png"
    opaque[0].save(apng, save_all=True, append_images=opaque[1:],
                   duration=DURATIONS, loop=0, disposal=0, blend=0)

    webp = ROOT / "anim.webp"
    opaque[0].save(webp, save_all=True, append_images=opaque[1:],
                   duration=DURATIONS, loop=0, lossless=True, quality=100,
                   method=6)

    entries = {
        "partial.gif": expected_entry(partial, opaque),
        "disposal2.gif": expected_entry(disposal, transparent),
        "anim.png": expected_entry(apng, opaque),
        "anim.webp": expected_entry(webp, opaque),
    }
    with (ROOT / "expected.json").open("w", encoding="utf-8", newline="\n") as output:
        json.dump(entries, output, indent=2)
        output.write("\n")
    print("Verified four decoded animations and wrote expected.json")


if __name__ == "__main__":
    main()
