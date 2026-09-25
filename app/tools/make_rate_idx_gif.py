"""Исходник для теста мигания на телефоне: app/Resources/rate_idx.gif.

30 непрозрачных кадров 240×240. Метки номера кадра в углах — как в probe/make_frames.py
(разбор probe/analyze_cells.py, режим idx), шарик по кругу, крупный номер кадра в верхней
полосе (разбор ищет шарик только ниже 29 % высоты, номер ему не мешает).
Кнопка «Тест мигания» в приложении берёт первые fps кадров: петля 1 с, N = fps, C = 2.
Фон светлый и непрозрачный: пропавший кадр виден как стекло виджета, метки исчезают.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "probe"))
from make_frames import PALETTE  # noqa: E402

COUNT = 30
SIZE = 240
BACKGROUND = (205, 205, 205)


def frame(index: int) -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE), BACKGROUND)
    draw = ImageDraw.Draw(image)
    marker = SIZE // 5
    draw.rectangle((0, 0, marker - 1, marker - 1), fill=PALETTE[index // 16])
    draw.rectangle((SIZE - marker, 0, SIZE - 1, marker - 1), fill=PALETTE[index % 16])

    font = ImageFont.load_default(size=round(SIZE * 0.2))
    draw.text((SIZE / 2, SIZE * 0.14), f"{index:02d}", fill=(0, 0, 0), font=font, anchor="mm")

    angle = 2 * math.pi * index / COUNT
    radius = SIZE * 0.19
    cx = SIZE * 0.5 + radius * math.cos(angle)
    cy = SIZE * 0.69 + radius * math.sin(angle)
    ball = SIZE / 12
    draw.ellipse((round(cx - ball), round(cy - ball), round(cx + ball), round(cy + ball)),
                 fill=(40, 40, 40))
    return image


def main() -> None:
    out = Path(__file__).resolve().parents[1] / "Resources" / "rate_idx.gif"
    frames = [frame(i) for i in range(COUNT)]
    # задержка не важна: пресет задаёт слоты вручную, частоту — планом
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=100, loop=0,
                   optimize=False, disposal=1)
    print(f"Wrote {COUNT} frames to {out}")


if __name__ == "__main__":
    main()
