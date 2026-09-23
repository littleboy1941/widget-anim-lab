"""Генератор шрифтов для анимации виджета на публичных API (приём Bryce Bostwick).

Как это работает в виджете:
- `Text(date, style: .timer)` система перерисовывает сама раз в секунду. Последние
  две цифры таймера — секунды 00..59. Лигатура из этих двух цифр заменяется одним
  цветным SVG-глифом — кадром.
- Чтобы получить FPS кадров в секунду, кладём стопкой P = 2*FPS таймеров, сдвинутых
  на 1/FPS секунды. Таймер фазы i тикает в момент i/FPS.
- Мигающий шрифт: две цифры секунд -> сплошной квадрат, если секунда чётная, иначе пусто.
  Две маски из мигающих таймеров оставляют таймер фазы i видимым ровно 1/FPS секунды
  за двухсекундный цикл: [i/FPS, (i+1)/FPS) mod 2. Так прозрачные кадры не просвечивают
  друг через друга.
- Глобальный номер кадра g = floor(FPS*t) = P*k + i, где k = n/2, n — чётное число секунд
  на таймере фазы i. Кадр = g mod L. Чтобы при переходе 59 -> 00 не было скачка,
  нужно P*30 делится на L (для 8 fps: L делит 480).

Вариант с картинками: шрифт только мигающая маска (WABlink<C>), кадры — обычные Image.
Маска фазы i = пересечение двух мигающих таймеров, цикл C секунд, P = C*FPS фаз.

Запуск: python fontgen.py --fps 8 --out Fonts --png-out Frames   (тестовые кадры)
        python fontgen.py --fps 8 --out Fonts a.png b.png   (свои кадры, одинакового размера)
"""
import argparse
import colorsys
import math
import os
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.S_V_G_ import SVGDocument
from PIL import Image, ImageDraw

DIGITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
TEST_SIZE = 32


def marker_colors(n):
    """n различимых насыщенных цветов для метки номера кадра."""
    out = []
    for k in range(n):
        r, g, b = colorsys.hsv_to_rgb(k / n, 1.0, 1.0)
        out.append((round(r * 255), round(g * 255), round(b * 255)))
    return out


def make_test_frames(count):
    """Тестовая анимация: цветная метка номера кадра слева сверху и шарик по кругу.
    Фон прозрачный, чтобы было видно, если кадры просвечивают друг через друга."""
    frames = []
    for k, color in enumerate(marker_colors(count)):
        im = Image.new("RGBA", (TEST_SIZE, TEST_SIZE), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        d.rectangle([0, 0, 9, 9], fill=color + (255,))
        a = 2 * math.pi * k / count
        cx, cy = 20 + 8 * math.cos(a), 20 + 8 * math.sin(a)
        d.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], fill=(40, 40, 40, 255))
        frames.append(im)
    return frames


def frame_svg(im, gid, em):
    """Пиксель-арт в SVG: по одному path на цвет, горизонтальные отрезки строк."""
    w, h = im.size
    unit = em / w
    px = im.load()
    runs = {}
    for y in range(h):
        x = 0
        while x < w:
            r, g, b, a = px[x, y]
            if a < 128:
                x += 1
                continue
            x0 = x
            while x < w and px[x, y][:3] == (r, g, b) and px[x, y][3] >= 128:
                x += 1
            runs.setdefault((r, g, b), []).append((x0, y, x - x0))
    paths = []
    for (r, g, b), segs in runs.items():
        dd = "".join(
            f"M{x0 * unit:g} {y * unit:g}h{n * unit:g}v{unit:g}h{-n * unit:g}z"
            for x0, y, n in segs
        )
        paths.append(f'<path fill="#{r:02x}{g:02x}{b:02x}" d="{dd}"/>')
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{em}" height="{em}" id="glyph{gid}">'
        f'<g transform="translate(0 -{em})">{"".join(paths)}</g></svg>'
    )


def empty_glyph():
    return TTGlyphPen(None).glyph()


def square_glyph(em):
    pen = TTGlyphPen(None)
    pen.moveTo((0, 0))
    pen.lineTo((0, em))
    pen.lineTo((em, em))
    pen.lineTo((em, 0))
    pen.closePath()
    return pen.glyph()


def build_font(path, family, em, extra_glyphs, liga, svg_docs=None):
    """extra_glyphs: {имя: glyf-глиф}; liga: {(a, b): имя глифа}; svg_docs: {имя: svg}."""
    base = [".notdef", "space"] + DIGITS + ["colon"]
    order = base + list(extra_glyphs)
    glyphs = {g: empty_glyph() for g in base}
    glyphs.update(extra_glyphs)

    fb = FontBuilder(em, isTTF=True)
    fb.setupGlyphOrder(order)
    cmap = {ord(" "): "space", ord(":"): "colon", 0xA0: "space"}
    cmap.update({ord(str(d)): DIGITS[d] for d in range(10)})
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    # Каждый глиф шириной в em: последний глиф таймера всегда у правого края.
    fb.setupHorizontalMetrics({g: (em, 0) for g in order})
    fb.setupHorizontalHeader(ascent=em, descent=0)
    fb.setupNameTable({"familyName": family, "styleName": "Regular",
                       "psName": f"{family}-Regular"})
    fb.setupOS2(sTypoAscender=em, sTypoDescender=0, sTypoLineGap=0,
                usWinAscent=em, usWinDescent=0)
    fb.setupPost()
    rules = "\n".join(f"  sub {DIGITS[a]} {DIGITS[b]} by {g};" for (a, b), g in sorted(liga.items()))
    fb.addOpenTypeFeatures(
        "languagesystem DFLT dflt;\nlanguagesystem latn dflt;\n"
        f"feature liga {{\n{rules}\n}} liga;\n"
    )
    if svg_docs:
        table = newTable("SVG ")
        table.docList = []
        for name, svg in svg_docs.items():
            gid = order.index(name)
            table.docList.append(SVGDocument(svg.replace("{gid}", str(gid)), gid, gid, False))
        table.docList.sort(key=lambda d: d.startGlyphID)
        fb.font["SVG "] = table
    fb.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fps", type=int, default=8)
    ap.add_argument("--frames", type=int, default=12, help="число тестовых кадров")
    ap.add_argument("--out", default="Fonts")
    ap.add_argument("--prefix", default="WAFrame")
    ap.add_argument("--blink", type=int, nargs="*", default=[2, 3], help="циклы мигающих масок, с")
    ap.add_argument("--png-out", help="куда сохранить кадры PNG (вариант с картинками)")
    ap.add_argument("images", nargs="*")
    args = ap.parse_args()

    frames = [Image.open(p).convert("RGBA") for p in args.images] or make_test_frames(args.frames)
    L = len(frames)
    P = 2 * args.fps
    if (P * 30) % L:
        sys.exit(f"{L} кадров не укладываются в минутный цикл: {P}*30 должно делиться на L")
    em = frames[0].size[0] * 16
    os.makedirs(args.out, exist_ok=True)

    for i in range(P):
        extra, liga, svgs = {"empty": empty_glyph()}, {}, {}
        for a in range(6):
            for b in range(10):
                n = 10 * a + b
                if n % 2:
                    liga[(a, b)] = "empty"
                    continue
                f = (P * (n // 2) + i) % L
                name = f"fr{f}"
                if name not in extra:
                    extra[name] = empty_glyph()
                    svgs[name] = frame_svg(frames[f], "{gid}", em)
                liga[(a, b)] = name
        build_font(os.path.join(args.out, f"{args.prefix}{i}.ttf"), f"{args.prefix}{i}", em, extra, liga, svgs)

    # Мигающие шрифты-маски: квадрат, если число секунд делится на C, иначе пусто.
    # Две цифры секунд дают n mod 60, поэтому C должно делить 60.
    for c in args.blink:
        if 60 % c:
            sys.exit(f"цикл мигания {c} не делит 60")
        blink_liga = {(a, b): ("full" if (10 * a + b) % c == 0 else "empty")
                      for a in range(6) for b in range(10)}
        build_font(os.path.join(args.out, f"WABlink{c}.ttf"), f"WABlink{c}", em,
                   {"full": square_glyph(em), "empty": empty_glyph()}, blink_liga)

    if args.png_out:
        os.makedirs(args.png_out, exist_ok=True)
        for k, im in enumerate(frames):
            im.save(os.path.join(args.png_out, f"frame_{k}.png"))

    colors = marker_colors(L)
    print(f"fps={args.fps} phases={P} frames={L} em={em}")
    print("markers=" + ";".join(f"{r},{g},{b}" for r, g, b in colors))


if __name__ == "__main__":
    main()
